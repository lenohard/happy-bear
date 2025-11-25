import Foundation

enum YouTubeError: Error {
    case invalidURL
    case networkError(Error)
    case decodingError(Error)
    case noStreamFound
}

struct YouTubeVideo: Decodable {
    let title: String
    let videoId: String
    let lengthSeconds: Int64
    let author: String
}

struct YouTubePlaylistResponse: Decodable {
    let title: String
    let author: String
    let videos: [YouTubeVideo]
}

struct YouTubeStreamFormat: Decodable {
    let url: String
    let mimeType: String
    let qualityLabel: String?
    let audioQuality: String?
    
    var isAudio: Bool {
        return mimeType.starts(with: "audio/")
    }
}

struct YouTubeVideoResponse: Decodable {
    let title: String
    let videoId: String
    let formatStreams: [YouTubeStreamFormat]
    let adaptiveFormats: [YouTubeStreamFormat]
}

class YouTubeService {
    static let shared = YouTubeService()
    
    // Using a reliable public Invidious instance
    // Ideally this should be configurable by the user
    private let baseURL = "https://inv.tux.pizza/api/v1"
    
    func extractPlaylistID(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let queryItems = components.queryItems else {
            return nil
        }
        return queryItems.first(where: { $0.name == "list" })?.value
    }
    
    func fetchPlaylist(playlistId: String) async throws -> YouTubePlaylistResponse {
        let urlString = "\(baseURL)/playlists/\(playlistId)"
        guard let url = URL(string: urlString) else {
            throw YouTubeError.invalidURL
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(YouTubePlaylistResponse.self, from: data)
        } catch {
            throw YouTubeError.decodingError(error)
        }
    }
    
    func fetchStreamURL(videoId: String) async throws -> URL {
        let urlString = "\(baseURL)/videos/\(videoId)"
        guard let url = URL(string: urlString) else {
            throw YouTubeError.invalidURL
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let videoResponse = try decoder.decode(YouTubeVideoResponse.self, from: data)
            
            // Prioritize audio-only streams (m4a/opus) for background play
            // Invidious returns 'adaptiveFormats' which usually contains separate audio/video streams
            let audioStreams = videoResponse.adaptiveFormats.filter { $0.isAudio }
            
            // Sort by quality if needed, or just pick the first m4a
            if let bestAudio = audioStreams.first(where: { $0.mimeType.contains("mp4") }) ?? audioStreams.first {
                if let streamURL = URL(string: bestAudio.url) {
                    return streamURL
                }
            }
            
            // Fallback to combined streams if no adaptive audio found
            if let bestFormat = videoResponse.formatStreams.first,
               let streamURL = URL(string: bestFormat.url) {
                return streamURL
            }
            
            throw YouTubeError.noStreamFound
        } catch {
            throw YouTubeError.decodingError(error)
        }
    }
}
