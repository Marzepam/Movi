extension Array {
    /// Bounds-checked subscript — `nil` instead of a crash for an out-of-range index.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
