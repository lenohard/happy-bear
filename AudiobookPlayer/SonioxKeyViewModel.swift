import Foundation
import SwiftUI

@MainActor
class SonioxKeyViewModel: ObservableObject {
    @Published var apiKey: String = ""
    @Published var keyExists: Bool = false
    @Published var statusMessage: String?
    @Published var isSuccess: Bool = false

    private let keychainStore: SonioxAPIKeyStore = KeychainSonioxAPIKeyStore()

    init() {
        Task {
            await loadKeyStatus()
        }
    }

    func saveKey() async {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            await updateStatus("API key cannot be empty", success: false)
            return
        }

        do {
            try keychainStore.saveKey(apiKey)
            await updateStatus(
                NSLocalizedString("soniox_key_saved", comment: ""),
                success: true
            )
            await loadKeyStatus()
        } catch {
            await updateStatus(error.localizedDescription, success: false)
        }
    }

    func clearKey() async {
        do {
            try keychainStore.clearKey()
            await MainActor.run {
                self.apiKey = ""
                self.keyExists = false
            }
            await updateStatus(
                NSLocalizedString("soniox_key_cleared", comment: ""),
                success: true
            )
        } catch {
            await updateStatus(error.localizedDescription, success: false)
        }
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
        } catch {
            await MainActor.run {
                self.keyExists = false
            }
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
