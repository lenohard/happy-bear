import Foundation

@MainActor
final class BaiduNetdiskBrowserViewModel: ObservableObject {
    @Published private(set) var entries: [BaiduNetdiskEntry] = []
    @Published private(set) var currentPath: String
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var audioOnly = true  // Default to audio files only for audiobook imports

    private let tokenProvider: () -> BaiduOAuthToken?
    private let client: BaiduNetdiskListing
    private var pathHistory: [String]

    init(
        startingPath: String = "/",
        tokenProvider: @escaping () -> BaiduOAuthToken?,
        client: BaiduNetdiskListing = BaiduNetdiskClient()
    ) {
        self.currentPath = startingPath
        self.pathHistory = [startingPath]
        self.tokenProvider = tokenProvider
        self.client = client
    }

    func refresh() {
        guard let token = tokenProvider() else {
            errorMessage = "Missing Baidu access token."
            entries = []
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let result = try await client.listDirectory(path: currentPath, token: token)
                let sorted = result.sorted { lhs, rhs in
                    if lhs.isDir != rhs.isDir {
                        return lhs.isDir && !rhs.isDir
                    }
                    return lhs.serverFilename.localizedCaseInsensitiveCompare(rhs.serverFilename) == .orderedAscending
                }

                await MainActor.run {
                    self.entries = sorted
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.entries = []
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    func search(keyword: String) {
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            refresh()
            return
        }

        guard let token = tokenProvider() else {
            errorMessage = "Missing Baidu access token."
            entries = []
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let result = try await client.search(
                    keyword: keyword,
                    directory: currentPath,
                    recursive: true,  // Always use recursive search
                    audioOnly: audioOnly,
                    token: token
                )
                let sorted = result.sorted { lhs, rhs in
                    if lhs.isDir != rhs.isDir {
                        return lhs.isDir && !rhs.isDir
                    }
                    return lhs.serverFilename.localizedCaseInsensitiveCompare(rhs.serverFilename) == .orderedAscending
                }

                await MainActor.run {
                    self.entries = sorted
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.entries = []
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    func enter(_ entry: BaiduNetdiskEntry) {
        guard entry.isDir else { return }
        currentPath = entry.path
        pathHistory.append(entry.path)
        refresh()
    }

    func goUp() {
        guard pathHistory.count > 1 else { return }
        pathHistory.removeLast()
        if let path = pathHistory.last {
            currentPath = path
            refresh()
        }
    }

    var canNavigateUp: Bool {
        pathHistory.count > 1
    }
}
