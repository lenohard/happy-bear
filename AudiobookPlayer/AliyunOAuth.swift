import AuthenticationServices
import Foundation
#if canImport(UIKit)
import UIKit
#endif

protocol AliyunOAuthAuthorizing {
    @MainActor
    func authorize() async throws -> AliyunOAuthToken
}

struct AliyunOAuthConfig: Equatable {
    let clientId: String
    let clientSecret: String
    let redirectURI: URL
    let scope: String
    let baseURL: URL

    // Default fallback for OAuth endpoints (shared endpoint)
    private static let defaultBaseURL = URL(string: "https://openapi.aliyundrive.com")!

    // Dynamic endpoints based on configured base URL
    var authorizationEndpoint: URL {
        baseURL.appendingPathComponent("v2/oauth/authorize")
    }
    var tokenEndpoint: URL {
        baseURL.appendingPathComponent("v2/oauth/token")
    }
}

extension AliyunOAuthConfig {
    var callbackScheme: String {
        redirectURI.scheme ?? ""
    }

    func authorizationURL(with state: String) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        // Aliyun OAuth 2.0 parameters
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: scope), // e.g., "user:base,file:all:read,file:all:write"
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "login_type", value: "default")
        ]
        return components.url!
    }

    static func loadFromMainBundle() throws -> AliyunOAuthConfig {
        guard let bundle = Bundle.main.infoDictionary else {
            throw AliyunOAuthService.Error.missingConfiguration
        }

        func value(for key: String) throws -> String {
            guard let value = bundle[key] as? String, !value.isEmpty else {
                throw AliyunOAuthService.Error.missingConfigurationValue(key: key)
            }
            if value.uppercased().contains("REPLACE") || value.uppercased().contains("YOUR_") {
                throw AliyunOAuthService.Error.placeholderConfigurationValue(key: key)
            }
            return value
        }

        let clientId = try value(for: "AliyunClientId")
        let clientSecret = try value(for: "AliyunClientSecret")
        let redirect = try value(for: "AliyunRedirectURI")
        let scope = try value(for: "AliyunScope")

        guard let redirectURL = URL(string: redirect) else {
            throw AliyunOAuthService.Error.invalidRedirectURI
        }

        // Load base URL from Info.plist, fallback to default shared endpoint
        let baseURL: URL
        if let baseURLString = bundle["AliyunOAuthBaseURL"] as? String,
           !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let url = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            baseURL = url
        } else {
            baseURL = defaultBaseURL
        }

        return AliyunOAuthConfig(
            clientId: clientId,
            clientSecret: clientSecret,
            redirectURI: redirectURL,
            scope: scope,
            baseURL: baseURL
        )
    }
}

struct AliyunOAuthToken: Codable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval
    let tokenType: String?
    let receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case receivedAt
    }

    init(
        accessToken: String,
        refreshToken: String?,
        expiresIn: TimeInterval,
        tokenType: String?,
        receivedAt: Date = Date()
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.tokenType = tokenType
        self.receivedAt = receivedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let accessToken = try container.decode(String.self, forKey: .accessToken)
        let refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        let expiresIn = try container.decode(TimeInterval.self, forKey: .expiresIn)
        let tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType)
        let receivedAt = try container.decodeIfPresent(Date.self, forKey: .receivedAt) ?? Date()

        self.init(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresIn: expiresIn,
            tokenType: tokenType,
            receivedAt: receivedAt
        )
    }

    var expiresAt: Date {
        receivedAt.addingTimeInterval(expiresIn)
    }
    
    var isExpired: Bool {
        Date() >= expiresAt
    }
}

struct AliyunOAuthErrorResponse: Decodable, Error {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

@MainActor
final class AliyunOAuthService: AliyunOAuthAuthorizing {
    enum Error: LocalizedError {
        case missingConfiguration
        case missingConfigurationValue(key: String)
        case placeholderConfigurationValue(key: String)
        case invalidRedirectURI
        case missingCallbackScheme
        case unableToStartSession
        case userCancelled
        case invalidState
        case authorizationCodeMissing
        case authorizationFailed(details: String)
        case tokenExchangeFailed(status: Int, message: String)
        case unexpectedResponse

        var errorDescription: String? {
            switch self {
            case .missingConfiguration:
                return "Unable to read Aliyun OAuth configuration from Info.plist."
            case .missingConfigurationValue(let key):
                return "Missing Aliyun OAuth configuration value for \(key)."
            case .placeholderConfigurationValue(let key):
                return "Replace the placeholder value for \(key) with your Aliyun credentials."
            case .invalidRedirectURI:
                return "The Aliyun redirect URI is invalid. Please ensure it is a valid URL."
            case .missingCallbackScheme:
                return "Redirect URI must contain a scheme for ASWebAuthenticationSession."
            case .unableToStartSession:
                return "Failed to launch Aliyun login session."
            case .userCancelled:
                return "Sign-in was cancelled."
            case .invalidState:
                return "Aliyun login response failed state verification."
            case .authorizationCodeMissing:
                return "Aliyun did not return an authorization code."
            case .authorizationFailed(let details):
                return "Aliyun sign-in failed: \(details)"
            case .tokenExchangeFailed(_, let message):
                return message
            case .unexpectedResponse:
                return "Received unexpected response from Aliyun."
            }
        }
    }

