import Foundation

struct CachedAudioAsset {
    let trackId: String
    let baiduFileId: String
    let streamingURL: URL
    let cachedURL: URL?

    /// Returns the appropriate URL for playback: cached if available, otherwise streaming
    func getPlaybackURL() -> URL {
        return cachedURL ?? streamingURL
    }
}

