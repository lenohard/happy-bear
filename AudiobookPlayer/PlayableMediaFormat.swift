import Foundation

enum PlayableMediaFormat {
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "flac", "wav", "opus", "ogg"
    ]

    static let videoExtensions: Set<String> = [
        "mp4", "mkv", "mov", "webm"
    ]

    static let playableExtensions: Set<String> = audioExtensions.union(videoExtensions)

    static func mediaKind(forFilename filename: String) -> AudiobookTrack.MediaKind {
        let ext = (filename as NSString).pathExtension.lowercased()
        if videoExtensions.contains(ext) {
            return .video
        }
        return .audio
    }

    static func isPlayableExtension(_ ext: String) -> Bool {
        playableExtensions.contains(ext.lowercased())
    }
}
