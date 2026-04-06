import Foundation
import SwiftUI
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

struct GenerationStats: Equatable {
    let tokensPerSecond: Double
    let totalTokens: Int
    let promptTokens: Int
    let timeToFirstToken: TimeInterval
    let totalTime: TimeInterval

    var formattedTPS: String { String(format: "%.1f tok/s", tokensPerSecond) }
    var formattedTTFT: String { String(format: "%.2fs", timeToFirstToken) }
    var formattedTotal: String { String(format: "%.2fs", totalTime) }
}

private struct LocalTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream: upstream)
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

@MainActor @Observable
final class LLMService {
    var isModelLoaded = false
    var isLoading = false
    var isGenerating = false
    var loadingProgress: Double = 0
    var statusText = ""
    var errorMessage: String?
    var currentStreamText = ""
    private(set) var activeBackend: BackendType?

    private var modelContainer: ModelContainer?
    private(set) var currentModelID: UUID?
    private var generateTask: Task<(String, GenerationStats?), Never>?
    private let pythonService = PythonMLXService()

    // MARK: - Load

    func loadModel(_ entry: ModelEntry) async {
        if currentModelID == entry.id && isModelLoaded {
            return
        }

        unloadModel()
        isLoading = true
        errorMessage = nil

        // Check for unsupported quantization before trying any backend
        if let reason = Self.checkSwiftCompatibility(entry.directoryURL) {
            errorMessage = reason
            statusText = "Load failed"
            isLoading = false
            return
        }

        let settings = SettingsStorage.settings(for: entry)

        switch settings.backend {
        case .swift:
            await loadSwift(entry)
        case .python:
            await loadPython(entry)
        case .auto:
            statusText = "Loading \(entry.displayName) (Swift)..."
            await loadSwift(entry)
            if !isModelLoaded {
                let swiftError = errorMessage
                errorMessage = nil
                statusText = "Swift failed, trying Python..."
                await loadPython(entry)
                if isModelLoaded {
                    var updated = settings
                    updated.backend = .python
                    SettingsStorage.save(updated, for: entry)
                } else if errorMessage == nil {
                    errorMessage = swiftError
                }
            }
        }

        isLoading = false
    }

    private static let swiftSupportedBits: Set<Int> = [2, 3, 4, 5, 6, 8]

    private func loadSwift(_ entry: ModelEntry) async {
        // Pre-check: read config.json for unsupported quantization that would crash
        if let unsupportedReason = Self.checkSwiftCompatibility(entry.directoryURL) {
            errorMessage = "Swift: \(unsupportedReason)"
            statusText = "Swift load failed"
            return
        }

        statusText = "Loading \(entry.displayName) (Swift)..."

        do {
            Memory.cacheLimit = 64 * 1024 * 1024

            let container = try await MLXLMCommon.loadModelContainer(
                from: entry.directoryURL,
                using: LocalTokenizerLoader()
            )

            modelContainer = container
            currentModelID = entry.id
            isModelLoaded = true
            activeBackend = .swift
            statusText = "Ready (Swift)"
        } catch {
            errorMessage = "Swift: \(error.localizedDescription)"
            statusText = "Swift load failed"
        }
    }

    /// Check if the model's config.json has settings that would crash Swift MLX
    private static func checkSwiftCompatibility(_ directoryURL: URL) -> String? {
        let configURL = directoryURL.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let quantization = json["quantization"] as? [String: Any],
           let bits = quantization["bits"] as? Int,
           !swiftSupportedBits.contains(bits) {
            return "\(bits)-bit quantization is not supported by MLX. Supported: 2, 3, 4, 5, 6, 8-bit."
        }

        return nil
    }

    private func loadPython(_ entry: ModelEntry) async {
        statusText = "Loading \(entry.displayName) (Python)..."

        do {
            try await pythonService.startServer(modelPath: entry.directoryURL)
            currentModelID = entry.id
            isModelLoaded = true
            activeBackend = .python
            statusText = "Ready (Python)"
        } catch {
            errorMessage = error.localizedDescription
            statusText = "Python load failed"
        }
    }

    // MARK: - Unload

    func unloadModel() {
        generateTask?.cancel()
        generateTask = nil
        modelContainer = nil
        pythonService.stopServer()
        currentModelID = nil
        isModelLoaded = false
        isGenerating = false
        activeBackend = nil
        currentStreamText = ""
        loadingProgress = 0
        statusText = ""
        errorMessage = nil
    }

    // MARK: - Generate

    func generate(messages: [[String: String]], settings: ModelSettings) async -> (String, GenerationStats?) {
        switch activeBackend {
        case .swift:
            return await generateSwift(messages: messages, settings: settings)
        case .python:
            let sanitized = Self.sanitizeMessages(messages)
            return await generatePython(messages: sanitized, settings: settings)
        default:
            errorMessage = "No model loaded"
            return ("", nil)
        }
    }

