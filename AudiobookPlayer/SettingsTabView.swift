import SwiftUI

// Helper struct for making String identifiable for sheet presentation
private struct IdentifiableString: Identifiable {
    let id = UUID()
    let value: String
}

struct SettingsTabView: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    @State private var selectedNetdiskEntry: BaiduNetdiskEntry?
    @State private var showingBaiduImport = false
    @State private var importFromPath: String?
    @State private var directPlayError: IdentifiableString?

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
    }
}

private extension SettingsTabView {
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
}

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
}
