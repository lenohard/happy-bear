import Foundation

@MainActor
final class BaiduAuthViewModel: ObservableObject {
    @Published private(set) var token: BaiduOAuthToken?
    @Published private(set) var isAuthorizing = false
    @Published var errorMessage: String?

    private let serviceFactory: @MainActor () -> Result<BaiduOAuthAuthorizing, BaiduOAuthService.Error>
    private var service: BaiduOAuthAuthorizing?

    init(serviceFactory: @escaping @MainActor () -> Result<BaiduOAuthAuthorizing, BaiduOAuthService.Error> = {
        BaiduOAuthService.makeFromBundle().map { $0 as BaiduOAuthAuthorizing }
    }) {
        self.serviceFactory = serviceFactory
    }

    func signIn() {
        guard !isAuthorizing else { return }
        isAuthorizing = true
        errorMessage = nil

        Task {
            do {
                let service = try await resolveService()
                let token = try await service.authorize()
                self.token = token
            } catch let error as BaiduOAuthService.Error {
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
    }

    private func resolveService() async throws -> BaiduOAuthAuthorizing {
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
}
