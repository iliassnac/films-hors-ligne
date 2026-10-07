import Foundation
import os

enum LibraryError: LocalizedError {
    case unsupportedFormat(String)      // extension not in supportedExtensions
    case insufficientSpace
    case fileMissing
    case accessDenied                   // security-scoped access refused
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            if ext.isEmpty {
                return "Format non pris en charge (MP4, M4V ou MOV uniquement)."
            }
            return "Le format .\(ext) n’est pas pris en charge (MP4, M4V ou MOV uniquement)."
        case .insufficientSpace:
            return "Espace de stockage insuffisant. Libérez de la place sur l’appareil, puis réessayez."
        case .fileMissing:
            return "Le fichier est introuvable."
        case .accessDenied:
            return "L’accès au fichier a été refusé."
        case .ioFailure(let detail):
            return "Erreur de stockage : \(detail)"
        }
    }
}

/// Owns the offline movie files and their JSON index (`<root>/library.json`).
/// Every stored file lives in `<root>/Movies` under the name `<uuid>.<ext>`.
@MainActor
final class MovieLibrary: ObservableObject {
    nonisolated static let supportedExtensions: Set<String> = ["mp4", "m4v", "mov"]

    private static let defaultTitle = "Film sans titre"
    private static let maxTitleLength = 120
    /// Free space that must remain on the volume after an import (200 MB).
    private static let safetyMargin: Int64 = 200_000_000
    private static let indexFileName = "library.json"
    private static let moviesFolderName = "Movies"

    @Published private(set) var movies: [Movie] = []

