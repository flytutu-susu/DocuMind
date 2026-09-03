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
