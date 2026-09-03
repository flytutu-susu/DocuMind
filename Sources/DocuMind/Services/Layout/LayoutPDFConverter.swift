import Foundation
import PDFKit

/// 版面保持的 PDF -> Word 转换器（纯 Swift 实现）。
///
/// 管线：
///   PDF 页面 → 渲染 → OCR（结构化块）→ LayoutAnalyzer → [LayoutElement]
///   → 插图按 bbox 从页面渲染裁剪 → DocxLayoutBuilder → .docx
///
/// 文本层快路径在 PDFToWordService 中判定；本类只负责扫描件的版面重建。
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

    func convert(pdfURL: URL, document: PDFDocument, progress: ProgressHandler) async throws -> Result {
        let pageCount = min(document.pageCount, maxPages)
        guard pageCount > 0 else { throw DocumentProcessError.cannotOpenPDF }

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

            // 无块输出时的兜底：整段文本
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
}
