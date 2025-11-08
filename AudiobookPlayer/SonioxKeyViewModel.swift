import Foundation
import SwiftUI
import OSLog

@MainActor
class SonioxKeyViewModel: ObservableObject {
    @Published var apiKey: String = ""
    @Published var keyExists: Bool = false
    @Published var statusMessage: String?
    @Published var isSuccess: Bool = false

    private let keychainStore: SonioxAPIKeyStore = KeychainSonioxAPIKeyStore()
    private let logger = Logger(subsystem: "com.wdh.audiobook", category: "SonioxKey")

    init() {
        Task {
            await loadKeyStatus()
        }
    }

    func saveKey(using providedKey: String? = nil) async {
        let input = providedKey ?? apiKey
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            logger.warning("Soniox save blocked: empty key")
            await updateStatus("API key cannot be empty", success: false)
            return
        }

        do {
            logger.debug("Saving Soniox key; length=\(input.count)")
            try keychainStore.saveKey(trimmed)
            await updateStatus(
                NSLocalizedString("soniox_key_saved", comment: ""),
                success: true
            )
            await loadKeyStatus()
        } catch {
            logger.error("Soniox key save failed: \(error.localizedDescription)")
            await updateStatus(error.localizedDescription, success: false)
        }
    }

    func refreshKeyStatus() async {
        await loadKeyStatus()
    }

    private func loadKeyStatus() async {
        do {
            let key = try keychainStore.loadKey()
            await MainActor.run {
                self.keyExists = key != nil
                if key != nil {
                    self.apiKey = ""  // Don't show the actual key
                }
            }
            logger.debug("Soniox key load complete; exists=\(key != nil)")
        } catch {
            await MainActor.run {
                self.keyExists = false
            }
            logger.error("Failed loading Soniox key: \(error.localizedDescription)")
        }
    }

    private func updateStatus(_ message: String, success: Bool) async {
        await MainActor.run {
            self.statusMessage = message
            self.isSuccess = success

            // Clear status message after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.statusMessage = nil
            }
        }
    }
}
