import Foundation

// MARK: - 文档类型

enum DocumentKind: String, Codable, CaseIterable {
    case pdf
    case image
    case docx
    case xlsx
    case unknown

    init(fileExtension ext: String) {
        switch ext.lowercased() {
        case "pdf": self = .pdf
        case "png", "jpg", "jpeg", "bmp", "gif", "webp", "heic", "tiff", "tif": self = .image
        case "docx": self = .docx
        case "xlsx": self = .xlsx
        default: self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .image: return "图片"
        case .docx: return "Word 文档"
        case .xlsx: return "Excel 表格"
        case .unknown: return "未知"
        }
    }
}

// MARK: - OCR / 解析任务

enum TaskStatus: Equatable {
    case pending
    case processing(progress: Double, message: String)
    case done
    case failed(String)

    var isRunning: Bool {
        if case .processing = self { return true }
        if case .pending = self { return true }
        return false
    }

    var shortDescription: String {
        switch self {
        case .pending: return "等待中"
        case .processing(let p, let msg): return "\(Int(p * 100))% \(msg)"
        case .done: return "完成"
        case .failed(let err): return "失败：\(err)"
        }
    }
}

struct DocumentTask: Identifiable, Hashable {
    let id: UUID
    let fileURL: URL
    let fileName: String
    let kind: DocumentKind
    var status: TaskStatus = .pending
    var resultText: String = ""
    var engine: String = ""          // 例如 "百度OCR·高精度" / "PDF 文本层" / "DOCX 解析"
    var pageCount: Int = 0
    let createdAt: Date = Date()

    init(fileURL: URL) {
        self.id = UUID()
        self.fileURL = fileURL
        self.fileName = fileURL.lastPathComponent
        self.kind = DocumentKind(fileExtension: fileURL.pathExtension)
    }

    static func == (lhs: DocumentTask, rhs: DocumentTask) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
