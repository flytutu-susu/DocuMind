import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ConvertView: View {
    @EnvironmentObject var appState: AppState

    @State private var pendingPDFs: [URL] = []
    @State private var isConverting = false
    @State private var progressText = ""
    @State private var progressValue: Double = 0
    @State private var lastMessage: String?
    @State private var isError = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "doc.on.doc")
                .font(.system(size: 48))
                .foregroundStyle(isDropTargeted ? .blue : .secondary)

            Text("PDF 转 Word")
                .font(.title2).bold()

            Text("文字版 PDF 直接提取文本层；扫描版自动逐页 OCR 后排版为 .docx\n转换完成后会弹出保存位置选择")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("选择 PDF 文件…") { showImporter = true }
                    .disabled(isConverting)
                if !pendingPDFs.isEmpty && !isConverting {
                    Button("开始转换（\(pendingPDFs.count) 个）") { convertAll() }
                        .buttonStyle(.borderedProminent)
                }
            }

            if !pendingPDFs.isEmpty {
                List {
                    ForEach(pendingPDFs, id: \.self) { url in
                        HStack {
                            Image(systemName: "doc.fill").foregroundStyle(.secondary)
                            Text(url.lastPathComponent).lineLimit(1)
                            Spacer()
                            if !isConverting {
                                Button {
                                    pendingPDFs.removeAll { $0 == url }
                                } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: 520, maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if isConverting {
                VStack(spacing: 8) {
                    ProgressView(value: progressValue)
                        .frame(width: 320)
                    Text(progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let msg = lastMessage {
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(isError ? .red : .green)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDropTargeted ? Color.blue.opacity(0.06) : .clear)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                pendingPDFs.append(contentsOf: urls.filter { !pendingPDFs.contains($0) })
            }
        }
    }

    @State private var showImporter = false

    // MARK: - 转换

    private func convertAll() {
        let files = pendingPDFs
        guard !files.isEmpty else { return }
        isConverting = true
        lastMessage = nil
        isError = false

        Task {
            var successCount = 0
            var failCount = 0
            for (index, url) in files.enumerated() {
                progressText = "(\(index + 1)/\(files.count)) \(url.lastPathComponent)"
                progressValue = 0
                do {
                    let data = try await appState.convertPDFToWord(url: url) { p, msg in
                        progressValue = p
                        progressText = "(\(index + 1)/\(files.count)) \(msg)"
                    }
                    let suggested = (url.lastPathComponent as NSString).deletingPathExtension + ".docx"
                    FileExporter.save(data: data, suggestedName: suggested, contentType: .docx)
                    successCount += 1
                } catch {
                    failCount += 1
                    lastMessage = "「\(url.lastPathComponent)」转换失败：\(error.readableMessage)"
                    isError = true
                }
            }
            isConverting = false
            pendingPDFs = []
            if failCount == 0 {
                lastMessage = "✅ 全部转换完成（\(successCount) 个文件）"
                isError = false
            }
        }
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
                if let url, url.pathExtension.lowercased() == "pdf" {
                    DispatchQueue.main.async {
                        if !pendingPDFs.contains(url) { pendingPDFs.append(url) }
                    }
                }
            }
            handled = true
        }
        return handled
    }
}