    private let config: AliyunOAuthConfig
    private let httpClient: HTTPClient
    private let jsonDecoder: JSONDecoder
    private let presentationContextProvider: ASWebAuthenticationPresentationContextProviding
    private var authSession: ASWebAuthenticationSession?

    init(
        config: AliyunOAuthConfig,
        httpClient: HTTPClient = URLSession.shared,
        jsonDecoder: JSONDecoder = JSONDecoder(),
        presentationContextProvider: ASWebAuthenticationPresentationContextProviding? = nil
    ) {
        self.config = config
        self.httpClient = httpClient
        self.jsonDecoder = jsonDecoder
        self.presentationContextProvider = presentationContextProvider ?? DefaultPresentationContextProvider()
    }

    static func makeFromBundle() -> Result<AliyunOAuthService, Error> {
        do {
            let config = try AliyunOAuthConfig.loadFromMainBundle()
            return .success(AliyunOAuthService(config: config))
        } catch let error as AliyunOAuthService.Error {
            return .failure(error)
        } catch {
            return .failure(.unexpectedResponse)
        }
    }

    func authorize() async throws -> AliyunOAuthToken {
        let code = try await beginAuthorizationSession()
        return try await exchangeAuthorizationCode(code)
    }

    private func beginAuthorizationSession() async throws -> String {
        guard !config.callbackScheme.isEmpty else {
            throw Error.missingCallbackScheme
        }

        let state = UUID().uuidString
        let authURL = config.authorizationURL(with: state)

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: config.callbackScheme
            ) { [weak self] callbackURL, error in
                guard let self else {
                    continuation.resume(throwing: Error.unexpectedResponse)
                    return
                }

                self.authSession = nil

                if let authError = error as? ASWebAuthenticationSessionError {
                    switch authError.code {
                    case .canceledLogin:
                        continuation.resume(throwing: Error.userCancelled)
                    default:
                        continuation.resume(throwing: Error.authorizationFailed(details: authError.localizedDescription))
                    }
                    return
                } else if let error = error {
                    continuation.resume(throwing: Error.authorizationFailed(details: error.localizedDescription))
                    return
                }

                guard
                    let callbackURL,
                    let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                    let queryItems = components.queryItems
                else {
                    continuation.resume(throwing: Error.authorizationCodeMissing)
                    return
                }

                if let stateValue = queryItems.first(where: { $0.name == "state" })?.value, stateValue != state {
                    continuation.resume(throwing: Error.invalidState)
                    return
                }

                if let errorDescription = queryItems.first(where: { $0.name == "error_description" })?.value {
                    continuation.resume(throwing: Error.authorizationFailed(details: errorDescription))
                    return
                }

                guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: Error.authorizationCodeMissing)
                    return
                }

                continuation.resume(returning: code)
            }

            session.presentationContextProvider = presentationContextProvider
            session.prefersEphemeralWebBrowserSession = true
            self.authSession = session

            guard session.start() else {
                self.authSession = nil
                continuation.resume(throwing: Error.unableToStartSession)
                return
            }
        }
    }

    private func exchangeAuthorizationCode(_ code: String) async throws -> AliyunOAuthToken {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Aliyun PDS Native App: use form-urlencoded, NO client_secret
        let bodyParams: [String: String] = [
            "code": code,
            "client_id": config.clientId,
            "redirect_uri": config.redirectURI.absoluteString,
            "grant_type": "authorization_code"
        ]
        
        request.httpBody = bodyParams.percentEncoded()

        let (data, response) = try await httpClient.perform(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw Error.unexpectedResponse
        }

        if (200...299).contains(httpResponse.statusCode) {
            return try jsonDecoder.decode(AliyunOAuthToken.self, from: data)
        }

        if let errorResponse = try? jsonDecoder.decode(AliyunOAuthErrorResponse.self, from: data) {
            throw Error.tokenExchangeFailed(
                status: httpResponse.statusCode,
                message: errorResponse.errorDescription ?? errorResponse.error
            )
        }

        throw Error.tokenExchangeFailed(status: httpResponse.statusCode, message: "Aliyun returned status \(httpResponse.statusCode).")
    }
}

// Helper to reuse the percent encoding if needed, though Aliyun uses JSON for token
private extension Dictionary where Key == String, Value == String {
    func percentEncoded() -> Data? {
        map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: .oauthQueryAllowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: .oauthQueryAllowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }
        .joined(separator: "&")
        .data(using: .utf8)
    }
}

private extension CharacterSet {
    static let oauthQueryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=?")
        return set
    }()
}
