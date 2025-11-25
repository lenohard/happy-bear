import SwiftUI

struct TranscriptCorrectionsCard: View {
    let track: AudiobookTrack
    @StateObject private var viewModel = TranscriptCorrectionViewModel()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Label("Transcript Corrections", systemImage: "text.badge.checkmark")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button {
                    viewModel.showAddForm.toggle()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
            }
            
            // Error message
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            
            // Add form
            if viewModel.showAddForm {
                addCorrectionForm
            }
            
            // Corrections list
            if viewModel.corrections.isEmpty && !viewModel.isLoading {
                Text("No corrections available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.corrections) { correction in
                    correctionRow(correction)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .onAppear {
            viewModel.setTrackId(track.id.uuidString)
        }
    }
    
    private var addCorrectionForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Incorrect text", text: $viewModel.incorrectText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            
            TextField("Correct text", text: $viewModel.correctText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            
            HStack {
                Button("Cancel") {
                    viewModel.clearForm()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button("Add") {
                    Task {
                        await viewModel.addCustomCorrection(
                            incorrectText: viewModel.incorrectText,
                            correctText: viewModel.correctText
                        )
                        viewModel.clearForm()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.incorrectText.isEmpty || viewModel.correctText.isEmpty)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))
        )
    }
    
    private func correctionRow(_ correction: TranscriptCorrection) -> some View {
        HStack(alignment: .center, spacing: 8) {
            // Status badge
            Image(systemName: correction.isApplied ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(correction.isApplied ? .green : .secondary)
            
            // Correction text
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(correction.incorrectText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .strikethrough(correction.isApplied)
                    
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    Text(correction.correctText)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                
                if correction.isApplied, let appliedAt = correction.appliedAt {
                    Text("Applied \(appliedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Actions
            if correction.isApplied {
                Button {
                    Task {
                        await viewModel.unapplyCorrection(correctionId: correction.id)
                    }
                } label: {
                    Text("Undo")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            } else {
                Button {
                    Task {
                        await viewModel.applyCorrection(correctionId: correction.id)
                    }
                } label: {
                    Text("Apply")
                        .font(.caption2)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task {
                    await viewModel.deleteCorrection(correctionId: correction.id)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
