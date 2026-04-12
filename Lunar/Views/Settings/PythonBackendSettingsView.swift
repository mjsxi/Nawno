//
//  PythonBackendSettingsView.swift
//  Lunar
//
//  macOS-only: auto-detects a usable python install for `mlx_lm.server` and
//  guides the user through installing python or mlx-lm if anything is missing.
//

#if os(macOS)
import SwiftUI
import AppKit

struct PythonBackendSettingsView: View {
    @State private var status: PythonProbeStatus?
    @State private var installing = false
    @State private var installError: String?
    @State private var latestMLXLMVersion: String?
    @State private var pythonVersion: String?
    @State private var updating = false

    var body: some View {
        Form {
            switch status {
            case .none:
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("checking python…")
                            .foregroundStyle(.secondary)
                    }
                }
            case .ready(let path, let version):
                readySection(path: path, version: version)
            case .missingMLXLM(let path):
                missingMLXLMSection(path: path)
            case .noPython:
                noPythonSection()
            }
        }
        .formStyle(.grouped)
        .centeredSettingsPageTitle("python backend")
        .task { await recheck() }
    }

    // MARK: - sections

    @ViewBuilder
    private func readySection(path: String, version: String) -> some View {
        let updateAvailable = latestMLXLMVersion.map { PythonMLXBackend.isNewerVersion($0, than: version) } ?? false
        let pythonOutdated = pythonVersion.map { PythonMLXBackend.isPythonOutdated($0) } ?? false

        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("python backend ready").font(.headline)
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let pv = pythonVersion {
                        Text("python \(pv)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("mlx_lm \(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }

        if pythonOutdated, let pv = pythonVersion {
            Section(header: Text("update python")) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("python \(pv) is out of date").font(.headline)
                        Text("mlx-lm needs python \(PythonMLXBackend.minimumPythonVersion.0).\(PythonMLXBackend.minimumPythonVersion.1) or newer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("1. install Homebrew from brew.sh")
                    Button {
                        if let url = URL(string: "https://brew.sh") { NSWorkspace.shared.open(url) }
                    } label: {
                        Label("open brew.sh", systemImage: "safari")
                            .themedSettingsButtonContent()
                    }

                    Text("2. then run in Terminal:")
                    commandRow("brew install python")

                    Text("3. then install mlx-lm:")
                    commandRow("pip3 install --user --break-system-packages mlx-lm")
                }
            }
        }

        if updateAvailable, let latest = latestMLXLMVersion {
            Section(header: Text("update available")) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("mlx_lm \(latest) available").font(.headline)
                        Text("you have \(version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("run this in Terminal:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    commandRow("\(path) -m pip install --user --break-system-packages --upgrade mlx-lm")
                }
            }
        }

        Section {
            Button {
                Task { await recheck() }
            } label: {
                Text("re-check")
                    .themedSettingsButtonContent()
            }
                .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func missingMLXLMSection(path: String) -> some View {
        Section(header: Text("install mlx-lm")) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("python found, mlx_lm missing").font(.headline)
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }

            Button {
                Task { await runInstall(path: path) }
            } label: {
                HStack {
                    if installing {
                        ProgressView().controlSize(.small)
                        Text("installing mlx-lm…")
                    } else {
                        Image(systemName: "arrow.down.circle")
                        Text("install mlx-lm")
                    }
                }
                .themedSettingsButtonContent()
            }
            .disabled(installing)

            if let err = installError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("couldn't install automatically", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    if !err.isEmpty {
                        Text(err)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Text("run this in Terminal:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    commandRow("\(path) -m pip install --user --break-system-packages mlx-lm")
                }
            }
        }
    }

    @ViewBuilder
    private func noPythonSection() -> some View {
        Section(header: Text("install python")) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("python not found").font(.headline)
                    Text("install python via Homebrew, then re-check.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("1. install Homebrew from brew.sh")
                Button {
                    if let url = URL(string: "https://brew.sh") { NSWorkspace.shared.open(url) }
                } label: {
                    Label("open brew.sh", systemImage: "safari")
                        .themedSettingsButtonContent()
                }

                Text("2. then run in Terminal:")
                commandRow("brew install python")

                Text("3. then:")
                commandRow("pip3 install --user --break-system-packages mlx-lm")
            }
        }
    }

    // MARK: - helpers

    @ViewBuilder
    private func commandRow(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.black.opacity(0.1), lineWidth: 1)
                )
            Button {
                copyToPasteboard(command)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("copy")
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func openTerminal() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open(url)
        }
    }

    private func recheck() async {
        status = nil
        installError = nil
        latestMLXLMVersion = nil
        pythonVersion = nil
        let probed = await PythonMLXBackend.probe()
        status = probed
        if case .ready(let path, _) = probed {
            pythonVersion = await PythonMLXBackend.pythonVersion(at: path)
            latestMLXLMVersion = await PythonMLXBackend.fetchLatestMLXLMVersion()
        } else if case .missingMLXLM(let path) = probed {
            pythonVersion = await PythonMLXBackend.pythonVersion(at: path)
        }
    }

    private func runInstall(path: String) async {
        installing = true
        installError = nil
        defer { installing = false }
        let result = await PythonMLXBackend.installMLXLM(using: path)
        if result.success {
            await recheck()
        } else {
            installError = result.stderrTail ?? ""
        }
    }

    private func runUpdate(path: String) async {
        updating = true
        installError = nil
        defer { updating = false }
        let result = await PythonMLXBackend.installMLXLM(using: path)
        if result.success {
            await recheck()
        } else {
            installError = result.stderrTail ?? ""
        }
    }
}
#endif
