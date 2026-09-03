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
}
