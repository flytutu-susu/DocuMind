import Foundation
import ZIPFoundation

enum OfficeExtractError: LocalizedError {
    case invalidPackage(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .invalidPackage(let msg): return "Office 文档解析失败：\(msg)"
        case .empty: return "文档中没有可提取的文字内容。"
        }
    }
}

/// 从 docx / xlsx 中直接提取文字（数字文档无需 OCR）。
enum OfficeTextExtractor {

    // MARK: - docx

    static func extractDocx(url: URL) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive["word/document.xml"] else {
            throw OfficeExtractError.invalidPackage("缺少 word/document.xml")
        }
        let xml = try readEntry(archive, entry)
        let parser = DocxXMLParser()
        let xmlParser = Foundation.XMLParser(data: xml)
        xmlParser.delegate = parser
        xmlParser.parse()
        let text = parser.result
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OfficeExtractError.empty
        }
        return text
    }

    // MARK: - xlsx

    static func extractXlsx(url: URL) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)

        // 1. 共享字符串表
        var sharedStrings: [String] = []
        if let entry = archive["xl/sharedStrings.xml"] {
            let parser = SharedStringsParser()
            let xp = Foundation.XMLParser(data: try readEntry(archive, entry))
            xp.delegate = parser
            xp.parse()
            sharedStrings = parser.strings
        }

        // 2. 工作表清单：workbook.xml + rels 映射 rId -> 文件路径
        var sheetFiles: [(name: String, path: String)] = []
        if let wbEntry = archive["xl/workbook.xml"] {
            let wbParser = WorkbookParser()
            let xp = Foundation.XMLParser(data: try readEntry(archive, wbEntry))
            xp.delegate = wbParser
            xp.parse()

            var rels: [String: String] = [:]
            if let relsEntry = archive["xl/_rels/workbook.xml.rels"] {
                let relsParser = RelsParser()
                let rp = Foundation.XMLParser(data: try readEntry(archive, relsEntry))
                rp.delegate = relsParser
                rp.parse()
                rels = relsParser.rels
            }
            for sheet in wbParser.sheets {
                if let target = rels[sheet.rid] {
                    let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
                    sheetFiles.append((sheet.name, path))
                }
            }
        }
        // 兜底：直接枚举 worksheets 目录
        if sheetFiles.isEmpty {
            let fallback = archive.filter { $0.path.hasPrefix("xl/worksheets/sheet") && $0.path.hasSuffix(".xml") }
            sheetFiles = fallback.sorted { $0.path < $1.path }.map { ($0.path, $0.path) }
        }

        var output: [String] = []
        for (index, sheet) in sheetFiles.enumerated() {
            guard let entry = archive[sheet.path] else { continue }
            let parser = SheetParser(sharedStrings: sharedStrings)
            let xp = Foundation.XMLParser(data: try readEntry(archive, entry))
            xp.delegate = parser
            xp.parse()
            if index > 0 { output.append("") }
            output.append("===== 工作表：\(sheet.name) =====")
            output.append(parser.result)
        }

        let text = output.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OfficeExtractError.empty
        }
        return text
    }

    // MARK: - 工具

    private static func readEntry(_ archive: Archive, _ entry: Entry) throws -> Data {
        var data = Data()
        _ = try archive.extract(entry, consumer: { chunk in data.append(chunk) })
        return data
    }
}

// MARK: - docx 段落解析器

private final class DocxXMLParser: NSObject, XMLParserDelegate {
    private var buffer = ""
    var result: String {
        // 收敛多余空行
        buffer.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .reduce(into: [String]()) { acc, line in
                if line.isEmpty, acc.last?.isEmpty != false { return }
                acc.append(line)
            }
            .joined(separator: "\n")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "w:tab": buffer.append("\t")
        case "w:br": buffer.append("\n")
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "w:p": buffer.append("\n")
        case "w:tc": buffer.append("\t")   // 表格单元格分隔
        case "w:tr": buffer.append("\n")
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer.append(string)
    }
}

// MARK: - xlsx 共享字符串解析器

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private(set) var strings: [String] = []
    private var current = ""
    private var insideSI = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "si" { insideSI = true; current = "" }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "si" { insideSI = false; strings.append(current) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideSI { current.append(string) }
    }
}

// MARK: - xlsx 工作簿解析器

private final class WorkbookParser: NSObject, XMLParserDelegate {
    private(set) var sheets: [(name: String, rid: String)] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "sheet",
           let name = attributeDict["name"],
           let rid = attributeDict["r:id"] ?? attributeDict["id"] {
            sheets.append((name, rid))
        }
    }
}

private final class RelsParser: NSObject, XMLParserDelegate {
    private(set) var rels: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "Relationship",
           let id = attributeDict["Id"],
           let target = attributeDict["Target"] {
            rels[id] = target
        }
    }
}

// MARK: - xlsx 工作表解析器（输出 TSV）

private final class SheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var rows: [[(col: Int, value: String)]] = []
    private var currentRow: [(col: Int, value: String)] = []
    private var currentCellRef = ""
    private var currentCellType = ""
    private var currentValue = ""
    private var insideInlineStr = false
    private var inlineText = ""

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    var result: String {
        rows.map { row in
            guard let maxCol = row.map({ $0.col }).max() else { return "" }
            var cells = Array(repeating: "", count: maxCol + 1)
            for cell in row { cells[cell.col] = cell.value }
            // 去掉行尾空单元格
            while cells.last?.isEmpty == true { cells.removeLast() }
            return cells.joined(separator: "\t")
        }
        .reduce(into: [String]()) { acc, line in
            if line.isEmpty, acc.last?.isEmpty != false { return }
            acc.append(line)
        }
        .joined(separator: "\n")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "row":
            currentRow = []
        case "c":
            currentCellRef = attributeDict["r"] ?? ""
            currentCellType = attributeDict["t"] ?? ""
            currentValue = ""
            inlineText = ""
            insideInlineStr = false
        case "is":
            insideInlineStr = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "row":
            rows.append(currentRow)
        case "c":
            currentRow.append((col: Self.columnIndex(from: currentCellRef), value: resolveValue()))
        case "is":
            insideInlineStr = false
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideInlineStr {
            inlineText.append(string)
        } else {
            currentValue.append(string)
        }
    }

    private func resolveValue() -> String {
        switch currentCellType {
        case "s":
            if let idx = Int(currentValue.trimmingCharacters(in: .whitespaces)),
               idx >= 0, idx < sharedStrings.count {
                return sharedStrings[idx]
            }
            return ""
        case "inlineStr":
            return inlineText
        case "b":
            return currentValue == "1" ? "TRUE" : "FALSE"
        default:
            return currentValue
        }
    }

    /// "B12" -> 1（0 起始列号）
    private static func columnIndex(from cellRef: String) -> Int {
        var index = 0
        for ch in cellRef {
            guard let scalar = ch.unicodeScalars.first else { break }
            if ch >= "A" && ch <= "Z" {
                index = index * 26 + Int(scalar.value) - Int(Character("A").unicodeScalars.first!.value) + 1
            } else {
                break
            }
        }
        return max(index - 1, 0)
    }
}
