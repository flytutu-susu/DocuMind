import Foundation

/// 版面分析器：把模型输出的语义块（OCRBlock）转换为版面元素（LayoutElement）。
///
/// 职责：
/// - 类别映射：title/header → heading（按 bbox 高度推断级别）；text/formula/footer… → paragraph
/// - 表格：markdown 表格文本 → 二维数组（解析失败降级为段落）
/// - 图片：bbox 有效才生成插图元素（退化区域丢弃）
/// - 阅读顺序：保持模型输出顺序（Unlimited-OCR 单次前向已按阅读顺序输出）
struct LayoutAnalyzer {

    /// A4 页面高度（pt），用于从归一化 bbox 推断字号级别
    var pageHeightPoints: CGFloat = 842

    /// 分析单页 blocks，产出该页的版面元素序列（不含分页符，由调用方插入）
    func elements(for blocks: [OCRBlock], page: Int) -> [LayoutElement] {
        let merged = mergeLineBlocks(blocks)
        var elements: [LayoutElement] = []
        for block in merged {
            let content = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
            switch block.category {
            case "title":
                guard !content.isEmpty else { continue }
                elements.append(.heading(text: content, level: headingLevel(for: block)))
            case "header":
                guard !content.isEmpty else { continue }
                elements.append(.heading(text: content, level: 3))
            case "table":
                if let rows = Self.parseMarkdownTable(content) {
                    elements.append(.table(rows: rows))
                } else if !content.isEmpty {
                    elements.append(.paragraph(text: content))
                }
            case "image", "figure":
                // bbox 有效且非退化区域才生成插图
                guard block.bbox.count == 4,
                      block.bbox[2] - block.bbox[0] > 0.02,
                      block.bbox[3] - block.bbox[1] > 0.02 else { continue }
                elements.append(.image(id: UUID(), page: block.page, bbox: block.bbox))
            default:
                // text / footer / footnote / caption / formula / reference …
                guard !content.isEmpty else { continue }
                elements.append(.paragraph(text: content))
            }
        }
        return elements
    }

    // MARK: - 行级块合并（云端含位置版 OCR 的逐行输出 → 段落）

    /// 把同页连续的行级 text 块按垂直间距合并成段落。
    /// 合并条件：同页 + 都是 text + 都有 bbox + 左边缘对齐 + 行间距 < 1.8 倍行高。
    /// 本地 Unlimited-OCR 的块已是段落级（bbox 很高，行距测试自然不通过），不受影响。
    func mergeLineBlocks(_ blocks: [OCRBlock]) -> [OCRBlock] {
        var result: [OCRBlock] = []
        for block in blocks {
            guard let last = result.last,
                  last.category == "text", block.category == "text",
                  last.page == block.page,
                  last.bbox.count == 4, block.bbox.count == 4 else {
                result.append(block)
                continue
            }
            let lineHeight = last.bbox[3] - last.bbox[1]
            let gap = block.bbox[1] - last.bbox[3]
            let leftAligned = abs(last.bbox[0] - block.bbox[0]) < 0.05
            let xOverlap = last.bbox[0] < block.bbox[2] && block.bbox[0] < last.bbox[2]
            guard lineHeight > 0, gap > -0.5 * lineHeight, gap < 1.8 * lineHeight,
                  leftAligned, xOverlap else {
                result.append(block)
                continue
            }
            // 合并：CJK 相邻直接拼接，拉丁系补空格
            let needSpace = (last.content.last?.isCJK == false) && (block.content.first?.isCJK == false)
            let mergedContent = last.content + (needSpace ? " " : "") + block.content
            let mergedBBox = [min(last.bbox[0], block.bbox[0]), last.bbox[1],
                              max(last.bbox[2], block.bbox[2]), block.bbox[3]]
            result[result.count - 1] = OCRBlock(category: "text", bbox: mergedBBox,
                                                content: mergedContent, page: last.page)
        }
        return result
    }

    // MARK: - 标题级别推断

    /// 按 bbox 高度推断标题级别：块越高字越大
    private func headingLevel(for block: OCRBlock) -> Int {
        guard block.bbox.count == 4 else { return 2 }
        let heightPt = CGFloat(block.bbox[3] - block.bbox[1]) * pageHeightPoints
        if heightPt >= 24 { return 1 }
        return 2
    }

    // MARK: - markdown 表格解析

    /// 解析 "| a | b |\n|---|---|\n| 1 | 2 |" 形式的 markdown 表格；无法解析返回 nil
    static func parseMarkdownTable(_ content: String) -> [[String]]? {
        var rows: [[String]] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            var s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("|") else { continue }
            s.removeFirst()
            if s.hasSuffix("|") { s.removeLast() }   // 去掉行尾 |，避免产生尾部空单元格
            let cells = s.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // 跳过分隔行 |---|---|
            let isSeparator = cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }
            if isSeparator { continue }
            if !cells.isEmpty { rows.append(cells) }
        }
        // 至少 2 列才认作表格
        guard rows.count >= 1, let maxCols = rows.map({ $0.count }).max(), maxCols >= 2 else {
            return nil
        }
        // 归一化列数
        let cols = maxCols
        return rows.map { row in
            row.count == cols ? row : row + Array(repeating: "", count: cols - row.count)
        }
    }
}

private extension Character {
    /// 是否为 CJK 字符（中日韩统一表意文字及全角标点范围）
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||   // CJK 统一表意
            (0x3400...0x4DBF).contains(scalar.value) ||   // 扩展 A
            (0x3000...0x303F).contains(scalar.value) ||   // CJK 标点
            (0xFF00...0xFFEF).contains(scalar.value)      // 全角字符
        }
    }
}
