import Foundation

enum MLXServiceError: LocalizedError {
    case serverUnreachable(port: Int)
    case modelNotReady(String)
    case httpError(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .serverUnreachable(let port):
            return "无法连接本地推理引擎（127.0.0.1:\(port)）。请到「设置 → OCR 引擎」安装并启动本地引擎。"
        case .modelNotReady(let status):
            return "本地模型尚未就绪（当前状态：\(status)）。首次启动需下载模型，请稍候。"
        case .httpError(let code, let msg):
            return "本地引擎错误 \(code)：\(msg)"
        case .badResponse:
            return "本地引擎返回数据格式异常。"
        }
    }
}

/// 本地 Unlimited-OCR (MLX) 推理服务的 HTTP 客户端。
/// 对应内嵌 Python sidecar（见 MLXServerScript.swift），仅监听 127.0.0.1。
struct LocalVLMOCRService: OCREngine {
    let port: Int
    let mode: MLXOutputMode

    var engineDisplayName: String { "本地 Unlimited-OCR" }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600        // 单页 OCR
        config.timeoutIntervalForResource = 6 * 3600  // 整本 PDF 转换可能耗时很长
        return URLSession(configuration: config)
    }()

    private var baseURL: String { "http://127.0.0.1:\(port)" }

    // MARK: - 单图识别（含结构化块）

    func recognize(imageData: Data) async throws -> OCRPageResult {
        let url = URL(string: baseURL + "/ocr")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "image": imageData.base64EncodedString(),
            "mode": mode.rawValue
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await send(request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MLXServiceError.badResponse
        }
        guard statusCode == 200, let text = json["text"] as? String else {
            let message = (json["error"] as? String) ?? "未知错误"
            if statusCode == 503 { throw MLXServiceError.modelNotReady(message) }
            throw MLXServiceError.httpError(statusCode, message)
        }

        let blocks = parseBlocks(json["blocks"])
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: "\n").map { OCRLine(text: $0, location: nil) }
        return OCRPageResult(text: trimmed, lines: lines, blocks: blocks)
    }

    private func parseBlocks(_ raw: Any?) -> [OCRBlock] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let category = item["category"] as? String,
                  let content = item["content"] as? String else { return nil }
            let bbox = (item["bbox"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
            let page = (item["page"] as? NSNumber)?.intValue ?? 0
            return OCRBlock(category: category, bbox: bbox, content: content, page: page)
        }
    }

    // MARK: - 版面保持的 PDF -> Word

    /// 上传整本 PDF 给本地版面引擎，轮询 /health 获取页级进度，返回 docx 数据。
    func convertPDFToDocx(pdfURL: URL,
                          fileName: String,
                          progress: @escaping @Sendable (Double, String) -> Void) async throws -> Data {
        let pdfData = try Data(contentsOf: pdfURL)

        let url = URL(string: baseURL + "/convert")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "document.pdf"
        request.setValue(encodedName, forHTTPHeaderField: "X-File-Name")
        request.httpBody = pdfData

        // 进度轮询（sidecar 在 /health 中暴露 convert.current/total）
        let poller = Task { [baseURL, session] in
            let healthURL = URL(string: baseURL + "/health")!
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let (data, _) = try? await session.data(from: healthURL),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let convert = json["convert"] as? [String: Any],
                      let current = (convert["current"] as? NSNumber)?.intValue,
                      let total = (convert["total"] as? NSNumber)?.intValue, total > 0
                else { continue }
                let p = 0.05 + 0.9 * Double(current) / Double(total)
                progress(p, "版面识别 第 \(current)/\(total) 页…")
            }
        }

        progress(0.02, "上传 PDF 到本地版面引擎…")
        let result: (Data, URLResponse)
        do {
            result = try await send(request)
        } catch {
            poller.cancel()
            throw error
        }
        poller.cancel()
        progress(0.98, "生成 Word 文档…")

        let (data, response) = result
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            var message = "未知错误"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? String {
                message = err
            }
            if statusCode == 503 { throw MLXServiceError.modelNotReady(message) }
            throw MLXServiceError.httpError(statusCode, message)
        }
        // docx 魔数校验（PK）
        guard data.count > 4, data[0] == 0x50, data[1] == 0x4B else {
            throw MLXServiceError.badResponse
        }
        return data
    }

    // MARK: - 内部

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw MLXServiceError.serverUnreachable(port: port)
        }
    }
}
