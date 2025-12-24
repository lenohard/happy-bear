import Foundation

// MARK: - Soniox API Models

/// Response from file upload endpoint
struct SonioxFileResponse: Decodable {
    let id: String
}

/// Metadata for a file stored on Soniox
struct SonioxFile: Decodable, Identifiable {
    let id: String
    let filename: String?
    let sizeBytes: Int?
    let createdAt: Date?

    var displayName: String {
        if let filename, !filename.isEmpty {
            return filename
        }
        return id
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case filename
        case sizeBytes = "size"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)

        if let intValue = try? container.decode(Int.self, forKey: .sizeBytes) {
            sizeBytes = intValue
        } else if let stringValue = try? container.decode(String.self, forKey: .sizeBytes), let intValue = Int(stringValue) {
            sizeBytes = intValue
        } else if let doubleValue = try? container.decode(Double.self, forKey: .sizeBytes) {
            sizeBytes = Int(doubleValue)
        } else {
            sizeBytes = nil
        }

        if let timestamp = try? container.decode(Double.self, forKey: .createdAt) {
            createdAt = Date(timeIntervalSince1970: timestamp)
        } else if let stringValue = try? container.decode(String.self, forKey: .createdAt) {
            createdAt = Self.parseDate(from: stringValue)
        } else {
            createdAt = nil
        }
    }

    private static func parseDate(from value: String) -> Date? {
        if let date = iso8601WithFractional.date(from: value) {
            return date
        }
        return iso8601WithoutFractional.date(from: value)
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601WithoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private struct SonioxFilesListResponse: Decodable {
    let files: [SonioxFile]
}

/// Request payload for creating transcription
struct SonioxTranscriptionRequest: Encodable {
    let file_id: String
    let model: String
    let language_hints: [String]
    let enable_speaker_diarization: Bool
    let enable_language_identification: Bool
    let context: String?
}

/// Response from transcription creation endpoint
struct SonioxTranscriptionResponse: Decodable {
    let id: String
}

/// Transcription status response
struct SonioxTranscriptionStatus: Decodable {
    let id: String
    let status: String  // "queued", "processing", "completed", "error"
    let error_message: String?
}

/// Token from transcript (represents a word/phrase with timing)
struct SonioxToken: Decodable {
    let text: String
    let start_ms: Int?
    let end_ms: Int?
    let duration_ms: Int?
    let speaker: String?
    let language: String?
    let confidence: Double?
}

/// Complete transcript response
struct SonioxTranscriptResponse: Decodable {
    let tokens: [SonioxToken]
}

// MARK: - Soniox API Client

class SonioxAPI {
    enum APIError: LocalizedError {
        case missingAPIKey
        case invalidURL
        case networkError(URLError)
        case decodingError(DecodingError)
        case serverError(statusCode: Int, message: String)
        case transcriptionFailed(message: String)
        case fileUploadFailed
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Soniox API key not configured"
            case .invalidURL:
                return "Invalid URL"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .decodingError(let error):
                return "Failed to decode response: \(error.localizedDescription)"
            case .serverError(let code, let message):
                return "Server error (\(code)): \(message)"
            case .transcriptionFailed(let message):
                return "Transcription failed: \(message)"
            case .fileUploadFailed:
                return "Failed to upload audio file"
            case .invalidResponse:
                return "Invalid response from server"
            }
        }
    }

    let apiKey: String
    let baseURL = URL(string: "https://api.soniox.com")!
    private let session: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey

        // Create URLSession with custom config for large file uploads
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300  // 5 minutes
        config.timeoutIntervalForResource = 3600  // 1 hour for large files
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API Methods

    /// Upload audio file to Soniox
    /// - Parameter fileURL: Local file URL to upload
    /// - Returns: File ID for use in transcription request
    func uploadFile(fileURL: URL) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("v1/files")
        let boundary = UUID().uuidString
        let fileName = fileURL.lastPathComponent

        // Create a temporary file for the multipart body to avoid loading the whole file into memory
        let tempDir = FileManager.default.temporaryDirectory
        let tempFileURL = tempDir.appendingPathComponent(UUID().uuidString)

        do {
            // 1. Create the multipart header
            var headerData = Data()
            headerData.append("--\(boundary)\r\n".data(using: .utf8)!)
            headerData.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
            headerData.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)

            // Write header to temp file
            try headerData.write(to: tempFileURL)

            // 2. Append audio file content using FileHandle to stream it
            let fileHandle = try FileHandle(forWritingTo: tempFileURL)
            try fileHandle.seekToEnd()

            let sourceHandle = try FileHandle(forReadingFrom: fileURL)
            let chunkSize = 1024 * 1024 // 1MB chunks

            // Get file size for loop limit
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
            var offset: Int64 = 0

            while offset < fileSize {
                // Read chunk
                let data = try sourceHandle.read(upToCount: chunkSize) ?? Data()
                if data.isEmpty { break }

                // Write chunk
                try fileHandle.write(contentsOf: data)
                offset += Int64(data.count)
            }

            try sourceHandle.close()

            // 3. Append multipart footer
            var footerData = Data()
            footerData.append("\r\n".data(using: .utf8)!)
            footerData.append("--\(boundary)--\r\n".data(using: .utf8)!)

            try fileHandle.write(contentsOf: footerData)
            try fileHandle.close()

            // 4. Create request
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            // 5. Upload using the temp file (streaming upload)
            let (data, response) = try await session.upload(for: request, fromFile: tempFileURL)

            // Cleanup temp file
            try? FileManager.default.removeItem(at: tempFileURL)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            // Accept both 200 and 201 (Created) as successful responses
            guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
                throw APIError.serverError(statusCode: httpResponse.statusCode, message: "File upload failed")
            }

            let decoder = JSONDecoder()
            let fileResponse = try decoder.decode(SonioxFileResponse.self, from: data)
            return fileResponse.id

        } catch {
            // Ensure cleanup on error
            try? FileManager.default.removeItem(at: tempFileURL)
            throw error
        }
    }

    /// Create transcription job
    /// - Parameters:
    ///   - fileId: File ID from upload
    ///   - languageHints: Language hints (e.g., ["en"], ["zh"], ["en", "zh"])
    ///   - enableSpeakerDiarization: Enable speaker identification
    ///   - context: Optional context for better accuracy
    /// - Returns: Transcription ID for polling
    func createTranscription(
        fileId: String,
        languageHints: [String] = ["zh", "en"],
        enableSpeakerDiarization: Bool = true,
        context: String? = nil
    ) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("v1/transcriptions")

        let payload = SonioxTranscriptionRequest(
            file_id: fileId,
            model: "stt-async-preview",
            language_hints: languageHints,
            enable_speaker_diarization: enableSpeakerDiarization,
            enable_language_identification: true,
            context: context
        )

        let jsonData = try JSONEncoder().encode(payload)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        // Accept both 200 and 201 (Created) as successful responses
        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let errorMsg = message?["message"] as? String ?? "Unknown error"
            throw APIError.serverError(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        let decoder = JSONDecoder()
        let transcriptionResponse = try decoder.decode(SonioxTranscriptionResponse.self, from: data)
        return transcriptionResponse.id
    }

    /// Poll transcription status
    /// - Parameter transcriptionId: Transcription ID from creation
    /// - Returns: Current status (queued, processing, completed, or error)
    func checkTranscriptionStatus(transcriptionId: String) async throws -> SonioxTranscriptionStatus {
        let endpoint = baseURL
            .appendingPathComponent("v1/transcriptions")
            .appendingPathComponent(transcriptionId)

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.serverError(statusCode: httpResponse.statusCode, message: "Status check failed")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(SonioxTranscriptionStatus.self, from: data)
    }

    /// Retrieve completed transcript
    /// - Parameter transcriptionId: Transcription ID from creation
    /// - Returns: Transcript with tokens and timing information
    func getTranscript(transcriptionId: String) async throws -> SonioxTranscriptResponse {
        let endpoint = baseURL
            .appendingPathComponent("v1/transcriptions")
            .appendingPathComponent(transcriptionId)
            .appendingPathComponent("transcript")

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.serverError(statusCode: httpResponse.statusCode, message: "Transcript retrieval failed")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(SonioxTranscriptResponse.self, from: data)
    }

    /// Delete transcription job (cleanup)
    /// - Parameter transcriptionId: Transcription ID to delete
    func deleteTranscription(transcriptionId: String) async throws {
        let endpoint = baseURL
            .appendingPathComponent("v1/transcriptions")
            .appendingPathComponent(transcriptionId)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        // 204 or 200 are both acceptable for DELETE
        guard httpResponse.statusCode == 204 || httpResponse.statusCode == 200 else {
            throw APIError.serverError(statusCode: httpResponse.statusCode, message: "Failed to delete transcription")
        }
    }

    /// List all files uploaded to Soniox
    func listFiles() async throws -> [SonioxFile] {
        let endpoint = baseURL.appendingPathComponent("v1/files")
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.serverError(statusCode: httpResponse.statusCode, message: "Failed to list files")
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode([SonioxFile].self, from: data)
        } catch let firstError {
            if let wrapper = try? decoder.decode(SonioxFilesListResponse.self, from: data) {
                return wrapper.files
            }
            throw firstError
        }
    }

    /// Delete uploaded file (cleanup)
    /// - Parameter fileId: File ID to delete
    func deleteFile(fileId: String) async throws {
        let endpoint = baseURL
            .appendingPathComponent("v1/files")
            .appendingPathComponent(fileId)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        // 204 or 200 are both acceptable for DELETE
        guard httpResponse.statusCode == 204 || httpResponse.statusCode == 200 else {
            throw APIError.serverError(statusCode: httpResponse.statusCode, message: "Failed to delete file")
        }
    }

    // MARK: - Private Helpers

}
