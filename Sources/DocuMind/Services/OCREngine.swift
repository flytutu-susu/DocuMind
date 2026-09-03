import Foundation

/// OCR 引擎抽象：百度云 OCR 与本地 Unlimited-OCR (MLX) 统一接口。
protocol OCREngine {
    var engineDisplayName: String { get }
    /// 识别一张图片（JPEG/PNG），返回全文文本。
    func recognize(imageData: Data) async throws -> OCRPageResult
}

enum OCREngineFactory {
    /// 按当前设置构建引擎；返回 nil 表示所选引擎未配置/不可用（调用方给出明确报错）。
    static func make(settings: AppSettings) -> (any OCREngine)? {
        switch settings.ocrEngine {
        case .baiduCloud:
            guard !settings.baiduAPIKey.isEmpty, !settings.baiduSecretKey.isEmpty else { return nil }
            return BaiduOCRService(apiKey: settings.baiduAPIKey,
                                   secretKey: settings.baiduSecretKey,
                                   endpoint: settings.baiduEndpoint,
                                   mergeParagraph: settings.mergeParagraph)
        case .localMLX:
            return LocalVLMOCRService(port: settings.mlxPort, mode: settings.mlxPromptMode)
        }
    }
}

extension BaiduOCRService: OCREngine {
    nonisolated var engineDisplayName: String { "百度云 OCR" }
}
