import Foundation
import AppKit
import ImageIO
import ZIPFoundation

enum DocxLayoutError: LocalizedError {
    case emptyDocument

    var errorDescription: String? { "没有可写入的版面内容。" }
}

/// 版面化 DOCX 生成器（OOXML）。
/// 输入 LayoutElement 序列 + 插图像素数据，输出标准 .docx：
/// - 标题 → Heading1-3 样式（Word 大纲视图可识别，可生成目录）
/// - 表格 → 真 w:tbl（Table Grid 边框，首行加粗）
/// - 插图 → w:drawing 内联嵌入（word/media/ + 关系表），宽度自适应页面
/// - 分页符
final class DocxLayoutBuilder {

    private struct ImageEntry {
        let id: UUID
        let data: Data
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// EMU 换算：1 px(96dpi) = 9525 EMU；页面可用宽约 6.0 英寸
    private let maxImageWidthEMU = Int(6.0 * 914400)

    /// - Parameters:
    ///   - elements: 版面元素序列
    ///   - crops: 插图 ID → PNG 数据（由转换器按 bbox 从页面渲染裁剪）
    func build(elements: [LayoutElement], crops: [UUID: Data]) throws -> Data {
        guard !elements.isEmpty else { throw DocxLayoutError.emptyDocument }

        // 收集按引用顺序注册的插图
        var imageEntries: [ImageEntry] = []
        for element in elements {
            guard let id = element.imageID, let data = crops[id] else { continue }
            let (w, h) = Self.pngSize(data) ?? (800, 600)
            imageEntries.append(ImageEntry(id: id, data: data, pixelWidth: w, pixelHeight: h))
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("documind-layout-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let archive = try Archive(url: tmp, accessMode: .create)
        try addFile(archive, "[Content_Types].xml", contentTypesXML(hasImages: !imageEntries.isEmpty))
        try addFile(archive, "_rels/.rels", rootRelsXML)
        try addFile(archive, "word/_rels/document.xml.rels", documentRelsXML(imageCount: imageEntries.count))
        try addFile(archive, "word/styles.xml", stylesXML)
        try addFile(archive, "word/document.xml", documentXML(elements: elements, images: imageEntries))
        for (index, entry) in imageEntries.enumerated() {
            try addFile(archive, "word/media/image\(index + 1).png", data: entry.data)
        }

        return try Data(contentsOf: tmp)
    }

    // MARK: - document.xml

    private func documentXML(elements: [LayoutElement], images: [ImageEntry]) -> String {
        var body = ""
        for element in elements {
            switch element {
            case .heading(let text, let level):
                let style = "Heading\(min(max(level, 1), 3))"
                body += #"<w:p><w:pPr><w:pStyle w:val="\#(style)"/></w:pPr>"# + runXML(text, bold: true) + "</w:p>"

            case .paragraph(let text):
                // 段落内保留换行
                body += "<w:p>"
                let parts = text.components(separatedBy: "\n")
                for (index, part) in parts.enumerated() {
                    if index > 0 { body += "<w:r><w:br/></w:r>" }
                    body += runXML(part)
                }
                body += "</w:p>"

            case .table(let rows):
                body += tableXML(rows: rows)

            case .image(let id, _, _):
                if let index = images.firstIndex(where: { $0.id == id }) {
                    body += imageXML(index: index, entry: images[index])
                }

            case .pageBreak:
                body += #"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"#
            }
        }

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
                    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                    xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
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

    private func runXML(_ text: String, bold: Bool = false) -> String {
        guard !text.isEmpty else { return "" }
        let rpr = bold ? "<w:rPr><w:b/></w:rPr>" : ""
        return "<w:r>\(rpr)<w:t xml:space=\"preserve\">\(escapeXML(text))</w:t></w:r>"
    }

    private func tableXML(rows: [[String]]) -> String {
        guard let cols = rows.first?.count, cols > 0 else { return "" }
        let colWidth = 9360 / cols   // 页面可用宽度约 9360 dxa

        var xml = """
        <w:tbl>
          <w:tblPr>
            <w:tblW w:w="9360" w:type="dxa"/>
            <w:tblBorders>
              <w:top w:val="single" w:sz="4" w:color="auto"/>
              <w:left w:val="single" w:sz="4" w:color="auto"/>
              <w:bottom w:val="single" w:sz="4" w:color="auto"/>
              <w:right w:val="single" w:sz="4" w:color="auto"/>
              <w:insideH w:val="single" w:sz="4" w:color="auto"/>
              <w:insideV w:val="single" w:sz="4" w:color="auto"/>
            </w:tblBorders>
          </w:tblPr>
          <w:tblGrid>
        """
        for _ in 0..<cols { xml += "<w:gridCol w:w=\"\(colWidth)\"/>" }
        xml += "</w:tblGrid>"

        for (rowIndex, row) in rows.enumerated() {
            xml += "<w:tr>"
            for cell in row {
                xml += """
                <w:tc><w:tcPr><w:tcW w:w="\(colWidth)" w:type="dxa"/></w:tcPr>
                <w:p>\(runXML(cell, bold: rowIndex == 0))</w:p></w:tc>
                """
            }
            xml += "</w:tr>"
        }
        xml += "</w:tbl>"
        return xml
    }

    private func imageXML(index: Int, entry: ImageEntry) -> String {
        let rid = "rIdImg\(index + 1)"
        // 等比缩放到页面宽度以内
        var widthEMU = entry.pixelWidth * 9525
        var heightEMU = entry.pixelHeight * 9525
        if widthEMU > maxImageWidthEMU {
            heightEMU = heightEMU * maxImageWidthEMU / widthEMU
            widthEMU = maxImageWidthEMU
        }
        let docPrID = index + 1
        return """
        <w:p><w:r><w:drawing>
          <wp:inline distT="0" distB="0" distL="0" distR="0">
            <wp:extent cx="\(widthEMU)" cy="\(heightEMU)"/>
            <wp:docPr id="\(docPrID)" name="image\(index + 1)"/>
            <a:graphic>
              <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                <pic:pic>
                  <pic:nvPicPr><pic:cNvPr id="\(docPrID)" name="image\(index + 1).png"/><pic:cNvPicPr/></pic:nvPicPr>
                  <pic:blipFill><a:blip r:embed="\(rid)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
                  <pic:spPr>
                    <a:xfrm><a:off x="0" y="0"/><a:ext cx="\(widthEMU)" cy="\(heightEMU)"/></a:xfrm>
                    <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
                  </pic:spPr>
                </pic:pic>
              </a:graphicData>
            </a:graphic>
          </wp:inline>
        </w:drawing></w:r></w:p>
        """
    }

    // MARK: - 包部件

    private func contentTypesXML(hasImages: Bool) -> String {
        let pngDefault = hasImages
            ? #"<Default Extension="png" ContentType="image/png"/>"#
            : ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          \(pngDefault)
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        </Types>
        """
    }

    private let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private func documentRelsXML(imageCount: Int) -> String {
        var rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        """
        for i in 0..<imageCount {
            rels += """
              <Relationship Id="rIdImg\(i + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image\(i + 1).png"/>
            """
        }
        rels += "</Relationships>"
        return rels
    }

    private let stylesXML = """
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
      <w:style w:type="paragraph" w:styleId="Heading1">
        <w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
        <w:pPr><w:outlineLvl w:val="0"/><w:spacing w:before="240" w:after="120"/></w:pPr>
        <w:rPr><w:rFonts w:ascii="Arial" w:eastAsia="黑体" w:hAnsi="Arial"/><w:b/><w:sz w:val="32"/></w:rPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Heading2">
        <w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
        <w:pPr><w:outlineLvl w:val="1"/><w:spacing w:before="200" w:after="100"/></w:pPr>
        <w:rPr><w:rFonts w:ascii="Arial" w:eastAsia="黑体" w:hAnsi="Arial"/><w:b/><w:sz w:val="28"/></w:rPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Heading3">
        <w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
        <w:pPr><w:outlineLvl w:val="2"/><w:spacing w:before="160" w:after="80"/></w:pPr>
        <w:rPr><w:rFonts w:ascii="Arial" w:eastAsia="黑体" w:hAnsi="Arial"/><w:b/><w:sz w:val="24"/></w:rPr>
      </w:style>
    </w:styles>
    """

    // MARK: - 工具

    private func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// 读 PNG 像素尺寸（用于计算嵌入比例）
    static func pngSize(_ data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    private func addFile(_ archive: Archive, _ path: String, _ content: String) throws {
        try addFile(archive, path, data: Data(content.utf8))
    }

    private func addFile(_ archive: Archive, _ path: String, data: Data) throws {
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
