import SwiftUI

struct CacheManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel

    @State private var retentionDays: Int = 0
    @State private var showClearAllConfirmation = false

    var body: some View {
        Form {
            Section(NSLocalizedString("cache_storage_section", comment: "Storage section title")) {
                HStack {
                    Text(NSLocalizedString("cache_total_size", comment: "Total cache size label"))
                    Spacer()
                    Text(audioPlayer.formattedCacheSize())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("cache_folder", comment: "Cache folder label"))
                    Text(audioPlayer.cacheDirectoryPath())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Stepper(value: $retentionDays, in: 1...30, step: 1) {
                    Text(String(format: NSLocalizedString("cache_retention_days", comment: "Cache retention days format"), retentionDays, retentionDays == 1 ? NSLocalizedString("cache_day", comment: "Day") : NSLocalizedString("cache_days", comment: "Days")))
                }
                .onChange(of: retentionDays) { newValue in
                    audioPlayer.updateCacheRetention(days: newValue)
                }

                Button(role: .destructive) {
                    showClearAllConfirmation = true
                } label: {
                    Label(NSLocalizedString("cache_clear_all", comment: "Clear all cached audio"), systemImage: "trash.slash")
                }
            }
        }
        .navigationTitle(NSLocalizedString("cache_settings_title", comment: "Cache settings title"))
        .confirmationDialog(NSLocalizedString("cache_clear_all_title", comment: "Clear cached audio confirmation title"), isPresented: $showClearAllConfirmation, titleVisibility: .visible) {
            Button(NSLocalizedString("cache_clear_all_confirm", comment: "Delete all cached audio button"), role: .destructive) {
                audioPlayer.clearAllCache()
            }
            Button(NSLocalizedString("cancel_button", comment: "Cancel button"), role: .cancel) { }
        } message: {
            Text(NSLocalizedString("cache_clear_all_message", comment: "Clear all cached audio confirmation message"))
        }
        .onAppear {
            retentionDays = audioPlayer.cacheRetentionDays()
        }
    }
}

#Preview {
    NavigationStack {
        CacheManagementView()
            .environmentObject(AudioPlayerViewModel())
    }
}
