import Foundation

enum RAMEstimator {
    /// Rough estimate: model weights + ~2 bytes per token for KV cache
    static func estimateRAM(modelDiskBytes: Int64, contextSize: Int) -> Int64 {
        let modelRAM = Int64(Double(modelDiskBytes) * 1.2) // ~20% overhead for runtime structures
        let kvCacheRAM = Int64(contextSize) * 2 * 1024     // rough KV cache estimate
        return modelRAM + kvCacheRAM
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
