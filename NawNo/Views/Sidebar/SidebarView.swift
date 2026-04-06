import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(ModelStore.self) private var store
    @Environment(LLMService.self) private var llm
    @Environment(HFDownloadService.self) private var downloader
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.openWindow) private var openWindow
    @State private var showImportSheet = false
    @State private var showFilePicker = false
    @State private var showDownloadSheet = false
    @State private var pendingImportURL: URL?
    @State private var importVendor = ""
    @State private var importModelName = ""
    @State private var importError: String?
    @State private var dropTargeted = false
    @State private var downloadInput = ""
    @State private var expandedModels: Set<UUID> = []

    var body: some View {
        @Bindable var store = store
        @Bindable var chatStore = chatStore

        List(selection: $chatStore.activeChatID) {
            ForEach(store.modelsByVendor, id: \.vendor) { group in
                Section(group.vendor) {
                    ForEach(group.models) { model in
                        modelSection(model)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button("Open Models Folder in Finder") {
                NSWorkspace.shared.open(ModelStore.modelsRoot)
            }
        }
        .navigationTitle("Models")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Import Folder...") {
                        showFilePicker = true
                    }
                    Button("Download from HuggingFace...") {
                        showDownloadSheet = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .overlay {
            if store.models.isEmpty && !dropTargeted {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Drop model folder here")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("or click + to import")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.1))
                    .padding(4)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                beginImport(url: url)
            }
        }
        .onAppear {
            expandedModels = Set(store.models.map(\.id))
        }
        .sheet(isPresented: $showImportSheet) {
            importSheet
        }
        .sheet(isPresented: $showDownloadSheet) {
            downloadSheet
        }
    }

    // MARK: - Model Section

    @ViewBuilder
    private func modelSection(_ model: ModelEntry) -> some View {
        HStack(spacing: 4) {
            Image(systemName: expandedModels.contains(model.id) ? "chevron.down" : "chevron.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if expandedModels.contains(model.id) {
                            expandedModels.remove(model.id)
                        } else {
                            expandedModels.insert(model.id)
                        }
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.body)
                    .fontWeight(.semibold)
                HStack(spacing: 4) {
                    Text(model.formattedDiskSize)
                    if let dateStr = model.folderDateString {
                        Text("·")
                        Text(dateStr)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedModelID = model.id
            chatStore.activeChatID = nil
        }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.directoryURL.path)
            }
            Divider()
            Button("Remove Model", role: .destructive) {
                if llm.isModelLoaded && store.selectedModelID == model.id {
                    llm.unloadModel()
                }
                store.removeModel(model)
            }
        }

        if expandedModels.contains(model.id) {
            ForEach(chatStore.chats(for: model)) { chat in
                chatRow(chat)
                    .tag(chat.id)
            }
        }
    }

    @ViewBuilder
    private func chatRow(_ chat: SavedChat) -> some View {
        HStack {
            Text(chat.title)
                .font(.callout)
                .lineLimit(1)
            Spacer()
            Button {
                chatStore.deleteChat(id: chat.id)
            } label: {
                Image(systemName: "trash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 8))
        .contextMenu {
            Button("Rename...") {
                // TODO: rename sheet
            }
            Divider()
            Button("Delete Chat", role: .destructive) {
                chatStore.deleteChat(id: chat.id)
            }
        }
    }

    // MARK: - Import Sheet

    private var importSheet: some View {
        VStack(spacing: 16) {
            Text("Import Model")
                .font(.headline)

            if let url = pendingImportURL {
                Text(url.lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextField("Vendor (e.g. Meta, Qwen)", text: $importVendor)
                .textFieldStyle(.roundedBorder)

            TextField("Model Name (e.g. Llama-3.2-1B-4bit)", text: $importModelName)
                .textFieldStyle(.roundedBorder)

            if let error = importError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    showImportSheet = false
                    resetImport()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Import") {
                    performImport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(importVendor.isEmpty || importModelName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    // MARK: - Download Sheet

    private var downloadSheet: some View {
        VStack(spacing: 16) {
            Text("Download from HuggingFace")
                .font(.headline)

            TextField("Model URL or ID (e.g. mlx-community/Llama-3.2-1B-Instruct-4bit)", text: $downloadInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { startDownload() }

            HStack {
                Button("Cancel") {
                    showDownloadSheet = false
                    downloadInput = ""
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Download") {
                    startDownload()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(downloadInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || downloader.isDownloading)
            }
        }
        .padding(20)
        .frame(width: 450)
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    beginImport(url: url)
                }
            }
        }
    }

    private func beginImport(url: URL) {
        pendingImportURL = url

        let parsed = ModelStore.parseModelFolder(url.lastPathComponent)
        importVendor = parsed.vendor
        importModelName = parsed.modelName

        showImportSheet = true
    }

    private func performImport() {
        guard let url = pendingImportURL else { return }
        importError = nil

        do {
            try store.importModel(from: url, vendor: importVendor, modelName: importModelName)
            showImportSheet = false

            if let newModel = store.models.last {
                store.selectedModelID = newModel.id
            }

            resetImport()
        } catch {
            importError = error.localizedDescription
        }
    }

    private func startDownload() {
        let input = downloadInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        // Dismiss the input sheet and open the download progress window
        showDownloadSheet = false
        let savedInput = downloadInput
        downloadInput = ""
        openWindow(id: "download")

        Task {
            do {
                let downloadedURL = try await downloader.download(input: savedInput)

                // Show import sheet so the user can name the vendor/model
                let repoID = HFDownloadService.parseRepoID(from: savedInput)
                let parsed = HFDownloadService.parseRepoComponents(from: repoID)
                pendingImportURL = downloadedURL
                importVendor = parsed.vendor
                importModelName = parsed.modelName
                showImportSheet = true
            } catch {
                // Error shown in the download window via downloader.errorMessage
            }
        }
    }

    private func resetImport() {
        pendingImportURL = nil
        importVendor = ""
        importModelName = ""
        importError = nil
    }
}
