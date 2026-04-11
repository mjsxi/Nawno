//
//  SuggestedModelsCatalog.swift
//  Lunar
//
//  Single source of truth for suggested models. To add a new model, append
//  an entry below under the appropriate RAM tier. Tiers are author-declared
//  (a model is shown in the tier you put it in, not auto-bucketed by size).
//
//  Paste the full Hugging Face URL into `url:` — the repo id is derived
//  automatically (e.g. https://huggingface.co/mlx-community/Qwen3-4B-4bit
//  → "mlx-community/Qwen3-4B-4bit").
//
//  At runtime the install picker:
//    - hides any tier > the device's physical RAM
//    - hides any individual model whose `sizeGB` exceeds 75% of physical RAM
//

import Foundation

struct SuggestedModel: Identifiable, Hashable {
    let repoId: String          // derived from `url`
    let displayName: String
    let sizeGB: Double          // approximate weights size on disk
    let tierGB: Int             // 8 | 12 | 16 | 24 | 32 | 48 | 64 | 128
    let isReasoning: Bool

    init(url: String, displayName: String, sizeGB: Double, tierGB: Int, isReasoning: Bool) {
        self.repoId = Self.repoId(fromURL: url)
        self.displayName = displayName
        self.sizeGB = sizeGB
        self.tierGB = tierGB
        self.isReasoning = isReasoning
    }

    /// Shorthand: url, displayName, sizeGB, tierGB, isReasoning
    init(_ url: String, _ displayName: String, _ sizeGB: Double, _ tierGB: Int, _ isReasoning: Bool) {
        self.init(url: url, displayName: displayName, sizeGB: sizeGB, tierGB: tierGB, isReasoning: isReasoning)
    }

    var id: String { repoId }
    var huggingFaceURL: URL { URL(string: "https://huggingface.co/\(repoId)")! }

    /// Strips the host/scheme from a Hugging Face URL and returns "org/name".
    /// Also accepts a bare "org/name" so existing entries keep working.
    private static func repoId(fromURL raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let host = url.host, host.contains("huggingface.co") {
            // path is "/org/name" — drop the leading slash
            return String(url.path.dropFirst())
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return trimmed
    }
}

enum SuggestedModelsCatalog {
    static let tiers: [Int] = [128, 64, 48, 32, 24, 16, 12, 8]

    // Shorthand: (url, displayName, sizeGB, tierGB, isReasoning)
    static let all: [SuggestedModel] = [
        // ——— 8 GB tier ———
        //gemma
        SuggestedModel("https://huggingface.co/mlx-community/gemma-3-1b-it-4bit-DWQ",  "Gemma 3 1B IT 4bit DWQ",  0.73, 8,  false),
        SuggestedModel("https://huggingface.co/mlx-community/gemma-3-4b-it-4bit-DWQ",  "Gemma 3 4B IT 4bit DWQ",  2.56, 8,  false),
        //qwen
        SuggestedModel("https://huggingface.co/mlx-community/Qwen3.5-0.8B-MLX-4bit", "Qwen3.5 0.8B 4bit", 0.63, 8, true),
        SuggestedModel("https://huggingface.co/mlx-community/Qwen3.5-2B-MLX-4bit", "Qwen3.5 2B 4bit", 1.72, 8, true),
        SuggestedModel("https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit", "Qwen3.5 4B 4bit", 3.03, 8, true),

        // ——— 12 GB tier ———
        //gemma
        SuggestedModel("https://huggingface.co/mlx-community/gemma-3-12b-it-4bit-DWQ", "Gemma 3 12B IT 4bit DWQ", 7.19, 12, false),
        //qwen
        SuggestedModel("https://huggingface.co/mlx-community/Qwen3.5-9B-MLX-4bit", "Qwen3.5 9B 4bit", 5.95, 12, true),

        // ——— 16 GB tier ———

        // ——— 24 GB tier ———
        //gemma
        SuggestedModel("https://huggingface.co/mlx-community/gemma-3-27b-it-4bit-DWQ", "Gemma 3 27B IT 4bit DWQ", 16, 24, false),
        //qwen
        SuggestedModel("https://huggingface.co/mlx-community/Qwen3.5-27B-MLX-4bit", "Qwen3.5 27B 4bit", 16.1, 24, true),

        // ——— 32 GB tier ———
        //qwen
        SuggestedModel("https://huggingface.co/mlx-community/Qwen3.5-35B-A3B-4bit", "Qwen3.5 35B A3B 4bit", 20.4, 32, true),

        // ——— 48 GB tier ———

        // ——— 64 GB tier ———

        // ——— 128 GB tier ———
    ]

    static func first(matching repoId: String) -> SuggestedModel? {
        all.first { $0.repoId == repoId }
    }
}
