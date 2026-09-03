import Foundation

/// Web API 路由：把 HTTP 请求分发到任务队列 / 文档库 / LLM 服务。
/// AppState 是 MainActor，所有访问都通过 MainActor.run 跳入。
final class WebAPIRouter {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    /// 在主 actor 上读取/操作 AppState
    private func onMain<T>(_ work: @MainActor (AppState) throws -> T) async throws -> T {
        guard let appState else { throw RouterError.unavailable }
        return try await MainActor.run { try work(appState) }
    }

    enum RouterError: LocalizedError {
        case unavailable
        var errorDescription: String? { "服务不可用" }
    }

    // MARK: - 路由

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // CORS 预检
        if request.method == "OPTIONS" {
            return HTTPResponse(statusCode: 200, headers: [
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, X-File-Name"
            ], body: Data())
        }

        let path = request.path
        let method = request.method

        // 参数化路径：/api/tasks/{id}、/api/tasks/{id}/download、/api/documents/{id}
        let components = path.split(separator: "/").map(String.init)
        if method == "GET", components.count >= 3, components[1] == "api" {
            if components[2] == "tasks", components.count >= 4, let id = UUID(uuidString: components[3]) {
                if components.count == 5, components[4] == "download" {
                    return await taskDownload(id: id)
                }
                if components.count == 4 {
                    return await taskDetail(id: id)
                }
            }
            if components[2] == "documents", components.count == 4, let id = UUID(uuidString: components[3]) {
                return await documentDetail(id: id)
            }
        }

