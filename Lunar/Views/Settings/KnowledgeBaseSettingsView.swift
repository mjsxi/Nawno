//
//  KnowledgeBaseSettingsView.swift
//  Lunar
//
//  Settings UI for the personal knowledge base (RAG) feature.
//

import SwiftUI
#if os(iOS)
import UniformTypeIdentifiers
#endif

struct KnowledgeBaseSettingsView: View {
    @EnvironmentObject var appPreferences: AppPreferences
    @EnvironmentObject var knowledgeBase: KnowledgeBaseIndex
    @State private var showPurgeConfirmation = false
    #if os(iOS)
    @State private var showDocumentPicker = false
    #endif

    var body: some View {
        Form {
            if let url = knowledgeBase.folderURL {
                Section(header: Text("folder"), footer: Text("select a folder containing your writing and documents. supported formats: .txt, .md, .pdf, .rtf")) {
                    LabeledContent("path", value: url.lastPathComponent)

                    HStack(spacing: 12) {
                        Button {
                            pickFolder()
                        } label: {
                            Text("change folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            knowledgeBase.removeFolder()
                        } label: {
                            Text("remove folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            } else {
                Section(header: Text("folder"), footer: Text("select a folder containing your writing and documents. supported formats: .txt, .md, .pdf, .rtf")) {
                    Button {
                        pickFolder()
                        } label: {
                            Text("select folder")
                                .themedSettingsButtonContent()
                        }
                    #if os(macOS)
                    .buttonStyle(.borderless)
                    #endif
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }

            if knowledgeBase.hasFolderConfigured {
                if knowledgeBase.hasIndex {
                    Section(header: Text("resources")) {
                        LabeledContent("RAM estimate", value: knowledgeBase.stats.ramEstimateFormatted)
                        LabeledContent("disk usage", value: knowledgeBase.stats.diskUsageFormatted)
                    }
                }

                Section(header: Text("index"), footer: Text("your documents are split into searchable chunks so the model can find relevant content. refresh updates for new or changed files. rebuild re-processes everything from scratch.")) {
                    if knowledgeBase.isIndexing {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("indexing...")
                                .foregroundStyle(.secondary)
                            ProgressView(value: knowledgeBase.indexProgress)
                        }
                    } else if knowledgeBase.hasIndex {
                        LabeledContent("files indexed", value: "\(knowledgeBase.stats.fileCount)")
                        LabeledContent("chunks", value: "\(knowledgeBase.stats.chunkCount)")

                        HStack(spacing: 12) {
                            Button {
                                Task { await knowledgeBase.refresh() }
                            } label: {
                                Text("refresh index")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                Task { await knowledgeBase.indexFolder() }
                            } label: {
                                Text("rebuild index")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    } else {
                        Button {
                            Task { await knowledgeBase.indexFolder() }
                        } label: {
                            Text("build index")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    if let error = knowledgeBase.errorMessage {
                        Text(error)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                if knowledgeBase.hasIndex {
                    Section(header: Text("retrieval"), footer: Text("how many chunks of your writing to include as context. more chunks means more context for the model, but uses more of its context window.")) {
                        Stepper("context chunks: \(appPreferences.ragTopK)", value: $appPreferences.ragTopK, in: 1...20)
                    }

                    Button(role: .destructive) {
                        showPurgeConfirmation = true
                    } label: {
                        Label("purge knowledge base", systemImage: "trash")
                            .themedSettingsButtonContent(color: .red)
                    }
                    #if os(macOS)
                    .buttonStyle(.borderless)
                    #endif
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
        }
        .formStyle(.grouped)
        .centeredSettingsPageTitle("knowledge base")
        #if os(iOS)
        .sheet(isPresented: $showDocumentPicker) {
            FolderPicker { url in
                knowledgeBase.setFolder(url)
                Task { await knowledgeBase.indexFolder() }
            }
        }
        #endif
        .alert("purge knowledge base?", isPresented: $showPurgeConfirmation) {
            Button("purge", role: .destructive) {
                knowledgeBase.purge()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("this will delete the .lunar_index folder and all indexed data. your original files will not be affected.")
        }
    }

    private func pickFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select your knowledge base folder"
        if panel.runModal() == .OK, let url = panel.url {
            knowledgeBase.setFolder(url)
            Task { await knowledgeBase.indexFolder() }
        }
        #else
        showDocumentPicker = true
        #endif
    }
}

#if os(iOS)
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            onPick(url)
        }
    }
}
#endif
