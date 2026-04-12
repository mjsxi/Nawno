import Foundation

struct ThreadMessageSnapshot: Sendable {
    let role: String
    let content: String
}

struct ThreadSnapshot: Sendable {
    let id: UUID
    let modelName: String?
    let messages: [ThreadMessageSnapshot]
}

extension Thread {
    @MainActor
    func snapshot() -> ThreadSnapshot {
        ThreadSnapshot(
            id: id,
            modelName: modelName,
            messages: sortedMessages.map {
                ThreadMessageSnapshot(role: $0.role.rawValue, content: $0.content)
            }
        )
    }
}

struct PromptPreparationTiming: Sendable {
    let ragQuery: TimeInterval
    let build: TimeInterval

    var total: TimeInterval { ragQuery + build }
}

struct PreparedPrompt: Sendable {
    let messages: [ChatTurn]
    let estimatedPromptTokens: Int
    let droppedMessageCount: Int
    let includedRAGChunks: Int
    let timing: PromptPreparationTiming
}

enum PromptFormatter {
    static func formatForTokenizer(_ message: String, reasoningEnabled: Bool) -> String {
        guard reasoningEnabled else { return message }

        let pattern = "<think>.*?(</think>|$)"
        var result = message
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
            let range = NSRange(location: 0, length: result.utf16.count)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        } catch {}

        if let endRange = result.range(of: "</think>") {
            result = String(result[endRange.upperBound...])
        }

        return " " + result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum PromptTokenEstimator {
    private static let charsPerToken = 4
    private static let turnOverhead = 6

    static func estimate(text: String) -> Int {
        max(1, (text.count + charsPerToken - 1) / charsPerToken)
    }

    static func estimate(turn: ChatTurn) -> Int {
        estimate(text: turn.content) + turnOverhead
    }
}

actor PromptPreparer {
    static let shared = PromptPreparer()

    func prepare(
        snapshot: ThreadSnapshot,
        systemPrompt: String,
        reasoningEnabled: Bool,
        contextWindow: Int,
        ragResults: [DocumentChunk],
        ragQueryDuration: TimeInterval
    ) -> PreparedPrompt {
        let buildStart = Date()
        let baseSystemTokens = PromptTokenEstimator.estimate(text: systemPrompt) + 6

        let formattedMessages = snapshot.messages.enumerated().map { index, message in
            let turn = ChatTurn(
                role: message.role,
                content: PromptFormatter.formatForTokenizer(message.content, reasoningEnabled: reasoningEnabled)
            )
            return IndexedTurn(index: index, turn: turn, estimatedTokens: PromptTokenEstimator.estimate(turn: turn))
        }

        let requiredIndexes = requiredIndexes(in: formattedMessages)
        var selectedIndexes = Set(requiredIndexes)
        var selectedTokenCount = formattedMessages
            .filter { selectedIndexes.contains($0.index) }
            .reduce(baseSystemTokens) { $0 + $1.estimatedTokens }

        for candidate in formattedMessages.reversed() where !selectedIndexes.contains(candidate.index) {
            if selectedTokenCount + candidate.estimatedTokens > contextWindow {
                continue
            }
            selectedIndexes.insert(candidate.index)
            selectedTokenCount += candidate.estimatedTokens
        }

        let selectedMessages = formattedMessages
            .filter { selectedIndexes.contains($0.index) }
            .sorted { $0.index < $1.index }
            .map(\.turn)

        let ragBudget = max(contextWindow - selectedTokenCount, 0)
        let ragContext = buildRAGContext(from: ragResults, remainingBudget: ragBudget)
        let finalSystemPrompt = systemPrompt + ragContext.text
        let finalMessages = [ChatTurn(role: "system", content: finalSystemPrompt)] + selectedMessages
        let finalTokenCount = selectedMessages.reduce(
            PromptTokenEstimator.estimate(text: finalSystemPrompt) + 6
        ) { $0 + PromptTokenEstimator.estimate(turn: $1) }

        return PreparedPrompt(
            messages: finalMessages,
            estimatedPromptTokens: finalTokenCount,
            droppedMessageCount: max(formattedMessages.count - selectedMessages.count, 0),
            includedRAGChunks: ragContext.chunkCount,
            timing: PromptPreparationTiming(
                ragQuery: ragQueryDuration,
                build: Date().timeIntervalSince(buildStart)
            )
        )
    }

    private func requiredIndexes(in messages: [IndexedTurn]) -> [Int] {
        var indexes: [Int] = []

        if let lastUser = messages.last(where: { $0.turn.role == "user" })?.index {
            indexes.append(lastUser)
        }
        if let lastAssistant = messages.last(where: { $0.turn.role == "assistant" })?.index,
           !indexes.contains(lastAssistant) {
            indexes.append(lastAssistant)
        }

        return indexes
    }

    private func buildRAGContext(from chunks: [DocumentChunk], remainingBudget: Int) -> (text: String, chunkCount: Int) {
        guard !chunks.isEmpty, remainingBudget > 0 else { return ("", 0) }

        let prefix = "\n\nUse the following reference material to help answer the user's question. If the reference material doesn't contain relevant information, say so.\n\n--- Reference Material ---"
        let suffix = "\n\n---"
        let fixedCost = PromptTokenEstimator.estimate(text: prefix) + PromptTokenEstimator.estimate(text: suffix)
        guard remainingBudget > fixedCost else { return ("", 0) }

        var includedSections: [String] = []
        var usedTokens = fixedCost

        for chunk in chunks {
            let section = "\n\n[Source: \(chunk.fileName)]\n\(chunk.text)"
            let sectionTokens = PromptTokenEstimator.estimate(text: section)
            if usedTokens + sectionTokens > remainingBudget {
                break
            }
            includedSections.append(section)
            usedTokens += sectionTokens
        }

        guard !includedSections.isEmpty else { return ("", 0) }
        return (prefix + includedSections.joined() + suffix, includedSections.count)
    }
}

private struct IndexedTurn: Sendable {
    let index: Int
    let turn: ChatTurn
    let estimatedTokens: Int
}
