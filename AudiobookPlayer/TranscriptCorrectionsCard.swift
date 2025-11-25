import SwiftUI

struct TranscriptCorrectionsCard: View {
    let track: AudiobookTrack
    @StateObject private var viewModel = TranscriptCorrectionViewModel()
    @State private var isExpanded = false
    @State private var isSelectionMode = false
    @State private var selectedIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Label("Transcript Corrections", systemImage: "text.badge.checkmark")
                            .font(.headline)
                            .fontWeight(.semibold)

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if isExpanded {
                    HStack(spacing: 8) {
                        if !viewModel.corrections.isEmpty {
                            Button {
                                withAnimation {
                                    isSelectionMode.toggle()
                                    if !isSelectionMode {
                                        selectedIDs.removeAll()
                                    }
                                }
                            } label: {
                                Text(isSelectionMode ? "Done" : "Edit")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            viewModel.showAddForm.toggle()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Error message
            if isExpanded {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                // Selection toolbar
                if isSelectionMode && !viewModel.corrections.isEmpty {
                    HStack {
                        Button {
                            if selectedIDs.count == viewModel.corrections.count {
                                selectedIDs.removeAll()
                            } else {
                                selectedIDs = Set(viewModel.corrections.map { $0.id })
                            }
                        } label: {
                            Text(selectedIDs.count == viewModel.corrections.count ? "Deselect All" : "Select All")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()

                        if !selectedIDs.isEmpty {
                            Button(role: .destructive) {
                                Task {
                                    for id in selectedIDs {
                                        await viewModel.deleteCorrection(correctionId: id)
                                    }
                                    selectedIDs.removeAll()
                                }
                            } label: {
                                Text("Delete (\(selectedIDs.count))")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
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
            // Selection checkbox / Status badge
            Button {
                if isSelectionMode {
                    withAnimation {
                        if selectedIDs.contains(correction.id) {
                            selectedIDs.remove(correction.id)
                        } else {
                            selectedIDs.insert(correction.id)
                        }
                    }
                }
            } label: {
                if isSelectionMode {
                    Image(systemName: selectedIDs.contains(correction.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selectedIDs.contains(correction.id) ? .blue : .secondary)
                } else {
                    Image(systemName: correction.isApplied ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(correction.isApplied ? .green : .secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!isSelectionMode)

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

            // Action buttons (only show when not in selection mode)
            if !isSelectionMode {
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
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))
        )
    }
}
