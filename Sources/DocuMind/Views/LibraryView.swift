import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// 文档库：已入库文档的列表、版本与识别结果。
struct LibraryView: View {
    @EnvironmentObject var appState: AppState
    @Binding var sidebarSelection: SidebarItem?

    @State private var documents: [DocumentRecord] = []
    @State private var selectedDocID: UUID?
    @State private var detailText: String = ""
    @State private var detailEngine: String = ""
    @State private var detailVersions: [DocumentVersionRecord] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("文档库").font(.headline)
                Text("\(documents.count) 个文档")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            if documents.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "books.vertical")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("文档库为空\n在「文字识别」或「PDF 转 Word」中处理的文件会自动入库")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(documents, selection: $selectedDocID) { doc in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(doc.name).lineLimit(1)
                            Text("\(doc.kind.displayName) · \(doc.createdAt.formatted(date: .numeric, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(doc.id)
                    }
                    .frame(minWidth: 220, maxWidth: 300)

                    detailPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { reload() }
        // 任务完成会改变识别结果，任务列表变化时刷新
        .onChange(of: appState.taskQueue.tasks.map(\.updatedAt)) { _ in
            reload()
            loadDetail()
        }
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let doc = documents.first(where: { $0.id == selectedDocID }) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doc.name).font(.headline).lineLimit(1)
                        Text("\(doc.kind.displayName) · \(detailVersions.count) 个版本 \(detailEngine.isEmpty ? "" : "· " + detailEngine)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !detailText.isEmpty {
                        Button {
                            let name = (doc.name as NSString).deletingPathExtension + ".txt"
                            FileExporter.save(data: Data(detailText.utf8), suggestedName: name, contentType: .plainText)
                        } label: { Label("导出文本", systemImage: "square.and.arrow.up") }
                        Button {
                            appState.pendingChatDraft = "以下是文档「\(doc.name)」识别出的内容，请阅读并等待我的问题：\n\n" + detailText
                            sidebarSelection = .chat
                        } label: { Label("发到对话", systemImage: "bubble.left") }
                    }
                }
                .padding()

                Divider()

                ScrollView {
                    Text(detailText.isEmpty ? "（该文档尚无识别结果）" : detailText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                Text("选择左侧文档查看")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func reload() {
        documents = (try? appState.store.listDocuments()) ?? []
    }

    private func loadDetail() {
        guard let id = selectedDocID else { return }
        detailVersions = (try? appState.store.versions(of: id)) ?? []
        if let result = try? appState.store.latestOCRResult(of: id) {
            detailText = result.text
            detailEngine = result.engine
        } else {
            detailText = ""
            detailEngine = ""
        }
    }
}
