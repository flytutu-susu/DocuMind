import XCTest
@testable import DocuMind

final class DocuMindTests: XCTestCase {

    /// DocxBuilder 生成的文件必须是合法 zip，且包含 docx 必需的部件
    func testDocxBuilderProducesValidPackage() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try DocxBuilder.build(text: "第一段：Hello 你好\n\n第二段：包含 <XML> & 特殊字符\n----- 第 2 页 -----\n分页后的内容", to: tmp)

        let data = try Data(contentsOf: tmp)
        XCTAssertGreaterThan(data.count, 500)
        // zip 魔数 PK
        XCTAssertEqual(data[0], 0x50)
        XCTAssertEqual(data[1], 0x4B)
    }

    /// 生成的 docx 能被 OfficeTextExtractor 读回文本
    func testDocxRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = "标题行\n正文内容 123"
        try DocxBuilder.build(text: source, to: tmp)
        let extracted = try OfficeTextExtractor.extractDocx(url: tmp)
        XCTAssertTrue(extracted.contains("标题行"))
        XCTAssertTrue(extracted.contains("正文内容 123"))
    }

    /// LLM URL 拼接逻辑
    func testLLMURLBuilder() throws {
        // 已含完整路径时原样使用
        let u1 = try LLMURLBuilder.endpoint(base: "https://api.deepseek.com/chat/completions", defaultPath: "/chat/completions")
        XCTAssertEqual(u1.absoluteString, "https://api.deepseek.com/chat/completions")
        // base 填到 /v1 时自动补路径
        let u2 = try LLMURLBuilder.endpoint(base: "https://api.openai.com/v1/", defaultPath: "/chat/completions")
        XCTAssertEqual(u2.absoluteString, "https://api.openai.com/v1/chat/completions")
        // Anthropic
        let u3 = try LLMURLBuilder.endpoint(base: "https://api.anthropic.com", defaultPath: "/v1/messages")
        XCTAssertEqual(u3.absoluteString, "https://api.anthropic.com/v1/messages")
    }

    /// 文档类型识别
    func testDocumentKind() {
        XCTAssertEqual(DocumentKind(fileExtension: "PDF"), .pdf)
        XCTAssertEqual(DocumentKind(fileExtension: "JPG"), .image)
        XCTAssertEqual(DocumentKind(fileExtension: "docx"), .docx)
        XCTAssertEqual(DocumentKind(fileExtension: "xlsx"), .xlsx)
        XCTAssertEqual(DocumentKind(fileExtension: "txt"), .unknown)
    }

    /// SQLite 封装：建表/插入/查询/NULL 处理
    func testDatabaseBasics() throws {
        let db = try Database(path: ":memory:")
        try db.exec("CREATE TABLE t(id TEXT PRIMARY KEY, n INTEGER, r REAL, s TEXT)")
        try db.run("INSERT INTO t VALUES(?,?,?,?)", ["a1", 42, 3.5, "你好"])
        try db.run("INSERT INTO t VALUES(?,?,?,?)", ["a2", nil, nil, nil])
        let rows = try db.fetch("SELECT * FROM t ORDER BY n DESC")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].string("id"), "a1")
        XCTAssertEqual(rows[0].int("n"), 42)
        XCTAssertEqual(rows[0].double("r"), 3.5, accuracy: 0.001)
        XCTAssertEqual(rows[0].string("s"), "你好")
        XCTAssertNil(rows[1].string("s"))   // NULL 读出为 nil
    }

    /// 文档库：入库（复制文件）→ 任务状态流转 → OCR 结果存取（含结构化块）
    func testDocumentStoreFlow() throws {
        let store = DocumentStore()
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-test-\(UUID().uuidString).txt")
        try "测试内容".write(to: src, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: src) }

        let doc = try store.createDocument(name: "测试文档.txt", kind: .image, sourceFile: src)
        let versionURL = try store.latestVersionURL(of: doc.id)
        XCTAssertNotNil(versionURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: versionURL!.path))
        XCTAssertEqual(try String(contentsOf: versionURL!, encoding: .utf8), "测试内容")

        let task = try store.createTask(kind: .ocr, documentID: doc.id, fileName: doc.name)
        XCTAssertEqual(task.state, .pending)
        try store.updateTask(task.id, state: .running, progress: 0.5, message: "处理中")
        try store.updateTask(task.id, state: .success, progress: 1.0, message: "完成", engine: "本地 Unlimited-OCR")
        let updated = try store.task(task.id)
        XCTAssertEqual(updated?.state, .success)
        XCTAssertEqual(updated?.engine, "本地 Unlimited-OCR")

        let blocks = [OCRBlock(category: "title", bbox: [0.1, 0.1, 0.9, 0.2], content: "标题", page: 0)]
        try store.saveOCRResult(documentID: doc.id, engine: "本地 Unlimited-OCR", mode: "markdown",
                                text: "识别文本", blocks: blocks, pageCount: 1)
        let result = try store.latestOCRResult(of: doc.id)
        XCTAssertEqual(result?.text, "识别文本")
        XCTAssertTrue(result?.blocksJSON.contains("title") ?? false)

        XCTAssertTrue(try store.listDocuments().contains(where: { $0.id == doc.id }))
        XCTAssertTrue(try store.listTasks().contains(where: { $0.id == task.id }))
    }
}
