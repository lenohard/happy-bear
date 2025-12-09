import Foundation

struct AliyunNetdiskEntry: Decodable, Identifiable, Equatable {
    let driveId: String
    let fileId: String
    let parentFileId: String
    let name: String
    let type: String // "file" or "folder"
    let size: Int64?
    let fileExtension: String?
    let contentHash: String?
    let category: String? // "video", "audio", "image", etc.
    let createdAt: String
    let updatedAt: String
    let url: String?
    let thumbnail: String?

    var id: String { fileId }
    var isDir: Bool { type == "folder" }

    enum CodingKeys: String, CodingKey {
        case driveId = "drive_id"
        case fileId = "file_id"
        case parentFileId = "parent_file_id"
        case name
        case type
        case size
        case fileExtension = "file_extension"
        case contentHash = "content_hash"
        case category
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case url
        case thumbnail
    }
}

struct AliyunNetdiskListResponse: Decodable {
    let items: [AliyunNetdiskEntry]
    let nextMarker: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextMarker = "next_marker"
    }
}

struct AliyunDriveInfoResponse: Decodable {
    let defaultDriveId: String
    let resourceDriveId: String?
    let backupDriveId: String?

    enum CodingKeys: String, CodingKey {
        case defaultDriveId = "default_drive_id"
        case resourceDriveId = "resource_drive_id"
        case backupDriveId = "backup_drive_id"
    }
}

struct AliyunDownloadUrlResponse: Decodable {
    let url: String
    let expiration: String
    let method: String

    enum CodingKeys: String, CodingKey {
        case url
        case expiration
        case method
    }
}

protocol AliyunNetdiskListing {
    func getDriveInfo(token: AliyunOAuthToken) async throws -> AliyunDriveInfoResponse
    func listDirectory(driveId: String, parentFileId: String, token: AliyunOAuthToken) async throws -> [AliyunNetdiskEntry]
    func getDownloadURL(driveId: String, fileId: String, token: AliyunOAuthToken) async throws -> URL
}

final class AliyunNetdiskClient: AliyunNetdiskListing {
    private static let defaultBaseURL = URL(string: "https://openapi.aliyundrive.com/adrive/v1.0")!
    private static let baseURLInfoKey = "AliyunOAuthBaseURL"

    private let baseURL: URL
    private let isPDS: Bool
    private let jsonDecoder: JSONDecoder
    private let urlSession: URLSession

    init(
        baseURL: URL? = nil,
        urlSession: URLSession = .shared,
        jsonDecoder: JSONDecoder = {
            let decoder = JSONDecoder()
            return decoder
        }()
    ) {
        self.urlSession = urlSession
        self.jsonDecoder = jsonDecoder
        
        if let baseURL = baseURL {
            self.baseURL = baseURL
            self.isPDS = false
        } else if let override = Bundle.main.object(forInfoDictionaryKey: Self.baseURLInfoKey) as? String,
                  !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            // For PDS, we use the domain root (e.g., https://bj27238.api.aliyunpds.com)
            // without appending /adrive/v1.0
            let urlStr = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
            self.baseURL = URL(string: urlStr) ?? Self.defaultBaseURL
            self.isPDS = true
        } else {
            self.baseURL = Self.defaultBaseURL
            self.isPDS = false
        }
    }

    func getDriveInfo(token: AliyunOAuthToken) async throws -> AliyunDriveInfoResponse {
        guard !token.isExpired else {
            throw AliyunNetdiskError.expiredToken
        }

        // PDS uses /v2/user/get, Public Cloud uses user/getDriveInfo
        let path = isPDS ? "v2/user/get" : "user/getDriveInfo"
        let url = baseURL.appendingPathComponent(path)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8) // Empty JSON object

        let (data, response) = try await urlSession.data(for: request)

        try validateResponse(data: data, response: response)

        return try jsonDecoder.decode(AliyunDriveInfoResponse.self, from: data)
    }

    func listDirectory(driveId: String, parentFileId: String, token: AliyunOAuthToken) async throws -> [AliyunNetdiskEntry] {
        guard !token.isExpired else {
            throw AliyunNetdiskError.expiredToken
        }

        // PDS uses /v2/file/list, Public Cloud uses openFile/list
        let path = isPDS ? "v2/file/list" : "openFile/list"
        let url = baseURL.appendingPathComponent(path)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "drive_id": driveId,
            "parent_file_id": parentFileId
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)

        try validateResponse(data: data, response: response)

        let decoded = try jsonDecoder.decode(AliyunNetdiskListResponse.self, from: data)
        return decoded.items
    }

    func getDownloadURL(driveId: String, fileId: String, token: AliyunOAuthToken) async throws -> URL {
        guard !token.isExpired else {
            throw AliyunNetdiskError.expiredToken
        }

        // PDS uses /v2/file/get_download_url, Public Cloud uses openFile/getDownloadUrl
        let path = isPDS ? "v2/file/get_download_url" : "openFile/getDownloadUrl"
        let url = baseURL.appendingPathComponent(path)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "drive_id": driveId,
            "file_id": fileId,
            "expire_sec": 14400
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)

        try validateResponse(data: data, response: response)

        let decoded = try jsonDecoder.decode(AliyunDownloadUrlResponse.self, from: data)
        
        guard let downloadURL = URL(string: decoded.url) else {
            throw AliyunNetdiskError.invalidRequest
        }
        
        return downloadURL
    }

    private func validateResponse(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AliyunNetdiskError.unexpectedResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AliyunNetdiskError.httpStatus(httpResponse.statusCode, body: body)
        }
    }
}

enum AliyunNetdiskError: LocalizedError {
    case expiredToken
    case invalidRequest
    case httpStatus(Int, body: String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .expiredToken:
            return "Aliyun token has expired. Please sign in again."
        case .invalidRequest:
            return "Failed to create Aliyun Netdisk request."
        case .httpStatus(let status, let body):
            return "Aliyun returned HTTP \(status): \(body)"
        case .unexpectedResponse:
            return "Received unexpected response from Aliyun Netdisk."
        }
    }
}
