import SwiftUI

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settingsStore: SettingsStore

    @State private var inputText = ""
    @State private var selectedProviderID: UUID?

    private var enabledProviders: [LLMProviderConfig] {
        settingsStore.settings.llmProviders.filter { $0.enabled }
    }

    private var selectedProvider: LLMProviderConfig? {
        if let id = selectedProviderID, let p = enabledProviders.first(where: { $0.id == id }) {
            return p
        }
        return settingsStore.settings.activeProvider ?? enabledProviders.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            Divider()
            inputArea
        }
        .onAppear {
            consumePendingDraft()
            if selectedProviderID == nil {
                selectedProviderID = settingsStore.settings.activeProvider?.id ?? enabledProviders.first?.id
            }
        }
        .onChange(of: appState.pendingChatDraft) { _ in consumePendingDraft() }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 12) {
            Picker("模型", selection: $selectedProviderID) {
                ForEach(enabledProviders) { provider in
                    Text("\(provider.name)（\(provider.model)）\(provider.apiKey.isEmpty ? " · 未填Key" : "")")
                        .tag(Optional(provider.id))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 320)

            if enabledProviders.isEmpty {
                Text("尚无服务商，请到「设置」添加")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            if !appState.chatMessages.isEmpty {
                Button("清空") { appState.clearChat() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(appState.isChatStreaming)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if appState.chatMessages.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("选择模型后开始对话\n可在「文字识别」页将识别结果一键发到对话")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                    }
                    ForEach(appState.chatMessages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: appState.chatMessages.last?.content) { _ in
                if let last = appState.chatMessages.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - 输入区

    private var inputArea: some View {
        VStack(spacing: 8) {
            TextEditor(text: $inputText)
                .font(.body)
                .frame(minHeight: 56, maxHeight: 120)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))

            HStack {
                Text("输入消息，点击发送（⌘↩ 也可发送）")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if appState.isChatStreaming {
                    ProgressView().scaleEffect(0.7)
                }
                Button("发送") { send() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || appState.isChatStreaming
                              || selectedProvider == nil
                              || (selectedProvider?.apiKey.isEmpty ?? true))
            }
        }
        .padding()
    }

    // MARK: - 逻辑

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let provider = selectedProvider else { return }
        inputText = ""
        appState.sendChat(text, provider: provider)
    }

    private func consumePendingDraft() {
        if let draft = appState.pendingChatDraft {
            inputText = draft
            appState.pendingChatDraft = nil
        }
    }
}

// MARK: - 气泡

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.role == .user ? "我" : "AI")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(message.content.isEmpty ? "…" : message.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(message.role == .user ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                    .foregroundStyle(message.role == .user ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            if message.role != .user { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}
