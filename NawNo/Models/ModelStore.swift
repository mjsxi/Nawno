import Foundation
import SwiftUI

@MainActor @Observable
final class ModelStore {
    var models: [ModelEntry] = []
    var selectedModelID: UUID?

    nonisolated static let appSupportRoot: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NawNo")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    nonisolated static let modelsRoot: URL = {
        let url = appSupportRoot.appendingPathComponent("Models")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static var registryURL: URL {
        appSupportRoot.appendingPathComponent("model_registry.json")
    }

    init() {
        loadRegistry()
        cleanStaleEntries()
        scanForUnregisteredModels()
    }

    var selectedModel: ModelEntry? {
        models.first { $0.id == selectedModelID }
    }

    var modelsByVendor: [(vendor: String, models: [ModelEntry])] {
        let grouped = Dictionary(grouping: models) { $0.vendor }
        return grouped.keys.sorted().map { vendor in
            (vendor: vendor, models: grouped[vendor]!.sorted { $0.name < $1.name })
        }
    }

    // MARK: - Import

    func importModel(from sourceURL: URL, vendor: String, modelName: String) throws {
        let sanitizedVendor = Self.sanitize(vendor)
        let sanitizedName = Self.sanitize(modelName)
        let timestamp = Self.timestamp()
        let folderName = "\(sanitizedName)_\(timestamp)"
        let relativePath = "\(sanitizedVendor)/\(folderName)"
        let destURL = Self.modelsRoot.appendingPathComponent(relativePath)

        // Create the destination directory first
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)

        _ = sourceURL.startAccessingSecurityScopedResource()
        defer { sourceURL.stopAccessingSecurityScopedResource() }

        // Check if source is a file or folder
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir)

        if isDir.boolValue {
            // Source is a folder — move its contents into our directory
            let contents = try FileManager.default.contentsOfDirectory(
                at: sourceURL, includingPropertiesForKeys: nil)
            for item in contents {
                let dest = destURL.appendingPathComponent(item.lastPathComponent)
                try FileManager.default.moveItem(at: item, to: dest)
            }
            // Remove the now-empty source folder
            try? FileManager.default.removeItem(at: sourceURL)
        } else {
            // Source is a single file — move it into the directory
            let destFile = destURL.appendingPathComponent(sourceURL.lastPathComponent)
            try FileManager.default.moveItem(at: sourceURL, to: destFile)
        }

        let entry = ModelEntry(vendor: sanitizedVendor, name: folderName, relativePath: relativePath)

        // Generate nawno_config.json (our metadata, separate from MLX's config.json)
        let nawnoConfig: [String: String] = [
            "vendor": sanitizedVendor,
            "model_name": sanitizedName,
            "id": entry.id.uuidString,
            "date_added": ISO8601DateFormatter().string(from: entry.dateAdded)
        ]
        let configEncoder = JSONEncoder()
        configEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let configData = try configEncoder.encode(nawnoConfig)
        try configData.write(to: destURL.appendingPathComponent("nawno_config.json"), options: .atomic)

        // Generate per-model nawno_settings.json with defaults
        let defaultSettings = ModelSettings.defaults
        let settingsEncoder = JSONEncoder()
        settingsEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let settingsData = try settingsEncoder.encode(defaultSettings)
        try settingsData.write(to: destURL.appendingPathComponent("nawno_settings.json"), options: .atomic)

        models.append(entry)
        saveRegistry()
    }

    /// Try to parse vendor and model name from a HuggingFace-style folder name.
    /// e.g. "mlx-community--Llama-3.2-1B-Instruct-4bit" → ("mlx-community", "Llama-3.2-1B-Instruct-4bit")
    static func parseModelFolder(_ folderName: String) -> (vendor: String, modelName: String) {
        // HuggingFace snapshot folders use "--" as separator: "org--model-name"
        if folderName.contains("--") {
            let dashParts = folderName.components(separatedBy: "--")
            if dashParts.count == 2 {
                return (vendor: dashParts[0], modelName: dashParts[1])
            }
        }
        // Otherwise return empty vendor and full name
        return (vendor: "", modelName: folderName)
    }

    // MARK: - Remove

    func removeModel(_ model: ModelEntry) {
        let dirURL = model.directoryURL
        try? FileManager.default.removeItem(at: dirURL)

        // Clean empty vendor directory
        let vendorURL = dirURL.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: vendorURL.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: vendorURL)
        }

        models.removeAll { $0.id == model.id }

        if selectedModelID == model.id {
            selectedModelID = nil
        }
        saveRegistry()
    }

    // MARK: - Persistence

    private func loadRegistry() {
        guard let data = try? Data(contentsOf: Self.registryURL),
              let entries = try? JSONDecoder().decode([ModelEntry].self, from: data) else {
            return
        }
        models = entries
    }

    private func saveRegistry() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(models) {
            try? data.write(to: Self.registryURL, options: .atomic)
        }
    }

    /// Scan the Models directory for folders not in the registry and add them.
    private func scanForUnregisteredModels() {
        let fm = FileManager.default
        let registeredPaths = Set(models.map { $0.relativePath })

        guard let vendors = try? fm.contentsOfDirectory(atPath: Self.modelsRoot.path) else { return }

        var added = false
        for vendor in vendors where !vendor.hasPrefix(".") {
            let vendorURL = Self.modelsRoot.appendingPathComponent(vendor)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: vendorURL.path, isDirectory: &isDir), isDir.boolValue else { continue }

            guard let modelFolders = try? fm.contentsOfDirectory(atPath: vendorURL.path) else { continue }
            for folder in modelFolders where !folder.hasPrefix(".") {
                let relativePath = "\(vendor)/\(folder)"
                if registeredPaths.contains(relativePath) { continue }

                let modelDir = Self.modelsRoot.appendingPathComponent(relativePath)
                guard fm.fileExists(atPath: modelDir.path, isDirectory: &isDir), isDir.boolValue else { continue }

                // Check it looks like a model (has config.json or safetensors files)
                let contents = (try? fm.contentsOfDirectory(atPath: modelDir.path)) ?? []
                let hasModelFiles = contents.contains(where: {
                    $0 == "config.json" || $0.hasSuffix(".safetensors")
                })
                guard hasModelFiles else { continue }

                let entry = ModelEntry(vendor: vendor, name: folder, relativePath: relativePath)
                models.append(entry)
                added = true
            }
        }

        if added {
            saveRegistry()
        }
    }

    private func cleanStaleEntries() {
        let before = models.count
        models.removeAll { !$0.isValid }
        if models.count != before {
            saveRegistry()
        }
    }

    private static func timestamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "dd.MM.yyyy.HH.mm.ss"
        return df.string(from: Date())
    }

    private static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }

    enum ImportError: LocalizedError {
        case alreadyExists

        var errorDescription: String? {
            switch self {
            case .alreadyExists:
                return "A model with this vendor and name already exists."
            }
        }
    }
}
