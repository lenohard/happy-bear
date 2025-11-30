import Foundation
import CommonCrypto
import AVFoundation

enum EdgeTTSError: Error {
    case connectionFailed
    case invalidResponse
    case audioDataMissing
    case socketError(Error)
}

final class EdgeTTSClient: NSObject, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    private let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private let chromiumVersion = "130.0.2849.68"
    
    private var audioData = Data()
    private var completion: ((Result<Data, Error>) -> Void)?
    private var isCompleted = false
    
    override init() {
        let config = URLSessionConfiguration.default
        self.session = URLSession(configuration: config)
        super.init()
    }
    
    func generateAudio(text: String, voice: String = "en-US-AriaNeural", rate: String = "+0%", pitch: String = "+0Hz", completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
        self.audioData = Data()
        self.isCompleted = false
        
        let connectId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let secMsGec = generateSecMsGec()
        
        // Build URL with query parameters
        var components = URLComponents(string: "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1")!
        components.queryItems = [
            URLQueryItem(name: "ConnectionId", value: connectId),
            URLQueryItem(name: "TrustedClientToken", value: trustedClientToken),
            URLQueryItem(name: "Sec-MS-GEC", value: secMsGec),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: "1-\(chromiumVersion)")
        ]
        
        guard let url = components.url else {
            completion(.failure(EdgeTTSError.connectionFailed))
            return
        }
        
        var request = URLRequest(url: url)
        request.addValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36 Edg/119.0.0.0", forHTTPHeaderField: "User-Agent")
        request.addValue("https://www.bing.com", forHTTPHeaderField: "Origin")
        
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
        
        listen()
        
        // Send config
        let timestamp = Date().iso8601
        let configMessage = """
        Content-Type: application/json; charset=utf-8\r
        Path: speech.config\r
        X-Timestamp: \(timestamp)\r
        \r
        {"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":false,"wordBoundaryEnabled":true},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}
        """
        send(text: configMessage)
        
        // Send SSML
        let ssml = """
        <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>
        <voice name='\(voice)'>
        <prosody pitch='\(pitch)' rate='\(rate)'>
        \(text)
        </prosody>
        </voice>
        </speak>
        """
        
        let ssmlMessage = """
        Content-Type: application/ssml+xml\r
        Path: ssml\r
        X-RequestId: \(connectId)\r
        X-Timestamp: \(timestamp)\r
        \r
        \(ssml)
        """
        send(text: ssmlMessage)
    }
    
    private func generateSecMsGec() -> String {
        let winEpochOffset: Int64 = 11644473600 // Windows epoch offset (1601 to 1970)
        let sToNs: Int64 = 1000000000 // Seconds to nanoseconds
        
        var ticks = Int64(Date().timeIntervalSince1970)
        // Switch to Windows file time epoch
        ticks += winEpochOffset
        // Round down to nearest 5 minutes (300 seconds)
        ticks -= ticks % 300
        // Convert to 100-nanosecond intervals
        ticks *= sToNs / 100
        
        // Create string to hash
        let strToHash = "\(ticks)\(trustedClientToken)"
        
        // Compute SHA256 hash
        guard let data = strToHash.data(using: .ascii) else {
            return ""
        }
        
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        
        return hash.map { String(format: "%02X", $0) }.joined()
    }
    
    private func send(text: String) {
        let message = URLSessionWebSocketTask.Message.string(text)
        webSocketTask?.send(message) { error in
            if let error = error {
                print("WebSocket send error: \(error)")
            }
        }
    }
    
    private func listen() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            // If already completed, ignore further messages
            guard !self.isCompleted else { return }
            
            switch result {
            case .failure(let error):
                // Only report error if we haven't completed successfully
                if !self.isCompleted {
                    self.isCompleted = true
                    self.completion?(.failure(EdgeTTSError.socketError(error)))
                }
                
            case .success(let message):
                switch message {
                case .string(let text):
                    if text.contains("Path:turn.end") {
                        self.isCompleted = true
                        self.webSocketTask?.cancel(with: .normalClosure, reason: nil)
                        if self.audioData.isEmpty {
                            self.completion?(.failure(EdgeTTSError.audioDataMissing))
                        } else {
                            self.completion?(.success(self.audioData))
                        }
                        return // Don't continue listening
                    }
                case .data(let data):
                    // Binary data contains headers, need to skip them
                    // Header length is 2 bytes (UInt16 big endian)
                    if data.count > 2 {
                        let headerLen = (Int(data[0]) << 8) | Int(data[1])
                        if data.count > headerLen + 2 {
                            let audioChunk = data.subdata(in: (headerLen + 2)..<data.count)
                            self.audioData.append(audioChunk)
                        }
                    }
                @unknown default:
                    break
                }
                
                // Continue listening only if not completed
                if !self.isCompleted {
                    self.listen()
                }
            }
        }
    }
}

extension Date {
    var iso8601: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: self)
    }
}

