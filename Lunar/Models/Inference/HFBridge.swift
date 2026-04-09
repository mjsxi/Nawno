//
//  HFBridge.swift
//  Lunar
//
//  Bridges huggingface/swift-transformers (HubApi + AutoTokenizer) to the
//  MLXLMCommon.Downloader and MLXLMCommon.TokenizerLoader protocols. The
//  mlx-swift-lm package no longer ships its own concrete HuggingFace plumbing
//  on `main`, so we provide it ourselves rather than going through the
//  half-finished MLXHuggingFace macros.
//

import Foundation
import MLXLMCommon
import Hub
import Tokenizers

/// Downloads model snapshots from huggingface.co via swift-transformers' HubApi.
struct LunarHubDownloader: MLXLMCommon.Downloader {
    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await HubApi.shared.snapshot(
            from: Hub.Repo(id: id),
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}

/// Loads a tokenizer from a local directory using AutoTokenizer and adapts
/// the swift-transformers Tokenizer protocol to MLXLMCommon.Tokenizer.
struct LunarTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream: upstream)
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let upstream: any Tokenizers.Tokenizer

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

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
