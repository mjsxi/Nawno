//
//  KnowledgeBaseIndex.swift
//  Lunar
//
//  Orchestrates document loading, chunking, embedding, and search
//  for the personal knowledge base feature.
//

import Foundation
import SwiftUI

@MainActor
class KnowledgeBaseIndex: ObservableObject {
    @Published var isIndexing = false
    @Published var indexProgress: Double = 0
    @Published var stats = KnowledgeBaseStats()
    @Published var folderURL: URL?
    @Published var errorMessage: String?

    private let store = VectorStore()
    private let worker = KnowledgeBaseIndexWorker()

    private let indexDirName = ".lunar_index"

    var hasIndex: Bool { !store.isEmpty }
    var hasFolderConfigured: Bool { folderURL != nil }

    private var indexDirURL: URL? {
        folderURL?.appendingPathComponent(indexDirName)
    }

    // MARK: - Lifecycle

    func loadPersistedIndex() {
        guard let indexDir = indexDirURL else { return }
        do {
            try store.load(from: indexDir)
            stats = store.computeStats(indexDir: indexDir)
        } catch {
            // No persisted index yet — that's fine
        }
    }

    // MARK: - Indexing

    func indexFolder() async {
        guard let folderURL else { return }
        isIndexing = true
        indexProgress = 0
        errorMessage = nil

        do {
            let result = try await worker.indexFolder(at: folderURL) { [weak self] progress in
                await MainActor.run {
                    self?.indexProgress = progress
                }
            }
            store.replace(chunks: result.chunks, manifest: result.manifest)

            // Persist
            if let indexDir = indexDirURL {
                try store.save(to: indexDir)
                stats = store.computeStats(indexDir: indexDir)
            }

            indexProgress = 1.0
        } catch {
            errorMessage = error.localizedDescription
        }

        isIndexing = false
    }

    // MARK: - Refresh

    func refresh() async {
        guard let folderURL else { return }
        isIndexing = true
        indexProgress = 0
        errorMessage = nil

        do {
            let result = try await worker.refreshIndex(
                at: folderURL,
                existingChunks: store.chunks,
                existingManifest: store.manifest
            ) { [weak self] progress in
                await MainActor.run {
                    self?.indexProgress = progress
                }
            }
            store.replace(chunks: result.chunks, manifest: result.manifest)

            if let indexDir = indexDirURL {
                try store.save(to: indexDir)
                stats = store.computeStats(indexDir: indexDir)
            }

            if result.wasAlreadyUpToDate {
                errorMessage = "Already up to date."
            }

            indexProgress = 1.0
        } catch {
            errorMessage = error.localizedDescription
        }

        isIndexing = false
    }

    // MARK: - Purge

    func purge() {
        store.clear()
        stats = KnowledgeBaseStats()
        errorMessage = nil

        if let indexDir = indexDirURL {
            try? FileManager.default.removeItem(at: indexDir)
        }
    }

    // MARK: - Query

    func query(_ text: String, topK: Int = 5) -> [DocumentChunk] {
        let embeddings = AppleNLEmbedding().embed([text])
        guard let queryVector = embeddings.first, !queryVector.isEmpty else { return [] }
        return store.search(query: queryVector, topK: topK)
    }

    // MARK: - Folder Management

    func setFolder(_ url: URL) {
        folderURL = url
        // Save bookmark
        if let bookmark = try? url.bookmarkData(options: bookmarkOptions) {
            UserDefaults.standard.set(bookmark, forKey: "ragFolderBookmark")
        }
        loadPersistedIndex()
    }

    func resolveBookmark() {
        guard let data = UserDefaults.standard.data(forKey: "ragFolderBookmark") else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: bookmarkResolutionOptions, bookmarkDataIsStale: &stale) {
            #if os(iOS)
            _ = url.startAccessingSecurityScopedResource()
            #endif
            folderURL = url
            if stale {
                // Re-save bookmark
                if let newBookmark = try? url.bookmarkData(options: bookmarkOptions) {
                    UserDefaults.standard.set(newBookmark, forKey: "ragFolderBookmark")
                }
            }
            loadPersistedIndex()
        }
    }

    func removeFolder() {
        purge()
        folderURL = nil
        UserDefaults.standard.removeObject(forKey: "ragFolderBookmark")
    }

    private var bookmarkOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        return []
        #else
        return .minimalBookmark
        #endif
    }

    private var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        return []
        #else
        return []
        #endif
    }
}

private struct KnowledgeBaseIndexResult: Sendable {
    let chunks: [DocumentChunk]
    let manifest: IndexManifest
    let wasAlreadyUpToDate: Bool
}

