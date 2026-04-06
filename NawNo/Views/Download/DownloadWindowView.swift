import SwiftUI

struct DownloadWindowView: View {
    @Environment(HFDownloadService.self) private var downloader
    @Environment(ModelStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Downloading Model")
                    .font(.headline)
            }

            if downloader.isDownloading {
                VStack(spacing: 8) {
                    if downloader.progress > 0 {
                        ProgressView(value: downloader.progress)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }

                    HStack {
                        Text(downloader.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !downloader.downloadSpeed.isEmpty {
                            Text(downloader.downloadSpeed)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if downloader.isStalled {
                        Text("Downloading large file — this may take a while...")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else if downloader.errorMessage != nil {
                Label(downloader.errorMessage!, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else {
                Label("Download complete!", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            HStack {
                Spacer()
                if downloader.isDownloading {
                    Button("Cancel") {
                        downloader.cancel()
                        dismissWindow(id: "download")
                    }
                } else {
                    Button("Close") {
                        dismissWindow(id: "download")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .onChange(of: downloader.isDownloading) { wasDownloading, isDownloading in
            if wasDownloading && !isDownloading {
                dismissWindow(id: "download")
            }
        }
    }
}
