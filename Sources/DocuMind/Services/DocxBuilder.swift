import Foundation
import ZIPFoundation

enum DocxBuilderError: LocalizedError {
    case cannotCreateArchive

    var errorDescription: String? { "创建 docx 文件失败。" }
}

/// 最小可用的 docx（OOXML）生成器。
/// 输入：段落列表（空段落视为分页/空行），输出标准 .docx，可被 Word / WPS / Pages 打开。
enum DocxBuilder {

    /// 将纯文本（按行/空行分段）写入 docx。
    /// - Parameters:
    ///   - text: 全文文本；连续两个换行视为段落分隔，"----- 第 N 页 -----" 分隔符会转换成分页符
    ///   - outputURL: 输出文件路径
    static func build(text: String, to outputURL: URL) throws {
        var paragraphs: [[ParagraphRun]] = []
        var pendingPageBreak = false

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("----- 第 "), line.hasSuffix(" 页 -----") {
                pendingPageBreak = true
                continue
            }
            if line.isEmpty {
                if !paragraphs.isEmpty { paragraphs.append([]) }  // 空行
                continue
            }
            var runs: [ParagraphRun] = []
            if pendingPageBreak {
                runs.append(ParagraphRun(text: "", pageBreakBefore: true))
                pendingPageBreak = false
            }
            runs.append(ParagraphRun(text: line, pageBreakBefore: false))
            paragraphs.append(runs)
        }

        try build(paragraphs: paragraphs, to: outputURL)
    }

    struct ParagraphRun {
        let text: String
        let pageBreakBefore: Bool
    }

    static func build(paragraphs: [[ParagraphRun]], to outputURL: URL) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        guard let archive = Archive(url: outputURL, accessMode: .create) else {
            throw DocxBuilderError.cannotCreateArchive
        }

        try addFile(archive, "[Content_Types].xml", contentTypesXML)
        try addFile(archive, "_rels/.rels", rootRelsXML)
        try addFile(archive, "word/_rels/document.xml.rels", documentRelsXML)
        try addFile(archive, "word/styles.xml", stylesXML)
        try addFile(archive, "word/document.xml", documentXML(paragraphs: paragraphs))
    }

    // MARK: - XML 模板

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
      <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
    </Types>
    """

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private static let documentRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """

    // 中文字体兜底（宋体正文），避免打开时字体缺失
    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:docDefaults>
        <w:rPrDefault>
          <w:rPr>
            <w:rFonts w:ascii="Times New Roman" w:eastAsia="宋体" w:hAnsi="Times New Roman"/>
            <w:sz w:val="21"/>
          </w:rPr>
        </w:rPrDefault>
      </w:docDefaults>
      <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
        <w:name w:val="Normal"/>
      </w:style>
    </w:styles>
    """

    private static func documentXML(paragraphs: [[ParagraphRun]]) -> String {
        var body = ""
        for runs in paragraphs {
            body.append("<w:p>")
            for run in runs {
                if run.pageBreakBefore {
                    body.append(#"<w:r><w:br w:type="page"/></w:r>"#)
                }
                if !run.text.isEmpty {
                    body.append("<w:r><w:t xml:space=\"preserve\">\(escapeXML(run.text))</w:t></w:r>")
                }
            }
            body.append("</w:p>")
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
        \(body)
            <w:sectPr>
              <w:pgSz w:w="11906" w:h="16838"/>
              <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>
            </w:sectPr>
          </w:body>
        </w:document>
        """
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func addFile(_ archive: Archive, _ path: String, _ content: String) throws {
        let data = Data(content.utf8)
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate,
            provider: { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        )
    }
}
