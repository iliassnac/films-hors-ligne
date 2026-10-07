import SwiftUI
import AVKit
import AVFoundation

/// Full-screen player. Present with .fullScreenCover.
struct PlayerView: View {
    let movie: Movie
    @EnvironmentObject private var library: MovieLibrary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            PlayerRepresentable(
                movie: movie,
                url: library.fileURL(for: movie),
                library: library
            )
            .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.white, Color.black.opacity(0.5))
                    .padding(12)
            }
            .accessibilityLabel("Fermer")
        }
    }
}

/// Bridges AVPlayerViewController into SwiftUI. The Coordinator owns the player,
/// its observers and the saving of playback progress.
private struct PlayerRepresentable: UIViewControllerRepresentable {
    let movie: Movie
    let url: URL
    let library: MovieLibrary

    func makeCoordinator() -> Coordinator {
        Coordinator(movie: movie, url: url, library: library)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        context.coordinator.attach(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.teardown()
    }

    /// Owns the AVPlayer and its observers. Library calls are hopped onto the main actor
    /// with `Task { @MainActor in ... }` because MovieLibrary is main-actor isolated.
    final class Coordinator: NSObject {
        private let movieID: UUID
        private let library: MovieLibrary
        /// Position stored when the player was opened (resume candidate).
        private let savedPosition: Double
        private let item: AVPlayerItem
        private let player: AVPlayer
        /// Duration in seconds, nil until known.
        private var duration: Double?
        /// Position the playback actually started from (0 when no resume happened).
        private var startPosition: Double = 0
        /// Progress is only stored once the start position has been decided,
        /// so that an early dismissal cannot overwrite the saved position with 0.
        private var canSave = false
        private var timeObserverToken: Any?
        private var endObserver: NSObjectProtocol?
        private var loadTask: Task<Void, Never>?

        init(movie: Movie, url: URL, library: MovieLibrary) {
            let item = AVPlayerItem(url: url)
            self.movieID = movie.id
            self.library = library
            self.savedPosition = movie.lastPosition
            self.duration = movie.duration
            self.item = item
            self.player = AVPlayer(playerItem: item)
            super.init()
        }

        func attach(to controller: AVPlayerViewController) {
            controller.player = player
            controller.allowsPictureInPicturePlayback = true

            timeObserverToken = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 5, preferredTimescale: 600),
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.savePeriodicPosition()
                }
            }

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handlePlaybackEnded()
                }
            }

            loadTask = Task { @MainActor [weak self] in
                await self?.prepareStart()
            }
        }

        /// Loads the duration, applies the resume rule and starts playback.
        @MainActor
        private func prepareStart() async {
            var loaded: Double?
            do {
                let time = try await item.asset.load(.duration)
                if time.isNumeric, time.seconds.isFinite, time.seconds > 0 {
                    loaded = time.seconds
                }
            } catch {
                // Duration stays unknown: playback still works, only the resume rule is less precise.
            }
            guard !Task.isCancelled else { return }

            if let loaded {
                duration = loaded
            }
            applyResume()
            canSave = true
            library.updatePlayback(movieID, position: startPosition, duration: duration)
            player.play()
        }

        /// Resume at the saved position when it is past 5 s and not in the last 30 s
        /// (or when the duration is unknown).
        @MainActor
        private func applyResume() {
            let target = savedPosition
            guard target > 5 else { return }
            if let total = duration, target >= total - 30 { return }
            startPosition = target
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        }

        @MainActor
        func savePeriodicPosition() {
            guard canSave, let position = progressPosition() else { return }
            library.updatePlayback(movieID, position: position, duration: duration)
        }

        /// Playback reached the end: the next play starts from the beginning.
        @MainActor
        func handlePlaybackEnded() {
            library.updatePlayback(movieID, position: 0, duration: duration)
        }

        /// Current position in seconds, or nil when it must not be stored: invalid time,
        /// or the very end of the item (the end handler stores 0 instead).
        private func progressPosition() -> Double? {
            let seconds = player.currentTime().seconds
            guard seconds.isFinite, seconds >= 0 else { return nil }
            let itemSeconds: Double? = item.duration.isNumeric ? item.duration.seconds : nil
            if let total = duration ?? itemSeconds, seconds >= total - 1 {
                return nil
            }
            return seconds
        }

        /// Pauses, saves the final position and removes every observer. Idempotent.
        func teardown() {
            loadTask?.cancel()
            loadTask = nil

            player.pause()

            if let token = timeObserverToken {
                player.removeTimeObserver(token)
                timeObserverToken = nil
            }
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }

            let finalPosition = canSave ? progressPosition() : nil
            canSave = false
            player.replaceCurrentItem(with: nil)

            guard let finalPosition else { return }
            let id = movieID
            let total = duration
            let library = self.library
            // Hop to the main actor: dismantling happens during a SwiftUI update,
            // and publishing library changes there is not allowed.
            Task { @MainActor in
                library.updatePlayback(id, position: finalPosition, duration: total)
            }
        }
    }
}
