import SwiftUI

struct SettingsTabView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink(destination: CacheManagementView()) {
                    HStack {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(.tint)
                        Text(NSLocalizedString("cache_management_row_title", comment: "Cache Management row in Settings"))
                    }
                }
            }
            .navigationTitle(NSLocalizedString("settings_tab", comment: "Settings tab"))
        }
    }
}

#Preview {
    SettingsTabView()
        .environmentObject(AudioPlayerViewModel())
}
