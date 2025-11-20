import SwiftUI
import UniformTypeIdentifiers

// Helper struct for making String identifiable for sheet presentation
private struct IdentifiableString: Identifiable {
    let id = UUID()
    let value: String
}

struct SettingsTabView: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var aiGateway: AIGatewayViewModel
    @AppStorage("floatingBubbleOpacity") private var floatingBubbleOpacity: Double = 0.5
    @State private var selectedNetdiskEntry: BaiduNetdiskEntry?
    @State private var showingBaiduImport = false
    @State private var importFromPath: String?
    @State private var directPlayError: IdentifiableString?
    @State private var includeCredentials = false
    @State private var isExportingBackup = false
    @State private var isImportingBackup = false
    @State private var exportSummaryText: String?
    @State private var importSummaryText: String?
    @State private var backupError: IdentifiableString?
    @State private var shareURL: URL?
    @State private var showingShareSheet = false
    @State private var showingImportPicker = false

    private let backupManager = UserDataBackupManager()

    private let playableExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "flac", "wav", "ogg", "opus"]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(destination: CacheManagementView()) {
                        HStack {
                            Image(systemName: "internaldrive")
                                .foregroundStyle(.tint)
                            Text(NSLocalizedString("cache_management_row_title", comment: "Cache Management row in Settings"))
                        }
                    }
                }
                
                Section {
                    HStack {
                        Image(systemName: "pip.enter")
                            .foregroundStyle(.tint)
                        Toggle(NSLocalizedString("floating_bubble_settings_title", comment: "Floating bubble settings title"), isOn: Binding(
                            get: { UserDefaults.standard.bool(forKey: "floatingBubbleEnabled") },
                            set: { UserDefaults.standard.set($0, forKey: "floatingBubbleEnabled") }
                        ))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(NSLocalizedString("floating_bubble_opacity_title", comment: "Floating bubble opacity title"))
                            Spacer()
                            Text(String(format: "%d%%", Int(floatingBubbleOpacity * 100)))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $floatingBubbleOpacity, in: 0.2...1.0, step: 0.05)
                        Text(NSLocalizedString("floating_bubble_opacity_description", comment: "Floating bubble opacity description"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(NSLocalizedString("floating_player_section", comment: "Floating player section"))
                }

                backupRestoreSection

                Section {
                    baiduSourcesContent
                }
            }
            .navigationTitle(NSLocalizedString("settings_tab", comment: "Settings tab"))
        }
        .sheet(item: $selectedNetdiskEntry) { entry in
            let canStream = isPlayable(entry)
            NavigationStack {
                SettingsNetdiskEntryDetailSheet(
                    entry: entry,
                    canStream: canStream,
                    onPlay: {
                        guard canStream else { return }
                        selectedNetdiskEntry = nil
                        startDirectPlayback(with: entry)
                    },
                    onSaveParent: {
                        presentSaveFlow(for: entry)
                    }
                )
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(NSLocalizedString("done_button", comment: "Done button")) {
                            selectedNetdiskEntry = nil
                        }
                    }
                }
            }
            .presentationDetents([.fraction(0.7), .large])
        }
        .sheet(isPresented: $showingBaiduImport) {
            NavigationStack {
                BaiduNetdiskBrowserView(
                    tokenProvider: { authViewModel.token },
                    onSelectFolder: { path in
                        importFromPath = path
                        showingBaiduImport = false
                    }
                )
            }
        }
        .sheet(item: Binding(
            get: { importFromPath.map { IdentifiableString(value: $0) } },
            set: { importFromPath = $0?.value }
        )) { identifiablePath in
            CreateCollectionView(
                folderPath: identifiablePath.value,
                tokenProvider: { authViewModel.token },
                onComplete: { _ in
                    // Collection is automatically added to library,
                    // don't interrupt current playback
                }
            )
        }
        .alert(item: $directPlayError) { payload in
            Alert(
                title: Text(NSLocalizedString("error_title", comment: "Error title")),
                message: Text(payload.value),
                dismissButton: .default(Text(NSLocalizedString("ok_button", comment: "OK button")))
            )
        }
        .sheet(isPresented: $showingShareSheet, onDismiss: {
            if let shareURL {
                try? FileManager.default.removeItem(at: shareURL)
            }
            shareURL = nil
        }) {
            if let shareURL {
                ShareSheet(activityItems: [shareURL])
            }
        }
        .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    processBackupImport(url: url)
                }
            case .failure(let error):
                backupError = IdentifiableString(value: error.localizedDescription)
            }
        }
        .alert(item: $backupError) { payload in
            Alert(
                title: Text(NSLocalizedString("error_title", comment: "Error title")),
                message: Text(payload.value),
                dismissButton: .default(Text(NSLocalizedString("ok_button", comment: "OK button")))
            )
        }
    }
}

