import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// 通用导出工具
enum FileExporter {
    @MainActor
    static func save(data: Data, suggestedName: String, contentType: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "保存失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

extension UTType {
    static let docx = UTType(filenameExtension: "docx") ?? .data
    static let xlsx = UTType(filenameExtension: "xlsx") ?? .data
}

struct OCRView: View {
    @EnvironmentObject var appState: AppState
    @Binding var sidebarSelection: SidebarItem?

    @State private var showImporter = false
    @State private var selectedTaskID: UUID?
    @State private var isDropTargeted = false

    private static let importTypes: [UTType] = [.pdf, .image, .docx, .xlsx]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if appState.tasks.isEmpty {
                emptyState
            } else {
                taskList
                Divider()
                detailPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                appState.processFiles(urls)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .docuMindOpenFiles)) { _ in
            showImporter = true
        }
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                showImporter = true
            } label: {
                Label("选择文件", systemImage: "plus")
            }

            Text("支持 PDF / 图片 / docx / xlsx，可直接拖拽到窗口")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if appState.tasks.contains(where: { !$0.status.isRunning }) {
                Button("清空已完成") { appState.clearFinishedTasks() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 52))
                .foregroundStyle(isDropTargeted ? .blue : .secondary)
            Text("拖拽文件到这里，或点击「选择文件」")
                .foregroundStyle(.secondary)
            Text("PDF 自动判断文本层/扫描件；docx、xlsx 直接本地解析")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDropTargeted ? Color.blue.opacity(0.06) : .clear)
    }

    // MARK: - 任务列表

    private var taskList: some View {
        List(selection: $selectedTaskID) {
            ForEach(appState.tasks) { task in
                TaskRow(task: task)
                    .tag(task.id)
                    .contextMenu {
                        Button("复制结果") { copy(task.resultText) }
                            .disabled(task.resultText.isEmpty)
                        Divider()
                        Button("移除") { appState.removeTask(task.id) }
                    }
            }
        }
        .frame(minHeight: 160, maxHeight: 260)
    }

    // MARK: - 结果详情

    private var selectedTask: DocumentTask? {
        appState.tasks.first { $0.id == selectedTaskID } ?? appState.tasks.first(where: { !$0.resultText.isEmpty })
    }

    private var detailPanel: some View {
        VStack(spacing: 0) {
            if let task = selectedTask {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.fileName).font(.headline).lineLimit(1)
                        Text("\(task.kind.displayName) · \(task.engine.isEmpty ? task.status.shortDescription : task.engine)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !task.resultText.isEmpty {
                        Button { copy(task.resultText) } label: { Label("复制", systemImage: "doc.on.clipboard") }
                        Button {
                            let name = (task.fileName as NSString).deletingPathExtension + ".txt"
                            FileExporter.save(data: Data(task.resultText.utf8), suggestedName: name, contentType: .plainText)
                        } label: { Label("导出", systemImage: "square.and.arrow.up") }
                        Button {
                            appState.pendingChatDraft = "以下是文档「\(task.fileName)」识别出的内容，请阅读并等待我的问题：\n\n" + task.resultText
                            sidebarSelection = .chat
                        } label: { Label("发到对话", systemImage: "bubble.left") }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                ScrollView {
                    Text(task.resultText.isEmpty ? placeholder(for: task) : task.resultText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                Text("在上方选择一个任务查看识别结果")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(for task: DocumentTask) -> String {
        switch task.status {
        case .failed(let err): return "❌ \(err)"
        case .processing(_, let msg): return "处理中…\(msg)"
        default: return ""
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - 拖拽

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
                if let url {
                    DispatchQueue.main.async {
                        appState.processFiles([url])
                    }
                }
            }
            handled = true
        }
        return handled
    }
}

// MARK: - 任务行

private struct TaskRow: View {
    let task: DocumentTask

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.fileName).lineLimit(1)
                if case .processing(let progress, let message) = task.status {
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                            .frame(width: 120)
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch task.status {
        case .pending: return "clock"
        case .processing: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch task.status {
        case .done: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    private var statusText: String {
        switch task.status {
        case .done: return "\(task.engine) · \(task.resultText.count) 字"
        default: return task.status.shortDescription
        }
    }
}
