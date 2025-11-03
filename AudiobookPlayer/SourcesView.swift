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
                }
                .padding()
            }
            .navigationTitle("Sources")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            if authViewModel.token != nil {
                                showingBaiduImport = true
                            }
                        } label: {
                            Label("Baidu Netdisk", systemImage: "icloud.and.arrow.down")
                        }
                        .disabled(authViewModel.token == nil)

                        Button {
                            // Placeholder for future import sources
                        } label: {
                            Label("Local Files (Coming Soon)", systemImage: "folder")
                        }
                        .disabled(true)
                    } label: {
                        Label("Import", systemImage: "plus.circle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .menuStyle(.button)
                }
            }
        }
        .sheet(item: $selectedNetdiskEntry) { entry in
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    Label("File Details", systemImage: "doc.text.magnifyingglass")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.serverFilename)
                            .font(.title3)
                            .bold()

                        Text(entry.path)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }

                    Text("Select \"Close\" and use the toolbar actions in the browser to download or stream once implemented.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Close", role: .cancel) { selectedNetdiskEntry = nil }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                .navigationTitle("Netdisk File")
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
    var baiduAuthSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Baidu Cloud Sign-In", systemImage: "icloud.and.arrow.down")
                    .font(.headline)

                Text("Connect your Baidu Netdisk account to browse and download audiobooks.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if let token = authViewModel.token {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Access token acquired.")
                            .font(.subheadline)
                            .bold()

                        if let scope = token.scope, !scope.isEmpty {
                            Text("Scopes: \(scope)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Text("Expires \(token.formattedExpiry)")
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
                        Label("Browse Baidu Netdisk", systemImage: "folder.badge.gear")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        authViewModel.signOut()
                    } label: {
                        Label("Sign Out", systemImage: "arrow.uturn.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        authViewModel.signIn()
                    } label: {
                        Label("Sign in with Baidu", systemImage: "person.crop.circle.badge.checkmark")
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
