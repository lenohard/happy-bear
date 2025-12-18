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

    /// Formats that require VLC for playback (not natively supported by AVPlayer)
    static let vlcRequiredExtensions: Set<String> = [
        "mkv", "webm"
    ]

    /// Check if a file requires VLC for playback
    static func requiresVLC(forFilename filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return vlcRequiredExtensions.contains(ext)
    }

    /// Video formats that support audio-only playback via AVPlayer (e.g., MP4, MOV)
    /// MKV/WebM cannot extract audio with AVPlayer
    static let audioExtractableVideoExtensions: Set<String> = [
        "mp4", "mov"
    ]

    /// Check if a video file supports audio-only playback (AVPlayer can extract audio)
    static func supportsAudioOnlyPlayback(forFilename filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return audioExtractableVideoExtensions.contains(ext)
    }

    /// Check if a file is a video format
    static func isVideo(forFilename filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return videoExtensions.contains(ext)
    }
}
