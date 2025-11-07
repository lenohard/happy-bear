import Foundation

// MARK: - Background Task Configuration

/// Manages background transcription tasks
/// Uses URLSession background upload/download for reliability
class BackgroundTranscriptionManager: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    enum BackgroundTaskError: LocalizedError {
        case sessionNotFound
        case invalidRequest
        case noActiveTranscriptions

        var errorDescription: String? {
            switch self {
            case .sessionNotFound:
                return "Background session not found"
            case .invalidRequest:
                return "Invalid transcription request"
            case .noActiveTranscriptions:
                return "No active transcriptions to process"
            }
        }
    }

    static let shared = BackgroundTranscriptionManager()

    private let backgroundSessionIdentifier = "com.audiobook-player.transcription.background"
    private var backgroundSession: URLSession?

    override init() {
        super.init()
        setupBackgroundSession()
    }

    // MARK: - Setup

    private func setupBackgroundSession() {
        let config = URLSessionConfiguration.background(withIdentifier: backgroundSessionIdentifier)

        // Configure session for reliability
        config.isDiscretionary = false  // Don't defer - transcription is user-initiated
        config.shouldUseExtendedBackgroundIdleMode = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 300  // 5 minutes
        config.timeoutIntervalForResource = 3600  // 1 hour

        // Allow app to run in background
        config.sessionSendsLaunchEvents = true

        self.backgroundSession = URLSession(
            configuration: config,
            delegate: self,
            delegateQueue: nil  // Use background queue
        )
    }

    // MARK: - Public API

    /// Create a background transcription task
    /// - Parameters:
    ///   - fileURL: Local file to transcribe
    ///   - taskIdentifier: Unique identifier for this task
    ///   - completion: Completion handler when task finishes
    /// - Returns: Background task identifier
    func createBackgroundTranscriptionTask(
        fileURL: URL,
        taskIdentifier: String,
        completion: @escaping (Result<String, BackgroundTaskError>) -> Void
    ) -> URLSessionUploadTask? {
        guard let session = backgroundSession else {
            completion(.failure(.sessionNotFound))
            return nil
        }

        // Create a request that will be handled by Soniox
        var request = URLRequest(url: URL(string: "https://api.soniox.com/v1/files")!)
        request.httpMethod = "POST"

        // Note: API key should be retrieved securely from Keychain
        if let apiKey = retrieveAPIKey() {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let task = session.uploadTask(with: request, fromFile: fileURL)

        // Store task metadata for later retrieval
        storeTaskMetadata(taskId: taskIdentifier, urlSessionTaskId: task.taskIdentifier)

        task.resume()
        return task
    }

    /// Cancel a background transcription task
    /// - Parameter taskIdentifier: Task identifier to cancel
    func cancelBackgroundTranscriptionTask(_ taskIdentifier: String) {
        guard let session = backgroundSession else { return }

        session.getTasksWithCompletionHandler { dataTasks, uploadTasks, downloadTasks in
            let allTasks = dataTasks + uploadTasks + downloadTasks
            allTasks.forEach { task in
                if String(task.taskIdentifier) == taskIdentifier {
                    task.cancel()
                }
            }
        }

        removeTaskMetadata(taskId: taskIdentifier)
    }

    // MARK: - URLSessionDelegate

    func urlSession(
        _ session: URLSession,
        didFinishEventsForBackgroundURLSession: URLSession
    ) {
        DispatchQueue.main.async {
            if let appDelegate = UIApplication.shared.delegate as? UIApplicationDelegate,
               let completionHandler = appDelegate.application?(
                UIApplication.shared,
                handleEventsForBackgroundURLSession: self.backgroundSessionIdentifier,
                completionHandler: { }
            ) {
                // Call completion handler to notify system that background work is complete
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession: URLSession) {
        DispatchQueue.main.async {
            // Notify observers that background session completed
            NotificationCenter.default.post(name: NSNotification.Name("BackgroundTranscriptionComplete"), object: nil)
        }
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            print("Background transcription task failed: \(error.localizedDescription)")
            postNotification(name: "BackgroundTranscriptionFailed", userInfo: ["error": error])
        } else {
            print("Background transcription task completed successfully")
            postNotification(name: "BackgroundTranscriptionSuccess", userInfo: nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        let userInfo: [String: Any] = [
            "progress": progress,
            "bytesSent": totalBytesSent,
            "bytesExpected": totalBytesExpectedToSend
        ]
        postNotification(name: "BackgroundTranscriptionProgress", userInfo: userInfo)
    }

    // MARK: - Private Helpers

    private func retrieveAPIKey() -> String? {
        // Retrieve from Keychain (similar to BaiduTokenStore)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "soniox_api_key",
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let apiKey = String(data: data, encoding: .utf8) else {
            return nil
        }

        return apiKey
    }

    private func storeTaskMetadata(taskId: String, urlSessionTaskId: Int) {
        UserDefaults.standard.set(urlSessionTaskId, forKey: "transcription_task_\(taskId)")
    }

    private func removeTaskMetadata(taskId: String) {
        UserDefaults.standard.removeObject(forKey: "transcription_task_\(taskId)")
    }

    private func postNotification(name: String, userInfo: [String: Any]?) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name(name),
                object: self,
                userInfo: userInfo
            )
        }
    }
}

// MARK: - App Delegate Extension

/// Add this to AudiobookPlayerApp or AppDelegate to handle background session completion
extension UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == BackgroundTranscriptionManager.shared.backgroundSessionIdentifier {
            // Handle completion
            completionHandler()
        }
    }
}
