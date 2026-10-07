import Foundation

/// Display helpers for file sizes and durations shown in the French UI.
enum Formatting {
    /// File size such as "1,2 Go" (ByteCountFormatter, file style).
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Duration such as "1 h 42 min", "2 h" or "42 min".
    /// Rounded to the nearest minute, and never below one minute.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 min" }
        let rounded = (seconds / 60).rounded()
        let clamped = min(max(rounded, 1), 1_000_000)
        let totalMinutes = Int(clamped)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h"
        }
        return "\(minutes) min"
    }
}
