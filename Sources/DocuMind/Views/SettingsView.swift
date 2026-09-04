import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var mlxManager: MLXServerManager

    @State private var selectedProviderID: UUID?

    var body: some View {
        TabView {
            ocrTab
                .tabItem { Label("OCR 引擎", systemImage: "text.viewfinder") }
            llmTab
                .tabItem { Label("大模型", systemImage: "brain") }
            generalTab
                .tabItem { Label("通用", systemImage: "gear") }
        }
        .padding()
    }

    // MARK: - OCR 引擎

    private var ocrTab: some View {
        Form {
            Section {
                Picker("识别引擎", selection: $settingsStore.settings.ocrEngine) {
                    ForEach(OCREngineKind.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                Toggle("PDF 优先提取文本层（无文本层再 OCR）", isOn: $settingsStore.settings.preferPDFTextLayer)
            }

            if settingsStore.settings.ocrEngine == .localMLX {
                mlxSection
            } else {
                baiduSection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 本地 MLX 引擎

    private var mlxSection: some View {
        Group {
            Section("本地 Unlimited-OCR（MLX mxfp8bit · 离线免费）") {
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(mlxManager.state.displayText)
                        .font(.callout)
                    Spacer()
                    if mlxManager.state.isBusy {
                        ProgressView().scaleEffect(0.7)
                    }
                }

                Picker("模型版本", selection: modelSelection) {
                    ForEach(MLXModelVariant.presets) { variant in
                        Text("\(variant.label)｜\(variant.detail)").tag(variant.repo)
                    }
                    Text("自定义（手动填写仓库 ID）").tag("custom")
                }
                .help("切换后点「应用配置并重启」生效；新模型首次启动会自动下载")

                if modelSelection.wrappedValue == "custom" {
                    TextField("HuggingFace 仓库 ID", text: $settingsStore.settings.mlxModelRepo)
                }

                HStack {
                    TextField("本地端口", value: $settingsStore.settings.mlxPort, format: .number)
                        .frame(width: 100)
                    Picker("输出模式", selection: $settingsStore.settings.mlxPromptMode) {
                        ForEach(MLXOutputMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }

                Toggle("国内镜像加速（HF 镜像 + 清华 pip 源）", isOn: $settingsStore.settings.hfMirror)
                Toggle("App 启动时自动启动引擎", isOn: $settingsStore.settings.mlxAutoStart)

                HStack(spacing: 12) {
                    switch mlxManager.state {
                    case .notInstalled:
                        Button("安装环境并启动") {
                            mlxManager.installAndStart(settings: settingsStore.settings)
                        }
                        .buttonStyle(.borderedProminent)
                    case .stopped, .failed:
                        Button("启动引擎") {
                            Task { await mlxManager.start(settings: settingsStore.settings) }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("重新安装环境") { reinstall() }
                            .foregroundStyle(.secondary)
                    case .running, .loadingModel:
                        Button("应用配置并重启") {
                            mlxManager.restart(settings: settingsStore.settings)
                        }
                        Button("停止") { mlxManager.stop() }
                            .foregroundStyle(.red)
                    case .installing:
                        Text("安装进行中，请耐心等待（pip 安装不可中断）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .starting:
                        Button("取消启动") { mlxManager.stop() }
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("运行日志") {
                ScrollView {
                    Text(mlxManager.logText.isEmpty ? "（暂无日志）" : mlxManager.logText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(6)
                }
                .frame(height: 130)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var statusColor: Color {
        switch mlxManager.state {
        case .running: return .green
        case .failed: return .red
        case .installing, .starting, .loadingModel: return .orange
        default: return .gray
        }
    }

    /// 模型版本下拉绑定：预设命中时绑定仓库 ID，未命中（手动改过）归入「自定义」
    private var modelSelection: Binding<String> {
        Binding(
            get: {
                let repo = settingsStore.settings.mlxModelRepo
                return MLXModelVariant.presets.contains(where: { $0.repo == repo }) ? repo : "custom"
            },
            set: { newValue in
                if newValue != "custom" {
                    settingsStore.settings.mlxModelRepo = newValue
                }
            }
        )
    }

    private func reinstall() {
        mlxManager.stop()
        mlxManager.installAndStart(settings: settingsStore.settings)
    }

    // MARK: 百度云 OCR

    private var baiduSection: some View {
        Group {
            Section {
                TextField("API Key", text: $settingsStore.settings.baiduAPIKey)
                SecureField("Secret Key", text: $settingsStore.settings.baiduSecretKey)
            } header: {
                Text("百度智能云密钥")
            } footer: {
                Text("到百度智能云控制台 → 文字识别 → 应用列表创建应用获取。无限制/标准/高精度套餐接口通用。")
                    .font(.caption)
            }

            Section("识别接口") {
                Picker("接口档位", selection: $settingsStore.settings.baiduEndpoint) {
                    ForEach(BaiduOCREndpoint.allCases) { endpoint in
                        Text(endpoint.displayName).tag(endpoint)
                    }
                }
                Toggle("按段落合并识别结果", isOn: $settingsStore.settings.mergeParagraph)
            }
        }
    }

    // MARK: - LLM 服务商

    private var llmTab: some View {
        HSplitView {
            VStack(alignment: .leading) {
                List(selection: $selectedProviderID) {
                    ForEach(settingsStore.settings.llmProviders) { provider in
                        HStack {
                            Circle()
                                .fill(provider.enabled ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(provider.name)
                            Spacer()
                            if provider.apiKey.isEmpty {
                                Image(systemName: "key.fill")
                                    .foregroundStyle(.orange)
                                    .help("未填写 API Key")
                            }
                        }
                        .tag(provider.id)
                    }
                }

                HStack {
                    Menu("添加") {
                        ForEach(LLMProviderConfig.presets) { preset in
                            Button(preset.name) { settingsStore.addPreset(preset) }
                        }
                    }
                    Button("删除") { deleteSelectedProvider() }
                        .disabled(selectedProviderID == nil)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(minWidth: 200, maxWidth: 240)

            providerEditor
        }
    }

    @ViewBuilder
    private var providerEditor: some View {
        if let id = selectedProviderID,
           let index = settingsStore.settings.llmProviders.firstIndex(where: { $0.id == id }) {
            Form {
                TextField("名称", text: providerBinding(index).name)
                Picker("协议", selection: providerBinding(index).protocolKind) {
                    ForEach(LLMProtocolKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                TextField("Base URL", text: providerBinding(index).baseURL)
                    .help("OpenAI 协议填到 /v1 即可；Anthropic 填 https://api.anthropic.com")
                SecureField("API Key", text: providerBinding(index).apiKey)
                TextField("模型", text: providerBinding(index).model)
                Toggle("启用", isOn: providerBinding(index).enabled)
                Toggle("设为默认", isOn: Binding(
                    get: { settingsStore.settings.activeProviderID == id },
                    set: { newValue in
                        settingsStore.settings.activeProviderID = newValue ? id : nil
                    }
                ))
            }
            .formStyle(.grouped)
            .padding()
        } else {
            Text("选择或添加一个服务商")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func providerBinding(_ index: Int) -> Binding<LLMProviderConfig> {
        Binding(
            get: { settingsStore.settings.llmProviders[index] },
            set: { settingsStore.settings.llmProviders[index] = $0 }
        )
    }

    private func deleteSelectedProvider() {
        guard let id = selectedProviderID else { return }
        settingsStore.settings.llmProviders.removeAll { $0.id == id }
        if settingsStore.settings.activeProviderID == id {
            settingsStore.settings.activeProviderID = nil
        }
        selectedProviderID = nil
    }

    // MARK: - 通用

    private var generalTab: some View {
        Form {
            Section("局域网服务") {
                HStack {
                    TextField("端口", value: $settingsStore.settings.serverPort, format: .number)
                        .frame(width: 100)
                    Button("应用并重启服务") { appState.restartServerIfRunning() }
                        .disabled(!appState.isServerRunning)
                }
                Toggle("App 启动时自动开启服务", isOn: $settingsStore.settings.autoStartServer)
            }

            Section("关于") {
                LabeledContent("版本", value: AppVersion.display)
                LabeledContent("OCR 引擎", value: "本地 Unlimited-OCR 3B (MLX) / 百度云 OCR")
                LabeledContent("支持模型", value: "DeepSeek / Kimi / 千问 / OpenAI 兼容 / Anthropic")
            }
        }
        .formStyle(.grouped)
    }
}
