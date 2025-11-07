import SwiftUI

// Helper struct for making String identifiable for sheet presentation
private struct IdentifiableString: Identifiable {
    let id = UUID()
    let value: String
}

struct SourcesView: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var authViewModel: BaiduAuthViewModel
    @State private var selectedNetdiskEntry: BaiduNetdiskEntry?
    @State private var showingBaiduImport = false
    @State private var importFromPath: String?
    @State private var directPlayError: IdentifiableString?

    private let playableExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "flac", "wav", "ogg", "opus"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    baiduAuthSection
                    localFilesSection
                }
                .padding()
            }
            .navigationTitle(NSLocalizedString("sources_title", comment: "Sources view title"))
        }
        .sheet(item: $selectedNetdiskEntry) { entry in
            let canStream = isPlayable(entry)
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    Label(NSLocalizedString("file_details", comment: "File details"), systemImage: "doc.text.magnifyingglass")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.serverFilename)
                            .font(.title3)
                            .bold()

                        Text(entry.path)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }

                    Text(NSLocalizedString("file_details_hint", comment: "File details hint"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Label(
                        canStream
                            ? NSLocalizedString("direct_play_sheet_hint", comment: "Direct play hint")
                            : NSLocalizedString("unsupported_audio_file_message", comment: "Unsupported audio file message"),
                        systemImage: canStream ? "bolt.horizontal" : "exclamationmark.triangle"
                    )
                    .font(.subheadline)
                    .foregroundStyle(canStream ? .secondary : Color.orange)

                    Spacer()

                    Button {
                        startDirectPlayback(with: entry)
                    } label: {
                        Label(NSLocalizedString("play_now_button", comment: "Play now button"), systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStream)

                    Button {
                        presentSaveFlow(for: entry)
                    } label: {
                        Label(NSLocalizedString("save_to_library_button", comment: "Save to library button"), systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(NSLocalizedString("close_button", comment: "Close button"), role: .cancel) { selectedNetdiskEntry = nil }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.bordered)
                }
                .padding()
                .navigationTitle(NSLocalizedString("netdisk_file_title", comment: "Netdisk file sheet title"))
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { selectedNetdiskEntry = nil }
                    }
                }
            }
            .presentationDetents([.medium])
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

private extension SourcesView {
    @ViewBuilder
    var localFilesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(NSLocalizedString("local_files_section", comment: "Local files section title"), systemImage: "folder")
                    .font(.headline)

                Text(NSLocalizedString("local_files_message", comment: "Local files message"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button {
                    // Placeholder for future local files implementation
                } label: {
                    Label(NSLocalizedString("local_files_coming_soon", comment: "Local files coming soon"), systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    var baiduAuthSection: some View {
        GroupBox {
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
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        authViewModel.signOut()
                    } label: {
                        Label(NSLocalizedString("sign_out_button", comment: "Sign out button"), systemImage: "arrow.uturn.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        authViewModel.signIn()
                    } label: {
                        Label(NSLocalizedString("sign_in_with_baidu", comment: "Sign in with Baidu"), systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(authViewModel.isAuthorizing)

                    if authViewModel.isAuthorizing {
                        ProgressView("Authorizing…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let error = authViewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func handleNetdiskFileSelection(_ entry: BaiduNetdiskEntry) {
        selectedNetdiskEntry = entry

        guard isPlayable(entry) else {
            directPlayError = IdentifiableString(value: NSLocalizedString("unsupported_audio_file_message", comment: "Unsupported audio file message"))
            return
        }

        startDirectPlayback(with: entry)
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

#Preview {
    SourcesView()
        .environmentObject(AudioPlayerViewModel())
        .environmentObject(BaiduAuthViewModel())
}