    private let root: URL
    /// Set when the storage folder could not be prepared; all mutations then fail.
    private var setupError: LibraryError? = nil
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "local.offlinemovies.app", category: "library")

    var moviesDirectory: URL {
        root.appendingPathComponent(Self.moviesFolderName, isDirectory: true)
    }

    private var indexURL: URL {
        root.appendingPathComponent(Self.indexFileName, isDirectory: false)
    }

    /// root == nil → <Application Support>/OfflineMovies. Creates dirs, loads index.
    init(root: URL? = nil) {
        var failure: LibraryError? = nil
        let base: URL
        if let root {
            base = root
        } else if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = support.appendingPathComponent("OfflineMovies", isDirectory: true)
        } else {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineMovies", isDirectory: true)
            failure = .ioFailure("dossier de l’application introuvable")
        }
        self.root = base.standardizedFileURL
        self.setupError = failure
        if setupError == nil {
            prepareStorage()
        }
        if setupError == nil {
            loadLibrary()
        }
    }

    // MARK: - Public API

    /// Resolved location of a movie's file. Never points outside `moviesDirectory`.
    func fileURL(for movie: Movie) -> URL {
        if let url = try? contained(fileName: movie.fileName, id: movie.id) {
            return url
        }
        // Non-existent placeholder inside the library: playback fails safely.
        return moviesDirectory.appendingPathComponent(".invalid", isDirectory: false)
    }

    /// Moves (not copies) a finished temp file into the library. Returns the new Movie.
    /// The caller owns `tempURL`; it is consumed on success.
    func addMovie(movingFileAt tempURL: URL, title: String, fileExtension: String) throws -> Movie {
        try ensureReady()
        let ext = try Self.validatedExtension(fileExtension)
        guard tempURL.isFileURL, fileManager.fileExists(atPath: tempURL.path) else {
            throw LibraryError.fileMissing
        }

        let id = UUID()
        let fileName = Self.storedFileName(for: id, fileExtension: ext)
        let destination = try contained(fileName: fileName, id: id)

        do {
            try fileManager.moveItem(at: tempURL, to: destination)
        } catch {
            throw LibraryError.ioFailure(error.localizedDescription)
        }

        do {
            try Self.applyFileProtection(to: destination)
        } catch {
            removeFileIfPresent(destination)
            throw LibraryError.ioFailure(error.localizedDescription)
        }

        let movie = Movie(
            id: id,
            title: Self.sanitizedTitle(title),
            fileName: fileName,
            addedAt: Date(),
            fileSize: Self.fileSize(at: destination) ?? 0,
            lastPosition: 0,
            duration: nil
        )
        do {
            try replaceMovies(with: movies + [movie])
        } catch {
            removeFileIfPresent(destination)
            throw error
        }
        return movie
    }

    /// Copies a file picked in the Files app (handles security-scoped access).
    func importMovie(from externalURL: URL) throws -> Movie {
        try ensureReady()
        let ext = try Self.validatedExtension(externalURL.pathExtension)
        guard externalURL.isFileURL else {
            throw LibraryError.fileMissing
        }

        let didStart = externalURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                externalURL.stopAccessingSecurityScopedResource()
            }
        }
        // If access was not granted we still try: files inside the sandbox need no scope.

        guard fileManager.fileExists(atPath: externalURL.path) else {
            throw LibraryError.fileMissing
        }

        let values: URLResourceValues
        do {
            values = try externalURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw LibraryError.accessDenied
        }
        guard values.isRegularFile == true else {
            throw LibraryError.ioFailure("le fichier sélectionné n’est pas valide")
        }
        let sourceSize = Int64(values.fileSize ?? 0)

        // If the free space is unknown we proceed; a full disk then fails the copy itself.
        if let free = availableDiskSpace(), free < sourceSize + Self.safetyMargin {
            throw LibraryError.insufficientSpace
        }

        let id = UUID()
        let fileName = Self.storedFileName(for: id, fileExtension: ext)
        let destination = try contained(fileName: fileName, id: id)

        do {
            try fileManager.copyItem(at: externalURL, to: destination)
        } catch {
            removeFileIfPresent(destination)
            throw Self.mapCopyError(error)
        }

        do {
            try Self.applyFileProtection(to: destination)
        } catch {
            removeFileIfPresent(destination)
            throw LibraryError.ioFailure(error.localizedDescription)
        }

        let movie = Movie(
            id: id,
            title: Self.sanitizedTitle(externalURL.deletingPathExtension().lastPathComponent),
            fileName: fileName,
            addedAt: Date(),
            fileSize: Self.fileSize(at: destination) ?? sourceSize,
            lastPosition: 0,
            duration: nil
        )
        do {
            try replaceMovies(with: movies + [movie])
        } catch {
            removeFileIfPresent(destination)
            throw error
        }
        return movie
    }

    func rename(_ id: UUID, to title: String) {
        guard let index = movies.firstIndex(where: { $0.id == id }) else { return }
        let newTitle = Self.sanitizedTitle(title)
        guard movies[index].title != newTitle else { return }
        movies[index].title = newTitle
        persistBestEffort()
    }

    /// Removes the file, then the entry. A missing file is not an error.
    func delete(_ id: UUID) throws {
        try ensureReady()
        guard let movie = movies.first(where: { $0.id == id }) else { return }
        let url = try contained(fileName: movie.fileName, id: movie.id)
        if fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw LibraryError.ioFailure(error.localizedDescription)
            }
        }
        movies.removeAll { $0.id == id }
        try persist()
    }

    func updatePlayback(_ id: UUID, position: Double, duration: Double?) {
        guard position.isFinite, let index = movies.firstIndex(where: { $0.id == id }) else { return }
        var movie = movies[index]
        if let duration, duration.isFinite, duration > 0 {
            movie.duration = duration
        }
        var clamped = max(position, 0)
        if let known = movie.duration {
            clamped = min(clamped, known)
        }
        movie.lastPosition = clamped
        guard movie != movies[index] else { return }
        movies[index] = movie
        persistBestEffort()
    }

    /// Free bytes on the volume (volumeAvailableCapacityForImportantUsageKey), nil if unknown.
    func availableDiskSpace() -> Int64? {
        guard let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
            return nil
        }
        return values.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Setup and loading

    private func ensureReady() throws {
        if let setupError {
            throw setupError
        }
    }

    private func prepareStorage() {
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: moviesDirectory, withIntermediateDirectories: true)
            try Self.excludeFromBackup(root)
            try Self.excludeFromBackup(moviesDirectory)
        } catch {
            setupError = .ioFailure(error.localizedDescription)
        }
    }

    /// Loads the index, drops entries whose file is gone, and adopts orphan files.
    /// A corrupt index starts empty; movie files are never deleted here.
    private func loadLibrary() {
        var entries: [Movie] = []
        var needsPersist = false

        if fileManager.fileExists(atPath: indexURL.path) {
            do {
                let data = try Data(contentsOf: indexURL)
                entries = try JSONDecoder().decode([Movie].self, from: data)
            } catch {
                logger.error("Library index unreadable; rebuilding from stored files")
                needsPersist = true
            }
        }

        var kept: [Movie] = []
        var knownIDs = Set<UUID>()
        for entry in entries {
            guard !knownIDs.contains(entry.id),
                  let url = try? contained(fileName: entry.fileName, id: entry.id),
                  fileManager.fileExists(atPath: url.path)
            else {
                continue
            }
            knownIDs.insert(entry.id)
            kept.append(entry)
        }
        if kept.count != entries.count {
            needsPersist = true
        }

        let orphans = scanOrphans(excluding: knownIDs)
        if !orphans.isEmpty {
            needsPersist = true
        }

        movies = Self.sortedNewestFirst(kept + orphans)
        if needsPersist {
            persistBestEffort()
        }
    }

    /// Movie files named "<uuid>.<supported ext>" that have no index entry.
    private func scanOrphans(excluding knownIDs: Set<UUID>) -> [Movie] {
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: moviesDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            logger.error("Movies folder could not be listed")
            return []
        }

        var orphans: [Movie] = []
        for url in urls {
            let fileName = url.lastPathComponent
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !knownIDs.contains(id),
                  Self.isCanonicalFileName(fileName, id: id),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey]),
                  values.isRegularFile == true
            else {
                continue
            }
            orphans.append(Movie(
                id: id,
                title: Self.defaultTitle,
                fileName: fileName,
                addedAt: values.creationDate ?? Date(),
                fileSize: Int64(values.fileSize ?? 0),
                lastPosition: 0,
                duration: nil
            ))
        }
        return orphans
    }

    // MARK: - Persistence

    /// Writes the index atomically. Throws on failure.
    private func persist() throws {
        do {
            let data = try JSONEncoder().encode(movies)
            try data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw LibraryError.ioFailure(error.localizedDescription)
        }
    }

    /// For non-throwing mutations: the in-memory change is kept and a generic event is logged.
    private func persistBestEffort() {
        do {
            try persist()
        } catch {
            logger.error("Library index could not be saved")
        }
    }

    /// Replaces the list and persists it; restores the previous list if the write fails.
    private func replaceMovies(with updated: [Movie]) throws {
        let previous = movies
        movies = Self.sortedNewestFirst(updated)
        do {
            try persist()
        } catch {
            movies = previous
            throw error
        }
    }

    private func removeFileIfPresent(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            logger.error("Library file could not be removed during cleanup")
        }
    }

    // MARK: - Path safety

    /// Builds the URL of a stored file and verifies it stays inside `moviesDirectory`.
    private func contained(fileName: String, id: UUID) throws -> URL {
        guard Self.isCanonicalFileName(fileName, id: id) else {
            throw LibraryError.ioFailure("nom de fichier invalide")
        }
        let directory = moviesDirectory.standardizedFileURL
        let candidate = directory.appendingPathComponent(fileName, isDirectory: false).standardizedFileURL
        guard candidate.path.hasPrefix(directory.path + "/") else {
            throw LibraryError.ioFailure("chemin hors de la bibliothèque")
        }
        return candidate
    }

    private static func storedFileName(for id: UUID, fileExtension: String) -> String {
        "\(id.uuidString).\(fileExtension)"
    }

    /// True only for "<id>.<ext>" with a lowercase supported extension.
    private static func isCanonicalFileName(_ name: String, id: UUID) -> Bool {
        supportedExtensions.contains { name == storedFileName(for: id, fileExtension: $0) }
    }

    private static func validatedExtension(_ raw: String) throws -> String {
        let ext = raw.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw LibraryError.unsupportedFormat(String(raw.prefix(16)))
        }
        return ext
    }

    // MARK: - Helpers

    private static func sanitizedTitle(_ raw: String) -> String {
        let singleLine = String(raw.map { $0.isNewline ? Character(" ") : $0 })
        let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultTitle }
        let truncated = String(trimmed.prefix(maxTitleLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return truncated.isEmpty ? defaultTitle : truncated
    }

    private static func sortedNewestFirst(_ movies: [Movie]) -> [Movie] {
        movies.sorted { $0.addedAt > $1.addedAt }
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return Int64(size)
    }

    private static func applyFileProtection(to url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }

    private static func mapCopyError(_ error: Error) -> LibraryError {
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileReadNoPermission, .fileWriteNoPermission:
                return .accessDenied
            case .fileWriteOutOfSpace:
                return .insufficientSpace
            default:
                break
            }
        }
        return .ioFailure(error.localizedDescription)
    }
}
