# OfflineMovies — technical specification (shared contract for all agents)

Personal iOS/iPadOS app: download video files the user is entitled to (her own
files, DRM-free purchases, files on her NAS/cloud) over HTTPS or import them from
the Files app, then watch them fully offline (plane mode).

**Out of scope, never implement:** DRM circumvention, scraping/streaming-site
extraction, torrenting, any telemetry/analytics, any third-party dependency.

## Format & toolchain
- Swift Playgrounds **App Playground** package: `OfflineMovies.swiftpm/`.
  `Package.swift` is already written — do NOT modify it.
- Single target `AppModule`, path `.` → every `.swift` file in the package is compiled
  together (one module: no `import AppModule`, types are visible across files).
- Swift 5.9 language mode, **iOS 16.0 minimum**: use `ObservableObject` /
  `@Published` / `@StateObject` / `@EnvironmentObject` (NOT `@Observable`, NOT
  SwiftData, NOT iOS 17-only APIs such as `ContentUnavailableView` or
  `onChange(of:initial:_:)` two-parameter closure form).
- Frameworks allowed: Foundation, SwiftUI, AVKit, AVFoundation, UIKit,
  UniformTypeIdentifiers. Nothing else.
- No `print` of URLs, file paths or titles (privacy). Use `os.Logger` only for
  generic events if needed (`import os`), never with user data.
- All user-facing strings in **French**. Code, identifiers, comments in English.
- No force unwraps (`!`) or `try!` except for compile-time-constant URLs.

## Files & owners (each agent writes ONLY its own files)

| File | Owner |
|---|---|
| `Models/Movie.swift` | Agent A |
| `Storage/MovieLibrary.swift` | Agent A |
| `Download/DownloadManager.swift` | Agent B |
| `Player/PlayerView.swift` | Agent C |
| `App/OfflineMoviesApp.swift` | Agent C |
| `Views/ContentView.swift` | Agent C |
| `Views/LibraryView.swift` | Agent C |
| `Views/AddDownloadView.swift` | Agent C |
| `Views/Formatting.swift` | Agent C |

## Interface contract (exact signatures — implement / consume as written)

### `Models/Movie.swift`
```swift
import Foundation

struct Movie: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    /// File name inside MovieLibrary.moviesDirectory, always "<id>.<ext>" — never user-derived.
    let fileName: String
    let addedAt: Date
    var fileSize: Int64
    /// Last playback position in seconds.
    var lastPosition: Double
    /// Duration in seconds, nil until known.
    var duration: Double?

    /// 0...1 watched fraction, 0 when duration unknown.
    var watchedFraction: Double { get }
}
```

### `Storage/MovieLibrary.swift`
```swift
import Foundation

enum LibraryError: LocalizedError {
    case unsupportedFormat(String)      // extension not in supportedExtensions
    case insufficientSpace
    case fileMissing
    case accessDenied                   // security-scoped access refused
    case ioFailure(String)
    var errorDescription: String? { get }   // French messages
}

@MainActor
final class MovieLibrary: ObservableObject {
    static let supportedExtensions: Set<String>   // ["mp4", "m4v", "mov"] (lowercase)

    @Published private(set) var movies: [Movie]   // sorted newest first

    /// root == nil → <Application Support>/OfflineMovies. Creates dirs, loads index.
    init(root: URL? = nil)

    var moviesDirectory: URL { get }              // <root>/Movies
    func fileURL(for movie: Movie) -> URL

    /// Moves (not copies) a finished temp file into the library. Returns the new Movie.
    func addMovie(movingFileAt tempURL: URL, title: String, fileExtension: String) throws -> Movie
    /// Copies a file picked in the Files app (handles security-scoped access).
    func importMovie(from externalURL: URL) throws -> Movie

    func rename(_ id: UUID, to title: String)
    func delete(_ id: UUID) throws
    func updatePlayback(_ id: UUID, position: Double, duration: Double?)

    /// Free bytes on the volume (volumeAvailableCapacityForImportantUsageKey), nil if unknown.
    func availableDiskSpace() -> Int64?
}
```
Requirements:
- Index persisted as JSON at `<root>/library.json`, written atomically
  (`.atomic`) after every mutation. Corrupt/unreadable index → start with an empty
  list but do NOT delete movie files; then rebuild entries for orphan files found in
  `moviesDirectory` whose name is `<uuid>.<supported ext>` (title = "Film sans titre").