        switch (method, path) {
        case ("GET", "/"):
            return .text(WebPage.html, contentType: "text/html; charset=utf-8")

        case ("GET", "/api/status"):
            return await handleStatus()

        case ("GET", "/api/llm/providers"):
            return await handleProviders()

        case ("GET", "/api/tasks"):
            return await taskList()

        case ("GET", "/api/documents"):
            return await documentList()

        case ("POST", "/api/ocr"):
            return await enqueueTask(request, kind: .ocr)

        case ("POST", "/api/pdf-to-word"):
            return await enqueueTask(request, kind: .pdfToWord)

        case ("POST", "/api/chat"):
            return await handleChat(request)

        default:
            return .error(404, "接口不存在：\(method) \(path)")
        }
    }

    // MARK: - 状态

    private func handleStatus() async -> HTTPResponse {
        do {
            let payload = try await onMain { appState -> [String: Any] in
                let settings = appState.settings
                let ocrReady: Bool = {
                    switch settings.ocrEngine {
                    case .localMLX: return appState.mlxManager.state == .running
                    case .baiduCloud: return !settings.baiduAPIKey.isEmpty
                    }
                }()
                return [
                    "app": "DocuMind",
                    "version": "1.2.0",
                    "ocrConfigured": ocrReady,
                    "ocrEngine": settings.ocrEngine == .localMLX ? "本地 Unlimited-OCR" : "百度云 OCR",
                    "engineState": appState.mlxManager.state.displayText,
                    "providers": settings.llmProviders.filter { $0.enabled }.map { $0.name }
                ]
            }
            return .json(payload)
        } catch {
            return .error(500, error.readableMessage)
        }
    }

    private func handleProviders() async -> HTTPResponse {
        do {
            let list = try await onMain { appState in
                appState.settings.llmProviders
                    .filter { $0.enabled }
                    .map { ["name": $0.name, "model": $0.model, "protocol": $0.protocolKind.rawValue, "hasKey": !$0.apiKey.isEmpty] as [String: Any] }
            }
            return .json(["providers": list])
        } catch {
            return .error(500, error.readableMessage)
        }
    }

    // MARK: - 任务

    private func enqueueTask(_ request: HTTPRequest, kind: TaskKind) async -> HTTPResponse {
        guard !request.body.isEmpty else { return .error(400, "请求体为空：请上传文件") }
        let fileName = sanitizedFileName(request.header("x-file-name") ?? "upload.bin")
        let body = request.body
        do {
            let taskID = try await onMain { appState -> UUID in
                switch kind {
                case .ocr:
                    return try appState.taskQueue.enqueueOCR(data: body, fileName: fileName)
                case .pdfToWord:
                    guard DocumentKind(fileExtension: (fileName as NSString).pathExtension) == .pdf else {
                        throw DocumentProcessError.unsupportedType
                    }
                    return try appState.taskQueue.enqueueConvert(data: body, fileName: fileName)
                }
            }
            return .json(["task_id": taskID.uuidString, "status": "pending"])
        } catch {
            return .error(400, error.readableMessage)
        }
    }

    private func taskList() async -> HTTPResponse {
        do {
            let tasks = try await onMain { $0.taskQueue.tasks.map(taskJSON) }
            return .json(["tasks": tasks])
        } catch {
            return .error(500, error.readableMessage)
        }
    }

    private func taskDetail(id: UUID) async -> HTTPResponse {
        do {
            let payload = try await onMain { appState -> [String: Any]? in
                guard let task = try? appState.store.task(id) else { return nil }
                var json = self.taskJSON(task)
                if task.kind == .ocr, task.state == .success,
                   let text = appState.taskQueue.resultText(for: task) {
                    json["text"] = text
                }
                if task.state == .success, task.outputPath != nil {
                    json["download_url"] = "/api/tasks/\(id.uuidString)/download"
                }
                return json
            }
            guard let payload else { return .error(404, "任务不存在") }
            return .json(payload)
        } catch {
            return .error(500, error.readableMessage)
        }
    }

    private func taskDownload(id: UUID) async -> HTTPResponse {
        do {
            let info = try await onMain { appState -> (String, String, String)? in
                guard let task = try? appState.store.task(id) else { return nil }
                if task.kind == .pdfToWord, let path = task.outputPath {
                    return (path,
                            task.outputName ?? "output.docx",
                            "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
                }
                if task.kind == .ocr, let text = appState.taskQueue.resultText(for: task) {
                    // OCR 任务下载为 txt：写到临时文件返回
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("documind-dl-\(id.uuidString).txt")
                    try? Data(text.utf8).write(to: tmp)
                    let name = (task.fileName as NSString).deletingPathExtension + ".txt"
                    return (tmp.path, name, "text/plain; charset=utf-8")
                }
                return nil
            }
            guard let (path, name, contentType),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                return .error(404, "产物不存在或任务未完成")
            }
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "download"
            return HTTPResponse(statusCode: 200, headers: [
                "Content-Type": contentType,
                "Content-Disposition": "attachment; filename=\"download\"; filename*=UTF-8''\(encoded)"
            ], body: data)
        } catch {
            return .error(500, error.readableMessage)
        }
    }

    // MARK: - 文档库

    private func documentList() async -> HTTPResponse {
        do {
            let docs = try await onMain { appState in
                ((try? appState.store.listDocuments()) ?? []).map { doc -> [String: Any] in
                    let versions = (try? appState.store.versions(of: doc.id)) ?? []
                    let hasResult = (try? appState.store.latestOCRResult(of: doc.id)) != nil
                    return [
                        "id": doc.id.uuidString,
                        "name": doc.name,
                        "kind": doc.kind.rawValue,
                        "kind_name": doc.kind.displayName,
                        "created_at": ISO8601DateFormatter().string(from: doc.createdAt),
                        "versions": versions.count,
                        "has_ocr_result": hasResult
                    ]
                }
            }
            return .json(["documents": docs])
        } catch {
            return .error(500, error.readableMessage)
        }
    }

    private func documentDetail(id: UUID) async -> HTTPResponse {
        do {
            let payload = try await onMain { appState -> [String: Any]? in
                guard let doc = try? appState.store.document(id: id) else { return nil }
                let versions = (try? appState.store.versions(of: doc.id)) ?? []
                let result = try? appState.store.latestOCRResult(of: doc.id)
                var json: [String: Any] = [
                    "id": doc.id.uuidString,
                    "name": doc.name,
                    "kind": doc.kind.rawValue,
                    "kind_name": doc.kind.displayName,
                    "created_at": ISO8601DateFormatter().string(from: doc.createdAt),
                    "versions": versions.map {
                        ["version": $0.versionNo, "size": $0.fileSize,
                         "created_at": ISO8601DateFormatter().string(from: $0.createdAt)] as [String: Any]
                    }
                ]
                if let result {
                    json["engine"] = result.engine
                    json["page_count"] = result.pageCount
                    json["text"] = result.text
                }
                return json
            }
            guard let payload else { return .error(404, "文档不存在") }
            return .json(payload)
        } catch {
            return .error(500, error.readableMessage)
        }
    }

    // MARK: - LLM 对话（同步，非流式）

    private func handleChat(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let rawMessages = json["messages"] as? [[String: Any]] else {
            return .error(400, "请求格式错误：需要 JSON {messages: [{role, content}]}")
        }

        do {
            let config = try await onMain { appState -> LLMProviderConfig in
                let settings = appState.settings
                let requestedName = json["provider"] as? String
                let provider: LLMProviderConfig?
                if let name = requestedName {
                    provider = settings.llmProviders.first { $0.enabled && $0.name == name }
                } else {
                    provider = settings.activeProvider
                }
                guard let config = provider else {
                    throw LLMError.noProviderConfigured
                }
                guard !config.apiKey.isEmpty else {
                    throw LLMError.apiError("服务商「\(config.name)」尚未填写 API Key")
                }
                return config
            }

            let messages: [ChatMessage] = rawMessages.compactMap { item in
                guard let roleStr = item["role"] as? String,
                      let role = ChatRole(rawValue: roleStr),
                      let content = item["content"] as? String else { return nil }
                return ChatMessage(role: role, content: content)
            }
            guard !messages.isEmpty else { return .error(400, "messages 为空") }

            let client = LLMClientFactory.client(for: config)
            let reply = try await client.chat(messages: messages, config: config)
            return .json(["reply": reply, "provider": config.name, "model": config.model])
        } catch {
            return .error(500, error.readableMessage)
        }
    }

    // MARK: - 工具

    private func taskJSON(_ task: TaskRecord) -> [String: Any] {
        var json: [String: Any] = [
            "id": task.id.uuidString,
            "kind": task.kind.rawValue,
            "kind_name": task.kind.displayName,
            "file_name": task.fileName,
            "status": task.state.rawValue,
            "progress": task.progress,
            "message": task.message,
            "engine": task.engine,
            "created_at": ISO8601DateFormatter().string(from: task.createdAt),
            "updated_at": ISO8601DateFormatter().string(from: task.updatedAt)
        ]
        if let error = task.error { json["error"] = error }
        if task.state == .success, task.outputPath != nil {
            json["download_url"] = "/api/tasks/\(task.id.uuidString)/download"
        }
        return json
    }

    private func sanitizedFileName(_ name: String) -> String {
        // 前端用 encodeURIComponent 编码（HTTP 头不能直接携带非 ASCII 字符）
        let decoded = name.removingPercentEncoding ?? name
        let cleaned = decoded.components(separatedBy: CharacterSet(charactersIn: "/\\?%*:|\"<>")).joined()
        return cleaned.isEmpty ? "upload.bin" : cleaned
    }
}
