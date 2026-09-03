import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ConvertView: View {
    @EnvironmentObject var appState: AppState

    @State private var showImporter = false
    @State private var isDropTargeted = false

    private var convertTasks: [TaskRecord] {
        appState.taskQueue.tasks.filter { $0.kind == .pdfToWord }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { showImporter = true } label: {
                    Label("选择 PDF 文件", systemImage: "plus")
                }
                Text("拖入 PDF 即入队转换，产物自动保存到文档库")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            if convertTasks.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(convertTasks) { task in
                        ConvertTaskRow(task: task)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                appState.enqueueConversion(urls)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.on.doc")
                .font(.system(size: 48))
                .foregroundStyle(isDropTargeted ? .blue : .secondary)
            Text("PDF 转 Word · 版面保持")
                .font(.title3)
            Text("本地引擎：标题/正文/表格/插图结构化还原\n表格生成真表格，插图按版面坐标裁剪嵌入，逐页分页")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if appState.settings.ocrEngine != .localMLX {
                Text("ℹ️ 当前为百度云引擎：走含位置版行级版面重建（无表格/图片语义）。\n本地 Unlimited-OCR 引擎可获得完整语义版面（标题/表格/插图）。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDropTargeted ? Color.blue.opacity(0.06) : .clear)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL? = nil
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let url, url.pathExtension.lowercased() == "pdf" {
                    DispatchQueue.main.async {
                        appState.enqueueConversion([url])
                    }
                }
            }
            handled = true
        }
        return handled
    }
}

private struct ConvertTaskRow: View {
    let task: TaskRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.fileName).lineLimit(1)
                if task.state == .running {
                    HStack(spacing: 8) {
                        ProgressView(value: task.progress).frame(maxWidth: 200)
                        Text(task.message).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(statusLine).font(.caption)
                        .foregroundStyle(task.state == .failed ? .red : .secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if task.state == .success, let path = task.outputPath {
                Button {
                    FileExporter.saveCopy(of: URL(fileURLWithPath: path),
                                          suggestedName: task.outputName ?? "output.docx",
                                          contentType: .docx)
                } label: { Label("导出 Word", systemImage: "square.and.arrow.up") }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("在访达中显示")
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch task.state {
        case .pending: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch task.state {
        case .success: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    private var statusLine: String {
        switch task.state {
        case .pending: return "排队中"
        case .running: return task.message
        case .success: return "完成 · \(task.engine)"
        case .failed: return "失败：\(task.error ?? "未知错误")"
        }
    }
}
