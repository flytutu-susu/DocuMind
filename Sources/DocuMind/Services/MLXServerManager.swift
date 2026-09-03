import Foundation

// MARK: - 引擎状态

enum MLXEngineState: Equatable {
    case notInstalled            // 尚未创建 Python 环境
    case installing(String)      // 正在安装（阶段描述）
    case stopped                 // 已安装，未启动
    case starting                // 进程已拉起，等待健康检查
    case loadingModel            // 服务在线，模型下载/加载中
    case running                 // 就绪
    case failed(String)

    var displayText: String {
        switch self {
        case .notInstalled: return "未安装"
        case .installing(let stage): return "安装中：\(stage)"
        case .stopped: return "已停止"
        case .starting: return "启动中…"
        case .loadingModel: return "模型加载中（首次需下载约 2.4GB）…"
        case .running: return "运行中"
        case .failed(let err): return "故障：\(err)"
        }
    }

    var isBusy: Bool {
        switch self {
        case .installing, .starting, .loadingModel: return true
        default: return false
        }
    }
}

enum MLXSetupError: LocalizedError {
    case pythonMissing
    case commandFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .pythonMissing:
            return "未找到 python3。请先安装 Xcode 命令行工具（终端执行 xcode-select --install）或安装 Python 3.10+。"
        case .commandFailed(let cmd, let code):
            return "命令执行失败（退出码 \(code)）：\(cmd)"
        }
    }
}

// MARK: - 本地 MLX 引擎管理器

/// 负责：创建 Python venv → 安装 mlx-vlm → 拉起推理服务进程 → 健康检查 → 停止。
/// 全部文件位于 ~/Library/Application Support/DocuMind/mlx/
@MainActor
final class MLXServerManager: ObservableObject {
    @Published private(set) var state: MLXEngineState = .notInstalled
    @Published private(set) var logText: String = ""

    private var serverProcess: Process?
    private var healthTask: Task<Void, Never>?

    private let fm = FileManager.default
    private let baseDir: URL

    /// 依赖规格标记，变更时触发重装
    private static let depsSpec = "mlx-vlm>=0.6.0"

    init() {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DocuMind/mlx", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.baseDir = dir
        self.state = isInstalled ? .stopped : .notInstalled
    }

    // MARK: - 路径

    private var venvDir: URL { baseDir.appendingPathComponent("venv", isDirectory: true) }
    private var venvPython: URL { venvDir.appendingPathComponent("bin/python") }
    private var scriptURL: URL { baseDir.appendingPathComponent("mlx_server.py") }
    private var depsMarkerURL: URL { venvDir.appendingPathComponent(".documind-deps") }

    var isInstalled: Bool {
        fm.fileExists(atPath: venvPython.path) &&
        (try? String(contentsOf: depsMarkerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) == Self.depsSpec
    }

    // MARK: - 日志

    func appendLog(_ text: String) {
        logText.append(text)
        if logText.count > 8000 {
            logText = String(logText.suffix(6000))
        }
    }

    // MARK: - 安装 + 启动

    func installAndStart(settings: AppSettings) {
        guard !state.isBusy else { return }
        Task {
            do {
                try await install(settings: settings)
                await start(settings: settings)
            } catch {
                self.state = .failed(error.readableMessage)
            }
        }
    }

    /// 安装 Python 环境与 mlx-vlm 依赖（幂等，已安装则跳过）
    func install(settings: AppSettings) async throws {
        if isInstalled { return }

        state = .installing("检查 Python")
        appendLog("[setup] 检查 python3…\n")
        let pythonCheck = try? await runCommand("/usr/bin/env", ["python3", "--version"])
        guard pythonCheck == 0 else { throw MLXSetupError.pythonMissing }

        state = .installing("创建虚拟环境")
        appendLog("[setup] 创建 venv：\(venvDir.path)\n")
        if fm.fileExists(atPath: venvDir.path) {
            try? fm.removeItem(at: venvDir)
        }
        let venvStatus = try await runCommand("/usr/bin/env", ["python3", "-m", "venv", venvDir.path])
        guard venvStatus == 0 else { throw MLXSetupError.commandFailed("python3 -m venv", venvStatus) }

        state = .installing("安装 mlx-vlm（约 300MB 依赖）")
        // 国内镜像加速 pip
        var pipArgs = ["-m", "pip", "install", "-U", Self.depsSpec]
        if settings.hfMirror {
            pipArgs += ["-i", "https://pypi.tuna.tsinghua.edu.cn/simple"]
        }
        appendLog("[setup] pip install \(Self.depsSpec)\n")
        let pipStatus = try await runCommand(venvPython.path, pipArgs)
        guard pipStatus == 0 else { throw MLXSetupError.commandFailed("pip install mlx-vlm", pipStatus) }

        try Self.depsSpec.write(to: depsMarkerURL, atomically: true, encoding: .utf8)
        appendLog("[setup] 依赖安装完成\n")
        state = .stopped
    }

    // MARK: - 启动 / 停止

    func start(settings: AppSettings) async {
        guard isInstalled else {
            state = .notInstalled
            return
        }
        stopServerProcess()
        state = .starting

        // 写入最新脚本（保持与 App 版本同步）
        do {
            try MLXServerScript.source.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            state = .failed("写入服务脚本失败：\(error.readableMessage)")
            return
        }

        var environment = ProcessInfo.processInfo.environment
        if settings.hfMirror {
            environment["HF_ENDPOINT"] = "https://hf-mirror.com"   // 国内模型下载镜像
        }

        let process = Process()
        process.executableURL = venvPython
        process.arguments = [
            scriptURL.path,
            "--model", settings.mlxModelRepo,
            "--port", String(settings.mlxPort),
            "--host", "127.0.0.1"
        ]
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // 强引用 self（let）：@Sendable 闭包不能引用 weak var；
        // 进程停止/替换时 serverProcess 置 nil，引用环随之断开（管理器本身是 App 生命周期单例）
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self.appendLog(str) }
        }

