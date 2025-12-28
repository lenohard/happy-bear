import Foundation

@MainActor
final class AliyunNetdiskBrowserViewModel: ObservableObject {
    @Published private(set) var entries: [AliyunNetdiskEntry] = []
    @Published private(set) var currentPath: String
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var audioOnly = false // Kept for consistency, although API usage might differ

    private let tokenProvider: () -> AliyunOAuthToken?
    private let client: AliyunNetdiskListing
    private var pathHistory: [String] // Stores "parent_file_id"
    private var currentDriveId: String?

    // NOTE: Aliyun Drive uses file_id for navigation, not path strings like Baidu.
    // However, the UI might expect path strings for display.
    // We will use file_id as the "path" for internal navigation, but we might need to
    // maintain a breadcrumb of names for the UI.
    // For simplicity in this first iteration, we'll just show IDs or implement a name stack if needed.
    // Let's modify the history to store tuples of (id, name) if possible, or just IDs.
    
    // Actually, to keep it simple and consistent with the interface:
    // currentPath will represent the 'parent_file_id'.
    // We might need a separate 'displayPath' if we want to show folder names.
    
    init(
        startingFileId: String = "root",
        tokenProvider: @escaping () -> AliyunOAuthToken?,
        client: AliyunNetdiskListing = AliyunNetdiskClient()
    ) {
        self.currentPath = startingFileId
        self.pathHistory = [startingFileId]
        self.tokenProvider = tokenProvider
        self.client = client
    }

    func refresh() {
        guard let token = tokenProvider() else {
            errorMessage = "Missing Aliyun access token."
            entries = []
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                // Ensure we have a drive_id first
                if currentDriveId == nil {
                    let driveInfo = try await client.getDriveInfo(token: token)
                    AppLog.debug("DEBUG: Fetched Drive Info: \(driveInfo)")
                    // Prefer resource drive or backup drive? Usually default is backup_drive_id for user files?
                    // Documentation often points to default_drive_id or specific ones.
                    // Let's use default_drive_id.
                    currentDriveId = driveInfo.defaultDriveId
                }
                
                guard let driveId = currentDriveId else {
                    throw AliyunNetdiskError.invalidRequest
                }
                AppLog.debug("DEBUG: Using Drive ID: \(driveId)")

                let result = try await client.listDirectory(driveId: driveId, parentFileId: currentPath, token: token)
                
                let sorted = result.sorted { lhs, rhs in
                    if lhs.isDir != rhs.isDir {
                        return lhs.isDir && !rhs.isDir
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                AppLog.debug("DEBUG: Found \(sorted.count) items in directory \(self.currentPath)")

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

    func enter(_ entry: AliyunNetdiskEntry) {
        guard entry.isDir else { return }
        currentPath = entry.fileId
        pathHistory.append(entry.fileId)
        refresh()
    }

    func goUp() {
        guard pathHistory.count > 1 else { return }
        pathHistory.removeLast()
        if let lastId = pathHistory.last {
            currentPath = lastId
            refresh()
        }
    }

    var canNavigateUp: Bool {
        pathHistory.count > 1
    }
}