private extension SettingsTabView {
    @ViewBuilder
    var backupRestoreSection: some View {
        Section {
            backupCard
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
        } header: {
            Label(NSLocalizedString("backup_restore_section_title", comment: "Backup section title"), systemImage: "archivebox")
        }
    }

    private var backupCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(NSLocalizedString("backup_restore_description", comment: "Backup restore description"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $includeCredentials) {
                Text(NSLocalizedString("backup_include_credentials_label", comment: "Include credentials toggle"))
                    .font(.headline)
            }
            .toggleStyle(SwitchToggleStyle(tint: .accentColor))

            if includeCredentials {
                Text(NSLocalizedString("backup_credentials_warning", comment: "Credentials warning"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    startBackupExport()
                } label: {
                    Text(NSLocalizedString("backup_export_button", comment: "Export button"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(BackupPillButtonStyle(kind: .primary))
                .disabled(isExportingBackup)

                exportStatusView
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text(NSLocalizedString("backup_import_warning", comment: "Import warning"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    showingImportPicker = true
                } label: {
                    Text(NSLocalizedString("backup_import_button", comment: "Import button"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(BackupPillButtonStyle(kind: .secondary))
                .disabled(isImportingBackup)

                importStatusView
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(.separator).opacity(0.2))
        )
    }

    @ViewBuilder
    private var exportStatusView: some View {
        if isExportingBackup {
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                Text(NSLocalizedString("backup_exporting_status", comment: "Exporting status"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let summary = exportSummaryText {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var importStatusView: some View {
        if isImportingBackup {
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                Text(NSLocalizedString("backup_importing_status", comment: "Importing status"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let importSummaryText {
            Text(importSummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    var baiduSourcesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(NSLocalizedString("baidu_auth_section", comment: "Baidu auth section title"), systemImage: "icloud.and.arrow.down")
                .font(.headline)

            Text(NSLocalizedString("connect_baidu_message", comment: "Connect Baidu message"))
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let token = authViewModel.token {
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("access_token_acquired", comment: "Access token acquired"))
                        .font(.subheadline)
                        .bold()

                    if let scope = token.scope, !scope.isEmpty {
                        Text(String(format: NSLocalizedString("scopes_label", comment: "Scopes label"), scope))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text(String(format: NSLocalizedString("expires_label", comment: "Expires label"), token.formattedExpiry))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                NavigationLink {
                    BaiduNetdiskBrowserView(
                        tokenProvider: { authViewModel.token },
                        onSelectFile: { entry in
                            handleNetdiskFileSelection(entry)
                        }
                    )
                } label: {
                    Label(NSLocalizedString("browse_baidu_netdisk", comment: "Browse Baidu netdisk"), systemImage: "folder.badge.gear")
                }
                .buttonStyle(.plain)

                Button {
                    authViewModel.signOut()
                } label: {
                    Label(NSLocalizedString("sign_out_button", comment: "Sign out button"), systemImage: "arrow.uturn.left")
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
            } else {
                Button {
                    authViewModel.signIn()
                } label: {
                    Label(NSLocalizedString("sign_in_with_baidu", comment: "Sign in with Baidu"), systemImage: "person.crop.circle.badge.checkmark")
                }
                .buttonStyle(.plain)
                .disabled(authViewModel.isAuthorizing)

                if authViewModel.isAuthorizing {
                    ProgressView("Authorizing…")
                }
            }

            if let error = authViewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    func handleNetdiskFileSelection(_ entry: BaiduNetdiskEntry) {
        selectedNetdiskEntry = entry
    }

    func startDirectPlayback(with entry: BaiduNetdiskEntry) {
        guard isPlayable(entry) else { return }

        guard let token = authViewModel.token else {
            directPlayError = IdentifiableString(value: NSLocalizedString("direct_play_requires_auth", comment: "Direct play requires auth message"))
            return
        }

        audioPlayer.playDirect(entry: entry, token: token)
    }

    func presentSaveFlow(for entry: BaiduNetdiskEntry) {
        let parentPath = parentDirectory(for: entry.path)
        importFromPath = parentPath
        selectedNetdiskEntry = nil
        showingBaiduImport = false
    }

    func isPlayable(_ entry: BaiduNetdiskEntry) -> Bool {
        guard !entry.isDir else { return false }
        let ext = (entry.serverFilename as NSString).pathExtension.lowercased()
        return playableExtensions.contains(ext)
    }

    func parentDirectory(for path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        return directory.isEmpty ? "/" : directory
    }

    func startBackupExport() {
        guard !isExportingBackup else { return }
        isExportingBackup = true
        backupError = nil
        let shouldIncludeCredentials = includeCredentials

        Task {
            do {
                let result = try await backupManager.exportUserData(
                    library: library,
                    options: .init(includeCredentials: shouldIncludeCredentials)
                )
                await MainActor.run {
                    exportSummaryText = exportSummary(from: result.manifest)
                    shareURL = result.archiveURL
                    showingShareSheet = true
                    isExportingBackup = false
                }
            } catch {
                await MainActor.run {
                    isExportingBackup = false
                    backupError = IdentifiableString(value: error.localizedDescription)
                }
            }
        }
    }

    func processBackupImport(url: URL) {
        guard !isImportingBackup else { return }
        isImportingBackup = true
        backupError = nil

        Task {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("HappyBear-Import-\(UUID().uuidString).zip")
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    try FileManager.default.removeItem(at: tempURL)
                }
                try FileManager.default.copyItem(at: url, to: tempURL)

                let result = try await backupManager.importUserData(from: tempURL)
                try? FileManager.default.removeItem(at: tempURL)

                await library.load()
                await transcriptionManager.reloadJobsAfterImport()
                if result.restoredCredentials.soniox {
                    await MainActor.run {
                        transcriptionManager.reloadSonioxAPIKey()
                    }
                }
                await MainActor.run {
                    if result.restoredCredentials.aiGateway {
                        aiGateway.loadStoredKey()
                    }
                    if result.restoredCredentials.baidu {
                        authViewModel.reloadFromStore()
                    }
                }

                await MainActor.run {
                    importSummaryText = importSummary(from: result.manifest)
                    isImportingBackup = false
                }
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                await MainActor.run {
                    isImportingBackup = false
                    backupError = IdentifiableString(value: error.localizedDescription)
                }
            }
        }
    }

    func exportSummary(from manifest: UserDataBackupManager.BackupManifest) -> String {
        String(
            format: NSLocalizedString("backup_export_summary_format", comment: "Export summary format"),
            manifest.counts.collections,
            manifest.counts.tracks
        )
    }

    func importSummary(from manifest: UserDataBackupManager.BackupManifest) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let dateString = formatter.string(from: manifest.exportedAt)
        return String(
            format: NSLocalizedString("backup_import_summary_format", comment: "Import summary format"),
            manifest.counts.collections,
            dateString
        )
    }
}

#if swift(>=5.8)
private struct BackupPillButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(foregroundColor.opacity(isEnabled ? 1 : 0.6))
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                Capsule()
                    .fill(backgroundColor.opacity(configuration.isPressed ? 0.85 : 1))
            )
            .overlay(
                Capsule()
                    .stroke(borderColor, lineWidth: kind == .secondary ? 1 : 0)
            )
            .contentShape(Capsule())
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }

    private var backgroundColor: Color {
        switch kind {
        case .primary:
            return Color.accentColor
        case .secondary:
            return Color(.systemGray5)
        }
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary:
            return .white
        case .secondary:
            return Color.accentColor
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary:
            return .clear
        case .secondary:
            return Color(.systemGray4)
        }
    }
}
#endif

#if canImport(UIKit)
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

private struct SettingsNetdiskEntryDetailSheet: View {
    let entry: BaiduNetdiskEntry
    let canStream: Bool
    let onPlay: () -> Void
    let onSaveParent: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(NSLocalizedString("netdisk_file_title", comment: "Netdisk file sheet title"))
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    Text(entry.serverFilename)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.leading)

                    Text(entry.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )

                if let metadataDescription = metadataDescription {
                    Label(metadataDescription, systemImage: "waveform.path.ecg")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                infoNote
            }
            .padding(.horizontal)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button {
                    guard canStream else { return }
                    onPlay()
                } label: {
                    Label(NSLocalizedString("play_now_button", comment: "Play now button"), systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canStream)

                Button {
                    onSaveParent()
                } label: {
                    Label(NSLocalizedString("save_to_library_button", comment: "Save to library button"), systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .background(.thinMaterial)
        }
    }

    private var metadataDescription: String? {
        let hasSize = entry.size > 0
        let hasDate = entry.serverMtime > 0
        guard hasSize || hasDate else { return nil }

        var segments: [String] = []
        if hasSize {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            segments.append(formatter.string(fromByteCount: entry.size))
        }
        if hasDate {
            let date = Date(timeIntervalSince1970: entry.serverMtime)
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            segments.append(formatter.string(from: date))
        }
        return segments.joined(separator: " • ")
    }

    @ViewBuilder
    private var infoNote: some View {
        let message = canStream
            ? NSLocalizedString("direct_play_sheet_hint", comment: "Direct play hint")
            : NSLocalizedString("unsupported_audio_file_message", comment: "Unsupported audio file message")
        let icon = canStream ? "bolt.horizontal.fill" : "exclamationmark.triangle.fill"
        let tint: Color = canStream ? .accentColor : .orange

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)

            Text(message)
                .font(.callout)
                .foregroundStyle(canStream ? .secondary : tint)
                .multilineTextAlignment(.leading)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

#Preview {
    SettingsTabView()
        .environmentObject(AudioPlayerViewModel())
        .environmentObject(BaiduAuthViewModel())
        .environmentObject(LibraryStore())
        .environmentObject(TranscriptionManager())
        .environmentObject(AIGatewayViewModel())
}
