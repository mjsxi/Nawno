//
//  AddModelView.swift
//  Lunar
//
//  Lets the user install a model either from the curated catalog (filtered
//  by available device RAM) or by pasting an arbitrary HuggingFace repo
//  URL / id. Both paths end up calling LLMEvaluator.switchModel which kicks
//  off the mlx-swift download.
//

import SwiftUI
import MLXLMCommon

struct AddModelView: View {
    @EnvironmentObject private var appPreferences: AppPreferences
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(LLMEvaluator.self) var llm

    @State private var pastedText: String = ""
    @State private var validating = false
    @State private var errorMessage: String?
    @State private var lastValidated: HFRepoInfo?
    @State private var installing = false
    @State private var validationTask: Task<Void, Never>?
    @State private var installTask: Task<Void, Never>?

    private var totalRAMGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
    }

    var body: some View {
        Form {
            Section("from huggingface") {
                TextField("", text: $pastedText, prompt: Text("org/name or https://huggingface.co/…"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .onChange(of: pastedText) { _, newValue in
                        scheduleValidate(newValue)
                    }

                if let info = lastValidated {
                    HStack {
                        Image(systemName: info.hasMLXLayout ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(info.hasMLXLayout ? .green : .orange)
                        VStack(alignment: .leading) {
                            Text(info.repoId).font(.callout).bold()
                            if !info.hasMLXLayout {
                                Text("not an mlx-compatible repo").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }

                if let err = errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 6) {
                    if validating {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("validating…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if installing {
                        HStack(spacing: 8) {
                            ProgressView(value: llm.progress)
                                .progressViewStyle(.linear)
                                .frame(maxWidth: .infinity)
                            Text("\(Int(llm.progress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if installing {
                        Text("models can take some time to download depending on your internet speed — please keep this window open")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let info = lastValidated, let bytes = info.totalBytes {
                        Text("≈ \(formatGB(bytes)) GB on disk")
                            .font(.caption)
                            .foregroundStyle(Double(bytes) / 1_073_741_824.0 > totalRAMGB * 0.75 ? .orange : .secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .centeredSettingsPageTitle("add model")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if lastValidated?.hasMLXLayout == true {
                VStack(spacing: 0) {
                    Divider()
                    Button {
                        installTask = Task { await install() }
                    } label: {
                        Group {
                            if installing {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("installing…")
                                }
                            } else {
                                Text("install")
                            }
                        }
                        .themedSettingsButtonContent()
                    }
                    #if os(macOS)
                    .buttonStyle(.borderless)
                    #endif
                    .disabled(installing)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.background)
                }
            }
        }
        .onDisappear {
            validationTask?.cancel()
            installTask?.cancel()
        }
    }

    private func formatGB(_ bytes: Int64) -> String {
        String(format: "%.2f", Double(bytes) / 1_073_741_824.0)
    }

    private func scheduleValidate(_ raw: String) {
        validationTask?.cancel()
        lastValidated = nil
        errorMessage = nil
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        validationTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            await validate()
        }
    }

    @MainActor
    private func validate() async {
        errorMessage = nil
        lastValidated = nil
        guard let repoId = HuggingFaceClient.parseRepoId(pastedText) else {
            errorMessage = HFError.invalidInput.localizedDescription
            return
        }
        validating = true
        defer { validating = false }
        do {
            let info = try await HuggingFaceClient.fetchRepoInfo(repoId)
            lastValidated = info
            if !info.hasMLXLayout {
                errorMessage = HFError.notMLXCompatible.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func install() async {
        guard let info = lastValidated, info.hasMLXLayout else { return }
        installing = true
        defer { installing = false }
        appPreferences.addCustomHFModel(info.repoId)
        let cfg = ModelConfiguration.getOrRegister(info.repoId)
        await llm.switchModel(cfg)
        if Task.isCancelled {
            // user hit cancel — roll back
            appPreferences.removeInstalledModel(info.repoId, settings: modelSettings)
            return
        }
        appPreferences.addInstalledModel(info.repoId)
        appPreferences.currentModelName = info.repoId
        dismiss()
    }

}
