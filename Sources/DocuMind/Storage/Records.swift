import Foundation

// MARK: - 结构化 OCR 块（Unlimited-OCR grounding 输出）

struct OCRBlock: Codable, Hashable {
    let category: String      // title / text / table / image / footer ...
    let bbox: [Double]        // 归一化 [x1, y1, x2, y2]（0-1），无坐标时为空数组
    let content: String
    let page: Int             // 0 起始页码
}

// MARK: - 数据库记录

struct DocumentRecord: Identifiable, Hashable {
    let id: UUID
    let name: String
    let kind: DocumentKind
    let createdAt: Date
    /// 数据归属："local" = 本机（App/本机网页）；其他 = 局域网客户端 IP
    var owner: String = "local"
}

struct DocumentVersionRecord: Identifiable, Hashable {
    let id: UUID
    let documentID: UUID
    let versionNo: Int
    let filePath: String
    let fileSize: Int64
    let createdAt: Date
}

struct OCRResultRecord: Identifiable, Hashable {
    let id: UUID
    let documentID: UUID
    let engine: String
    let mode: String
    let text: String
    let blocksJSON: String    // OCRBlock 数组的 JSON，可为空串
    let pageCount: Int
    let createdAt: Date
}

enum TaskKind: String, Codable {
    case ocr
    case pdfToWord = "pdf_to_word"

    var displayName: String {
        switch self {
        case .ocr: return "文字识别"
        case .pdfToWord: return "PDF 转 Word"
        }
    }
}

enum TaskState: String, Codable {
    case pending
    case running
    case success
    case failed
}

struct TaskRecord: Identifiable, Hashable {
    let id: UUID
    let kind: TaskKind
    let documentID: UUID?
    let fileName: String
    var state: TaskState
    var progress: Double       // 0-1
    var message: String
    var error: String?
    var engine: String
    var outputPath: String?    // 转换产物路径
    var outputName: String?
    let createdAt: Date
    var updatedAt: Date
    /// 数据归属："local" = 本机；其他 = 局域网客户端 IP
    var owner: String = "local"

    var isActive: Bool { state == .pending || state == .running }
}

// MARK: - 行映射工具

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func uuid(_ key: String) -> UUID? { (self[key] as? String).flatMap(UUID.init) }
    func int(_ key: String) -> Int {
        if let v = self[key] as? Int64 { return Int(v) }
        if let v = self[key] as? Int { return v }
        return 0
    }
    func int64(_ key: String) -> Int64 {
        if let v = self[key] as? Int64 { return v }
        if let v = self[key] as? Int { return Int64(v) }
        return 0
    }
    func double(_ key: String) -> Double {
        if let v = self[key] as? Double { return v }
        if let v = self[key] as? Int64 { return Double(v) }
        return 0
    }
    func date(_ key: String) -> Date { Date(timeIntervalSince1970: double(key)) }
}
