import Foundation
import UIKit

/// User-facing download errors (French messages).
enum DownloadError: LocalizedError {
    case invalidURL           // unparsable / no host
    case insecureScheme       // anything but https
    case alreadyDownloading

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Le lien n'est pas valide."
        case .insecureScheme:
            return "Le lien doit commencer par https://."
        case .alreadyDownloading:
            return "Ce fichier est déjà en cours de téléchargement."
        }
    }
}

struct ActiveDownload: Identifiable, Equatable {
    enum State: Equatable { case downloading, failed(String) }

    let id: UUID
    var title: String
    var bytesWritten: Int64
    var totalBytes: Int64        // <= 0 when unknown
    var state: State

    /// 0...1, 0 when the total size is unknown.
    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(bytesWritten) / Double(totalBytes), 0), 1)
    }
}

/// Downloads video files over HTTPS in the foreground (with a short background grace period).
///
/// Threading: the class lives on the main actor. URLSession delegate callbacks arrive on the
/// session's private serial queue; they are `nonisolated`, do only synchronous work on the
/// temp file and value copies, then hop back with `Task { @MainActor in ... }`.
@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {

    @Published private(set) var downloads: [ActiveDownload] = []

    private struct ProgressMark {
        let bytes: Int64
        let time: TimeInterval
    }

    private let library: MovieLibrary

    /// Created on first use (main actor), after `super.init()`. The session retains `self`
    /// as delegate; the manager lives for the whole app lifetime, so the cycle is harmless.
    private lazy var session: URLSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    /// Download id -> task, for cancellation and to know which downloads are in flight.
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    /// Download id -> source URL, so the URL can be removed from `activeSourceURLs` on completion.
    private var sourceURLs: [UUID: URL] = [:]
    /// Source URLs of downloads in flight, for duplicate detection.
    private var activeSourceURLs: Set<URL> = []
    private var backgroundTaskIDs: [UUID: UIBackgroundTaskIdentifier] = [:]
    /// Last published progress per download, for throttling.
    private var progressMarks: [UUID: ProgressMark] = [:]

    init(library: MovieLibrary) {
        self.library = library
        super.init()
    }

    // MARK: - Public API

    /// Validates the input and starts the download. Throws `DownloadError`.
    func start(urlString: String, title: String) throws {
        let url = try DownloadManager.validate(urlString: urlString)
        guard !activeSourceURLs.contains(url) else {
            throw DownloadError.alreadyDownloading
        }

        let id = UUID()
        let task = session.downloadTask(with: url)
        task.taskDescription = id.uuidString
        tasks[id] = task
        sourceURLs[id] = url
        activeSourceURLs.insert(url)
        downloads.append(ActiveDownload(
            id: id,
            title: DownloadManager.resolveTitle(title, url: url),
            bytesWritten: 0,
            totalBytes: 0,
            state: .downloading
        ))
        startBackgroundTask(for: id)
        updateIdleTimer()
        task.resume()
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        downloads.removeAll { $0.id == id }
        release(id)
    }

    /// Removes a failed entry from the list. Active downloads are left untouched.
    func dismiss(_ id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              case .failed = downloads[index].state else {
            return
        }
        downloads.remove(at: index)
    }

    // MARK: - Pure helpers (nonisolated, unit-test friendly)

    /// Trims whitespace and requires an absolute https URL with a host.
    nonisolated static func validate(urlString: String) throws -> URL {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            throw DownloadError.invalidURL
        }
        guard url.scheme?.lowercased() == "https" else {
            throw DownloadError.insecureScheme
        }
        return url
    }

    /// Picks the file extension: the URL path extension when supported, otherwise derived from the
    /// MIME type. Returns nil when neither gives a supported movie format.
    nonisolated static func resolveExtension(url: URL, mimeType: String?) -> String? {
        let pathExtension = url.pathExtension.lowercased()
        if MovieLibrary.supportedExtensions.contains(pathExtension) {
            return pathExtension
        }
        guard let mimeType else { return nil }
        let baseMimeType = mimeType
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch baseMimeType {
        case "video/mp4":
            return "mp4"
        case "video/x-m4v":
            return "m4v"
        case "video/quicktime":
            return "mov"
        default:
            return nil
        }
    }

    /// Uses the typed title when present, else the URL's file name without extension, else a fallback.
    /// The URL is never logged or shown; only its file name is used.
    private nonisolated static func resolveTitle(_ title: String, url: URL) -> String {
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            return typed
        }
        var baseName = ""
        let lastComponent = url.lastPathComponent
        if !lastComponent.isEmpty, lastComponent != "/" {
            baseName = url.deletingPathExtension().lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return baseName.isEmpty ? "Film sans titre" : baseName
    }

    private nonisolated static func downloadID(of task: URLSessionTask) -> UUID? {
        guard let description = task.taskDescription else { return nil }
        return UUID(uuidString: description)
    }

    /// Moves the system temp file to a location we own. Must run synchronously inside the delegate
    /// callback, because the system deletes `location` as soon as that callback returns.
    private nonisolated static func stage(_ location: URL, id: UUID) -> URL? {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(id.uuidString).tmp")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Maps a transport error to a French message. Never includes the URL.
    private nonisolated static func failureMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "Connexion perdue. Vérifiez le Wi-Fi et réessayez."
            case .timedOut:
                return "Délai dépassé. Réessayez."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Serveur introuvable."
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                return "Connexion HTTPS impossible (certificat invalide)."
            default:
                break
            }
        }
        if let cocoaError = error as? CocoaError, cocoaError.code == .fileWriteOutOfSpace {
            return "Espace disque insuffisant."
        }
        return "Le téléchargement a échoué."
    }

    // MARK: - URLSessionDownloadDelegate (nonisolated: runs on the session's delegate queue)

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = DownloadManager.downloadID(of: downloadTask) else { return }
        // Synchronous: `location` is deleted when this method returns.
        let staged = DownloadManager.stage(location, id: id)
        let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode
        let mimeType = downloadTask.response?.mimeType
        Task { @MainActor in
            self.finishDownload(id: id, staged: staged, statusCode: statusCode, mimeType: mimeType)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = DownloadManager.downloadID(of: downloadTask) else { return }
        Task { @MainActor in
            self.updateProgress(id: id, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A nil error means success, which didFinishDownloadingTo already handles.
        guard let error, let id = DownloadManager.downloadID(of: task) else { return }
        let isCancelled = (error as? URLError)?.code == .cancelled
        let message = DownloadManager.failureMessage(for: error)
        Task { @MainActor in
            self.completeWithError(id: id, isCancelled: isCancelled, message: message)
        }
    }

    // MARK: - Main-actor state transitions

    /// Runs after the file has been staged. Every path releases the download's resources.
    private func finishDownload(id: UUID, staged: URL?, statusCode: Int?, mimeType: String?) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else {
            // Cancelled or dismissed before this callback reached the main actor.
            discard(staged)
            release(id)
            return
        }
        guard let staged else {
            markFailed(id, message: "Impossible d'enregistrer le fichier téléchargé.")
            return
        }
        guard let statusCode else {
            discard(staged)
            markFailed(id, message: "Réponse du serveur invalide.")
            return
        }
        guard (200...299).contains(statusCode) else {
            discard(staged)
            markFailed(id, message: "Le serveur a refusé le téléchargement (code \(statusCode)).")
            return
        }
        if let mimeType, mimeType.lowercased().hasPrefix("text/html") {
            // Typically a login or virus-scan page instead of the video.
            discard(staged)
            markFailed(id, message: "Le lien renvoie une page web et non un fichier vidéo.")
            return
        }
        guard let sourceURL = sourceURLs[id],
              let fileExtension = DownloadManager.resolveExtension(url: sourceURL, mimeType: mimeType) else {
            discard(staged)
            markFailed(id, message: "Format non pris en charge (MP4, M4V ou MOV uniquement).")
            return
        }
        do {
            _ = try library.addMovie(
                movingFileAt: staged,
                title: downloads[index].title,
                fileExtension: fileExtension
            )
        } catch {
            discard(staged)
            markFailed(id, message: error.localizedDescription)
            return
        }
        downloads.remove(at: index)
        release(id)
    }

    /// Cancellation removes the entry silently; any other error marks it as failed.
    private func completeWithError(id: UUID, isCancelled: Bool, message: String) {
        if isCancelled {
            downloads.removeAll { $0.id == id }
            release(id)
        } else {
            markFailed(id, message: message)
        }
    }

    private func markFailed(_ id: UUID, message: String) {
        if let index = downloads.firstIndex(where: { $0.id == id }) {
            downloads[index].state = .failed(message)
        }
        release(id)
    }

    /// Throttled: publishes the first update, then whenever at least 1 % of the total size or
    /// 0.5 s has passed since the last published value (the 1 % check needs a known total).
    private func updateProgress(id: UUID, written: Int64, expected: Int64) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].state == .downloading else {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = progressMarks[id] {
            let byteStep = expected / 100
            let stepReached = expected > 0 && written - previous.bytes >= byteStep
            let timeReached = now - previous.time >= 0.5
            guard stepReached || timeReached else { return }
        }
        progressMarks[id] = ProgressMark(bytes: written, time: now)
        downloads[index].bytesWritten = written
        downloads[index].totalBytes = expected
    }

    /// Forgets everything kept for one download. Idempotent, so callback order does not matter.
    private func release(_ id: UUID) {
        tasks.removeValue(forKey: id)
        progressMarks.removeValue(forKey: id)
        if let url = sourceURLs.removeValue(forKey: id) {
            activeSourceURLs.remove(url)
        }
        releaseBackgroundTask(for: id)
        updateIdleTimer()
    }

    /// The screen stays on while any download is in flight (downloads are foreground-only).
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = !tasks.isEmpty
    }

    private func startBackgroundTask(for id: UUID) {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "download-\(id.uuidString)") { [weak self] in
            // Expiration handler: iOS requires the background task to be ended here.
            Task { @MainActor in
                self?.releaseBackgroundTask(for: id)
            }
        }
        backgroundTaskIDs[id] = identifier
    }

    private func releaseBackgroundTask(for id: UUID) {
        guard let identifier = backgroundTaskIDs.removeValue(forKey: id), identifier != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(identifier)
    }

    /// Removes a staged temp file. Failure is harmless: the file lives in the temporary directory.
    private func discard(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
