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

struct GenerationResult {
    let response: String
    let thinking: String?
    let stats: GenerationStats?
}

/// Incrementally parses `<think>...</think>` blocks from a streaming text buffer.
/// Starts in response mode. If `<think>` is seen, switches to thinking mode.
/// If `</think>` is seen without a prior `<think>` (tokenizer stripped it),
/// retroactively moves accumulated response to thinking.
struct ThinkingParser {
    private(set) var thinking = ""
    private(set) var response = ""
    private var inThinking: Bool
    private var sawThinkTag = false
    private var buffer = ""

    init(startInThinking: Bool = false) {
        self.inThinking = startInThinking
    }

    mutating func append(_ text: String) {
        buffer += text

        while !buffer.isEmpty {
            if inThinking {
                // In thinking mode — look for </think>
                if let endRange = buffer.range(of: "</think>") {
                    thinking += buffer[buffer.startIndex..<endRange.lowerBound]
                    buffer = String(buffer[endRange.upperBound...])
                    inThinking = false
                } else {
                    let partial = partialSuffix(of: buffer, matching: "</think>")
                    if partial > 0 {
                        thinking += buffer.dropLast(partial)
                        buffer = String(buffer.suffix(partial))
                    } else {
                        thinking += buffer
                        buffer = ""
                    }
                    break
                }
            } else {
                // In response mode — look for <think> or </think>
                if let startRange = buffer.range(of: "<think>") {
                    response += buffer[buffer.startIndex..<startRange.lowerBound]
                    buffer = String(buffer[startRange.upperBound...])
                    inThinking = true
                    sawThinkTag = true
                } else if !sawThinkTag, let endRange = buffer.range(of: "</think>") {
                    // </think> without <think> — tokenizer stripped <think>
                    // Move everything accumulated so far to thinking
                    thinking = response + String(buffer[buffer.startIndex..<endRange.lowerBound])
                    response = ""
                    buffer = String(buffer[endRange.upperBound...])
                    sawThinkTag = true
                } else {
                    let partial = max(
                        partialSuffix(of: buffer, matching: "<think>"),
                        partialSuffix(of: buffer, matching: "</think>")
                    )
                    if partial > 0 {
                        response += buffer.dropLast(partial)
                        buffer = String(buffer.suffix(partial))
                    } else {
                        response += buffer
                        buffer = ""
                    }
                    break
                }
            }
        }
    }

    /// Flush any remaining buffer content to the appropriate destination.
    /// Call after the stream ends to ensure no content is lost.
    /// If still in thinking mode and </think> was never seen, the model doesn't
    /// actually use thinking — move everything to response.
    mutating func flush() {
        if !buffer.isEmpty {
            if inThinking {
                thinking += buffer
            } else {
                response += buffer
            }
            buffer = ""
        }
        // If we're still in thinking mode and never saw </think>,
        // the model doesn't use thinking — move all to response
        if inThinking && !sawThinkTag {
            response = thinking + response
            thinking = ""
        }
    }

    /// Returns the length of the longest suffix of `text` that is a prefix of `tag`.
    private func partialSuffix(of text: String, matching tag: String) -> Int {
        let tagChars = Array(tag)
        for len in stride(from: min(text.count, tagChars.count - 1), through: 1, by: -1) {
            if text.hasSuffix(String(tagChars.prefix(len))) {
                return len
            }
        }
        return 0
    }
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
    var currentThinkingText = ""
    private(set) var activeBackend: BackendType?

    private var modelContainer: ModelContainer?
    private(set) var currentModelID: UUID?
    private var generateTask: Task<GenerationResult, Never>?
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
            statusText = "Loading \(entry.displayName) (Python)..."
            await loadPython(entry)
            if !isModelLoaded {
                let pythonError = errorMessage
                errorMessage = nil
                statusText = "Python failed, trying Swift..."
                await loadSwift(entry)
                if !isModelLoaded, errorMessage == nil {
                    errorMessage = pythonError
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
        do {
            // Auto-setup: download Python + install mlx-lm if needed
            if await !PythonMLXService.isAvailable() {
                if !PythonMLXService.isStandalonePythonReady && PythonMLXService.findSystemPython() == nil {
                    statusText = "Downloading Python..."
                }
                statusText = "Setting up Python environment..."
                try await pythonService.ensureFullSetup()
            }

            statusText = "Loading \(entry.displayName) (Python)..."
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
        currentThinkingText = ""
        loadingProgress = 0
        statusText = ""
        errorMessage = nil
    }

    // MARK: - Generate

    func generate(messages: [[String: String]], settings: ModelSettings) async -> GenerationResult {
        switch activeBackend {
        case .swift:
            return await generateSwift(messages: messages, settings: settings)
        case .python:
            let sanitized = Self.sanitizeMessages(messages)
            return await generatePython(messages: sanitized, settings: settings)
        default:
            errorMessage = "No model loaded"
            return GenerationResult(response: "", thinking: nil, stats: nil)
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

    private func generateSwift(messages: [[String: String]], settings: ModelSettings) async -> GenerationResult {
        guard let container = modelContainer else {
            errorMessage = "No model loaded"
            return GenerationResult(response: "", thinking: nil, stats: nil)
        }

        isGenerating = true
        currentStreamText = ""
        currentThinkingText = ""
        errorMessage = nil

        let task = Task { () -> GenerationResult in
            var genResult = GenerationResult(response: "", thinking: nil, stats: nil)

            do {
                genResult = try await container.perform { context in
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

                    var parser = ThinkingParser(startInThinking: settings.enableThinking)
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
                            parser.append(text)
                            let thinkSnap = parser.thinking
                            let respSnap = parser.response
                            Task { @MainActor in
                                withAnimation(.easeIn(duration: 0.15)) {
                                    self.currentThinkingText = thinkSnap
                                    self.currentStreamText = respSnap
                                }
                            }
                        case .info(let info):
                            completionInfo = info
                        case .toolCall:
                            break
                        }
                    }

                    parser.flush()

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

                    let thinking = parser.thinking.isEmpty ? nil : parser.thinking
                    return GenerationResult(response: parser.response, thinking: thinking, stats: genStats)
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.errorMessage = "Generation error: \(error.localizedDescription)"
                    }
                }
            }

            return genResult
        }

        generateTask = task
        let result = await task.value

        isGenerating = false
        currentStreamText = ""
        currentThinkingText = ""
        return result
    }

    private func generatePython(messages: [[String: String]], settings: ModelSettings) async -> GenerationResult {
        isGenerating = true
        currentStreamText = ""
        currentThinkingText = ""
        errorMessage = nil

        let task = Task { () -> GenerationResult in
            var parser = ThinkingParser(startInThinking: settings.enableThinking)
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
                        parser.append(text)
                        let thinkSnap = parser.thinking
                        let respSnap = parser.response
                        Task { @MainActor in
                            withAnimation(.easeIn(duration: 0.15)) {
                                self.currentThinkingText = thinkSnap
                                self.currentStreamText = respSnap
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

            parser.flush()

            let thinking = parser.thinking.isEmpty ? nil : parser.thinking
            return GenerationResult(response: parser.response, thinking: thinking, stats: stats)
        }

        generateTask = task
        let result = await task.value

        isGenerating = false
        currentStreamText = ""
        currentThinkingText = ""
        return result
    }

    func cancelGeneration() {
        generateTask?.cancel()
        generateTask = nil
        isGenerating = false
        currentStreamText = ""
        currentThinkingText = ""
    }

}