- Entries whose file no longer exists are dropped on load.
- Stored file name is always `"\(id.uuidString).\(ext)"` with `ext` lowercased and
  validated against `supportedExtensions` → no path traversal possible. Before any
  file operation, verify `url.standardizedFileURL.path` has prefix
  `moviesDirectory.standardizedFileURL.path + "/"`.
- Set `URLResourceValues.isExcludedFromBackup = true` on `root` (big files must
  not fill iCloud backup).
- Use `FileProtectionType.completeUntilFirstUserAuthentication` on written files
  (playback works while locked-screen audio continues).
- Titles: trimmed, collapse to "Film sans titre" if empty, max 120 characters.
- `importMovie`: title = file name without extension; check free space ≥ file size
  + 200 MB margin else `.insufficientSpace`; `startAccessingSecurityScopedResource`
  / `stop…` in `defer` (if start returns false, still try the copy — files inside
  the app sandbox don't need it — and map a copy permission failure to `.accessDenied`).
- `delete`: remove file then entry; missing file is not an error.

### `Download/DownloadManager.swift`
```swift
import Foundation

enum DownloadError: LocalizedError {
    case invalidURL           // unparsable / no host
    case insecureScheme       // anything but https
    case alreadyDownloading
    var errorDescription: String? { get }   // French
}

struct ActiveDownload: Identifiable, Equatable {
    enum State: Equatable { case downloading, failed(String) }
    let id: UUID
    var title: String
    var bytesWritten: Int64
    var totalBytes: Int64        // <= 0 when unknown
    var state: State
    var progress: Double { get } // 0...1, 0 when total unknown
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    @Published private(set) var downloads: [ActiveDownload]

    init(library: MovieLibrary)

    /// Validates input and starts the download. Throws DownloadError.
    func start(urlString: String, title: String) throws
    func cancel(_ id: UUID)
    /// Removes a failed entry from the list.
    func dismiss(_ id: UUID)

    /// Pure validation, unit-test friendly: trims whitespace, requires https + host.
    nonisolated static func validate(urlString: String) throws -> URL
    /// Picks the file extension: URL path extension if supported, else from MIME type
    /// (video/mp4→mp4, video/x-m4v→m4v, video/quicktime→mov), else nil.
    nonisolated static func resolveExtension(url: URL, mimeType: String?) -> String?
}
```
Requirements:
- One `URLSession(configuration: .default, delegate: self, delegateQueue: nil)`;
  `URLSessionDownloadTask`; store the download UUID in `task.taskDescription`
  (so nonisolated delegate callbacks need no shared mutable state).
- Delegate methods are `nonisolated`; hop to the main actor with
  `Task { @MainActor in … }` to mutate `downloads`.
- `didFinishDownloadingTo`: the temp file is deleted when the callback returns →
  synchronously move it to `FileManager.default.temporaryDirectory/<uuid>.tmp`
  inside the callback, then on main actor: check HTTP status 200…299, reject
  `text/html` MIME (typical "login page / virus scan page" instead of a video),
  resolve extension (failure → state `.failed("Format non pris en charge (MP4, M4V ou MOV uniquement).")`),
  then `library.addMovie(movingFileAt:…)` and remove the entry from `downloads`.
  Clean up the temp file on every failure path.
- `didCompleteWithError`: if error is cancellation, remove the entry silently;
  otherwise set `.failed(<French message>)`.
- Throttle progress updates (≥ 1 % change or ≥ 0.5 s) to avoid flooding SwiftUI.
- While any download is active: `UIApplication.shared.isIdleTimerDisabled = true`
  (screen stays on, downloads are foreground-only); reset to false when none
  remain. Also wrap each download in `UIApplication.shared.beginBackgroundTask`
  so a short trip to background doesn't kill it; end the task on completion.
  (`import UIKit` for this.)
- Same URL already downloading → `.alreadyDownloading`.
- Title empty → use URL's last path component without extension, else "Film sans titre".
- Never log the URL (it may contain access tokens).

### `Player/PlayerView.swift`
```swift
import SwiftUI
import AVKit

/// Full-screen player. Present with .fullScreenCover.
struct PlayerView: View {
    let movie: Movie
    // reads MovieLibrary from @EnvironmentObject
}
```
Requirements:
- `UIViewControllerRepresentable` wrapping `AVPlayerViewController`
  (native controls, PiP allowed, AirPlay irrelevant offline).
- Resume at `movie.lastPosition` if it is > 5 s and < duration − 30 s.
- Save position via `library.updatePlayback` every 5 s (periodic time observer)
  and on disappear; also save duration once the item is ready
  (`try await asset.load(.duration)` is iOS 16 OK).
- At end of playback, save position 0 (so next play restarts).
- A visible close button (SF Symbol `xmark.circle.fill`) overlay top-leading,
  plus AVPlayerViewController's own "Done" handled via dismiss.
- Pause and remove observers on disappear (no leaks).

### `App/OfflineMoviesApp.swift`
- `@main struct OfflineMoviesApp: App` creating `MovieLibrary` and
  `DownloadManager(library:)` as `@StateObject`s in `init()`
  (`_library = StateObject(wrappedValue: lib)` pattern, same instance passed to
  the download manager), injected with `.environmentObject` for both.
- In `init()`: `try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)`
  — sound plays even with the silent switch on (critical in a plane).

### Views (`Views/*.swift`), French UI
- `ContentView`: `NavigationStack { LibraryView() }`.
- `LibraryView`:
  - Title "Mes films". Toolbar `Menu` with "+" icon: "Télécharger depuis un lien"
    (sheet → `AddDownloadView`) and "Importer depuis Fichiers"
    (`.fileImporter`, allowed types `[.movie, .mpeg4Movie, .quickTimeMovie]`,
    single selection → `library.importMovie`; errors shown in an alert).
  - Section "Téléchargements en cours" (only if non-empty): title, `ProgressView`
    with value, "x Mo / y Mo" text, cancel button; failed ones show the message in
    red + "Retirer" button (`dismiss`).
  - Section "Prêts hors ligne": rows with SF Symbol `film`, title, size,
    duration (if known), a thin watched-progress bar when 0 < fraction < 1. Tap →
    `.fullScreenCover` PlayerView. Swipe to delete (with confirmation dialog).
    Context menu "Renommer" (alert with TextField — iOS 16 supports TextField in
    alert) and "Supprimer".
  - Empty state (no movies, no downloads): VStack with big `film.stack` icon and
    text "Aucun film pour l'instant. Touchez + pour en ajouter." (no
    ContentUnavailableView — iOS 17 only).
  - Footer: "Espace libre : X Go" from `library.availableDiskSpace()`.
- `AddDownloadView`: `NavigationStack` + `Form`: TextField "Lien HTTPS du fichier
  vidéo" (keyboard `.URL`, no autocapitalization/autocorrection), TextField
  "Titre (optionnel)", a help text explaining: direct link to an .mp4/.m4v/.mov
  file, keep the app open and the screen on during the download, connect to Wi-Fi.
  Buttons "Annuler" / "Télécharger" (disabled when the link is empty); validation
  errors displayed inline in red. On success: dismiss.
- `Formatting.swift`: `enum Formatting { static func bytes(_: Int64) -> String`
  (ByteCountFormatter, .file) `; static func duration(_: Double) -> String` ("1 h 42 min"
  / "42 min") `}`.

## Definition of done (per agent)
- Only owned files written; signatures exactly as above.
- Compiles in principle under Swift 5.9 / iOS 16 (no toolchain available in the
  build container: re-read your code carefully for type errors, missing imports,
  actor-isolation errors, optional handling).
- No dependency, no telemetry, no force unwrap, French UI strings.
