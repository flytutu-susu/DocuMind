import Foundation
import Combine

/// 应用中枢：设置、任务队列、文档库、局域网服务、聊天状态。
@MainActor
final class AppState: ObservableObject {
    let settingsStore: SettingsStore
    let mlxManager: MLXServerManager
    let store: DocumentStore
    let taskQueue: TaskQueue

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
    private lazy var router = WebAPIRouter(appState: self)

    init() {
        let store = SettingsStore()
        self.settingsStore = store
        self.mlxManager = MLXServerManager()
        let docStore = DocumentStore()
        self.store = docStore
        self.taskQueue = TaskQueue(store: docStore, settingsStore: store)
    }

    var settings: AppSettings { settingsStore.settings }

    // MARK: - 服务构建

    func makeProcessor() -> DocumentProcessor {
        DocumentProcessor(ocrEngine: OCREngineFactory.make(settings: settings),
                          preferPDFTextLayer: settings.preferPDFTextLayer)
    }

    // MARK: - 文件入队（App 拖入/选择）

    /// 入队 OCR，返回任务 ID 列表（入库失败的文件生成失败任务记录便于用户感知）
    @discardableResult
    func processFiles(_ urls: [URL]) -> [UUID?] {
        urls.map { url in
            do {
                return try taskQueue.enqueueOCR(fileURL: url)
            } catch {
                if let task = try? store.createTask(kind: .ocr, documentID: nil, fileName: url.lastPathComponent) {
                    try? store.updateTask(task.id, state: .failed, error: error.readableMessage)
                    taskQueue.refresh()
                    return task.id
                }
                return nil
            }
        }
    }

    @discardableResult
    func enqueueConversion(_ urls: [URL]) -> [UUID?] {
        urls.map { url in
            do {
                return try taskQueue.enqueueConvert(fileURL: url)
            } catch {
                if let task = try? store.createTask(kind: .pdfToWord, documentID: nil, fileName: url.lastPathComponent) {
                    try? store.updateTask(task.id, state: .failed, error: error.readableMessage)
                    taskQueue.refresh()
                    return task.id
                }
                return nil
            }
        }
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
