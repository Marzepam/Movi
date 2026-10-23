import CoreMedia

extension CMTime {
    /// `mm:ss`, or `h:mm:ss` past the one-hour mark. Falls back to `00:00`
    /// for invalid/indefinite times so the UI never shows garbage.
    var shaveFormatted: String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
