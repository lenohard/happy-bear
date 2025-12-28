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
    private var session: URLSession?
    private let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private let chromiumVersion = "130.0.2849.68"
    
    private var audioData = Data()
    private var completion: ((Result<Data, Error>) -> Void)?
    private var isCompleted = false
    
    // Connection state management
    private var isSocketOpen = false
    private var pendingMessages: [String] = []
    
    override init() {
        super.init()
    }
    
    func generateAudio(text: String, voice: String = "en-US-AriaNeural", rate: String = "+0%", pitch: String = "+0Hz", completion: @escaping (Result<Data, Error>) -> Void) {
        // Reset state
        self.session?.invalidateAndCancel()
        self.session = nil
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
        
        self.completion = completion
        self.audioData = Data()
        self.isCompleted = false
        self.isSocketOpen = false
        self.pendingMessages = []
        
        AppLog.debug("[EdgeTTS] Starting generation for text length: \(text.count)")
        
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
            AppLog.debug("[EdgeTTS] Failed to construct URL")
            completion(.failure(EdgeTTSError.connectionFailed))
            return
        }
        
        var request = URLRequest(url: url)
        request.addValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36 Edg/119.0.0.0", forHTTPHeaderField: "User-Agent")
        request.addValue("https://www.bing.com", forHTTPHeaderField: "Origin")
        
        AppLog.debug("[EdgeTTS] Connecting to WebSocket...")
        webSocketTask = session?.webSocketTask(with: request)
        webSocketTask?.resume()
        
        listen()
        
        // Send config
        let timestamp = Date().iso8601
        let configMessage = "Content-Type: application/json; charset=utf-8\r\nPath: speech.config\r\nX-Timestamp: \(timestamp)\r\n\r\n{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":false,\"wordBoundaryEnabled\":true},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}} "
        queueOrSend(text: configMessage)
        
        // Send SSML
        let escapedText = escapeXML(text)
        let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>\n<voice name='\(voice)'>\n<prosody pitch='\(pitch)' rate='\(rate)'>\n\(escapedText)\n</prosody>\n</voice>\n</speak>"
        
        let ssmlMessage = "Content-Type: application/ssml+xml\r\nPath: ssml\r\nX-RequestId: \(connectId)\r\nX-Timestamp: \(timestamp)\r\n\r\n\(ssml)"
        queueOrSend(text: ssmlMessage)
    }
    
    private func escapeXML(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    
    private func queueOrSend(text: String) {
        if isSocketOpen {
            AppLog.debug("[EdgeTTS] Sending message immediately (socket open)")
            send(text: text)
        } else {
            AppLog.debug("[EdgeTTS] Queueing message (socket connecting)")
            pendingMessages.append(text)
        }
    }
    
    // MARK: - URLSessionWebSocketDelegate
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        AppLog.debug("[EdgeTTS] WebSocket didOpenWithProtocol")
        isSocketOpen = true
        if !pendingMessages.isEmpty {
            AppLog.debug("[EdgeTTS] Flushing \(pendingMessages.count) queued messages")
            for text in pendingMessages {
                send(text: text)
            }
            pendingMessages.removeAll()
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            AppLog.debug("[EdgeTTS] WebSocket didCompleteWithError: \(error)")
            if !isCompleted {
                isCompleted = true
                completion?(.failure(EdgeTTSError.socketError(error)))
            }
        } else {
            AppLog.debug("[EdgeTTS] WebSocket didComplete successfully")
        }
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
                AppLog.debug("WebSocket send error: \(error)")
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