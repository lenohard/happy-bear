import Foundation

@MainActor
final class AliyunAuthViewModel: ObservableObject {
    @Published private(set) var token: AliyunOAuthToken?
    @Published private(set) var isAuthorizing = false
    @Published var errorMessage: String?

    private let serviceFactory: @MainActor () -> Result<AliyunOAuthAuthorizing, AliyunOAuthService.Error>
    private var service: AliyunOAuthAuthorizing?
    private let tokenStore: AliyunOAuthTokenStore

    init(
        serviceFactory: @escaping @MainActor () -> Result<AliyunOAuthAuthorizing, AliyunOAuthService.Error> = {
            AliyunOAuthService.makeFromBundle().map { $0 as AliyunOAuthAuthorizing }
        },
        tokenStore: AliyunOAuthTokenStore = KeychainAliyunOAuthTokenStore()
    ) {
        self.serviceFactory = serviceFactory
        self.tokenStore = tokenStore
        loadPersistedToken()
    }

    func signIn() {
        guard !isAuthorizing else { return }
        isAuthorizing = true
        errorMessage = nil

        Task {
            do {
                let service = try await resolveService()
                let token = try await service.authorize()
                if token.isExpired {
                    throw AliyunOAuthService.Error.authorizationFailed(details: "Received expired access token from Aliyun.")
                }
                try tokenStore.saveToken(token)
                self.token = token
            } catch let error as AliyunOAuthService.Error {
                errorMessage = error.localizedDescription
            } catch {
                errorMessage = error.localizedDescription
            }
            isAuthorizing = false
        }
    }

    func signOut() {
        token = nil
        errorMessage = nil
        try? tokenStore.clearToken()
    }

    func reloadFromStore() {
        loadPersistedToken()
    }

    private func resolveService() async throws -> AliyunOAuthAuthorizing {
        if let service {
            return service
        }

        switch serviceFactory() {
        case .success(let resolved):
            service = resolved
            return resolved
        case .failure(let error):
            throw error
        }
    }

    private func loadPersistedToken() {
        do {
            if let stored = try tokenStore.loadToken(), !stored.isExpired {
                token = stored
            } else {
                try? tokenStore.clearToken()
            }
        } catch {
            errorMessage = "Failed to load saved Aliyun session."
        }
    }
}
