import Foundation

/// Lightweight container describing how a track should be loaded.
/// When `cachedURL` is non-nil the caller should prefer it, otherwise fall back to the streaming URL.
struct CachedAudioAsset {
    let trackId: String
    let baiduFileId: String
    let streamingURL: URL?
    let cachedURL: URL?

    func isCached() -> Bool {
        cachedURL != nil
    }
}
