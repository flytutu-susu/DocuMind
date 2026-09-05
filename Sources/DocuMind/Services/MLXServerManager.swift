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
    case pythonTooOld(String)
    case pythonDownloadFailed(String)
    case commandFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .pythonMissing:
            return "未找到 python3。请先安装 Xcode 命令行工具（终端执行 xcode-select --install）或安装 Python 3.10+。"
        case .pythonTooOld(let version):
            return "系统 Python 版本过低（\(version)），mlx-vlm 需要 Python 3.10+。App 将尝试自动下载独立运行时。"
        case .pythonDownloadFailed(let detail):
            return "独立 Python 运行时下载失败：\(detail)。可手动安装 Python 3.10+（如 brew install python@3.12）后重试。"
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

    /// 依赖规格标记，变更时触发增量安装
    /// （v1.3 起版面引擎移到 Swift 侧，sidecar 仅需 mlx-vlm）
    private static let depsSpec = "mlx-vlm>=0.6.0"
    private static let pipPackages = ["mlx-vlm>=0.6.0"]

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

    /// 安装 Python 环境与依赖（幂等；venv 已存在且 Python 版本合格时增量 pip 安装）
    func install(settings: AppSettings) async throws {
        if isInstalled { return }

        state = .installing("检查 Python 运行时")
        // mlx-vlm 需要 Python ≥ 3.10；系统 python3 可能是 3.9（macOS CLT）
        let python = try await resolvePython(settings: settings)

        // venv 已存在但 Python 版本不合格（如旧版 3.9 创建）→ 重建
        if fm.fileExists(atPath: venvPython.path), !(await pythonMeetsRequirement(venvPython.path)) {
            appendLog("[setup] 现有 venv 的 Python 版本过低，重建…\n")
            try? fm.removeItem(at: venvDir)
        }

        if !fm.fileExists(atPath: venvPython.path) {
            state = .installing("创建虚拟环境")
            appendLog("[setup] 创建 venv：\(venvDir.path)（Python: \(python)）\n")
            let venvStatus = try await runCommand(python, ["-m", "venv", venvDir.path])
            guard venvStatus == 0 else { throw MLXSetupError.commandFailed("python -m venv", venvStatus) }
        }

        state = .installing("安装依赖（mlx-vlm）")
        // 国内镜像加速 pip
        var pipArgs = ["-m", "pip", "install", "-U"] + Self.pipPackages
        if settings.hfMirror {
            pipArgs += ["-i", "https://pypi.tuna.tsinghua.edu.cn/simple"]
        }
        appendLog("[setup] pip install \(Self.pipPackages.joined(separator: " "))\n")
        let pipStatus = try await runCommand(venvPython.path, pipArgs)
        guard pipStatus == 0 else { throw MLXSetupError.commandFailed("pip install", pipStatus) }

        try Self.depsSpec.write(to: depsMarkerURL, atomically: true, encoding: .utf8)
        appendLog("[setup] 依赖安装完成\n")
        state = .stopped
    }

    // MARK: - Python 运行时探测

    /// 探测顺序：已下载的独立运行时 → Homebrew/Frameworks 高版本 → 系统 python3 → 自动下载独立运行时
    private func resolvePython(settings: AppSettings) async throws -> String {
        if fm.fileExists(atPath: runtimePython.path), await pythonMeetsRequirement(runtimePython.path) {
            return runtimePython.path
        }

        let candidates: [String] = [
            "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11", "/opt/homebrew/bin/python3.10",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3.13", "/usr/local/bin/python3.12",
            "/usr/local/bin/python3.11", "/usr/local/bin/python3.10",
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.10/bin/python3",
            "/usr/bin/python3"
        ]
        for candidate in candidates where fm.fileExists(atPath: candidate) {
            if await pythonMeetsRequirement(candidate) {
                appendLog("[setup] 使用本机 Python：\(candidate)\n")
                return candidate
            } else {
                let version = await pythonVersion(candidate)
                appendLog("[setup] 跳过 \(candidate)（版本 \(version) < 3.10）\n")
            }
        }

        // 都没有：自动下载 python-build-standalone 独立运行时（免安装、免 sudo）
        appendLog("[setup] 本机无 Python ≥3.10，下载独立运行时…\n")
        return try await downloadStandalonePython(settings: settings)
    }

    private var runtimeDir: URL { baseDir.appendingPathComponent("python-runtime", isDirectory: true) }
    private var runtimePython: URL { runtimeDir.appendingPathComponent("python/bin/python3") }

    /// python-build-standalone（astral-sh 维护），Apple Silicon 免安装包
    private static let standalonePythonURL =
        "https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.12.14+20260901-aarch64-apple-darwin-install_only.tar.gz"

    private func downloadStandalonePython(settings: AppSettings) async throws -> String {
        state = .installing("下载 Python 3.12 独立运行时（约 45MB）")
        // hfMirror 开启时优先走 GitHub 加速镜像前缀，失败回退直连
        let prefixes: [String] = settings.hfMirror
            ? ["https://ghfast.top/", "https://gh-proxy.com/", ""]
            : [""]
        var lastError: Error = MLXSetupError.pythonDownloadFailed("未知错误")
        for prefix in prefixes {
            let urlString = prefix + Self.standalonePythonURL
            guard let url = URL(string: urlString) else { continue }
            do {
                appendLog("[setup] 下载：\(urlString)\n")
                let (tmpFile, response) = try await URLSession.shared.download(from: url)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard (200..<300).contains(statusCode) else {
                    throw MLXSetupError.pythonDownloadFailed("HTTP \(statusCode)")
                }
                if fm.fileExists(atPath: runtimeDir.path) { try fm.removeItem(at: runtimeDir) }
                try fm.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
                let tarStatus = try await runCommand("/usr/bin/tar", ["-xzf", tmpFile.path, "-C", runtimeDir.path])
                guard tarStatus == 0, fm.fileExists(atPath: runtimePython.path) else {
                    throw MLXSetupError.pythonDownloadFailed("解压失败")
                }
                guard await pythonMeetsRequirement(runtimePython.path) else {
                    throw MLXSetupError.pythonDownloadFailed("运行时自检失败")
                }
                appendLog("[setup] 独立运行时就绪：\(runtimePython.path)\n")
                return runtimePython.path
            } catch {
                lastError = error
                appendLog("[setup] 该源失败：\(error.localizedDescription)，尝试下一个…\n")
            }
        }
        throw lastError
    }

    // MARK: - Python 版本检查

    private func pythonMeetsRequirement(_ path: String) async -> Bool {
        let version = await pythonVersion(path)
        guard let major = Double(version) else { return false }
        return major >= 3.10
    }

    private func pythonVersion(_ path: String) async -> String {
        let (status, output) = await runCapture(path, ["-c", "import sys; print('%d.%d' % sys.version_info[:2])"])
        guard status == 0 else { return "0" }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 执行命令并捕获 stdout（不写入日志面板，用于探测）
    private func runCapture(_ executable: String, _ arguments: [String]) async -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
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

        // 模型引用：本地目录优先（复用手动下载），否则 HF 仓库 ID
        let modelRef: String
        if !settings.mlxModelPath.isEmpty {
            let path = (settings.mlxModelPath as NSString).expandingTildeInPath
            let configPath = (path as NSString).appendingPathComponent("config.json")
            guard fm.fileExists(atPath: configPath) else {
                state = .failed("本地模型目录无效（缺少 config.json）：\(path)")
                appendLog("[server] 本地模型目录无效：\(path)\n")
                return
            }
            modelRef = path
        } else {
            modelRef = settings.mlxModelRepo
        }

        let process = Process()
        process.executableURL = venvPython
        process.arguments = [
            scriptURL.path,
            "--model", modelRef,
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
            appendLog("[server] 已启动，端口 \(settings.mlxPort)，模型 \(modelRef)\n")
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
