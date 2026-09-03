import Foundation

/// OpenAI 兼容协议客户端。
/// 覆盖：DeepSeek / Kimi(Moonshot) / 通义千问(DashScope 兼容模式) / OpenAI / 任意兼容网关（OneAPI、Ollama 等）。
struct OpenAICompatibleClient: LLMClient {

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

                    try await SSEParser.parse(lines: bytes.lines) { _, data in
                        if data == "[DONE]" { return false }
                        guard let jsonData = data.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                        else { return true }

                        // 兼容错误事件 {"error": {...}}
                        if let error = json["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            continuation.finish(throwing: LLMError.apiError(message))
                            return false
                        }

                        guard let choices = json["choices"] as? [[String: Any]],
                              let first = choices.first,
                              let delta = first["delta"] as? [String: Any]
                        else { return true }

                        if let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(content)
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
        let url = try LLMURLBuilder.endpoint(base: config.baseURL, defaultPath: "/chat/completions")

        let payload: [String: Any] = [
            "model": config.model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": true
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }
}
