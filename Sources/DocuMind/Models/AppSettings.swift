import Foundation
import Combine

enum BaiduOCREndpoint: String, Codable, CaseIterable, Identifiable {
    case generalBasic = "general_basic"      // 通用文字识别（标准版）
    case accurateBasic = "accurate_basic"    // 通用文字识别（高精度版）
    case general = "general"                 // 标准含位置版
    case accurate = "accurate"               // 高精度含位置版

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .generalBasic: return "标准版 general_basic"
        case .accurateBasic: return "高精度版 accurate_basic"
        case .general: return "标准含位置版 general"
        case .accurate: return "高精度含位置版 accurate"
        }
    }

    /// 是否返回文字位置信息（用于按行/段落重排）
    var hasLocation: Bool {
        self == .general || self == .accurate
    }
}

// MARK: - OCR 引擎选择

enum OCREngineKind: String, Codable, CaseIterable, Identifiable {
    case localMLX       // 本地 Unlimited-OCR（MLX mxfp8bit，离线免费）
    case baiduCloud     // 百度智能云 OCR

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localMLX: return "本地 Unlimited-OCR（推荐，离线免费）"
        case .baiduCloud: return "百度智能云 OCR"
        }
    }
}

enum MLXOutputMode: String, Codable, CaseIterable, Identifiable {
    case text           // Free OCR. 纯文本
    case markdown       // 带版面结构的 Markdown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .text: return "纯文本（更快）"
        case .markdown: return "Markdown（保留版面结构，适合转 Word）"
        }
    }
}

// MARK: - 本地模型版本预设

struct MLXModelVariant: Identifiable, Hashable {
    let repo: String
    let label: String
    let detail: String   // 体积 / 精度说明

    var id: String { repo }

    /// 默认模型：mlx-community/Unlimited-OCR-mxfp8（config 原生修复版）
    static let defaultRepo = "mlx-community/Unlimited-OCR-mxfp8"

    /// 可切换版本（精度数据来自量化作者在 FUNSD 上的评测）
    static let presets: [MLXModelVariant] = [
        MLXModelVariant(repo: "mlx-community/Unlimited-OCR-mxfp8",
                        label: "MXFP8 · mlx-community（默认）",
                        detail: "3.6GB · CER 1.46% · config 原生修复版，需 mlx-vlm≥0.6"),
        MLXModelVariant(repo: "sahilchachra/unlimited-ocr-mxfp8-mlx",
                        label: "MXFP8",
                        detail: "3.6GB · CER 1.46%"),
        MLXModelVariant(repo: "sahilchachra/unlimited-ocr-8bit-mlx",
                        label: "Int8",
                        detail: "3.7GB · CER 1.57% · 均衡"),
        MLXModelVariant(repo: "sahilchachra/unlimited-ocr-4bit-mlx",
                        label: "Int4",
                        detail: "2.3GB · CER 2.29% · 最小最快"),
        MLXModelVariant(repo: "sahilchachra/unlimited-ocr-mxfp4-mlx",
                        label: "MXFP4",
                        detail: "2.3GB · CER 2.39%"),
    ]
}

// MARK: - 全局设置（Codable 持久化）

struct AppSettings: Codable {
    // OCR 引擎
    var ocrEngine: OCREngineKind = .localMLX
    /// PDF 有文本层时优先直接提取（更快、免费），无文本层再走 OCR
    var preferPDFTextLayer: Bool = true

    // 百度 OCR（云端，可选）
    var baiduAPIKey: String = ""
    var baiduSecretKey: String = ""
    var baiduEndpoint: BaiduOCREndpoint = .accurateBasic
    /// OCR 请求按段落合并结果
    var mergeParagraph: Bool = true

    // 本地 MLX 引擎
    var mlxModelRepo: String = MLXModelVariant.defaultRepo
    var mlxPort: Int = 8091
    var mlxPromptMode: MLXOutputMode = .markdown
    var mlxAutoStart: Bool = false
    /// 国内网络加速：HF 模型下载走 hf-mirror.com，pip 走清华源
    var hfMirror: Bool = true

    // LLM
    var llmProviders: [LLMProviderConfig] = []
    var activeProviderID: UUID? = nil

    // 局域网服务
    var serverPort: Int = 8080
    var autoStartServer: Bool = false

    var activeProvider: LLMProviderConfig? {
        if let id = activeProviderID, let p = llmProviders.first(where: { $0.id == id && $0.enabled }) {
            return p
        }
        return llmProviders.first(where: { $0.enabled && !$0.apiKey.isEmpty })
    }

    /// 兼容旧版配置文件：缺失字段取默认值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ocrEngine = try c.decodeIfPresent(OCREngineKind.self, forKey: .ocrEngine) ?? .localMLX
        preferPDFTextLayer = try c.decodeIfPresent(Bool.self, forKey: .preferPDFTextLayer) ?? true
        baiduAPIKey = try c.decodeIfPresent(String.self, forKey: .baiduAPIKey) ?? ""
        baiduSecretKey = try c.decodeIfPresent(String.self, forKey: .baiduSecretKey) ?? ""
        baiduEndpoint = try c.decodeIfPresent(BaiduOCREndpoint.self, forKey: .baiduEndpoint) ?? .accurateBasic
        mergeParagraph = try c.decodeIfPresent(Bool.self, forKey: .mergeParagraph) ?? true
        mlxModelRepo = try c.decodeIfPresent(String.self, forKey: .mlxModelRepo) ?? MLXModelVariant.defaultRepo
        mlxPort = try c.decodeIfPresent(Int.self, forKey: .mlxPort) ?? 8091
        mlxPromptMode = try c.decodeIfPresent(MLXOutputMode.self, forKey: .mlxPromptMode) ?? .markdown
        mlxAutoStart = try c.decodeIfPresent(Bool.self, forKey: .mlxAutoStart) ?? false
        hfMirror = try c.decodeIfPresent(Bool.self, forKey: .hfMirror) ?? true
        llmProviders = try c.decodeIfPresent([LLMProviderConfig].self, forKey: .llmProviders) ?? []
        activeProviderID = try c.decodeIfPresent(UUID.self, forKey: .activeProviderID)
        serverPort = try c.decodeIfPresent(Int.self, forKey: .serverPort) ?? 8080
        autoStartServer = try c.decodeIfPresent(Bool.self, forKey: .autoStartServer) ?? false
    }

    init() {}
}

// MARK: - 设置存储

/// 配置文件保存在 ~/Library/Application Support/DocuMind/settings.json
/// 线程安全：局域网服务在后台线程读取配置，视图在主线程写入，统一走锁。
final class SettingsStore: ObservableObject {
    private var storedSettings: AppSettings
    private let lock = NSLock()

    var settings: AppSettings {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedSettings
        }
        set {
            objectWillChange.send()
            lock.lock()
            storedSettings = newValue
            lock.unlock()
            save()
        }
    }

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DocuMind", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.storedSettings = decoded
        } else {
            // 首次启动：预置常用服务商（API Key 留空待填）
            var initial = AppSettings()
            initial.llmProviders = LLMProviderConfig.presets
            self.storedSettings = initial
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[DocuMind] 保存设置失败: \(error.localizedDescription)")
        }
    }

    func addPreset(_ preset: LLMProviderConfig) {
        var p = preset
        p.id = UUID()
        settings.llmProviders.append(p)
    }
}
