import Foundation

enum PythonMLXError: LocalizedError {
    case notInstalled
    case noPython
    case serverStartFailed(String)
    case serverTimeout
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Python mlx-lm not found. Install with: pip install mlx-lm"
        case .noPython:
            return "Python 3 not found. Install from python.org or run: brew install python3"
        case .serverStartFailed(let reason):
            return "Failed to start Python MLX server: \(reason)"
        case .serverTimeout:
            return "Python MLX server timed out while loading the model"
        case .requestFailed(let reason):
            return "Python MLX request failed: \(reason)"
        }
    }
}

enum PythonStreamEvent {
    case chunk(String)
    case done(promptTokens: Int, completionTokens: Int)
}

@MainActor
final class PythonMLXService {
    private var process: Process?
    private var port: Int = 0
    private(set) var isServerReady = false
    private var currentModelPath: URL?

    private static var cachedAvailability: Bool?
    private static var cachedVersion: String?
    nonisolated(unsafe) private static var cachedPythonPath: String?

    /// The venv lives alongside Models and Chats in the app's data directory
    nonisolated static var venvURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("NawNo/python-env")
    }

    /// Python executable inside the venv
    nonisolated static var venvPython: URL {
        venvURL.appendingPathComponent("bin/python3")
    }

    /// pip inside the venv
    nonisolated static var venvPip: URL {
        venvURL.appendingPathComponent("bin/pip")
    }

    /// Check if the venv exists and has mlx-lm installed
    nonisolated static var isVenvReady: Bool {
        FileManager.default.isExecutableFile(atPath: venvPython.path)
    }

    // MARK: - Find System Python

    /// Find a usable system Python 3 for creating the venv
    nonisolated static func findSystemPython() -> String? {
        if let cached = cachedPythonPath { return cached }

        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/opt/local/bin/python3",
            "/usr/bin/python3"
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedPythonPath = path
                return path
            }
        }

        return nil
    }

    // MARK: - Venv Management

    /// Create the venv if it doesn't exist
    static func ensureVenv() async throws {
        if isVenvReady { return }

        guard let systemPython = findSystemPython() else {
            throw PythonMLXError.noPython
        }

        try await runProcess(
            executable: systemPython,
            arguments: ["-m", "venv", venvURL.path]
        )
    }

    /// Install or upgrade mlx-lm in the venv
    func installMLXLM() async throws {
        try await PythonMLXService.ensureVenv()

        try await PythonMLXService.runProcess(
            executable: PythonMLXService.venvPip.path,
            arguments: ["install", "--upgrade", "mlx-lm"]
        )

        PythonMLXService.clearCache()
    }

    /// Remove the entire venv directory
    static func removeVenv() throws {
        if FileManager.default.fileExists(atPath: venvURL.path) {
            try FileManager.default.removeItem(at: venvURL)
        }
        clearCache()
    }

    // MARK: - Availability

    static func isAvailable() async -> Bool {
        if let cached = cachedAvailability { return cached }
        guard isVenvReady else { return false }
        let result = await runVenvPython(args: ["-c", "import mlx_lm"])
        cachedAvailability = result
        return result
    }

    static func installedVersion() async -> String? {
        if let cached = cachedVersion { return cached }
        guard isVenvReady else { return nil }
        let version = await runVenvPythonOutput(args: ["-c", "import mlx_lm; print(mlx_lm.__version__)"])
        cachedVersion = version
        return version
    }

    static func clearCache() {
        cachedAvailability = nil
        cachedVersion = nil
    }

    // MARK: - Server Lifecycle

    func startServer(modelPath: URL) async throws {
        stopServer()

        guard await PythonMLXService.isAvailable() else {
            throw PythonMLXError.notInstalled
        }

        port = Int.random(in: 49152...65535)

        let proc = Process()
        proc.executableURL = PythonMLXService.venvPython
        proc.arguments = ["-m", "mlx_lm.server", "--model", modelPath.path, "--port", String(port)]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            throw PythonMLXError.serverStartFailed(error.localizedDescription)
        }

        process = proc
        currentModelPath = modelPath

        let timeout: TimeInterval = 120
        let start = Date()
        let pollInterval: UInt64 = 500_000_000 // 500ms

        while Date().timeIntervalSince(start) < timeout {
            if !proc.isRunning {
                let stderrData = stderrPipe.fileHandleForReading.availableData
                let stderr = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
                throw PythonMLXError.serverStartFailed(stderr)
            }

            if await checkServerHealth() {
                isServerReady = true
                return
            }

            try await Task.sleep(nanoseconds: pollInterval)
        }

        stopServer()
        throw PythonMLXError.serverTimeout
    }

    func stopServer() {
        guard let proc = process else { return }

        if proc.isRunning {
            proc.terminate()

            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if proc.isRunning {
                    proc.interrupt()
                }
            }
        }

        process = nil
        isServerReady = false
        currentModelPath = nil
    }

    // MARK: - Generation

    nonisolated func generate(messages: [[String: String]], settings: ModelSettings) -> AsyncThrowingStream<PythonStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let port = await self.port
                    let url = URL(string: "http://localhost:\(port)/v1/chat/completions")!

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let body: [String: Any] = [
                        "messages": messages,
                        "stream": true,
                        "stream_options": ["include_usage": true],
                        "temperature": Double(settings.temperature),
                        "top_p": Double(settings.topP),
                        "max_tokens": settings.maxTokens
                    ]

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                            if errorBody.count > 500 { break }
                        }
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        throw PythonMLXError.requestFailed("HTTP \(code): \(errorBody)")
                    }

                    var promptTokens = 0
                    var completionTokens = 0

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }

                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        if payload == "[DONE]" {
                            continuation.yield(.done(promptTokens: promptTokens, completionTokens: completionTokens))
                            break
                        }

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                        if let choices = json["choices"] as? [[String: Any]],
                           let firstChoice = choices.first,
                           let delta = firstChoice["delta"] as? [String: Any],
                           let content = delta["content"] as? String,
                           !content.isEmpty {
                            continuation.yield(.chunk(content))
                        }

                        if let usage = json["usage"] as? [String: Any] {
                            promptTokens = usage["prompt_tokens"] as? Int ?? promptTokens
                            completionTokens = usage["completion_tokens"] as? Int ?? completionTokens
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private Helpers

    private nonisolated func checkServerHealth() async -> Bool {
        let port = await self.port
        let url = URL(string: "http://localhost:\(port)/v1/models")!
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Run the venv Python with given args, return success/failure
    private static func runVenvPython(args: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = venvPython
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0)
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    /// Run the venv Python with given args, return stdout
    private static func runVenvPythonOutput(args: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = venvPython
            process.arguments = args

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: output?.isEmpty == false ? output : nil)
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Run any executable and throw on failure
    private static func runProcess(executable: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments

                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe

                do {
                    try proc.run()
                    proc.waitUntilExit()

                    if proc.terminationStatus != 0 {
                        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        continuation.resume(throwing: PythonMLXError.serverStartFailed(output))
                    } else {
                        continuation.resume()
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
