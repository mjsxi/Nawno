//
//  InferenceBackend.swift
//  Lunar
//
//  Abstraction over the underlying LLM runtime so the chat layer can
//  remain agnostic to whether tokens come from mlx-swift (in-process)
//  or from an mlx_lm Python subprocess (macOS only).
//

import Foundation

public enum BackendKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case mlxSwift   // ml-explore/mlx-swift, in-process. iOS + macOS.
    case pythonMLX  // mlx_lm via Process + HTTP. macOS only.

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mlxSwift:  return "MLX Swift"
        case .pythonMLX: return "MLX LM (Python)"
        }
    }

    public var isAvailableOnThisPlatform: Bool {
        #if os(macOS)
        return true
        #else
        return self == .mlxSwift
        #endif
    }
}

public struct GenerateParams: Sendable {
    public var temperature: Float = 0.5
    public var topP: Float = 1.0
    public var topK: Int = 40
    public var maxTokens: Int = 4096
    public init(temperature: Float = 0.5, topP: Float = 1.0, topK: Int = 40, maxTokens: Int = 4096) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxTokens = maxTokens
    }
}

public struct ChatTurn: Sendable {
    public let role: String   // "system" | "user" | "assistant"
    public let content: String
    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

@MainActor
public protocol InferenceBackend: AnyObject {
    /// Eagerly download/load the model weights.
    func load(modelName: String, progress: @Sendable @escaping (Double) -> Void) async throws

    /// Streaming generation. Each yielded String is the *full* output so far
    /// (matching how LLMEvaluator already updates its `output` property).
    func generate(modelName: String,
                  messages: [ChatTurn],
                  params: GenerateParams) -> AsyncThrowingStream<String, Error>

    func cancel()
}
