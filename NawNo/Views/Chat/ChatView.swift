import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: Role
    var content: String
    var thinkingContent: String?
    var stats: GenerationStats?
    var isStreaming: Bool = false

    enum Role: Equatable {
        case user, assistant, system
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content && lhs.thinkingContent == rhs.thinkingContent && lhs.isStreaming == rhs.isStreaming
    }

    var asDict: [String: String] {
        let roleString: String
        switch role {
        case .user: roleString = "user"
        case .assistant: roleString = "assistant"
        case .system: roleString = "system"
        }
        return ["role": roleString, "content": content]
    }
}

struct ChatView: View {
    let model: ModelEntry
    @Binding var messages: [ChatMessage]
    @Environment(LLMService.self) private var llm
    @State private var inputText = ""
    @State private var streamingMessageIndex: Int?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 28) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        Color.clear
                            .frame(height: 8)
                            .id("bottom")
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(llm.isGenerating ? .hidden : .automatic)
                .onChange(of: messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: llm.isGenerating) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: llm.currentStreamText) { _, newValue in
                    if let idx = streamingMessageIndex, idx < messages.count, llm.isGenerating {
                        messages[idx].content = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    scrollToBottom(proxy)
                }
                .onChange(of: llm.currentThinkingText) { _, newValue in
                    if let idx = streamingMessageIndex, idx < messages.count, llm.isGenerating {
                        let thinkingEnabled = SettingsStorage.settings(for: model).enableThinking
                        messages[idx].thinkingContent = (thinkingEnabled && !newValue.isEmpty) ? newValue : nil
                    }
                    scrollToBottom(proxy)
                }
            }

            Divider()
            inputBar
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Type something...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit {
                    sendMessage()
                }

            if llm.isGenerating {
                Button {
                    llm.cancelGeneration()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 22)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && llm.isModelLoaded && !llm.isGenerating
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSend else { return }

        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        inputText = ""

        let settings = SettingsStorage.settings(for: model)

        // Build messages array for MLX (exclude streaming placeholder)
        var mlxMessages: [[String: String]] = []
        if !settings.systemPrompt.isEmpty {
            mlxMessages.append(["role": "system", "content": settings.systemPrompt])
        }
        for msg in messages where !msg.isStreaming {
            mlxMessages.append(msg.asDict)
        }

        // Insert placeholder assistant message
        let placeholder = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(placeholder)
        streamingMessageIndex = messages.count - 1

        Task {
            let result = await llm.generate(messages: mlxMessages, settings: settings)
            guard let idx = streamingMessageIndex, idx < messages.count else { return }

            if !result.response.isEmpty || result.thinking != nil {
                let thinking = settings.enableThinking ? result.thinking?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                messages[idx].content = result.response.trimmingCharacters(in: .whitespacesAndNewlines)
                messages[idx].thinkingContent = thinking
                messages[idx].stats = result.stats
                messages[idx].isStreaming = false
            } else {
                messages.remove(at: idx)
            }
            streamingMessageIndex = nil
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("bottom", anchor: .bottom)
    }
}
