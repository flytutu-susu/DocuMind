import Foundation
import PDFKit

/// PDF -> Word 统一转换入口（产品核心）。
///
/// 所有引擎统一走 blocks → layout → docx 管线：
///
///   ┌ 文字版 PDF：文本层直出（零误差、秒级，简单排版）
///   │
///   └ 扫描版 PDF：逐页 OCR 产出结构化块
///        ├─ 本地 Unlimited-OCR：grounding 语义块（title/text/table/image + bbox）
///        └─ 百度云（自动切含位置版）：行级 location 合成 blocks
///     → LayoutAnalyzer（类别映射 / 行合并 / 表格解析）
///     → DocxLayoutBuilder（OOXML：Heading 样式 / 真表格 / 插图嵌入 / 分页）
final class PDFToWordService {

    struct Result {
        let data: Data
        let engine: String
        let pageCount: Int
    }

    typealias ProgressHandler = @Sendable (Double, String) -> Void

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - 统一入口

    func convert(pdfURL: URL, progress: ProgressHandler) async throws -> Result {
        guard let document = PDFDocument(url: pdfURL) else { throw DocumentProcessError.cannotOpenPDF }

        // 1) 文本层快路径（文字版 PDF）
        if settings.preferPDFTextLayer, let text = Self.extractTextLayer(document) {
            progress(0.9, "文本层直出，生成 Word…")
            let data = try Self.simpleDocx(from: text)
            progress(1.0, "完成")
            return Result(data: data, engine: "PDF 文本层直出", pageCount: document.pageCount)
        }

        // 2) blocks → layout → docx（扫描件，所有引擎统一）
        guard let engine = Self.makeLayoutEngine(settings: settings) else {
            throw DocumentProcessError.ocrUnavailable
        }
        let converter = LayoutPDFConverter(engine: engine)
        let converted = try await converter.convert(pdfURL: pdfURL, document: document, progress: progress)
        return Result(data: converted.data, engine: converted.engine, pageCount: converted.pageCount)
    }

    // MARK: - 引擎装配

    /// 为版面转换装配引擎：
    /// - 本地 MLX：强制 grounding（markdown）模式，拿到语义块
    /// - 百度云：无位置接口自动升级为含位置版（版面重建需要坐标）
    static func makeLayoutEngine(settings: AppSettings) -> (any OCREngine)? {
        switch settings.ocrEngine {
        case .localMLX:
            return LocalVLMOCRService(port: settings.mlxPort, mode: .markdown)

        case .baiduCloud:
            guard !settings.baiduAPIKey.isEmpty, !settings.baiduSecretKey.isEmpty else { return nil }
            let endpoint: BaiduOCREndpoint
            switch settings.baiduEndpoint {
            case .generalBasic: endpoint = .general      // 升级为含位置版
            case .accurateBasic: endpoint = .accurate
            default: endpoint = settings.baiduEndpoint
            }
            return BaiduOCRService(apiKey: settings.baiduAPIKey,
                                   secretKey: settings.baiduSecretKey,
                                   endpoint: endpoint,
                                   mergeParagraph: settings.mergeParagraph)
        }
    }

    // MARK: - 文本层快路径

    static func extractTextLayer(_ document: PDFDocument) -> String? {
        guard document.pageCount > 0 else { return nil }
        var textPages = 0
        var pages: [String] = []
        for i in 0..<document.pageCount {
            let pageText = document.page(at: i)?.string ?? ""
            pages.append(pageText)
            if pageText.filter({ !$0.isWhitespace }).count >= 10 { textPages += 1 }
        }
        guard textPages > 0, textPages * 2 >= document.pageCount else { return nil }
        return pages.enumerated().map { idx, t in
            document.pageCount > 1 ? "----- 第 \(idx + 1) 页 -----\n\(t)" : t
        }.joined(separator: "\n")
    }

    static func simpleDocx(from text: String) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("documind-text-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try DocxBuilder.build(text: text, to: tmp)
        return try Data(contentsOf: tmp)
    }
}
