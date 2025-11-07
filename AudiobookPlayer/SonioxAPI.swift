import Foundation

// MARK: - Soniox API Models

/// Response from file upload endpoint
struct SonioxFileResponse: Decodable {
    let id: String
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

    private let apiKey: String
    private let baseURL = URL(string: "https://api.soniox.com")!
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

        let fileData = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent

        var request = try self.makeMultipartRequest(
            url: endpoint,
            fileData: fileData,
            fileName: fileName
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.serverError(statusCode: httpResponse.statusCode, message: "File upload failed")
        }

        let decoder = JSONDecoder()
        let fileResponse = try decoder.decode(SonioxFileResponse.self, from: data)
        return fileResponse.id
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

        guard httpResponse.statusCode == 200 else {
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

    private func makeMultipartRequest(
        url: URL,
        fileData: Data,
        fileName: String
    ) throws -> URLRequest {
        let boundary = UUID().uuidString

        var body = Data()

        // Add file part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        return request
    }
}
