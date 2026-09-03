import Foundation

// MARK: - 版面元素（Layout 层的核心数据模型）
//
// 数据流：
//   Unlimited-OCR grounding 输出
//     → [OCRBlock]（Storage/Records.swift：category/bbox/content/page）
//     → LayoutAnalyzer → [LayoutElement]
//     → DocxLayoutBuilder → .docx
//
// 模型输出示例：
//   {"category":"title","text":"第一章","bbox":[0.04,0.02,0.9,0.06],"page":0}
//   {"category":"table","content":"| a | b |\\n|---|---|\\n| 1 | 2 |"}
//   {"category":"image","bbox":[0.2,0.3,0.8,0.6]}

/// 版面元素：与 OOXML 结构一一对应
enum LayoutElement {
    /// 标题（level 1-3，映射 OOXML Heading1-3 样式）
    case heading(text: String, level: Int)
    /// 正文段落
    case paragraph(text: String)
    /// 真表格（含表头，rows[0] 加粗）
    case table(rows: [[String]])
    /// 插图：bbox 为归一化坐标（0-1，相对所在页），实际像素裁剪由转换器完成
    case image(id: UUID, page: Int, bbox: [Double])
    /// 分页符
    case pageBreak
}

extension LayoutElement {
    /// 该元素引用的插图 ID（供裁剪回填）
    var imageID: UUID? {
        if case .image(let id, _, _) = self { return id }
        return nil
    }
}
