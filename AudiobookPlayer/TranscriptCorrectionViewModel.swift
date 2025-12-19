import Foundation

@MainActor
final class TranscriptCorrectionViewModel: ObservableObject {
    @Published private(set) var corrections: [TranscriptCorrection] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    
    // Form state (public for binding)
    @Published var incorrectText = ""
    @Published var correctText = ""
    @Published var showAddForm = false
    
    private let dbManager: GRDBDatabaseManager
    private var currentTrackId: String?
    
    init(dbManager: GRDBDatabaseManager = .shared) {
        self.dbManager = dbManager
    }
    
    func setTrackId(_ trackId: String?) {
        guard trackId != currentTrackId else { return }
        currentTrackId = trackId
        Task { await loadCorrections() }
    }
    
    func loadCorrections(showLoading: Bool = true) async {
        guard let trackId = currentTrackId else {
            corrections = []
            return
        }
        
        if showLoading {
            isLoading = true
        }
        errorMessage = nil
        
        do {
            corrections = try await dbManager.loadTranscriptCorrections(trackId: trackId)
        } catch {
            errorMessage = error.localizedDescription
            corrections = []
        }
        
        if showLoading {
            isLoading = false
        }
    }
    
    /// Apply a correction to all transcript segments
    func applyCorrection(correctionId: String) async {
        guard let correction = corrections.first(where: { $0.id == correctionId }),
              !correction.isApplied,
              let trackId = currentTrackId else {
            return
        }
        
        errorMessage = nil
        
        do {
            // Apply the correction to transcript segments and mark as applied
            try await dbManager.applyTranscriptCorrectionsBatch(
                trackId: trackId,
                corrections: [(id: correction.id, incorrect: correction.incorrectText, correct: correction.correctText)]
            )
            
            // Reload corrections to update UI
            await loadCorrections(showLoading: false)
            
        } catch {
            errorMessage = "Failed to apply correction: \(error.localizedDescription)"
        }
    }
    
    /// Unapply a correction (revert to original text)
    func unapplyCorrection(correctionId: String) async {
        guard let correction = corrections.first(where: { $0.id == correctionId }),
              correction.isApplied,
              let trackId = currentTrackId else {
            return
        }
        
        errorMessage = nil
        
        do {
            // Reverse the correction: swap incorrect/correct
            try await dbManager.applyTextReplacements(
                trackId: trackId,
                replacements: [(from: correction.correctText, to: correction.incorrectText)]
            )
            
            // Mark correction as not applied
            try await dbManager.updateTranscriptCorrectionStatus(id: correctionId, isApplied: false)
            
            // Reload corrections to update UI
            await loadCorrections(showLoading: false)
            
        } catch {
            errorMessage = "Failed to unapply correction: \(error.localizedDescription)"
        }
    }
    
    /// Add a custom correction
    func addCustomCorrection(incorrectText: String, correctText: String) async {
        guard let trackId = currentTrackId else { return }
        
        let trimmedIncorrect = incorrectText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCorrect = correctText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedIncorrect.isEmpty, !trimmedCorrect.isEmpty else {
            errorMessage = "Both fields are required"
            return
        }
        
        errorMessage = nil
        
        do {
            _ = try await dbManager.addTranscriptCorrection(
                trackId: trackId,
                incorrectText: trimmedIncorrect,
                correctText: trimmedCorrect
            )
            
            await loadCorrections(showLoading: false)
        } catch {
            errorMessage = "Failed to add correction: \(error.localizedDescription)"
        }
    }
    
    /// Delete a correction
    func deleteCorrection(correctionId: String) async {
        errorMessage = nil

        do {
            try await dbManager.deleteTranscriptCorrection(id: correctionId)
            await loadCorrections(showLoading: false)
        } catch {
            errorMessage = "Failed to delete correction: \(error.localizedDescription)"
        }
    }

    /// Apply all unapplied corrections
    func applyAllCorrections() async {
        let unappliedCorrections = corrections.filter { !$0.isApplied }
        guard !unappliedCorrections.isEmpty, let trackId = currentTrackId else { return }

        isLoading = true
        errorMessage = nil

        do {
            let batch = unappliedCorrections.map { ($0.id, $0.incorrectText, $0.correctText) }
            try await dbManager.applyTranscriptCorrectionsBatch(trackId: trackId, corrections: batch)
            
            await loadCorrections(showLoading: false)
        } catch {
            errorMessage = "Failed to apply corrections: \(error.localizedDescription)"
        }

        isLoading = false
    }

    /// Apply a specific set of corrections (by ID)
    func applyCorrections(ids: Set<String>) async {
        guard !ids.isEmpty, let trackId = currentTrackId else { return }
        
        // Filter for corrections that exist, match IDs, and are NOT already applied
        let targets = corrections.filter { ids.contains($0.id) && !$0.isApplied }
        guard !targets.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        do {
            let batch = targets.map { ($0.id, $0.incorrectText, $0.correctText) }
            try await dbManager.applyTranscriptCorrectionsBatch(trackId: trackId, corrections: batch)
            
            await loadCorrections(showLoading: false)
        } catch {
            errorMessage = "Failed to apply selected corrections: \(error.localizedDescription)"
        }

        isLoading = false
    }
    
    /// Clear the add form
    func clearForm() {
        incorrectText = ""
        correctText = ""
        showAddForm = false
    }
}

// MARK: - Error Types

enum TranscriptCorrectionError: LocalizedError {
    case transcriptNotFound
    
    var errorDescription: String? {
        switch self {
        case .transcriptNotFound:
            return "Transcript not found for this track"
        }
    }
}
