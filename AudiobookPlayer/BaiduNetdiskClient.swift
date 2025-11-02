import Foundation

struct BaiduNetdiskEntry: Decodable, Identifiable {
    let fsId: Int64
    let path: String
    let serverFilename: String
    let isDir: Bool
    let size: Int64
    let md5: String?
    let serverCtime: TimeInterval
    let serverMtime: TimeInterval

    var id: Int64 { fsId }

    enum CodingKeys: String, CodingKey {
        case fsId = "fs_id"
        case path
        case serverFilename = "server_filename"
        case isDir = "isdir"
        case size
        case md5
        case serverCtime = "server_ctime"
        case serverMtime = "server_mtime"
    }
    
    init(
        fsId: Int64,
        path: String,
        serverFilename: String,
        isDir: Bool,
        size: Int64,
        md5: String?,
        serverCtime: TimeInterval,
        serverMtime: TimeInterval
    ) {
        self.fsId = fsId
        self.path = path
        self.serverFilename = serverFilename
        self.isDir = isDir
        self.size = size
        self.md5 = md5
        self.serverCtime = serverCtime
        self.serverMtime = serverMtime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fsId = try container.decode(Int64.self, forKey: .fsId)
        let path = try container.decode(String.self, forKey: .path)
        let serverFilename = try container.decode(String.self, forKey: .serverFilename)
        let isDirValue = try container.decode(Int.self, forKey: .isDir)
        let size = try container.decode(Int64.self, forKey: .size)
        let md5 = try container.decodeIfPresent(String.self, forKey: .md5)
        let serverCtime = try container.decode(TimeInterval.self, forKey: .serverCtime)
        let serverMtime = try container.decode(TimeInterval.self, forKey: .serverMtime)

        self.init(
            fsId: fsId,
            path: path,
            serverFilename: serverFilename,
            isDir: isDirValue == 1,
            size: size,
            md5: md5,
            serverCtime: serverCtime,
            serverMtime: serverMtime
        )
    }
}

struct BaiduNetdiskListResponse: Decodable {
    let errno: Int
    let list: [BaiduNetdiskEntry]
    let requestId: Int?

    enum CodingKeys: String, CodingKey {
        case errno
        case list
        case requestId = "request_id"
    }
}

protocol BaiduNetdiskListing {
    func listDirectory(path: String, token: BaiduOAuthToken) async throws -> [BaiduNetdiskEntry]
}

final class BaiduNetdiskClient: BaiduNetdiskListing {
    private let baseURL = URL(string: "https://pan.baidu.com/rest/2.0/xpan/file")!
    private let jsonDecoder: JSONDecoder
    private let urlSession: URLSession

    init(
        urlSession: URLSession = .shared,
        jsonDecoder: JSONDecoder = {
            let decoder = JSONDecoder()
            return decoder
        }()
    ) {
        self.urlSession = urlSession
        self.jsonDecoder = jsonDecoder
    }

    func listDirectory(path: String, token: BaiduOAuthToken) async throws -> [BaiduNetdiskEntry] {
        guard !token.isExpired else {
            throw NetdiskError.expiredToken
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "dir", value: path),
            URLQueryItem(name: "access_token", value: token.accessToken)
        ]

        guard let url = components.url else {
            throw NetdiskError.invalidRequest
        }

        let (data, response) = try await urlSession.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetdiskError.unexpectedResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NetdiskError.httpStatus(httpResponse.statusCode, body: body)
        }

        let decoded = try jsonDecoder.decode(BaiduNetdiskListResponse.self, from: data)

        guard decoded.errno == 0 else {
            throw NetdiskError.apiError(decoded.errno)
        }

        return decoded.list
    }
}

enum NetdiskError: LocalizedError {
    case expiredToken
    case invalidRequest
    case httpStatus(Int, body: String)
    case apiError(Int)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .expiredToken:
            return "Baidu token has expired. Please sign in again."
        case .invalidRequest:
            return "Failed to create Baidu Netdisk request."
        case .httpStatus(let status, let body):
            return "Baidu returned HTTP \(status): \(body)"
        case .apiError(let code):
            return "Baidu Netdisk API error \(code)."
        case .unexpectedResponse:
            return "Received unexpected response from Baidu Netdisk."
        }
    }
}
