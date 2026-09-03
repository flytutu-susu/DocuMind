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

    /// 复制已有文件到用户选择的位置
    @MainActor
    static func saveCopy(of fileURL: URL, suggestedName: String, contentType: UTType) {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        save(data: data, suggestedName: suggestedName, contentType: contentType)
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
    @State private var resultText: String = ""

    private static let importTypes: [UTType] = [.pdf, .image, .docx, .xlsx]

    /// OCR 类任务（转换任务在「PDF 转 Word」页展示）
    private var ocrTasks: [TaskRecord] {
        appState.taskQueue.tasks.filter { $0.kind == .ocr }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if ocrTasks.isEmpty {
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

            Text("支持 PDF / 图片 / docx / xlsx，拖入即进入任务队列")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if ocrTasks.contains(where: { !$0.isActive }) {
                Button("清空已完成") { clearFinished() }
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
            Text("本地 Unlimited-OCR 结构化识别 · 结果自动入库到「文档库」")
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
            ForEach(ocrTasks) { task in
                TaskRow(task: task)
                    .tag(task.id)
            }
        }
        .frame(minHeight: 160, maxHeight: 260)
    }

    // MARK: - 结果详情

    private var selectedTask: TaskRecord? {
        ocrTasks.first { $0.id == selectedTaskID } ?? ocrTasks.first(where: { $0.state == .success })
    }

    private var detailPanel: some View {
        VStack(spacing: 0) {
            if let task = selectedTask {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.fileName).font(.headline).lineLimit(1)
                        Text("\(task.kind.displayName) · \(task.engine.isEmpty ? task.message : task.engine)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !resultText.isEmpty {
                        Button { copy(resultText) } label: { Label("复制", systemImage: "doc.on.clipboard") }
                        Button {
                            let name = (task.fileName as NSString).deletingPathExtension + ".txt"
                            FileExporter.save(data: Data(resultText.utf8), suggestedName: name, contentType: .plainText)
                        } label: { Label("导出", systemImage: "square.and.arrow.up") }
                        Button {
                            appState.pendingChatDraft = "以下是文档「\(task.fileName)」识别出的内容，请阅读并等待我的问题：\n\n" + resultText
                            sidebarSelection = .chat
                        } label: { Label("发到对话", systemImage: "bubble.left") }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                ScrollView {
                    Text(displayText(for: task))
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                // 任务更新（完成/进度变化）时重新加载结果文本
                .task(id: task.updatedAt) {
                    if task.state == .success {
                        resultText = appState.taskQueue.resultText(for: task) ?? ""
                    }
                }
            } else {
                Text("在上方选择一个任务查看识别结果")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func displayText(for task: TaskRecord) -> String {
        switch task.state {
        case .failed: return "❌ \(task.error ?? "未知错误")"
        case .running: return "处理中…\(task.message)"
        case .pending: return "排队中…"
        case .success: return resultText.isEmpty ? "（无文本结果）" : resultText
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func clearFinished() {
        // 目前仅清除视图选择；任务记录保留在库中供文档库/追溯使用
        selectedTaskID = nil
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
    let task: TaskRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.fileName).lineLimit(1)
                if task.state == .running {
                    HStack(spacing: 8) {
                        ProgressView(value: task.progress)
                            .frame(width: 120)
                        Text(task.message).font(.caption).foregroundStyle(.secondary)
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

    private var statusText: String {
        switch task.state {
        case .success: return task.engine.isEmpty ? "完成" : task.engine
        case .failed: return "失败：\(task.error ?? "")"
        case .pending: return "排队中"
        case .running: return task.message
        }
    }
}