    /// Ensure messages alternate roles (system?, user, assistant, user, ...).
    /// Merges consecutive same-role messages and ensures it ends with a user message.
    private static func sanitizeMessages(_ messages: [[String: String]]) -> [[String: String]] {
        var result: [[String: String]] = []
        for msg in messages {
            guard let role = msg["role"], let content = msg["content"] else { continue }
            if role == "system" {
                if result.isEmpty || result.first?["role"] != "system" {
                    result.insert(msg, at: result.isEmpty ? 0 : (result.first?["role"] == "system" ? 1 : 0))
                }
                continue
            }
            if let last = result.last, last["role"] == role {
                // Merge consecutive same-role messages
                result[result.count - 1] = ["role": role, "content": (last["content"] ?? "") + "\n" + content]
            } else {
                result.append(msg)
            }
        }
        return result
    }

    private func generateSwift(messages: [[String: String]], settings: ModelSettings) async -> (String, GenerationStats?) {
        guard let container = modelContainer else {
            errorMessage = "No model loaded"
            return ("", nil)
        }

        isGenerating = true
        currentStreamText = ""
        errorMessage = nil

        let task = Task { () -> (String, GenerationStats?) in
            var fullText = ""
            var stats: GenerationStats?

            do {
                let result: (String, GenerationStats?) = try await container.perform { context in
                    let input = try await context.processor.prepare(
                        input: .init(messages: messages)
                    )

                    let params = GenerateParameters(
                        maxTokens: settings.maxTokens,
                        temperature: settings.temperature,
                        topP: settings.topP,
                        topK: settings.topK,
                        repetitionPenalty: settings.repetitionPenalty,
                        repetitionContextSize: settings.repetitionContextSize
                    )

                    let stream = try MLXLMCommon.generate(
                        input: input,
                        parameters: params,
                        context: context
                    )

                    var generated = ""
                    var firstTokenTime: Date?
                    let startTime = Date()
                    var completionInfo: GenerateCompletionInfo?

                    for await generation in stream {
                        if Task.isCancelled { break }
                        switch generation {
                        case .chunk(let text):
                            if firstTokenTime == nil {
                                firstTokenTime = Date()
                            }
                            generated += text
                            let snapshot = generated
                            Task { @MainActor in
                                withAnimation(.easeIn(duration: 0.15)) {
                                    self.currentStreamText = snapshot
                                }
                            }
                        case .info(let info):
                            completionInfo = info
                        case .toolCall:
                            break
                        }
                    }

                    var genStats: GenerationStats?
                    if let info = completionInfo {
                        genStats = GenerationStats(
                            tokensPerSecond: info.tokensPerSecond,
                            totalTokens: info.generationTokenCount,
                            promptTokens: info.promptTokenCount,
                            timeToFirstToken: firstTokenTime?.timeIntervalSince(startTime) ?? 0,
                            totalTime: Date().timeIntervalSince(startTime)
                        )
                    }

                    return (generated, genStats)
                }
                fullText = result.0
                stats = result.1
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.errorMessage = "Generation error: \(error.localizedDescription)"
                    }
                }
            }

            return (fullText, stats)
        }

        generateTask = task
        let result = await task.value

        isGenerating = false
        currentStreamText = ""
        return result
    }

    private func generatePython(messages: [[String: String]], settings: ModelSettings) async -> (String, GenerationStats?) {
        isGenerating = true
        currentStreamText = ""
        errorMessage = nil

        let task = Task { () -> (String, GenerationStats?) in
            var fullText = ""
            var stats: GenerationStats?

            let startTime = Date()
            var firstTokenTime: Date?

            do {
                let stream = pythonService.generate(messages: messages, settings: settings)

                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .chunk(let text):
                        if firstTokenTime == nil {
                            firstTokenTime = Date()
                        }
                        fullText += text
                        let snapshot = fullText
                        Task { @MainActor in
                            withAnimation(.easeIn(duration: 0.15)) {
                                self.currentStreamText = snapshot
                            }
                        }
                    case .done(let promptTok, let completionTok):
                        let totalTime = Date().timeIntervalSince(startTime)
                        let tps = totalTime > 0 ? Double(completionTok) / totalTime : 0
                        stats = GenerationStats(
                            tokensPerSecond: tps,
                            totalTokens: completionTok,
                            promptTokens: promptTok,
                            timeToFirstToken: firstTokenTime?.timeIntervalSince(startTime) ?? 0,
                            totalTime: totalTime
                        )
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.errorMessage = "Generation error: \(error.localizedDescription)"
                    }
                }
            }

            return (fullText, stats)
        }

        generateTask = task
        let result = await task.value

        isGenerating = false
        currentStreamText = ""
        return result
    }

    func cancelGeneration() {
        generateTask?.cancel()
        generateTask = nil
        isGenerating = false
        currentStreamText = ""
    }

}
