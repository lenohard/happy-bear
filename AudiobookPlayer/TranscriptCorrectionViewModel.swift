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
            // Apply the correction to transcript segments
            try await applyCorrection(
                trackId: trackId,
                incorrectText: correction.incorrectText,
                correctText: correction.correctText
            )
            
            // Mark correction as applied
            try await dbManager.updateTranscriptCorrectionStatus(id: correctionId, isApplied: true)
            
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
            try await applyCorrection(
                trackId: trackId,
                incorrectText: correction.correctText,  // Swap
                correctText: correction.incorrectText   // Swap
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
        guard !unappliedCorrections.isEmpty else { return }

        errorMessage = nil

        for correction in unappliedCorrections {
            do {
                try await applyCorrection(
                    trackId: currentTrackId ?? "",
                    incorrectText: correction.incorrectText,
                    correctText: correction.correctText
                )

                try await dbManager.updateTranscriptCorrectionStatus(id: correction.id, isApplied: true)
            } catch {
                errorMessage = "Failed to apply correction '\(correction.incorrectText)': \(error.localizedDescription)"
                break
            }
        }

        await loadCorrections(showLoading: false)
    }
    
    /// Clear the add form
    func clearForm() {
        incorrectText = ""
        correctText = ""
        showAddForm = false
    }
    
    // MARK: - Private Helpers
    
    /// Apply a text correction to all transcript segments for a track
    private func applyCorrection(
        trackId: String,
        incorrectText: String,
        correctText: String
    ) async throws {
        try await dbManager.initializeDatabase()
        
        // Load all segments for this track
        guard let transcript = try await dbManager.loadTranscript(forTrackId: trackId) else {
            throw TranscriptCorrectionError.transcriptNotFound
        }
        
        let segments = try await dbManager.loadSortedTranscriptSegments(transcriptId: transcript.id)
        
        var updatedCount = 0
        
        // Update segments that contain the incorrect text
        for segment in segments {
            if segment.text.contains(incorrectText) {
                let updatedText = segment.text.replacingOccurrences(
                    of: incorrectText,
                    with: correctText
                )
                
                // Update segment in database
                try await dbManager.updateTranscriptSegmentText(
                    segmentId: segment.id,
                    newText: updatedText
                )
                
                updatedCount += 1
            }
        }
        
        // Update the full_text in the transcript record
        if updatedCount > 0 {
            try await dbManager.rebuildTranscriptFullText(transcriptId: transcript.id)
        }
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
