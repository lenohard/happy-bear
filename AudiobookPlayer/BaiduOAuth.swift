import AuthenticationServices
import Foundation
#if canImport(UIKit)
import UIKit
#endif

protocol BaiduOAuthAuthorizing {
    @MainActor
    func authorize() async throws -> BaiduOAuthToken
}

struct BaiduOAuthConfig: Equatable {
    let clientId: String
    let clientSecret: String
    let redirectURI: URL
    let scope: String

    static let authorizationEndpoint = URL(string: "https://openapi.baidu.com/oauth/2.0/authorize")!
    static let tokenEndpoint = URL(string: "https://openapi.baidu.com/oauth/2.0/token")!
}

extension BaiduOAuthConfig {
    var callbackScheme: String {
        redirectURI.scheme ?? ""
    }

    func authorizationURL(with state: String) -> URL {
        var components = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "display", value: "mobile")
        ]
        return components.url!
    }

    static func loadFromMainBundle() throws -> BaiduOAuthConfig {
        guard let bundle = Bundle.main.infoDictionary else {
            throw BaiduOAuthService.Error.missingConfiguration
        }

        func value(for key: String) throws -> String {
            guard let value = bundle[key] as? String, !value.isEmpty else {
                throw BaiduOAuthService.Error.missingConfigurationValue(key: key)
            }
            if value.uppercased().contains("REPLACE") || value.uppercased().contains("YOUR_") {
                throw BaiduOAuthService.Error.placeholderConfigurationValue(key: key)
            }
            return value
        }

        let clientId = try value(for: "BaiduClientId")
        let clientSecret = try value(for: "BaiduClientSecret")
        let redirect = try value(for: "BaiduRedirectURI")
        let scope = try value(for: "BaiduScope")

        guard let redirectURL = URL(string: redirect) else {
            throw BaiduOAuthService.Error.invalidRedirectURI
        }

        return BaiduOAuthConfig(
            clientId: clientId,
            clientSecret: clientSecret,
            redirectURI: redirectURL,
            scope: scope
        )
    }
}

struct BaiduOAuthToken: Codable, Equatable {
    let accessToken: String
    let expiresIn: TimeInterval
    let refreshToken: String?
    let scope: String?
    let sessionKey: String?
    let sessionSecret: String?
    let receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case sessionKey = "session_key"
        case sessionSecret = "session_secret"
        case receivedAt
    }

    init(
        accessToken: String,
        expiresIn: TimeInterval,
        refreshToken: String?,
        scope: String?,
        sessionKey: String?,
        sessionSecret: String?,
        receivedAt: Date = Date()
    ) {
        self.accessToken = accessToken
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.scope = scope
        self.sessionKey = sessionKey
        self.sessionSecret = sessionSecret
        self.receivedAt = receivedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let accessToken = try container.decode(String.self, forKey: .accessToken)
        let expiresIn = try container.decode(TimeInterval.self, forKey: .expiresIn)
        let refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        let scope = try container.decodeIfPresent(String.self, forKey: .scope)
        let sessionKey = try container.decodeIfPresent(String.self, forKey: .sessionKey)
        let sessionSecret = try container.decodeIfPresent(String.self, forKey: .sessionSecret)
        let receivedAt = try container.decodeIfPresent(Date.self, forKey: .receivedAt) ?? Date()

        self.init(
            accessToken: accessToken,
            expiresIn: expiresIn,
            refreshToken: refreshToken,
            scope: scope,
            sessionKey: sessionKey,
            sessionSecret: sessionSecret,
            receivedAt: receivedAt
        )
    }

    var expiresAt: Date {
        receivedAt.addingTimeInterval(expiresIn)
    }

    var formattedExpiry: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: expiresAt)
    }

    var isExpired: Bool {
        Date() >= expiresAt
    }
}

struct BaiduOAuthErrorResponse: Decodable, Error {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

protocol HTTPClient {
    func perform(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPClient {
    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

@MainActor
final class BaiduOAuthService: BaiduOAuthAuthorizing {
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
                return "Unable to read Baidu OAuth configuration from Info.plist."
            case .missingConfigurationValue(let key):
                return "Missing Baidu OAuth configuration value for \(key)."
            case .placeholderConfigurationValue(let key):
                return "Replace the placeholder value for \(key) with your Baidu credentials."
            case .invalidRedirectURI:
                return "The Baidu redirect URI is invalid. Please ensure it is a valid URL."
            case .missingCallbackScheme:
                return "Redirect URI must contain a scheme for ASWebAuthenticationSession."
            case .unableToStartSession:
                return "Failed to launch Baidu login session."
            case .userCancelled:
                return "Sign-in was cancelled."
            case .invalidState:
                return "Baidu login response failed state verification."
            case .authorizationCodeMissing:
                return "Baidu did not return an authorization code."
            case .authorizationFailed(let details):
                return "Baidu sign-in failed: \(details)"
            case .tokenExchangeFailed(_, let message):
                return message
            case .unexpectedResponse:
                return "Received unexpected response from Baidu."
            }
        }
    }

    private let config: BaiduOAuthConfig
    private let httpClient: HTTPClient
    private let jsonDecoder: JSONDecoder
    private let presentationContextProvider: ASWebAuthenticationPresentationContextProviding
    private var authSession: ASWebAuthenticationSession?

    init(
        config: BaiduOAuthConfig,
        httpClient: HTTPClient = URLSession.shared,
        jsonDecoder: JSONDecoder = JSONDecoder(),
        presentationContextProvider: ASWebAuthenticationPresentationContextProviding = DefaultPresentationContextProvider()
    ) {
        self.config = config
        self.httpClient = httpClient
        self.jsonDecoder = jsonDecoder
        self.presentationContextProvider = presentationContextProvider
    }

    static func makeFromBundle() -> Result<BaiduOAuthService, Error> {
        do {
            let config = try BaiduOAuthConfig.loadFromMainBundle()
            return .success(BaiduOAuthService(config: config))
        } catch let error as BaiduOAuthService.Error {
            return .failure(error)
        } catch {
            return .failure(.unexpectedResponse)
        }
    }

    func authorize() async throws -> BaiduOAuthToken {
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

    private func exchangeAuthorizationCode(_ code: String) async throws -> BaiduOAuthToken {
        var request = URLRequest(url: BaiduOAuthConfig.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI.absoluteString
        ]

        request.httpBody = body.percentEncoded()

        let (data, response) = try await httpClient.perform(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw Error.unexpectedResponse
        }

        if (200...299).contains(httpResponse.statusCode) {
            return try jsonDecoder.decode(BaiduOAuthToken.self, from: data)
        }

        if let errorResponse = try? jsonDecoder.decode(BaiduOAuthErrorResponse.self, from: data) {
            throw Error.tokenExchangeFailed(
                status: httpResponse.statusCode,
                message: errorResponse.errorDescription ?? errorResponse.error
            )
        }

        throw Error.tokenExchangeFailed(status: httpResponse.statusCode, message: "Baidu returned status \(httpResponse.statusCode).")
    }
}

final class DefaultPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
#if canImport(UIKit)
        if let window = UIApplication.shared.keyWindowForAuth {
            return window
        }
#endif
        return ASPresentationAnchor()
    }
}

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

#if canImport(UIKit)
private extension UIApplication {
    var keyWindowForAuth: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })
    }
}
#endif
