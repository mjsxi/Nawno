import SwiftUI

struct ContentView: View {
    @Environment(ModelStore.self) private var store
    @Environment(LLMService.self) private var llm
    @Environment(ChatStore.self) private var chatStore
    @Environment(UpdateService.self) private var updateService
    @State private var showSettings = false
    @State private var chatMessages: [ChatMessage] = []
    @State private var suppressSave = false
    @State private var showLoadError = false
    @State private var isInstallingPython = false
    @State private var pythonInstallResult: String?
    @State private var showInstallResult = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            VStack(spacing: 0) {
                updateBanners
                detailContent
            }
            .navigationBarBackButtonHidden()
            .navigationTitle("")
            .toolbar {
                if let model = store.selectedModel {
                    ToolbarItem(placement: .navigation) {
                        Text(model.displayName)
                            .font(.headline)
                            .lineLimit(1)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: 8) {
                            statusView
                            loadButton(for: model)
                            settingsButton
                        }
                        .fixedSize()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showLoadError) {
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.title2)
                    Text("Failed to Load Model")
                        .font(.headline)
                    Spacer()
                }

                ScrollView {
                    Text(llm.errorMessage ?? "")
                        .font(.body.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)

                HStack {
                    Spacer()
                    if llm.errorMessage?.contains("mlx-lm not found") == true {
                        Button("Install mlx-lm") {
                            showLoadError = false
                            llm.errorMessage = nil
                            installPythonMLX()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button(llm.errorMessage?.contains("mlx-lm not found") == true ? "Cancel" : "OK") {
                        showLoadError = false
                        llm.errorMessage = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 450)
        }
        .alert(pythonInstallResult?.contains("failed") == true ? "Install Failed" : "Install Complete",
               isPresented: $showInstallResult) {
            Button("OK") { pythonInstallResult = nil }
        } message: {
            Text(pythonInstallResult ?? "")
        }
        .overlay {
            if isInstallingPython {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Installing mlx-lm...")
                        .font(.headline)
                    Text("This may take a minute")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(32)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onChange(of: llm.errorMessage) { _, newValue in
            showLoadError = newValue != nil
        }
        .background(WindowAccessor())
        .onChange(of: store.selectedModelID) { _, _ in
            if chatStore.activeChatID == nil {
                suppressSave = true
                chatMessages = []
            }
        }
        .onChange(of: chatStore.activeChatID) { _, newID in
            showSettings = false
            loadChat(id: newID)
        }
        .onChange(of: chatMessages) { _, newMessages in
            if suppressSave {
                suppressSave = false
                return
            }
            if chatStore.activeChatID == nil, !newMessages.isEmpty, let model = store.selectedModel {
                let chat = chatStore.createChat(for: model)
                chatStore.updateChat(id: chat.id, messages: newMessages)
            } else {
                saveCurrentChat()
            }
        }
    }

    // MARK: - Update Banners

    @ViewBuilder
    private var updateBanners: some View {
        if let update = updateService.appUpdate {
            updateBanner(
                icon: "arrow.down.app.fill",
                message: "NawNo \(update.latest) available (you have \(update.current))",
                actionLabel: "Download",
                action: {
                    if let url = update.downloadURL {
                        NSWorkspace.shared.open(url)
                    }
                },
                dismiss: { updateService.appUpdate = nil }
            )
        }

        if let update = updateService.mlxSwiftUpdate {
            updateBanner(
                icon: "shippingbox.fill",
                message: "New mlx-swift-lm available (\(update.current) \u{2192} \(update.latest)) — update NawNo for latest model support",
                actionLabel: nil,
                action: nil,
                dismiss: { updateService.mlxSwiftUpdate = nil }
            )
        }

        if let update = updateService.mlxPythonUpdate {
            updateBanner(
                icon: "arrow.triangle.2.circlepath",
                message: "Python mlx-lm \(update.latest) available (installed: \(update.current))",
                actionLabel: updateService.isUpgradingPython ? "Upgrading..." : "Update",
                action: {
                    Task { await updateService.upgradePython() }
                },
                dismiss: { updateService.mlxPythonUpdate = nil }
            )
        }

        if let error = updateService.upgradeError {
            updateBanner(
                icon: "exclamationmark.triangle.fill",
                message: "Python upgrade failed: \(error)",
                actionLabel: nil,
                action: nil,
                dismiss: { updateService.upgradeError = nil }
            )
        }
    }

    private func updateBanner(
        icon: String,
        message: String,
        actionLabel: String?,
        action: (() -> Void)?,
        dismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
            Text(message)
                .font(.caption)
            Spacer()
            if let label = actionLabel, let action = action {
                Button(label, action: action)
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(updateService.isUpgradingPython && label == "Upgrading...")
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.blue.opacity(0.08))
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        if let model = store.selectedModel {
            if showSettings {
                ModelSettingsView(model: model)
            } else {
                ChatView(model: model, messages: $chatMessages)
            }
        } else {
            VStack(spacing: 12) {
                Image("LilGuy")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .opacity(0.6)
                Text("Select a model to get started")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Drag a model folder onto the sidebar to import it")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Toolbar

    private var statusView: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
            .padding(.trailing, 2)
            .help(llm.errorMessage ?? llm.statusText)
    }

    private var isSelectedModelLoaded: Bool {
        llm.isModelLoaded && llm.currentModelID == store.selectedModelID
    }

    private var statusColor: Color {
        if llm.isLoading { return .yellow }
        if isSelectedModelLoaded { return .green }
        return .red
    }

    private func loadButton(for model: ModelEntry) -> some View {
        Button {
            Task {
                if isSelectedModelLoaded {
                    llm.unloadModel()
                } else {
                    await llm.loadModel(model)
                }
            }
        } label: {
            Image(systemName: isSelectedModelLoaded ? "eject.fill" : "play.fill")
                .font(.callout)
        }
        .buttonStyle(.plain)
        .disabled(llm.isLoading)
        .help(isSelectedModelLoaded ? "Unload" : "Load")
    }

    private var settingsButton: some View {
        Button {
            showSettings.toggle()
        } label: {
            Image(systemName: showSettings ? "gearshape.fill" : "gearshape")
                .font(.callout)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Chat

    private func loadChat(id: UUID?) {
        guard let id, let chat = chatStore.chats.first(where: { $0.id == id }) else {
            suppressSave = true
            chatMessages = []
            return
        }
        if let model = store.models.first(where: { $0.vendor == chat.vendor && $0.displayName == chat.modelName }) {
            store.selectedModelID = model.id
        }
        suppressSave = true
        chatMessages = chat.messages.map { $0.toChatMessage }
    }

    private func installPythonMLX() {
        isInstallingPython = true
        Task {
            do {
                let service = PythonMLXService()
                try await service.ensureFullSetup()
                pythonInstallResult = "Python environment ready. You can now load models with the Python backend."
            } catch {
                pythonInstallResult = "Install failed: \(error.localizedDescription)"
            }
            isInstallingPython = false
            showInstallResult = true
        }
    }

    private func saveCurrentChat() {
        guard let chatID = chatStore.activeChatID else { return }
        chatStore.updateChat(id: chatID, messages: chatMessages)
    }
}
