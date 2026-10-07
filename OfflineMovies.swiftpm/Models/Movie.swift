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
    var watchedFraction: Double {
        guard let duration, duration.isFinite, duration > 0, lastPosition.isFinite else {
            return 0
        }
        return min(max(lastPosition / duration, 0), 1)
    }
}
