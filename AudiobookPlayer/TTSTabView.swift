import SwiftUI

struct TTSTabView: View {
    @StateObject private var sonioxViewModel = SonioxKeyViewModel()
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var library: LibraryStore
    @FocusState private var isKeyFieldFocused: Bool
    @State private var isTestInProgress = false
    @State private var testResult: String?
    @State private var testError: String?
    @State private var showSonioxKey = false
    @State private var isEditingSonioxKey = false
    @State private var jobActionError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    sonioxKeyRow
                        .modifier(CredentialRowModifier(alignment: .leading))
                } header: {
                    Label(NSLocalizedString("soniox_section_title", comment: ""), systemImage: "waveform")
                        .font(.headline)
                }

                if sonioxViewModel.keyExists {
                    Section {
                        Button(action: { Task { await testTranscription() } }) {
                            if isTestInProgress {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8, anchor: .center)
                                    Text("Testing transcription...")
                                }
                            } else {
                                Label("Test with sample audio", systemImage: "play.circle")
                            }
                        }
                        .disabled(isTestInProgress)

                        if let error = testError {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Test Failed", systemImage: "exclamationmark.triangle")
                                    .font(.footnote)
                                    .foregroundColor(.red)
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }

                        if let result = testResult {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Transcription Result", systemImage: "checkmark.circle")
                                    .font(.footnote)
                                    .foregroundColor(.green)
                                Text(result)
                                    .font(.caption)
                                    .lineLimit(5)
                                    .truncationMode(.tail)
                            }
                        }
                    } header: {
                        Text("Test Soniox API")
                    }

                    // Quick Access Section
                    Section {
                        NavigationLink {
                            TTSJobsListView()
                        } label: {
                            Label("Transcription Jobs", systemImage: "list.bullet.clipboard")
                        }
                        
                        NavigationLink {
                            SonioxFilesListView()
                        } label: {
                            Label(NSLocalizedString("tts_files_section_label", comment: ""), systemImage: "folder")
                        }
                    } header: {
                        Text("Quick Access")
                            .font(.headline)
                    }
                }
            }
            .navigationTitle(Text(NSLocalizedString("tts_tab_title", comment: "")))
            .task {
                // Reload key status when view appears
                await sonioxViewModel.refreshKeyStatus()
                // Load all recent jobs
                await transcriptionManager.refreshAllRecentJobs()
            }
            .refreshable {
                await transcriptionManager.refreshAllRecentJobs()
            }
            .alert(isPresented: Binding(
                get: { jobActionError != nil },
                set: { if !$0 { jobActionError = nil } }
            )) {
                Alert(
                    title: Text(NSLocalizedString("tts_jobs_action_error_title", comment: "")),
                    message: Text(jobActionError ?? ""),
                    dismissButton: .default(Text(NSLocalizedString("ok_button", comment: "OK button")))
                )
            }
            .onAppear {
                isEditingSonioxKey = !sonioxViewModel.keyExists
            }
            .onChange(of: sonioxViewModel.keyExists) { exists in
                isEditingSonioxKey = !exists
            }
            .onChange(of: sonioxViewModel.statusMessage) { _ in
                if sonioxViewModel.isSuccess {
                    isEditingSonioxKey = false
                    showSonioxKey = false
                }
            }
            .onChange(of: isKeyFieldFocused) { isFocused in
                if !isFocused && isEditingSonioxKey {
                    // Auto-save when losing focus
                    let pendingKey = sonioxViewModel.apiKey
                    if !pendingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Task { await sonioxViewModel.saveKey(using: pendingKey) }
                    }
                }
            }
        }
    }

    private var shouldShowSonioxKeyInput: Bool {
        isEditingSonioxKey || !sonioxViewModel.keyExists
    }

    private var sonioxKeyRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if shouldShowSonioxKeyInput {
                    sonioxKeyInputField
                } else if !sonioxViewModel.storedKeyValue.isEmpty {
                    Button(action: {
                        sonioxViewModel.apiKey = sonioxViewModel.storedKeyValue
                        isEditingSonioxKey = true
                        isKeyFieldFocused = true
                    }) {
                        HStack {
                            Text(maskedSonioxKey(sonioxViewModel.storedKeyValue))
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(NSLocalizedString("soniox_key_placeholder", comment: ""))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { showSonioxKey.toggle() }) {
                Image(systemName: showSonioxKey ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var sonioxKeyInputField: some View {
        HStack(spacing: 8) {
            Group {
                if showSonioxKey {
                    TextField(NSLocalizedString("soniox_key_placeholder", comment: ""), text: $sonioxViewModel.apiKey)
                } else {
                    SecureField(NSLocalizedString("soniox_key_placeholder", comment: ""), text: $sonioxViewModel.apiKey)
                }
            }
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .focused($isKeyFieldFocused)
            
            if isEditingSonioxKey && sonioxViewModel.keyExists {
                Button(action: {
                    isEditingSonioxKey = false
                    sonioxViewModel.apiKey = ""
                    isKeyFieldFocused = false
                    showSonioxKey = false
                    resignFirstResponder()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggleSonioxEditing() {
        guard sonioxViewModel.keyExists else { return }

        if isEditingSonioxKey {
            isEditingSonioxKey = false
            sonioxViewModel.apiKey = ""
            isKeyFieldFocused = false
            showSonioxKey = false
            resignFirstResponder()
        } else {
            sonioxViewModel.apiKey = sonioxViewModel.storedKeyValue
            isEditingSonioxKey = true
            isKeyFieldFocused = true
        }
    }

    private func maskedSonioxKey(_ apiKey: String) -> String {
        if showSonioxKey {
            return apiKey
        }
        guard apiKey.count > 8 else { return String(repeating: "•", count: apiKey.count) }
        let prefix = String(apiKey.prefix(4))
        let suffix = String(apiKey.suffix(4))
        return "\(prefix)...\(suffix)"
    }
    
    private func testTranscription() async {
        isTestInProgress = true
        testError = nil
        testResult = nil

        do {
            // Get the API key from keychain
            let keychainStore: SonioxAPIKeyStore = KeychainSonioxAPIKeyStore()
            guard let apiKey = try keychainStore.loadKey() else {
                throw SonioxAPI.APIError.missingAPIKey
            }

            let api = SonioxAPI(apiKey: apiKey)

            // Get the test audio file from the app bundle
            let fileManager = FileManager.default
            let documentURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let testAudioURL = documentURL.appendingPathComponent("test-1min.mp3")

            // Check if file exists, if not try the app bundle, then try the project root
            let audioFileURL: URL
            if fileManager.fileExists(atPath: testAudioURL.path) {
                audioFileURL = testAudioURL
            } else if let bundleResourceURL = Bundle.main.url(forResource: "test-1min", withExtension: "mp3") {
                audioFileURL = bundleResourceURL
            } else {
                // Try the app directory if available (for development)
                if let appBundleURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("test-1min.mp3") as URL?,
                   fileManager.fileExists(atPath: appBundleURL.path) {
                    audioFileURL = appBundleURL
                } else {
                    throw SonioxAPI.APIError.fileUploadFailed
                }
            }

            // Upload the audio file
            let fileId = try await api.uploadFile(fileURL: audioFileURL)

            // Create transcription job
            let transcriptionId = try await api.createTranscription(
                fileId: fileId,
                languageHints: ["zh", "en"]
            )

            // Poll for completion (with timeout)
            var attempts = 0
            let maxAttempts = 120  // 2 minutes with 1 second polling
            while attempts < maxAttempts {
                let status = try await api.checkTranscriptionStatus(transcriptionId: transcriptionId)

                if status.status == "completed" {
                    // Get the transcript
                    let transcript = try await api.getTranscript(transcriptionId: transcriptionId)

                    // Extract text from tokens
                    let fullText = transcript.tokens
                        .map { $0.text }
                        .joined(separator: " ")

                    await MainActor.run {
                        testResult = fullText.isEmpty ? "(Empty transcript)" : fullText
                        isTestInProgress = false
                    }
                    return
                } else if status.status == "error" {
                    throw SonioxAPI.APIError.transcriptionFailed(message: status.error_message ?? "Unknown error")
                }

                // Wait before polling again
                try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
                attempts += 1
            }

            throw SonioxAPI.APIError.transcriptionFailed(message: "Transcription timeout after 2 minutes")

        } catch {
            await MainActor.run {
                testError = error.localizedDescription
                isTestInProgress = false
            }
        }
    }
}

private struct CredentialRowModifier: ViewModifier {
    var alignment: Alignment = .leading

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: alignment)
            .padding(.vertical, 8)
            .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
    }
}

struct SonioxFilesListView: View {
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @State private var files: [SonioxFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var deletingFileIDs: Set<String> = []

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else if files.isEmpty {
                Text(NSLocalizedString("tts_files_empty_state", comment: ""))
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(files) { file in
                    fileRow(for: file)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(NSLocalizedString("tts_files_view_title", comment: "")))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await loadFiles() }
                } label: {
                    Label(NSLocalizedString("tts_files_refresh_button", comment: ""), systemImage: "arrow.clockwise")
                }
            }
        }
        .task { await loadFiles() }
        .refreshable { await loadFiles() }
    }

    private func fileRow(for file: SonioxFile) -> some View {
        let sizeDescription = sizeText(for: file)
        return VStack(alignment: .leading, spacing: 4) {
            Text(file.displayName)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                if let sizeDescription {
                    Text(sizeDescription)
                }
                if sizeDescription != nil && file.createdAt != nil {
                    Text("•")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if let createdAt = file.createdAt {
                    Text(Self.fileDateFormatter.string(from: createdAt))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if deletingFileIDs.contains(file.id) {
                Button {
                } label: {
                    ProgressView()
                }
                .disabled(true)
            } else {
                Button(role: .destructive) {
                    Task { await deleteFile(file) }
                } label: {
                    Label(NSLocalizedString("tts_files_delete_action", comment: ""), systemImage: "trash")
                }
            }
        }
    }

    @MainActor
    private func loadFiles() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        files = []
        defer { isLoading = false }

        transcriptionManager.reloadSonioxAPIKey()
        guard let api = transcriptionManager.sonioxAPI else {
            errorMessage = NSLocalizedString("tts_files_no_key_message", comment: "")
            return
        }

        do {
            let fetched = try await api.listFiles()
            files = fetched.sorted(by: {
                let lhs = $0.createdAt ?? .distantPast
                let rhs = $1.createdAt ?? .distantPast
                return lhs > rhs
            })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deleteFile(_ file: SonioxFile) async {
        deletingFileIDs.insert(file.id)
        defer { deletingFileIDs.remove(file.id) }

        transcriptionManager.reloadSonioxAPIKey()
        guard let api = transcriptionManager.sonioxAPI else {
            errorMessage = NSLocalizedString("tts_files_no_key_message", comment: "")
            return
        }

        do {
            try await api.deleteFile(fileId: file.id)
            files.removeAll { $0.id == file.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sizeText(for file: SonioxFile) -> String? {
        guard let bytes = file.sizeBytes else { return nil }
        return Self.fileSizeFormatter.string(fromByteCount: Int64(bytes))
    }

    private static let fileSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
