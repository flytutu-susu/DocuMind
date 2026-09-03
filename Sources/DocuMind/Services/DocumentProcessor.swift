import Foundation
import AppKit
import PDFKit

struct ProcessedDocument {
    let text: String
    let engine: String
    let pageCount: Int
}

enum DocumentProcessError: LocalizedError {
    case unsupportedType
    case cannotOpenPDF
    case emptyResult
    case ocrUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedType: return "不支持的文件类型（支持 pdf / 图片 / docx / xlsx）。"
        case .cannotOpenPDF: return "无法打开 PDF 文件（可能已加密或损坏）。"
        case .emptyResult: return "未识别到任何文字内容。"
        case .ocrUnavailable: return "OCR 引擎不可用：请检查本地引擎是否已启动，或百度 OCR 密钥是否已配置。"
        }
    }
}

/// 文档统一处理管线：
/// - PDF：有文本层直接提取；无文本层逐页渲染成图片走 OCR
/// - 图片：压缩后走 OCR
/// - docx / xlsx：本地直接解析文本
final class DocumentProcessor {
    private let ocrEngine: (any OCREngine)?
    private let preferPDFTextLayer: Bool
    private let maxOCRPages: Int

    init(ocrEngine: (any OCREngine)?, preferPDFTextLayer: Bool, maxOCRPages: Int = 50) {
        self.ocrEngine = ocrEngine
        self.preferPDFTextLayer = preferPDFTextLayer
        self.maxOCRPages = maxOCRPages
    }

    typealias ProgressHandler = @Sendable (Double, String) -> Void

    func process(url: URL, kind: DocumentKind, progress: ProgressHandler) async throws -> ProcessedDocument {
        switch kind {
        case .docx:
            progress(0.3, "解析 DOCX…")
            let text = try await Task.detached(priority: .userInitiated) {
                try OfficeTextExtractor.extractDocx(url: url)
            }.value
            progress(1.0, "完成")
            return ProcessedDocument(text: text, engine: "DOCX 本地解析", pageCount: 1)

        case .xlsx:
            progress(0.3, "解析 XLSX…")
            let text = try await Task.detached(priority: .userInitiated) {
                try OfficeTextExtractor.extractXlsx(url: url)
            }.value
            progress(1.0, "完成")
            return ProcessedDocument(text: text, engine: "XLSX 本地解析", pageCount: 1)

        case .image:
            progress(0.2, "识别图片…")
            let text = try await ocrImage(url: url)
            progress(1.0, "完成")
            return ProcessedDocument(text: text, engine: ocrEngine?.engineDisplayName ?? "OCR", pageCount: 1)

        case .pdf:
            return try await processPDF(url: url, progress: progress)

        case .unknown:
            throw DocumentProcessError.unsupportedType
        }
    }

    // MARK: - PDF

    private func processPDF(url: URL, progress: ProgressHandler) async throws -> ProcessedDocument {
        guard let document = PDFDocument(url: url) else { throw DocumentProcessError.cannotOpenPDF }
        let pageCount = document.pageCount

        // 1) 优先尝试文本层（需过半页面有实质文字，避免扫描件残留少量字符的误判）
        if preferPDFTextLayer {
            progress(0.1, "读取 PDF 文本层…")
            var pages: [String] = []
            var textPages = 0
            for i in 0..<pageCount {
                let pageText = document.page(at: i)?.string ?? ""
                pages.append(pageText)
                if pageText.filter({ !$0.isWhitespace }).count >= 10 { textPages += 1 }
            }
            let hasUsableTextLayer = textPages > 0 && textPages * 2 >= pageCount
            if hasUsableTextLayer {
                let text = pages.enumerated().map { idx, t in
                    pageCount > 1 ? "----- 第 \(idx + 1) 页 -----\n\(t)" : t
                }.joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    progress(1.0, "完成")
                    return ProcessedDocument(text: text, engine: "PDF 文本层", pageCount: pageCount)
                }
            }
        }

        // 2) 扫描件：逐页渲染 -> OCR
        guard let ocr = ocrEngine else { throw DocumentProcessError.ocrUnavailable }
        let pagesToOCR = min(pageCount, maxOCRPages)
        var texts: [String] = []
        for i in 0..<pagesToOCR {
            try Task.checkCancellation()
            progress(Double(i) / Double(pagesToOCR), "OCR 第 \(i + 1)/\(pagesToOCR) 页…")
            guard let page = document.page(at: i) else { continue }
            let imageData = try Self.renderPageToJPEG(page)
            let result = try await ocr.recognize(imageData: imageData)
            texts.append("----- 第 \(i + 1) 页 -----\n\(result.text)")
        }
        if pageCount > pagesToOCR {
            texts.append("（注：共 \(pageCount) 页，仅识别前 \(pagesToOCR) 页）")
        }
        let text = texts.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentProcessError.emptyResult
        }
        progress(1.0, "完成")
        return ProcessedDocument(text: text, engine: "\(ocr.engineDisplayName)（扫描版PDF）", pageCount: pagesToOCR)
    }

    // MARK: - 图片 OCR

    private func ocrImage(url: URL) async throws -> String {
        guard let ocr = ocrEngine else { throw DocumentProcessError.ocrUnavailable }
        let data = try Data(contentsOf: url)
        let result = try await ocr.recognize(imageData: data)
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentProcessError.emptyResult
        }
        return result.text
    }

    // MARK: - PDF 页面渲染

    /// 将 PDF 页面渲染为 JPEG（2x 缩放，长边不超 4096，供 OCR 使用）
    static func renderPageToJPEG(_ page: PDFPage, scale: CGFloat = 2.0, quality: CGFloat = 0.85) throws -> Data {
        let bounds = page.bounds(for: .mediaBox)
        let maxSide = max(bounds.width, bounds.height)
        // 2x 缩放提升识别率；同时保证渲染后长边不超过百度 4096px 限制
        let effectiveScale = maxSide > 0 ? min(scale, 4096.0 / maxSide) : scale
        let pixelWidth = Int(bounds.width * effectiveScale)
        let pixelHeight = Int(bounds.height * effectiveScale)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw DocumentProcessError.cannotOpenPDF
        }

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            throw DocumentProcessError.cannotOpenPDF
        }
        NSGraphicsContext.current = context

        let cgContext = context.cgContext
        cgContext.setFillColor(CGColor.white)
        cgContext.fill(CGRect(origin: .zero, size: CGSize(width: pixelWidth, height: pixelHeight)))
        cgContext.saveGState()
        cgContext.scaleBy(x: effectiveScale, y: effectiveScale)
        page.draw(with: .mediaBox, to: cgContext)
        cgContext.restoreGState()

        NSGraphicsContext.restoreGraphicsState()

        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            throw DocumentProcessError.cannotOpenPDF
        }
        return jpeg
    }
}
