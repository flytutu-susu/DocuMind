import Foundation

/// Anthropic Messages API 客户端（Claude 系列）。
/// 与 OpenAI 协议的差异：system 独立字段、x-api-key 鉴权、SSE 事件类型不同。
struct AnthropicClient: LLMClient {

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    func streamChat(messages: [ChatMessage], config: LLMProviderConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildRequest(messages: messages, config: config)
                    let (bytes, response) = try await session.bytes(for: request)
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    guard (200..<300).contains(statusCode) else {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                            if errorData.count > 16 * 1024 { break }
                        }
                        try LLMHTTPHelper.throwIfError(statusCode: statusCode, data: errorData)
                        continuation.finish()
                        return
                    }

                    try await SSEParser.parse(lines: bytes.lines) { event, data in
                        guard let jsonData = data.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                              let type = json["type"] as? String
                        else { return true }

                        switch type {
                        case "content_block_delta":
                            if let delta = json["delta"] as? [String: Any],
                               let text = delta["text"] as? String, !text.isEmpty {
                                continuation.yield(text)
                            }
                        case "message_stop":
                            return false
                        case "error":
                            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "未知错误"
                            continuation.finish(throwing: LLMError.apiError(message))
                            return false
                        default:
                            break  // message_start / content_block_start/stop / ping 等忽略
                        }
                        return true
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func buildRequest(messages: [ChatMessage], config: LLMProviderConfig) throws -> URLRequest {
        let url = try LLMURLBuilder.endpoint(base: config.baseURL, defaultPath: "/v1/messages")

        // system 消息抽出来单独传
        let systemPrompt = messages.filter { $0.role == .system }.map { $0.content }.joined(separator: "\n")
        let conversation = messages.filter { $0.role != .system }

        var payload: [String: Any] = [
            "model": config.model,
            "max_tokens": 4096,
            "stream": true,
            "messages": conversation.map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
        if !systemPrompt.isEmpty {
            payload["system"] = systemPrompt
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }
}
