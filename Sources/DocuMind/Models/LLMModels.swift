import Foundation

// MARK: - LLM 协议类型

enum LLMProtocolKind: String, Codable, CaseIterable, Identifiable {
    case openAICompatible   // DeepSeek / Kimi / 千问(兼容模式) / 通用 OpenAI
    case anthropic          // Anthropic Messages API

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI 兼容协议"
        case .anthropic: return "Anthropic 协议"
        }
    }
}

// MARK: - 单个 LLM 服务商配置

struct LLMProviderConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String                 // 展示名，例如 "DeepSeek"
    var protocolKind: LLMProtocolKind
    var baseURL: String              // 例如 https://api.deepseek.com
    var apiKey: String
    var model: String                // 例如 deepseek-chat
    var enabled: Bool = true

    /// 内置预设（可在设置中一键添加）
    static let presets: [LLMProviderConfig] = [
        LLMProviderConfig(
            name: "DeepSeek",
            protocolKind: .openAICompatible,
            baseURL: "https://api.deepseek.com",
            apiKey: "",
            model: "deepseek-chat"
        ),
        LLMProviderConfig(
            name: "Kimi (Moonshot)",
            protocolKind: .openAICompatible,
            baseURL: "https://api.moonshot.cn/v1",
            apiKey: "",
            model: "kimi-k2-0905-preview"
        ),
        LLMProviderConfig(
            name: "通义千问 (DashScope)",
            protocolKind: .openAICompatible,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            apiKey: "",
            model: "qwen-plus"
        ),
        LLMProviderConfig(
            name: "OpenAI",
            protocolKind: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            apiKey: "",
            model: "gpt-4o-mini"
        ),
        LLMProviderConfig(
            name: "Anthropic Claude",
            protocolKind: .anthropic,
            baseURL: "https://api.anthropic.com",
            apiKey: "",
            model: "claude-sonnet-4-5"
        )
    ]
}

// MARK: - 聊天消息

enum ChatRole: String, Codable {
    case system
    case user
    case assistant
}

struct ChatMessage: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var role: ChatRole
    var content: String

    init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

// MARK: - LLM 错误

enum LLMError: LocalizedError {
    case noProviderConfigured
    case invalidBaseURL(String)
    case httpError(Int, String)
    case apiError(String)
    case streamClosed

    var errorDescription: String? {
        switch self {
        case .noProviderConfigured: return "尚未配置可用的 LLM 服务商，请先到「设置」中添加并填写 API Key。"
        case .invalidBaseURL(let url): return "无效的服务地址：\(url)"
        case .httpError(let code, let body): return "HTTP \(code)：\(body)"
        case .apiError(let msg): return msg
        case .streamClosed: return "流式连接中断"
        }
    }
}
