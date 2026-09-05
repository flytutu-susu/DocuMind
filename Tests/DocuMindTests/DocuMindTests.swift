import XCTest
import ZIPFoundation
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

    /// 删除文档：级联清理记录与磁盘文件
    func testDocumentStoreDelete() throws {
        let store = DocumentStore()
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-del-\(UUID().uuidString).txt")
        try "待删除".write(to: src, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: src) }

        let doc = try store.createDocument(name: "待删除.txt", kind: .image, sourceFile: src)
        let versionURL = try store.latestVersionURL(of: doc.id)
        _ = try store.createTask(kind: .ocr, documentID: doc.id, fileName: doc.name)
        try store.saveOCRResult(documentID: doc.id, engine: "test", mode: "text",
                                text: "abc", blocks: [], pageCount: 1)

        try store.deleteDocument(id: doc.id)

        XCTAssertNil(try store.document(id: doc.id))
        XCTAssertNil(try store.latestOCRResult(of: doc.id))
        XCTAssertTrue(try store.versions(of: doc.id).isEmpty)
        if let versionURL {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: versionURL.deletingLastPathComponent().path), "磁盘目录应被清理")
        }
    }

    // MARK: - Layout 层

    /// markdown 表格解析
    func testLayoutAnalyzerTableParse() {
        let rows = LayoutAnalyzer.parseMarkdownTable("| 姓名 | 年龄 |\n|---|---|\n| 张三 | 30 |")
        XCTAssertEqual(rows, [["姓名", "年龄"], ["张三", "30"]])
        XCTAssertNil(LayoutAnalyzer.parseMarkdownTable("这里没有表格"))
        // 单列不视为表格
        XCTAssertNil(LayoutAnalyzer.parseMarkdownTable("| 只有一列 |\n|---|"))
    }

    /// blocks -> 版面元素：类别映射 + 退化插图丢弃
    func testLayoutAnalyzerElements() {
        let blocks = [
            OCRBlock(category: "title", bbox: [0.1, 0.02, 0.9, 0.06], content: "第一章 概述", page: 0),
            OCRBlock(category: "text", bbox: [], content: "姓名 张三", page: 0),
            OCRBlock(category: "table", bbox: [], content: "| 姓名 | 年龄 |\n|---|---|\n| 张三 | 30 |", page: 0),
            OCRBlock(category: "image", bbox: [0.2, 0.3, 0.8, 0.6], content: "", page: 0),
            OCRBlock(category: "image", bbox: [0.2, 0.3, 0.205, 0.31], content: "", page: 0)  // 退化区域应丢弃
        ]
        let elements = LayoutAnalyzer().elements(for: blocks, page: 0)
        XCTAssertEqual(elements.count, 4)   // heading + paragraph + table + image
        if case .heading(_, let level) = elements[0] { XCTAssertEqual(level, 1) } else { XCTFail("首元素应为标题") }
        if case .table(let rows) = elements[2] { XCTAssertEqual(rows.count, 2) } else { XCTFail("第三元素应为表格") }
        guard case .image = elements[3] else { return XCTFail("第四元素应为插图") }
    }

    /// 行级块合并（云端含位置版场景）：相邻行应合并为段落，错位/远距行不合并
    func testLayoutAnalyzerLineMerging() {
        let analyzer = LayoutAnalyzer()
        // 连续三行同一段落（行高 0.02，行距 0.005），然后一个大间距行，再一个错位行
        let blocks = [
            OCRBlock(category: "text", bbox: [0.1, 0.10, 0.9, 0.12], content: "第一行文字", page: 0),
            OCRBlock(category: "text", bbox: [0.1, 0.125, 0.9, 0.145], content: "第二行文字", page: 0),
            OCRBlock(category: "text", bbox: [0.1, 0.15, 0.5, 0.17], content: "第三行", page: 0),
            OCRBlock(category: "text", bbox: [0.1, 0.30, 0.9, 0.32], content: "新段落的开始", page: 0),   // 大间距 → 新段
            OCRBlock(category: "text", bbox: [0.5, 0.325, 0.9, 0.345], content: "错位行", page: 0),      // 左缘错位 → 不合并
            OCRBlock(category: "title", bbox: [0.1, 0.5, 0.9, 0.55], content: "章节标题", page: 0)       // 非 text → 不打断语义
        ]
        let elements = analyzer.elements(for: blocks, page: 0)
        // 期望：段落(三行合并) + 段落(新段落) + 段落(错位行) + 标题
        XCTAssertEqual(elements.count, 4)
        guard case .paragraph(let merged) = elements[0] else { return XCTFail("应为段落") }
        XCTAssertTrue(merged.contains("第一行文字"))
        XCTAssertTrue(merged.contains("第三行"))
        guard case .heading = elements[3] else { return XCTFail("末元素应为标题") }
    }

    /// 英文跨行合并时补空格
    func testLayoutAnalyzerLineMergingLatinSpace() {
        let analyzer = LayoutAnalyzer()
        let blocks = [
            OCRBlock(category: "text", bbox: [0.1, 0.10, 0.9, 0.12], content: "Hello", page: 0),
            OCRBlock(category: "text", bbox: [0.1, 0.125, 0.9, 0.145], content: "World", page: 0)
        ]
        let elements = analyzer.elements(for: blocks, page: 0)
        guard case .paragraph(let merged) = elements.first else { return XCTFail("应为段落") }
        XCTAssertEqual(merged, "Hello World")
    }

    /// 版面化 DOCX：标题样式 + 真表格 + 内联插图 + 分页，且可被回读
    func testDocxLayoutBuilder() throws {
        // 1x1 红点 PNG
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        let imageID = UUID()
        let elements: [LayoutElement] = [
            .heading(text: "第一章 概述", level: 1),
            .paragraph(text: "姓名 张三"),
            .table(rows: [["姓名", "年龄"], ["张三", "30"]]),
            .image(id: imageID, page: 0, bbox: [0.2, 0.3, 0.8, 0.6]),
            .pageBreak,
            .paragraph(text: "第二页内容")
        ]
        let data = try DocxLayoutBuilder().build(elements: elements, crops: [imageID: png])

        // zip 魔数 PK
        XCTAssertEqual(data[0], 0x50)
        XCTAssertEqual(data[1], 0x4B)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-test-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try data.write(to: tmp)

        // 校验包部件与 document.xml 结构
        let archive = try Archive(url: tmp, accessMode: .read)
        XCTAssertNotNil(archive["word/media/image1.png"], "插图应写入 word/media/")
        guard let entry = archive["word/document.xml"] else { return XCTFail("缺少 document.xml") }
        var xmlData = Data()
        _ = try archive.extract(entry, consumer: { xmlData.append($0) })
        let xml = String(decoding: xmlData, as: UTF8.self)
        XCTAssertTrue(xml.contains("<w:tbl>"), "应包含真表格")
        XCTAssertTrue(xml.contains("w:drawing"), "应包含内联插图")
        XCTAssertTrue(xml.contains("w:pStyle w:val=\"Heading1\""), "应应用 Heading1 样式")
        XCTAssertTrue(xml.contains("w:br w:type=\"page\""), "应包含分页符")

        // 文本可回读（含表格单元格）
        let text = try OfficeTextExtractor.extractDocx(url: tmp)
        XCTAssertTrue(text.contains("第一章 概述"))
        XCTAssertTrue(text.contains("张三"))
        XCTAssertTrue(text.contains("第二页内容"))
    }

    // MARK: - Web 路由

    /// 参数化路径路由回归测试（/api/tasks/{id} 曾因下标越界全部 404）
    @MainActor
    func testRouterParameterizedRoutes() async throws {
        let appState = AppState()
        let router = WebAPIRouter(appState: appState)

        func req(_ path: String, method: String = "GET") -> HTTPRequest {
            HTTPRequest(method: method, path: path, query: [:], headers: [:], body: Data(), remoteAddress: "test")
        }

        // 任务详情（参数化路径）
        let task = try appState.store.createTask(kind: .ocr, documentID: nil, fileName: "路由测试.pdf")
        let detailResp = await router.handle(req("/api/tasks/\(task.id.uuidString)"))
        XCTAssertEqual(detailResp.statusCode, 200, "GET /api/tasks/{id} 应返回 200")

        // 任务下载（参数化路径，任务未完成 → 404 属预期行为，但路由必须命中）
        let downloadResp = await router.handle(req("/api/tasks/\(task.id.uuidString)/download"))
        XCTAssertEqual(downloadResp.statusCode, 404, "未完成任务下载应返回 404（路由命中、无产物）")
        let downloadBody = String(decoding: downloadResp.body, as: UTF8.self)
        XCTAssertTrue(downloadBody.contains("产物"), "应返回产物缺失错误而非路由 404")

        // 任务/文档列表
        let tasksResp = await router.handle(req("/api/tasks"))
        XCTAssertEqual(tasksResp.statusCode, 200)
        let docsResp = await router.handle(req("/api/documents"))
        XCTAssertEqual(docsResp.statusCode, 200)
        let statusResp = await router.handle(req("/api/status"))
        XCTAssertEqual(statusResp.statusCode, 200)

        // 不存在的任务 → 404
        let missingTask = await router.handle(req("/api/tasks/\(UUID().uuidString)"))
        XCTAssertEqual(missingTask.statusCode, 404)
        // 未知路径 → 404
        let unknown = await router.handle(req("/api/nope"))
        XCTAssertEqual(unknown.statusCode, 404)
    }
}