private actor KnowledgeBaseIndexWorker {
    private let chunker = TextChunker()
    private let embeddingService = AppleNLEmbedding()
    private let batchSize = 64

    func indexFolder(
        at folderURL: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> KnowledgeBaseIndexResult {
        let files = try DocumentLoaderRegistry.supportedFiles(in: folderURL)
        guard !files.isEmpty else {
            throw KnowledgeBaseIndexWorkerError.noSupportedFiles
        }

        let parsed = try await parseFiles(files, progress: progress)
        let chunks = await embedChunks(parsed.chunks, progress: progress)
        return KnowledgeBaseIndexResult(
            chunks: chunks,
            manifest: IndexManifest(files: parsed.manifestEntries),
            wasAlreadyUpToDate: false
        )
    }

    func refreshIndex(
        at folderURL: URL,
        existingChunks: [DocumentChunk],
        existingManifest: IndexManifest,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> KnowledgeBaseIndexResult {
        let files = try DocumentLoaderRegistry.supportedFiles(in: folderURL)
        let currentFileNames = Set(files.map(\.lastPathComponent))
        let indexedFileNames = Set(existingManifest.files.map(\.relativePath))
        let manifestLookup = Dictionary(uniqueKeysWithValues: existingManifest.files.map { ($0.relativePath, $0) })

        var filesToIndex: [URL] = []
        for fileURL in files {
            let name = fileURL.lastPathComponent
            if let existing = manifestLookup[name] {
                let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let modDate = attrs[.modificationDate] as? Date ?? Date()
                if modDate > existing.modificationDate {
                    filesToIndex.append(fileURL)
                }
            } else {
                filesToIndex.append(fileURL)
            }
        }

        let deletedFiles = indexedFileNames.subtracting(currentFileNames)
        let unchangedFileNames = currentFileNames.subtracting(Set(filesToIndex.map(\.lastPathComponent)))
        var retainedManifestEntries = existingManifest.files.filter { unchangedFileNames.contains($0.relativePath) }
        var refreshedChunks = existingChunks.filter {
            unchangedFileNames.contains($0.fileName) && !deletedFiles.contains($0.fileName)
        }

        if filesToIndex.isEmpty && deletedFiles.isEmpty {
            return KnowledgeBaseIndexResult(
                chunks: refreshedChunks,
                manifest: IndexManifest(files: retainedManifestEntries),
                wasAlreadyUpToDate: true
            )
        }

        if !filesToIndex.isEmpty {
            let parsed = try await parseFiles(filesToIndex, progress: progress)
            refreshedChunks.append(contentsOf: await embedChunks(parsed.chunks, progress: progress))
            retainedManifestEntries.append(contentsOf: parsed.manifestEntries)
        } else {
            await progress(1.0)
        }

        return KnowledgeBaseIndexResult(
            chunks: refreshedChunks,
            manifest: IndexManifest(files: retainedManifestEntries),
            wasAlreadyUpToDate: false
        )
    }

    private func parseFiles(
        _ files: [URL],
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> (chunks: [DocumentChunk], manifestEntries: [IndexManifest.FileEntry]) {
        var manifestEntries: [IndexManifest.FileEntry] = []
        var allChunks: [DocumentChunk] = []

        for (index, fileURL) in files.enumerated() {
            guard let loader = DocumentLoaderRegistry.loader(for: fileURL) else { continue }
            do {
                let text = try loader.loadText(from: fileURL)
                let relativePath = fileURL.lastPathComponent
                let chunks = chunker.chunk(text: text, fileName: relativePath)
                allChunks.append(contentsOf: chunks)

                let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let modDate = attrs[.modificationDate] as? Date ?? Date()
                let fileSize = attrs[.size] as? Int64 ?? 0
                manifestEntries.append(IndexManifest.FileEntry(
                    relativePath: relativePath,
                    modificationDate: modDate,
                    fileSize: fileSize
                ))
            } catch {
                AppLogger.knowledgeBase.warning("skipped file \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

            await progress(Double(index + 1) / Double(files.count) * 0.5)
        }

        return (allChunks, manifestEntries)
    }

    private func embedChunks(
        _ chunks: [DocumentChunk],
        progress: @escaping @Sendable (Double) async -> Void
    ) async -> [DocumentChunk] {
        guard !chunks.isEmpty else {
            await progress(1.0)
            return []
        }

        var embeddedChunks = chunks
        for batchStart in stride(from: 0, to: embeddedChunks.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, embeddedChunks.count)
            let texts = embeddedChunks[batchStart..<batchEnd].map(\.text)
            let embeddings = embeddingService.embed(texts)
            for (offset, embedding) in embeddings.enumerated() {
                embeddedChunks[batchStart + offset].embedding = embedding
            }

            await progress(0.5 + Double(batchEnd) / Double(embeddedChunks.count) * 0.5)
        }

        return embeddedChunks.filter { !$0.embedding.isEmpty }
    }
}

private enum KnowledgeBaseIndexWorkerError: LocalizedError {
    case noSupportedFiles

    var errorDescription: String? {
        switch self {
        case .noSupportedFiles:
            return "No supported files found in folder."
        }
    }
}
