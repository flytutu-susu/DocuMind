import SwiftUI
import AppKit

struct ServerView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settingsStore: SettingsStore

    @State private var portText: String = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: appState.isServerRunning ? "network.badge.shield.half.filled" : "network.slash")
                .font(.system(size: 48))
                .foregroundStyle(appState.isServerRunning ? .green : .secondary)

            Text(appState.isServerRunning ? "局域网服务运行中" : "局域网服务已停止")
                .font(.title2).bold()

            // 端口
            HStack {
                Text("端口")
                TextField("8080", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .disabled(appState.isServerRunning)
                Button(appState.isServerRunning ? "停止服务" : "启动服务") {
                    toggleServer()
                }
                .buttonStyle(.borderedProminent)
                .tint(appState.isServerRunning ? .red : .accentColor)
            }

            Toggle("App 启动时自动开启服务", isOn: $settingsStore.settings.autoStartServer)
                .toggleStyle(.checkbox)

            // 地址列表
            if appState.isServerRunning && !appState.serverAddresses.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("局域网内其他设备访问：")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(appState.serverAddresses, id: \.self) { address in
                        HStack {
                            Image(systemName: address.contains("127.0.0.1") ? "laptopcomputer" : "iphone")
                                .foregroundStyle(.secondary)
                            Text(address)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Button { copy(address) } label: {
                                Image(systemName: "doc.on.clipboard")
                            }
                            .buttonStyle(.borderless)
                            Button { open(address) } label: {
                                Image(systemName: "safari")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if let error = appState.serverError {
                Text("启动失败：\(error)")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Text("提示：首次启动时 macOS 可能弹出防火墙提示，请选择「允许」。\n网页端提供 OCR 识别、PDF 转 Word 下载、AI 对话功能。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            portText = String(settingsStore.settings.serverPort)
        }
    }

    private func toggleServer() {
        if appState.isServerRunning {
            appState.stopServer()
        } else {
            let port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? 8080
            settingsStore.settings.serverPort = port
            appState.startServer()
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func open(_ address: String) {
        if let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        }
    }
}
