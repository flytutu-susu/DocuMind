import Foundation
import PDFKit

/// 版面保持的 PDF -> Word 转换器（纯 Swift 实现）。
///
/// 管线：
///   PDF 页面 → 渲染 → OCR（grounding 结构化块）→ LayoutAnalyzer → [LayoutElement]
///   → 插图按 bbox 从页面渲染裁剪 → DocxLayoutBuilder → .docx
///
/// 内存控制：逐页处理（渲染→识别→裁剪→丢弃页面位图），不缓存整本页面图像。
final class LayoutPDFConverter {
    private let engine: any OCREngine
    private let maxPages: Int

    init(engine: any OCREngine, maxPages: Int = 100) {
        self.engine = engine
        self.maxPages = maxPages
    }

    typealias ProgressHandler = @Sendable (Double, String) -> Void

    struct Result {
        let data: Data
        let engine: String
        let pageCount: Int
    }

    func convert(pdfURL: URL, progress: ProgressHandler) async throws -> Result {
        guard let document = PDFDocument(url: pdfURL) else { throw DocumentProcessError.cannotOpenPDF }
        let pageCount = min(document.pageCount, maxPages)

        // 有可用文本层的 PDF：直接提取（快且零误差），走简单 docx 生成
        if let text = Self.extractTextLayer(document) {
            progress(0.9, "文本层直出，生成 Word…")
            let data = try Self.simpleDocx(from: text)
            return Result(data: data, engine: "PDF 文本层直出", pageCount: document.pageCount)
        }

        let analyzer = LayoutAnalyzer()
        let builder = DocxLayoutBuilder()
        var elements: [LayoutElement] = []
        var crops: [UUID: Data] = [:]

        for i in 0..<pageCount {
            try Task.checkCancellation()
            progress(0.05 + 0.85 * Double(i) / Double(pageCount),
                     "版面识别 第 \(i + 1)/\(pageCount) 页…")
            guard let page = document.page(at: i) else { continue }

            // 1) 渲染页面
            let pageImage = try DocumentProcessor.renderPageToCGImage(page)
            let jpeg = try DocumentProcessor.renderPageToJPEG(page)

            // 2) OCR 结构化识别
            let result = try await engine.recognize(imageData: jpeg)

            // 3) blocks -> 版面元素（页码改写为真实页码）
            let blocks = result.blocks.map {
                OCRBlock(category: $0.category, bbox: $0.bbox, content: $0.content, page: i)
            }
            var pageElements = analyzer.elements(for: blocks, page: i)

            // grounding 未产出块时的兜底：整段文本
            if pageElements.isEmpty, !result.text.isEmpty {
                pageElements = [.paragraph(text: result.text)]
            }

            // 4) 插图立即裁剪（随后释放页面位图，控制内存）
            for element in pageElements {
                guard case .image(let id, _, let bbox) = element else { continue }
                if let crop = DocumentProcessor.cropPNG(from: pageImage, normalizedBBox: bbox) {
                    crops[id] = crop
                }
            }
            elements.append(contentsOf: pageElements)

            // 5) 分页符
            if i < pageCount - 1 {
                elements.append(.pageBreak)
            }
        }

        if document.pageCount > maxPages {
            elements.append(.paragraph(text: "（注：共 \(document.pageCount) 页，仅转换前 \(maxPages) 页）"))
        }

        guard !elements.isEmpty else { throw DocumentProcessError.emptyResult }
        progress(0.95, "生成 Word 文档…")
        let data = try builder.build(elements: elements, crops: crops)
        progress(1.0, "完成")
        return Result(data: data, engine: "\(engine.engineDisplayName) · 版面引擎", pageCount: pageCount)
    }

    // MARK: - 文本层快路径

    private static func extractTextLayer(_ document: PDFDocument) -> String? {
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

    private static func simpleDocx(from text: String) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("documind-text-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try DocxBuilder.build(text: text, to: tmp)
        return try Data(contentsOf: tmp)
    }
}
