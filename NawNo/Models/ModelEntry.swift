import Foundation

struct ModelEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var vendor: String
    var name: String
    var relativePath: String
    var dateAdded: Date

    init(id: UUID = UUID(), vendor: String, name: String, relativePath: String, dateAdded: Date = Date()) {
        self.id = id
        self.vendor = vendor
        self.name = name
        self.relativePath = relativePath
        self.dateAdded = dateAdded
    }

    var directoryURL: URL {
        ModelStore.modelsRoot.appendingPathComponent(relativePath)
    }

    var isValid: Bool {
        FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("nawno_config.json").path)
    }

    var diskSizeBytes: Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directoryURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    var formattedDiskSize: String {
        RAMEstimator.formatBytes(diskSizeBytes)
    }

    /// Model name without the timestamp suffix (e.g. "Bonsai" from "Bonsai_05.04.2026.02.20.34")
    var displayName: String {
        // Match pattern: _DD.MM.YYYY.HH.mm.ss at the end
        if let range = name.range(of: #"_\d{2}\.\d{2}\.\d{4}\.\d{2}\.\d{2}\.\d{2}$"#, options: .regularExpression) {
            return String(name[name.startIndex..<range.lowerBound])
        }
        return name
    }

    /// The date portion from the folder name (e.g. "05.04.2026" from "Bonsai_05.04.2026.02.20.34")
    var folderDateString: String? {
        if let range = name.range(of: #"(\d{2}\.\d{2}\.\d{4})\.\d{2}\.\d{2}\.\d{2}$"#, options: .regularExpression) {
            let full = String(name[range])
            // Return just DD.MM.YYYY
            let parts = full.split(separator: ".")
            if parts.count >= 3 {
                return "\(parts[0]).\(parts[1]).\(parts[2])"
            }
        }
        return nil
    }
}
