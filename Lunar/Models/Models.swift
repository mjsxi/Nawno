//
//  Models.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/4/24.
//

import Foundation
import MLXLMCommon

public extension ModelConfiguration {
    enum ModelType {
        case regular, reasoning
    }

    var modelType: ModelType {
        let isReasoning = SuggestedModelsCatalog.first(matching: name)?.isReasoning ?? false
        return isReasoning ? .reasoning : .regular
    }

    func modelType(reasoningEnabled: Bool) -> ModelType {
        return reasoningEnabled ? .reasoning : .regular
    }
}

extension ModelConfiguration {
    @MainActor
    public static var availableModels: [ModelConfiguration] = SuggestedModelsCatalog.all.map {
        ModelConfiguration(id: $0.repoId)
    }

    @MainActor
    public static var defaultModel: ModelConfiguration {
        availableModels.first ?? ModelConfiguration(id: "mlx-community/Llama-3.2-1B-Instruct-4bit")
    }

    @MainActor
    public static func getModelByName(_ name: String) -> ModelConfiguration? {
        if let model = availableModels.first(where: { $0.name == name }) {
            return model
        }
        return nil
    }

    func getPromptHistory(thread: Thread, systemPrompt: String, reasoningEnabled: Bool? = nil) -> [[String: String]] {
        var history: [[String: String]] = []
        let isReasoning = reasoningEnabled ?? (modelType == .reasoning)

        // system prompt
        history.append([
            "role": "system",
            "content": systemPrompt,
        ])

        // messages
        for message in thread.sortedMessages {
            let role = message.role.rawValue
            history.append([
                "role": role,
                "content": formatForTokenizer(message.content, reasoningEnabled: isReasoning), // remove reasoning part
            ])
        }

        return history
    }

    // TODO: Remove this function when Jinja gets updated
    func formatForTokenizer(_ message: String, reasoningEnabled: Bool? = nil) -> String {
        let isReasoning = reasoningEnabled ?? (modelType == .reasoning)
        return PromptFormatter.formatForTokenizer(message, reasoningEnabled: isReasoning)
    }

    /// Returns the model's approximate size, in GB.
    public var modelSize: Decimal? {
        SuggestedModelsCatalog.first(matching: name).map { Decimal($0.sizeGB) }
    }
}
