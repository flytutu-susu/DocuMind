import Foundation

/// PDF -> Word 转换管线：复用 DocumentProcessor 拿到全文，再生成 docx。
final class PDFToWordService {
    private let processor: DocumentProcessor

    init(processor: DocumentProcessor) {
        self.processor = processor
    }

    /// 转换单个 PDF，返回生成的 docx 数据与统计信息。
    func convert(pdfURL: URL, progress: DocumentProcessor.ProgressHandler) async throws -> (data: Data, engine: String, pageCount: Int) {
        let result = try await processor.process(url: pdfURL, kind: .pdf, progress: progress)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("documind-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: tmp) }

        progress(0.95, "生成 Word 文档…")
        try DocxBuilder.build(text: result.text, to: tmp)
        let data = try Data(contentsOf: tmp)
        progress(1.0, "完成")
        return (data, result.engine, result.pageCount)
    }
}
