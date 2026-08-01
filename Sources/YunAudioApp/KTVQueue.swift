import Foundation

/// The songs that have been put on, in the order they will be sung.
///
/// The third thing a KTV machine has that a music player does not — after the
/// key and 原唱／伴奏 — and like those two it only became possible once the
/// songs were ours to play. A queue over somebody else's player is a request;
/// a queue over files we open is a fact.
///
/// A pure value, because everything interesting about a queue is a decision
/// somebody will disagree with: what 插播 means, whether the end wraps, what
/// happens when the song being sung is removed. Those belong somewhere they can
/// be argued with and asserted rather than inside a view.
struct KTVQueue: Equatable, Sendable {

    /// Every song put on, including duplicates. Two people wanting the same
    /// song is normal and the second one is not a mistake to be de-duplicated.
    private(set) var songs: [URL] = []

    /// Which one is being sung. Nil before anything has been chosen, and after
    /// the last song ends.
    private(set) var index: Int?

    /// Whether the song being sung comes round again instead of the next one.
    ///
    /// 重唱, which on a real machine is a button rather than a mode buried in a
    /// menu: the moment somebody wants a song again is the moment it ends.
    var repeatsOne = false

    /// Rebuilds a queue that was written down, dropping what is no longer there.
    ///
    /// A KTV evening is a list somebody built up, and it did not survive
    /// quitting. Restoring it has one hazard worth handling rather than
    /// ignoring: a song may have been moved or deleted since, and a queue that
    /// points at a file which is gone fails at the moment somebody presses
    /// play. So the list is filtered first, and the position follows the song
    /// that was current rather than the number it happened to have — removing
    /// an earlier file would otherwise shift everything and leave the marker on
    /// somebody else's song.
    static func restored(paths: [String], currentIndex: Int?) -> KTVQueue {
        let wanted = paths.map { URL(fileURLWithPath: $0) }
        let current = currentIndex.flatMap { wanted.indices.contains($0) ? wanted[$0] : nil }
        let surviving = wanted.filter { FileManager.default.fileExists(atPath: $0.path) }
        var queue = KTVQueue()
        queue.songs = surviving
        queue.index = current.flatMap { surviving.firstIndex(of: $0) }
        return queue
    }

    var current: URL? {
        guard let index, songs.indices.contains(index) else { return nil }
        return songs[index]
    }

    var isEmpty: Bool { songs.isEmpty }

    /// What is still to come, for a list somebody can look at.
    var upcoming: [URL] {
        guard let index else { return songs }
        return Array(songs.dropFirst(index + 1))
    }

    /// Puts songs at the end.
    ///
    /// - Returns: The song to play, when the queue had run out and this starts
    ///   it again. Nil when something is already being sung — adding to the
    ///   list must not interrupt whoever is at the microphone.
    @discardableResult
    mutating func append(_ urls: [URL]) -> URL? {
        guard !urls.isEmpty else { return nil }
        let wasFinished = index == nil
        songs.append(contentsOf: urls)
        guard wasFinished else { return nil }
        index = songs.count - urls.count
        return current
    }

    /// 插播: next, not last.
    ///
    /// The whole point of the verb. Somebody who wants their song after this
    /// one is not asking to go to the back of a queue of eleven.
    mutating func playNext(_ url: URL) {
        guard let index, songs.indices.contains(index) else {
            append([url])
            return
        }
        songs.insert(url, at: index + 1)
    }

    /// The next song, or nil at the end.
    ///
    /// The end stops rather than wrapping. A KTV machine that starts the
    /// evening again by itself at two in the morning is a machine somebody has
    /// to get up and turn off; if the list is meant to go round, that is what
    /// putting the songs on again is for.
    @discardableResult
    mutating func advance() -> URL? {
        guard let index, songs.indices.contains(index) else { return nil }
        if repeatsOne { return songs[index] }
        let next = index + 1
        guard songs.indices.contains(next) else {
            self.index = nil
            return nil
        }
        self.index = next
        return songs[next]
    }

    /// The song before, or the start of this one.
    ///
    /// Stops at the first rather than wrapping to the last, for the same reason
    /// the end does not wrap.
    @discardableResult
    mutating func goBack() -> URL? {
        guard let index, songs.indices.contains(index) else { return nil }
        let previous = index - 1
        guard songs.indices.contains(previous) else { return songs[index] }
        self.index = previous
        return songs[previous]
    }

    /// Whether ⏮ has a song to go back to rather than only the top of this one.
    var hasSongBefore: Bool {
        guard let index else { return false }
        return songs.indices.contains(index - 1)
    }

    /// Somebody pointing at a line in the list.
    @discardableResult
    mutating func choose(_ position: Int) -> URL? {
        guard songs.indices.contains(position) else { return nil }
        index = position
        return songs[position]
    }

    /// Takes a song out.
    ///
    /// - Returns: The song that should now be playing, when the one removed was
    ///   the one being sung. Nil when the removal did not disturb it.
    @discardableResult
    mutating func remove(at position: Int) -> URL? {
        guard songs.indices.contains(position) else { return nil }
        songs.remove(at: position)
        guard let index else { return nil }
        if position < index {
            // Everything after it shifted down, so the same song is still being
            // sung — it is just one line higher in the list.
            self.index = index - 1
            return nil
        }
        guard position == index else { return nil }
        // The song being sung was taken out. The one that moved up into its
        // place is the one to play; if it was the last, the evening is over.
        guard songs.indices.contains(index) else {
            self.index = nil
            return nil
        }
        return songs[index]
    }

    mutating func clear() {
        songs = []
        index = nil
    }
}
