import Foundation

/// Web API 路由：把 HTTP 请求分发到 OCR / 转换 / LLM 服务。
/// 与 SwiftUI 界面共用同一套服务实例。
final class WebAPIRouter {
    /// 依赖注入：由 AppState 提供（始终读取最新配置）
    let settingsProvider: @Sendable () -> AppSettings

    init(settingsProvider: @escaping @Sendable () -> AppSettings) {
        self.settingsProvider = settingsProvider
    }

    /// 按当前设置即时构建文档处理器（配置修改后下次请求即生效）
    private func makeProcessor() -> DocumentProcessor {
        let s = settingsProvider()
        return DocumentProcessor(ocrEngine: OCREngineFactory.make(settings: s),
                                 preferPDFTextLayer: s.preferPDFTextLayer)
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // CORS 预检
        if request.method == "OPTIONS" {
            return HTTPResponse(statusCode: 200, headers: [
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, X-File-Name"
            ], body: Data())
        }

        switch (request.method, request.path) {
        case ("GET", "/"):
            return .text(WebPage.html, contentType: "text/html; charset=utf-8")

        case ("GET", "/api/status"):
            let settings = settingsProvider()
            let ocrReady: Bool = {
                switch settings.ocrEngine {
                case .localMLX: return true   // 本地引擎已选用，运行状态由 App 管理
                case .baiduCloud: return !settings.baiduAPIKey.isEmpty
                }
            }()
            return .json([
                "app": "DocuMind",
                "version": "1.0.0",
                "ocrConfigured": ocrReady,
                "ocrEngine": settings.ocrEngine == .localMLX ? "本地 Unlimited-OCR" : "百度云 OCR",
                "providers": settings.llmProviders.filter { $0.enabled }.map { $0.name }
            ])

        case ("GET", "/api/llm/providers"):
            let settings = settingsProvider()
            let list: [[String: Any]] = settings.llmProviders
                .filter { $0.enabled }
                .map { ["name": $0.name, "model": $0.model, "protocol": $0.protocolKind.rawValue, "hasKey": !$0.apiKey.isEmpty] }
            return .json(["providers": list])

        case ("POST", "/api/ocr"):
            return await handleOCR(request)

        case ("POST", "/api/pdf-to-word"):
            return await handlePDFToWord(request)

        case ("POST", "/api/chat"):
            return await handleChat(request)

        default:
            return .error(404, "接口不存在：\(request.method) \(request.path)")
        }
    }

    // MARK: - OCR

    private func handleOCR(_ request: HTTPRequest) async -> HTTPResponse {
        guard !request.body.isEmpty else { return .error(400, "请求体为空：请上传文件") }
        let fileName = sanitizedFileName(request.header("x-file-name") ?? "upload.bin")
        let kind = DocumentKind(fileExtension: (fileName as NSString).pathExtension)
        guard kind != .unknown else {
            return .error(400, "不支持的文件类型（支持 pdf / 图片 / docx / xlsx）")
        }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("documind-upload-\(UUID().uuidString).\((fileName as NSString).pathExtension)")
        do {
            try request.body.write(to: tmpURL)
            defer { try? FileManager.default.removeItem(at: tmpURL) }

            let processor = makeProcessor()
            let result = try await processor.process(url: tmpURL, kind: kind) { _, _ in }
            return .json([
                "fileName": fileName,
                "engine": result.engine,
                "pageCount": result.pageCount,
                "text": result.text
            ])
        } catch {
            return .error(500, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - PDF 转 Word

    private func handlePDFToWord(_ request: HTTPRequest) async -> HTTPResponse {
        guard !request.body.isEmpty else { return .error(400, "请求体为空：请上传 PDF 文件") }
        let fileName = sanitizedFileName(request.header("x-file-name") ?? "document.pdf")

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("documind-upload-\(UUID().uuidString).pdf")
        do {
            try request.body.write(to: tmpURL)
            defer { try? FileManager.default.removeItem(at: tmpURL) }

            let processor = makeProcessor()
            let service = PDFToWordService(processor: processor)
            let (data, engine, pageCount) = try await service.convert(pdfURL: tmpURL) { _, _ in }

            let outName = ((fileName as NSString).deletingPathExtension) + ".docx"
            let encoded = outName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "output.docx"
            return HTTPResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                    "Content-Disposition": "attachment; filename=\"output.docx\"; filename*=UTF-8''\(encoded)",
                    "X-Engine": engine,
                    "X-Page-Count": "\(pageCount)"
                ],
                body: data
            )
        } catch {
            return .error(500, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - LLM 对话

    private func handleChat(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let rawMessages = json["messages"] as? [[String: Any]] else {
            return .error(400, "请求格式错误：需要 JSON {messages: [{role, content}]}")
        }

        let settings = settingsProvider()
        let requestedName = json["provider"] as? String
        let provider: LLMProviderConfig?
        if let name = requestedName {
            provider = settings.llmProviders.first { $0.enabled && $0.name == name }
        } else {
            provider = settings.activeProvider
        }
        guard let config = provider else {
            return .error(400, "未找到可用的 LLM 服务商，请先在 App 的设置中配置 API Key")
        }
        guard !config.apiKey.isEmpty else {
            return .error(400, "服务商「\(config.name)」尚未填写 API Key")
        }

        let messages: [ChatMessage] = rawMessages.compactMap { item in
            guard let roleStr = item["role"] as? String,
                  let role = ChatRole(rawValue: roleStr),
                  let content = item["content"] as? String else { return nil }
            return ChatMessage(role: role, content: content)
        }
        guard !messages.isEmpty else { return .error(400, "messages 为空") }

        do {
            let client = LLMClientFactory.client(for: config)
            let reply = try await client.chat(messages: messages, config: config)
            return .json(["reply": reply, "provider": config.name, "model": config.model])
        } catch {
            return .error(500, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - 工具

    private func sanitizedFileName(_ name: String) -> String {
        // 前端用 encodeURIComponent 编码（HTTP 头不能直接携带非 ASCII 字符）
        let decoded = name.removingPercentEncoding ?? name
        let cleaned = decoded.components(separatedBy: CharacterSet(charactersIn: "/\\?%*:|\"<>")).joined()
        return cleaned.isEmpty ? "upload.bin" : cleaned
    }
}
