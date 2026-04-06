import Foundation
import Hub

@MainActor @Observable
final class HFDownloadService {
    var isDownloading = false
    var progress: Double = 0
    var downloadSpeed: String = ""
    var statusText = ""
    var errorMessage: String?
    var lastProgressUpdate = Date()
    var totalSizeBytes: Int64 = 0
    var fileCount: Int = 0

    private var downloadTask: Task<URL, Error>?

    private static let fileGlobs = ["*.safetensors", "*.json", "*.jinja"]

    /// True when progress hasn't updated in 8+ seconds during download
    var isStalled: Bool {
        isDownloading && Date().timeIntervalSince(lastProgressUpdate) > 8
    }

    /// Download a HuggingFace model repo to a local directory.
    /// Accepts a full URL or bare repo ID (e.g. "mlx-community/Llama-3.2-1B-Instruct-4bit").
    func download(input: String) async throws -> URL {
        let repoID = Self.parseRepoID(from: input)

        isDownloading = true
        progress = 0
        downloadSpeed = ""
        statusText = "Fetching model info..."
        errorMessage = nil
        totalSizeBytes = 0
        fileCount = 0

        // Fetch file metadata to get accurate total size before downloading
        do {
            let metadata = try await HubApi.shared.getFileMetadata(
                from: repoID,
                matching: Self.fileGlobs
            )
            totalSizeBytes = metadata.reduce(0) { $0 + Int64($1.size ?? 0) }
            fileCount = metadata.count
            statusText = "Starting download — \(Self.formatBytes(totalSizeBytes)) across \(fileCount) files"
        } catch {
            // Non-fatal: proceed without size info
            statusText = "Downloading \(repoID)..."
        }

        let knownTotal = totalSizeBytes
        let service = self
        let task = Task { () -> URL in
            let url = try await HubApi.shared.snapshot(
                from: repoID,
                matching: Self.fileGlobs
            ) { prog, speed in
                let fraction = prog.fractionCompleted
                let now = Date()
                Task { @MainActor in
                    service.progress = fraction
                    service.lastProgressUpdate = now

                    if let speed, speed > 0 {
                        service.downloadSpeed = HFDownloadService.formatSpeed(speed)
                    }

                    let percent = Int(fraction * 100)
                    if knownTotal > 0 {
                        let downloaded = Self.formatBytes(Int64(fraction * Double(knownTotal)))
                        let total = Self.formatBytes(knownTotal)
                        service.statusText = "\(downloaded) of \(total) — \(percent)%"
                    } else if fraction > 0 {
                        service.statusText = "\(percent)% complete"
                    }
                }
            }
            return url
        }

        downloadTask = task

        do {
            let resultURL = try await task.value
            isDownloading = false
            statusText = "Download complete"
            return resultURL
        } catch {
            isDownloading = false
            errorMessage = error.localizedDescription
            statusText = "Download failed"
            throw error
        }
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        progress = 0
        downloadSpeed = ""
        statusText = ""
        errorMessage = nil
        totalSizeBytes = 0
        fileCount = 0
    }

    /// Parse a HuggingFace repo ID from various input formats.
    static func parseRepoID(from input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip URL prefix: https://huggingface.co/org/model → org/model
        if let url = URL(string: s), let host = url.host,
           host.contains("huggingface") {
            // Path is like /org/model or /org/model/tree/main
            let components = url.pathComponents.filter { $0 != "/" }
            if components.count >= 2 {
                return "\(components[0])/\(components[1])"
            }
        }

        // Strip trailing slashes
        while s.hasSuffix("/") { s = String(s.dropLast()) }

        return s
    }

    /// Parse vendor and model name from a repo ID like "mlx-community/Llama-3.2-1B-Instruct-4bit"
    static func parseRepoComponents(from repoID: String) -> (vendor: String, modelName: String) {
        let parts = repoID.split(separator: "/", maxSplits: 1)
        if parts.count == 2 {
            return (vendor: String(parts[0]), modelName: String(parts[1]))
        }
        return (vendor: "", modelName: repoID)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 {
            return String(format: "%.2f GB", gb)
        }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 {
            return String(format: "%.0f MB", mb)
        }
        let kb = Double(bytes) / 1_000
        return String(format: "%.0f KB", kb)
    }

    private static func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond > 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        } else if bytesPerSecond > 1_000 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}
