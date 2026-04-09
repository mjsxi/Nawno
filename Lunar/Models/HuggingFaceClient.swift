//
//  HuggingFaceClient.swift
//  Lunar
//
//  Tiny wrapper around the public HuggingFace Hub API for validating that
//  a user-pasted repo exists and estimating its on-disk size.
//

import Foundation

struct HFRepoInfo {
    let repoId: String
    let totalBytes: Int64?
    let hasMLXLayout: Bool   // config.json + safetensors present
}

enum HFError: LocalizedError {
    case invalidInput
    case notFound
    case network(String)
    case notMLXCompatible

    var errorDescription: String? {
        switch self {
        case .invalidInput:     return "That doesn't look like a HuggingFace repo URL or id."
        case .notFound:         return "Repo not found on HuggingFace."
        case .network(let m):   return "Network error: \(m)"
        case .notMLXCompatible: return "Repo doesn't contain a config.json + safetensors layout that mlx-swift can load."
        }
    }
}

enum HuggingFaceClient {
    /// Accepts either `org/name` or any huggingface.co URL pointing at a model.
    static func parseRepoId(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let url = URL(string: trimmed), let host = url.host, host.contains("huggingface.co") {
            // Path is like /org/name or /org/name/tree/main
            let parts = url.path.split(separator: "/").map(String.init)
            if parts.count >= 2 { return "\(parts[0])/\(parts[1])" }
            return nil
        }
        // Bare "org/name"
        let parts = trimmed.split(separator: "/")
        if parts.count == 2 { return trimmed }
        return nil
    }

    static func fetchRepoInfo(_ repoId: String) async throws -> HFRepoInfo {
        let url = URL(string: "https://huggingface.co/api/models/\(repoId)?blobs=true")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw HFError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw HFError.network("no response") }
        if http.statusCode == 404 { throw HFError.notFound }
        guard http.statusCode == 200 else { throw HFError.network("HTTP \(http.statusCode)") }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HFError.network("bad json")
        }

        var total: Int64 = 0
        var hasConfig = false
        var hasSafetensors = false
        if let siblings = obj["siblings"] as? [[String: Any]] {
            for s in siblings {
                if let name = s["rfilename"] as? String {
                    if name == "config.json" { hasConfig = true }
                    if name.hasSuffix(".safetensors") { hasSafetensors = true }
                }
                if let size = s["size"] as? Int64 { total += size }
                else if let size = s["size"] as? Int { total += Int64(size) }
            }
        }
        return HFRepoInfo(
            repoId: repoId,
            totalBytes: total > 0 ? total : nil,
            hasMLXLayout: hasConfig && hasSafetensors
        )
    }
}