        process.terminationHandler = { p in
            Task { @MainActor in
                // 用进程身份判断：restart 时旧进程的退出回调不影响新进程状态
                guard self.serverProcess === p else { return }
                self.state = .failed("推理进程意外退出（code \(p.terminationStatus)），详见日志")
                self.serverProcess = nil
            }
        }

        do {
            try process.run()
            serverProcess = process
            appendLog("[server] 已启动，端口 \(settings.mlxPort)，模型 \(settings.mlxModelRepo)\n")
        } catch {
            state = .failed("启动失败：\(error.readableMessage)")
            return
        }

        startHealthCheck(port: settings.mlxPort)
    }

    func stop() {
        healthTask?.cancel()
        healthTask = nil
        stopServerProcess()
        state = isInstalled ? .stopped : .notInstalled
        appendLog("[server] 已停止\n")
    }

    func restart(settings: AppSettings) {
        Task {
            stop()
            await start(settings: settings)
        }
    }

    /// App 启动时按需自动拉起
    func autoStartIfNeeded(settings: AppSettings) {
        guard settings.ocrEngine == .localMLX, settings.mlxAutoStart, isInstalled else { return }
        Task { await start(settings: settings) }
    }

    private func stopServerProcess() {
        healthTask?.cancel()
        healthTask = nil
        // 先清空引用再 terminate，使 terminationHandler 的身份判断识别出这是主动停止
        let p = serverProcess
        serverProcess = nil
        if let p, p.isRunning {
            p.terminate()
        }
    }

    // MARK: - 健康检查

    private func startHealthCheck(port: Int) {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            let url = URL(string: "http://127.0.0.1:\(port)/health")!
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 3
            let session = URLSession(configuration: config)

            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let (data, _) = try await session.data(from: url)
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let status = json["status"] as? String {
                        await MainActor.run {
                            switch status {
                            case "ready":
                                if self.state != .running {
                                    self.state = .running
                                    self.appendLog("[server] 模型就绪，可以开始识别\n")
                                }
                            case "loading":
                                if case .failed = self.state {} else { self.state = .loadingModel }
                            case "failed":
                                self.state = .failed((json["error"] as? String) ?? "模型加载失败")
                            default:
                                break
                            }
                        }
                    }
                } catch {
                    // 进程还在启动中，连接失败正常；若之前在运行则视为掉线
                    await MainActor.run {
                        if self.state == .running {
                            self.state = .failed("与推理进程的连接中断")
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    // MARK: - 命令执行

    @discardableResult
    private func runCommand(_ executable: String, _ arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // 强引用 self：terminationHandler 中置 nil 后引用即断开
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self.appendLog(str) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: p.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
