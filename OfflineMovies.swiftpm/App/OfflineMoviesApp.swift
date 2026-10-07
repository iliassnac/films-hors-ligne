import SwiftUI
import AVFoundation

@main
@MainActor
struct OfflineMoviesApp: App {
    @StateObject private var library: MovieLibrary
    @StateObject private var downloadManager: DownloadManager

    init() {
        // Playback keeps sound even with the silent switch on (critical in a plane).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)

        let library = MovieLibrary()
        _library = StateObject(wrappedValue: library)
        _downloadManager = StateObject(wrappedValue: DownloadManager(library: library))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(downloadManager)
        }
    }
}
