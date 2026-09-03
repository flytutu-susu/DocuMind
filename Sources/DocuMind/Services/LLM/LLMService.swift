import Foundation

/// LLM 客户端抽象：所有云端大模型统一为「消息进、流式文本出」。
protocol LLMClient {
    /// 流式对话：逐段 yield 增量文本。
    func streamChat(messages: [ChatMessage], config: LLMProviderConfig) -> AsyncThrowingStream<String, Error>
}

extension LLMClient {
    /// 非流式便捷方法（Web API 用）：收集完整回复。
    func chat(messages: [ChatMessage], config: LLMProviderConfig) async throws -> String {
        var result = ""
        for try await chunk in streamChat(messages: messages, config: config) {
            result += chunk
        }
        return result
    }
}

enum LLMClientFactory {
    static func make(for protocolKind: LLMProtocolKind) -> LLMClient {
        switch protocolKind {
        case .openAICompatible: return OpenAICompatibleClient()
        case .anthropic: return AnthropicClient()
        }
    }

    static func client(for config: LLMProviderConfig) -> LLMClient {
        make(for: config.protocolKind)
    }
}

// MARK: - SSE 解析工具

/// Server-Sent Events 逐事件解析：聚合 "data:" 行，回调 (event, data)。
struct SSEParser {
    /// 从 URLSession 的字节行序列中解析 SSE，直到流结束。
    static func parse<S: AsyncSequence>(
        lines: S,
        onEvent: (String?, String) throws -> Bool   // 返回 false 表示提前终止
    ) async throws where S.Element == String {
        var event: String? = nil
        var dataBuffer = ""

        func flush() throws -> Bool {
            guard !dataBuffer.isEmpty else { return true }
            let d = dataBuffer
            dataBuffer = ""
            let e = event
            event = nil
            return try onEvent(e, d)
        }

        for try await rawLine in lines {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty {
                if try flush() == false { return }
                continue
            }
            if line.hasPrefix(":") { continue }  // 注释/心跳
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let value = line.dropFirst(5).trimmingCharacters(in: .init(charactersIn: " "))
                dataBuffer += (dataBuffer.isEmpty ? "" : "\n") + value
            }
        }
        _ = try flush()
    }
}

// MARK: - URL 拼接

enum LLMURLBuilder {
    /// 智能拼接：baseURL 已含目标路径时原样使用，否则补默认后缀。
    static func endpoint(base: String, defaultPath: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { throw LLMError.invalidBaseURL(base) }

        // 用户直接填了完整路径（如 .../v1/chat/completions 或 .../v1/messages）时不再追加
        if trimmed.hasSuffix(defaultPath) || trimmed.hasSuffix("/chat/completions") || trimmed.hasSuffix("/messages") {
            guard let url = URL(string: trimmed) else { throw LLMError.invalidBaseURL(base) }
            return url
        }
        guard let url = URL(string: trimmed + defaultPath) else { throw LLMError.invalidBaseURL(base) }
        return url
    }
}

// MARK: - HTTP 错误解析

enum LLMHTTPHelper {
    static func throwIfError(statusCode: Int, data: Data) throws {
        guard (200..<300).contains(statusCode) else {
            // 尝试解析 {"error":{"message":"..."}} 结构
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw LLMError.httpError(statusCode, message)
            }
            let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw LLMError.httpError(statusCode, body)
        }
    }
}
