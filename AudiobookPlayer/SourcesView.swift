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

                    Spacer()

                    Button(NSLocalizedString("close_button", comment: "Close button"), role: .cancel) { selectedNetdiskEntry = nil }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.borderedProminent)
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
                onComplete: { collection in
                    // Optionally load the collection immediately
                    audioPlayer.loadCollection(collection)
                }
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
                                selectedNetdiskEntry = entry
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
}

#Preview {
    SourcesView()
        .environmentObject(AudioPlayerViewModel())
        .environmentObject(BaiduAuthViewModel())
}
