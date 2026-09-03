import Foundation

/// 串行任务队列：OCR / 转换任务排队执行，状态持久化到 SQLite。
/// App 界面与局域网 Web API 共用这一个队列，请求入队后立即返回 task_id，不阻塞调用方。
@MainActor
final class TaskQueue: ObservableObject {
    @Published private(set) var tasks: [TaskRecord] = []

    let store: DocumentStore
    private let settingsStore: SettingsStore

    private var pendingIDs: [UUID] = []
    private var workerRunning = false

    init(store: DocumentStore, settingsStore: SettingsStore) {
        self.store = store
        self.settingsStore = settingsStore
        refresh()
        // 上次异常退出遗留的 running/pending 任务标记为失败
        for task in tasks where task.isActive {
            try? store.updateTask(task.id, state: .failed, error: "应用重启，任务中断")
        }
        refresh()
    }

    // MARK: - 入队

    /// 文件入库 + 创建 OCR 任务
    @discardableResult
    func enqueueOCR(fileURL: URL) throws -> UUID {
        let kind = DocumentKind(fileExtension: fileURL.pathExtension)
        guard kind != .unknown else { throw DocumentProcessError.unsupportedType }
        let doc = try store.createDocument(name: fileURL.lastPathComponent, kind: kind, sourceFile: fileURL)
        let task = try store.createTask(kind: .ocr, documentID: doc.id, fileName: doc.name)
        pendingIDs.append(task.id)
        refresh()
        kickWorker()
        return task.id
    }

    /// 原始字节入库（Web 上传）+ 创建 OCR 任务
    @discardableResult
    func enqueueOCR(data: Data, fileName: String) throws -> UUID {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("documind-incoming-\(UUID().uuidString)")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 用原始文件名入库，临时文件仅作搬运
        let kind = DocumentKind(fileExtension: (fileName as NSString).pathExtension)
        guard kind != .unknown else { throw DocumentProcessError.unsupportedType }
        let doc = try store.createDocument(name: fileName, kind: kind, sourceFile: tmp.renamed(to: fileName))
        let task = try store.createTask(kind: .ocr, documentID: doc.id, fileName: fileName)
        pendingIDs.append(task.id)
        refresh()
        kickWorker()
        return task.id
    }

    @discardableResult
    func enqueueConvert(fileURL: URL) throws -> UUID {
        let doc = try store.createDocument(name: fileURL.lastPathComponent, kind: .pdf, sourceFile: fileURL)
        let task = try store.createTask(kind: .pdfToWord, documentID: doc.id, fileName: doc.name)
        pendingIDs.append(task.id)
        refresh()
        kickWorker()
        return task.id
    }

    @discardableResult
    func enqueueConvert(data: Data, fileName: String) throws -> UUID {
        let tmpDir = FileManager.default.temporaryDirectory
        let tmp = tmpDir.appendingPathComponent("documind-incoming-\(UUID().uuidString).pdf")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let doc = try store.createDocument(name: fileName, kind: .pdf, sourceFile: tmp)
        let task = try store.createTask(kind: .pdfToWord, documentID: doc.id, fileName: fileName)
        pendingIDs.append(task.id)
        refresh()
        kickWorker()
        return task.id
    }

    // MARK: - 执行

    private func kickWorker() {
        guard !workerRunning else { return }
        workerRunning = true
        Task { await workerLoop() }
    }

    private func workerLoop() async {
        while !pendingIDs.isEmpty {
            let id = pendingIDs.removeFirst()
            await run(id)
            refresh()
        }
        workerRunning = false
    }

    private func run(_ id: UUID) async {
        guard let task = try? store.task(id) else { return }
        update(id, state: .running, progress: 0, message: "开始处理…")
        do {
            switch task.kind {
            case .ocr:
                try await runOCR(task)
            case .pdfToWord:
                try await runConvert(task)
            }
        } catch {
            update(id, state: .failed, error: error.readableMessage, message: "失败")
        }
    }

