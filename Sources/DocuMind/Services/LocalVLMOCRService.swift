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
            return "本地模型尚未就绪（当前状态：\(status)）。首次启动需下载约 2.4GB 模型，请稍候。"
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
        config.timeoutIntervalForRequest = 600   // M1 上单页约 10~60 秒
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }()

    func recognize(imageData: Data) async throws -> OCRPageResult {
        let url = URL(string: "http://127.0.0.1:\(port)/ocr")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "image": imageData.base64EncodedString(),
            "mode": mode.rawValue
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MLXServiceError.serverUnreachable(port: port)
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MLXServiceError.badResponse
        }

        guard statusCode == 200, let text = json["text"] as? String else {
            let message = (json["error"] as? String) ?? "未知错误"
            if statusCode == 503 { throw MLXServiceError.modelNotReady(message) }
            throw MLXServiceError.httpError(statusCode, message)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: "\n").map { OCRLine(text: $0, location: nil) }
        return OCRPageResult(text: trimmed, lines: lines)
    }
}
