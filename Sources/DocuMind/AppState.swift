import Foundation
import Combine

/// 应用中枢：持有设置、任务列表、局域网服务、聊天状态。
@MainActor
final class AppState: ObservableObject {
    let settingsStore: SettingsStore
    let mlxManager: MLXServerManager

    // OCR / 解析任务
    @Published private(set) var tasks: [DocumentTask] = []

    // 局域网服务
    @Published private(set) var isServerRunning = false
    @Published private(set) var serverAddresses: [String] = []
    @Published private(set) var serverError: String?

    // AI 对话
    @Published var chatMessages: [ChatMessage] = []
    @Published private(set) var isChatStreaming = false

    /// OCR 视图「发到对话」的联动载荷（ChatView 消费后清空）
    @Published var pendingChatDraft: String?

    private var server: LocalHTTPServer?
    private lazy var router = WebAPIRouter(settingsProvider: { [settingsStore] in
        settingsStore.settings
    })

    init() {
        let store = SettingsStore()
        self.settingsStore = store
        self.mlxManager = MLXServerManager()
    }

    var settings: AppSettings { settingsStore.settings }

    // MARK: - 服务构建

    func makeProcessor() -> DocumentProcessor {
        DocumentProcessor(ocrEngine: OCREngineFactory.make(settings: settings),
                          preferPDFTextLayer: settings.preferPDFTextLayer)
    }

    // MARK: - OCR / 文档识别

    func processFiles(_ urls: [URL]) {
        for url in urls {
            let task = DocumentTask(fileURL: url)
            guard task.kind != .unknown else {
                var failed = task
                failed.status = .failed("不支持的文件类型")
                tasks.insert(failed, at: 0)
                continue
            }
            tasks.insert(task, at: 0)
            let taskID = task.id

            Task { [weak self] in
                guard let self else { return }
                self.updateTask(taskID) { $0.status = .processing(progress: 0, message: "准备中…") }
                do {
                    let processor = self.makeProcessor()
                    let result = try await processor.process(url: url, kind: task.kind) { [weak self] p, msg in
                        Task { @MainActor in
                            self?.updateTask(taskID) { $0.status = .processing(progress: p, message: msg) }
                        }
                    }
                    self.updateTask(taskID) {
                        $0.status = .done
                        $0.resultText = result.text
                        $0.engine = result.engine
                        $0.pageCount = result.pageCount
                    }
                } catch {
                    self.updateTask(taskID) { $0.status = .failed(error.readableMessage) }
                }
            }
        }
    }

    func removeTask(_ id: UUID) {
        tasks.removeAll { $0.id == id }
    }

    func clearFinishedTasks() {
        tasks.removeAll { !$0.status.isRunning }
    }

    private func updateTask(_ id: UUID, _ mutate: (inout DocumentTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[index])
    }

    // MARK: - PDF 转 Word

    func convertPDFToWord(url: URL,
                          progress: @escaping (Double, String) -> Void) async throws -> Data {
        let processor = makeProcessor()
        let service = PDFToWordService(processor: processor)
        let (data, _, _) = try await service.convert(pdfURL: url) { p, msg in
            Task { @MainActor in progress(p, msg) }
        }
        return data
    }

    // MARK: - AI 对话

    func sendChat(_ text: String, provider: LLMProviderConfig) {
        let userMessage = ChatMessage(role: .user, content: text)
        chatMessages.append(userMessage)

        let assistant = ChatMessage(role: .assistant, content: "")
        chatMessages.append(assistant)
        let assistantID = assistant.id
        isChatStreaming = true

        // 发送给模型的历史（不含刚追加的空 assistant 占位），保留最近 20 条
        let history = Array(chatMessages.dropLast().suffix(20))

        Task { [weak self] in
            guard let self else { return }
            defer { self.isChatStreaming = false }
            do {
                let client = LLMClientFactory.client(for: provider)
                for try await chunk in client.streamChat(messages: history, config: provider) {
                    self.appendToMessage(assistantID, chunk)
                }
            } catch is CancellationError {
                self.appendToMessage(assistantID, "\n\n[已取消]")
            } catch {
                self.appendToMessage(assistantID, "\n\n[错误] \(error.readableMessage)")
            }
        }
    }

    func clearChat() {
        chatMessages.removeAll()
    }

    private func appendToMessage(_ id: UUID, _ chunk: String) {
        guard let index = chatMessages.firstIndex(where: { $0.id == id }) else { return }
        chatMessages[index].content += chunk
    }

    // MARK: - 局域网服务

    func startServer() {
        guard !isServerRunning else { return }
        let port = UInt16(clamping: settings.serverPort)
        let server = LocalHTTPServer(port: port) { [router] request in
            await router.handle(request)
        }
        do {
            try server.start()
            self.server = server
            self.isServerRunning = true
            self.serverError = nil
            refreshServerAddresses()
        } catch {
            self.serverError = error.readableMessage
            self.isServerRunning = false
        }
    }

    func stopServer() {
        server?.stop()
        server = nil
        isServerRunning = false
        serverAddresses = []
    }

    func restartServerIfRunning() {
        if isServerRunning {
            stopServer()
            startServer()
        } else if settings.autoStartServer {
            startServer()
        }
    }

    private func refreshServerAddresses() {
        let port = settings.serverPort
        var addrs = LocalHTTPServer.localIPv4Addresses().map { "http://\($0):\(port)" }
        addrs.append("http://127.0.0.1:\(port)")
        serverAddresses = addrs
    }

    /// App 启动时调用
    func applicationDidFinishLaunching() {
        if settings.autoStartServer {
            startServer()
        }
        mlxManager.autoStartIfNeeded(settings: settings)
    }
}