    private func runOCR(_ task: TaskRecord) async throws {
        guard let docID = task.documentID else { throw DocumentProcessError.unsupportedType }
        guard let fileURL = try store.latestVersionURL(of: docID) else {
            throw DocumentProcessError.emptyResult
        }
        let kind = DocumentKind(fileExtension: fileURL.pathExtension)
        let settings = settingsStore.settings
        let processor = DocumentProcessor(
            ocrEngine: OCREngineFactory.make(settings: settings),
            preferPDFTextLayer: settings.preferPDFTextLayer
        )
        let taskID = task.id
        // 强引用 self（let）：@Sendable 闭包不能引用 weak var
        let result = try await processor.process(url: fileURL, kind: kind) { p, msg in
            Task { @MainActor in
                self.update(taskID, progress: p, message: msg)
            }
        }
        try store.saveOCRResult(documentID: docID, engine: result.engine,
                                mode: settings.ocrEngine == .localMLX ? settings.mlxPromptMode.rawValue : settings.baiduEndpoint.rawValue,
                                text: result.text, blocks: result.blocks, pageCount: result.pageCount)
        update(taskID, state: .success, progress: 1, message: "完成", engine: result.engine)
    }

    private func runConvert(_ task: TaskRecord) async throws {
        guard let docID = task.documentID,
              let fileURL = try store.latestVersionURL(of: docID) else {
            throw DocumentProcessError.cannotOpenPDF
        }
        let settings = settingsStore.settings
        let taskID = task.id
        let outName = (task.fileName as NSString).deletingPathExtension + ".docx"
        let outDir = store.rootDir.appendingPathComponent("conversions", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("\(taskID.uuidString).docx")

        let data: Data
        var engineName: String
        if settings.ocrEngine == .localMLX {
            // 版面保持转换：本地模型 grounding -> Layout Engine -> python-docx
            let service = LocalVLMOCRService(port: settings.mlxPort, mode: settings.mlxPromptMode)
            engineName = "本地 Unlimited-OCR · 版面引擎"
            data = try await service.convertPDFToDocx(pdfURL: fileURL, fileName: task.fileName) { p, msg in
                Task { @MainActor in self.update(taskID, progress: p, message: msg) }
            }
        } else {
            // 云端引擎：纯文本路径
            let legacy = PDFToWordService(processor: DocumentProcessor(
                ocrEngine: OCREngineFactory.make(settings: settings),
                preferPDFTextLayer: settings.preferPDFTextLayer))
            let (legacyData, engine, _) = try await legacy.convert(pdfURL: fileURL) { p, msg in
                Task { @MainActor in self.update(taskID, progress: p, message: msg) }
            }
            data = legacyData
            engineName = engine
        }

        try data.write(to: outURL)
        update(taskID, state: .success, progress: 1, message: "完成",
               engine: engineName, outputPath: outURL.path, outputName: outName)
    }

    // MARK: - 状态

    private func update(_ id: UUID,
                        state: TaskState? = nil,
                        progress: Double? = nil,
                        message: String? = nil,
                        error: String? = nil,
                        engine: String? = nil,
                        outputPath: String? = nil,
                        outputName: String? = nil) {
        try? store.updateTask(id, state: state, progress: progress, message: message,
                              error: error, engine: engine,
                              outputPath: outputPath, outputName: outputName)
        refresh()
    }

    func refresh() {
        tasks = (try? store.listTasks()) ?? []
    }

    /// 取任务的 OCR 结果文本（OCR 任务完成时）
    func resultText(for task: TaskRecord) -> String? {
        guard let docID = task.documentID else { return nil }
        return try? store.latestOCRResult(of: docID)?.text
    }
}

private extension URL {
    /// 重命名临时文件以保留原始文件名后缀（供类型判断）
    func renamed(to fileName: String) -> URL {
        let dest = deletingLastPathComponent().appendingPathComponent(fileName)
        try? FileManager.default.moveItem(at: self, to: dest)
        return FileManager.default.fileExists(atPath: dest.path) ? dest : self
    }
}
