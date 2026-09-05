import Foundation

/// 任务调度器（Worker Pool）：按任务类型分派到独立流水线并行执行。
///
///     TaskQueue（入队 / 持久化 / 状态发布）
///        │ Dispatcher
///        ├─ OCR Worker ×1     （图片 / 扫描版 PDF 识别 —— 走推理引擎）
///        ├─ Convert Worker ×1 （PDF→Word —— 走推理引擎 + 版面构建）
///        └─ Parse Worker ×1   （docx/xlsx 本地解析 —— 纯 CPU，秒级）
///
/// 说明：
/// - 本地 MLX 引擎内部串行（gen_lock），OCR/Convert 两条 lane 在 HTTP 层并行、引擎层排队，
///   单用户长转换不阻塞他人的图片识别请求分发；云端引擎（百度）则真实并行。
/// - lane 并发度目前固定 1（M1 单推理引擎的合理值），结构上支持按 lane 扩展。
@MainActor
final class TaskQueue: ObservableObject {
    @Published private(set) var tasks: [TaskRecord] = []

    let store: DocumentStore
    private let settingsStore: SettingsStore

    // MARK: - Lane（流水线）

    enum Lane: String, CaseIterable {
        case ocr
        case convert
        case parse
    }

    private var lanePending: [Lane: [UUID]] = Dictionary(uniqueKeysWithValues: Lane.allCases.map { ($0, []) })
    private var laneRunning: [Lane: Bool] = Dictionary(uniqueKeysWithValues: Lane.allCases.map { ($0, false) })
    private var taskLane: [UUID: Lane] = [:]

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

    /// 文件入库 + 创建 OCR 任务（docx/xlsx 自动路由到 Parse lane）
    /// - Parameter owner: 数据归属（"local"=本机，或局域网客户端 IP）
    @discardableResult
    func enqueueOCR(fileURL: URL, owner: String = "local") throws -> UUID {
        let kind = DocumentKind(fileExtension: fileURL.pathExtension)
        guard kind != .unknown else { throw DocumentProcessError.unsupportedType }
        let doc = try store.createDocument(name: fileURL.lastPathComponent, kind: kind, sourceFile: fileURL, owner: owner)
        let task = try store.createTask(kind: .ocr, documentID: doc.id, fileName: doc.name, owner: owner)
        enqueue(taskID: task.id, lane: laneForDocumentKind(kind))
        return task.id
    }

    /// 原始字节入库（Web 上传）+ 创建 OCR 任务
    @discardableResult
    func enqueueOCR(data: Data, fileName: String, owner: String = "local") throws -> UUID {
        let kind = DocumentKind(fileExtension: (fileName as NSString).pathExtension)
        guard kind != .unknown else { throw DocumentProcessError.unsupportedType }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("documind-incoming-\(UUID().uuidString)-\(fileName)")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let doc = try store.createDocument(name: fileName, kind: kind, sourceFile: tmp, owner: owner)
        let task = try store.createTask(kind: .ocr, documentID: doc.id, fileName: fileName, owner: owner)
        enqueue(taskID: task.id, lane: laneForDocumentKind(kind))
        return task.id
    }

    @discardableResult
    func enqueueConvert(fileURL: URL, owner: String = "local") throws -> UUID {
        let doc = try store.createDocument(name: fileURL.lastPathComponent, kind: .pdf, sourceFile: fileURL, owner: owner)
        let task = try store.createTask(kind: .pdfToWord, documentID: doc.id, fileName: doc.name, owner: owner)
        enqueue(taskID: task.id, lane: .convert)
        return task.id
    }

    @discardableResult
    func enqueueConvert(data: Data, fileName: String, owner: String = "local") throws -> UUID {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("documind-incoming-\(UUID().uuidString).pdf")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let doc = try store.createDocument(name: fileName, kind: .pdf, sourceFile: tmp, owner: owner)
        let task = try store.createTask(kind: .pdfToWord, documentID: doc.id, fileName: fileName, owner: owner)
        enqueue(taskID: task.id, lane: .convert)
        return task.id
    }

    // MARK: - Dispatcher

    private func laneForDocumentKind(_ kind: DocumentKind) -> Lane {
        switch kind {
        case .docx, .xlsx: return .parse
        default: return .ocr
        }
    }

    private func enqueue(taskID: UUID, lane: Lane) {
        taskLane[taskID] = lane
        lanePending[lane, default: []].append(taskID)
        refresh()
        kickLane(lane)
    }

    private func kickLane(_ lane: Lane) {
        guard laneRunning[lane] != true else { return }
        laneRunning[lane] = true
        Task { await laneLoop(lane) }
    }

    private func laneLoop(_ lane: Lane) async {
        while let nextID = lanePending[lane]?.first {
            lanePending[lane]?.removeFirst()
            await run(nextID)
            refresh()
        }
        laneRunning[lane] = false
    }

    // MARK: - 执行

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
            update(id, state: .failed, message: "失败", error: error.readableMessage)
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
        let taskID = task.id
        let outName = (task.fileName as NSString).deletingPathExtension + ".docx"
        let outDir = store.rootDir.appendingPathComponent("conversions", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("\(taskID.uuidString).docx")

        // 统一入口：blocks → layout → docx（本地 grounding / 百度含位置版 均可产出 blocks）
        let service = PDFToWordService(settings: settingsStore.settings)
        let result = try await service.convert(pdfURL: fileURL) { p, msg in
            Task { @MainActor in self.update(taskID, progress: p, message: msg) }
        }

        try result.data.write(to: outURL)
        update(taskID, state: .success, progress: 1, message: "完成",
               engine: result.engine, outputPath: outURL.path, outputName: outName)
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
