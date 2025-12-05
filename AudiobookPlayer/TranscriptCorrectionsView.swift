import SwiftUI

/// Full-page view for managing transcript corrections with List-based multi-selection
struct TranscriptCorrectionsView: View {
    let trackId: String
    let trackName: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.editMode) private var editMode
    @StateObject private var viewModel = TranscriptCorrectionViewModel()
    @State private var selectedIDs: Set<String> = []
    @State private var showAddForm = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        List(selection: $selectedIDs) {
            // Add correction section
            Section {
                if showAddForm {
                    addCorrectionForm
                } else {
                    Button {
                        withAnimation { showAddForm = true }
                    } label: {
                        Label("Add Correction", systemImage: "plus.circle.fill")
                    }
                }
            }

            // Corrections list section
            Section {
                if viewModel.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if viewModel.corrections.isEmpty {
                    ContentUnavailableView(
                        "No Corrections",
                        systemImage: "text.badge.checkmark",
                        description: Text("Add corrections to fix recurring transcript errors")
                    )
                } else {
                    ForEach(viewModel.corrections) { correction in
                        CorrectionRowView(
                            correction: correction,
                            onApply: {
                                Task { await viewModel.applyCorrection(correctionId: correction.id) }
                            },
                            onUnapply: {
                                Task { await viewModel.unapplyCorrection(correctionId: correction.id) }
                            }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await viewModel.deleteCorrection(correctionId: correction.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if correction.isApplied {
                                Button {
                                    Task { await viewModel.unapplyCorrection(correctionId: correction.id) }
                                } label: {
                                    Label("Undo", systemImage: "arrow.uturn.backward")
                                }
                                .tint(.orange)
                            } else {
                                Button {
                                    Task { await viewModel.applyCorrection(correctionId: correction.id) }
                                } label: {
                                    Label("Apply", systemImage: "checkmark")
                                }
                                .tint(.green)
                            }
                        }
                    }
                }
            } header: {
                if !viewModel.corrections.isEmpty {
                    Text("\(viewModel.corrections.count) corrections")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Corrections")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !viewModel.corrections.isEmpty {
                    HStack(spacing: 8) {
                        // Apply All button - only show if there are unapplied corrections
                        if viewModel.corrections.contains(where: { !$0.isApplied }) {
                            Button {
                                Task { await viewModel.applyAllCorrections() }
                            } label: {
                                Label("Apply All", systemImage: "checkmark.circle.fill")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.green)
                        }

                        EditButton()
                    }
                }
            }

            ToolbarItem(placement: .bottomBar) {
                if editMode?.wrappedValue.isEditing == true && !selectedIDs.isEmpty {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete \(selectedIDs.count)", systemImage: "trash")
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete \(selectedIDs.count) corrections?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    for id in selectedIDs {
                        await viewModel.deleteCorrection(correctionId: id)
                    }
                    selectedIDs.removeAll()
                    editMode?.wrappedValue = .inactive
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onAppear {
            viewModel.setTrackId(trackId)
        }
    }

    // MARK: - Add Correction Form

    private var addCorrectionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add New Correction")
                .font(.subheadline)
                .fontWeight(.semibold)

            TextField("Incorrect text", text: $viewModel.incorrectText)
                .textFieldStyle(.roundedBorder)

            TextField("Correct text", text: $viewModel.correctText)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") {
                    viewModel.clearForm()
                    withAnimation { showAddForm = false }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Add") {
                    Task {
                        await viewModel.addCustomCorrection(
                            incorrectText: viewModel.incorrectText,
                            correctText: viewModel.correctText
                        )
                        viewModel.clearForm()
                        withAnimation { showAddForm = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.incorrectText.isEmpty || viewModel.correctText.isEmpty)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Correction Row View

private struct CorrectionRowView: View {
    let correction: TranscriptCorrection
    let onApply: () -> Void
    let onUnapply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Correction text
            HStack(spacing: 6) {
                Text(correction.incorrectText)
                    .font(.subheadline)
                    .foregroundStyle(correction.isApplied ? .secondary : .primary)
                    .strikethrough(correction.isApplied)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(correction.correctText)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }

            // Status row
            HStack(spacing: 8) {
                if correction.isApplied {
                    Label("Applied", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("Not applied", systemImage: "circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let appliedAt = correction.appliedAt {
                    Text(appliedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // Quick action button
                Button {
                    if correction.isApplied {
                        onUnapply()
                    } else {
                        onApply()
                    }
                } label: {
                    Text(correction.isApplied ? "Undo" : "Apply")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        TranscriptCorrectionsView(
            trackId: "preview-track-id",
            trackName: "Sample Track"
        )
    }
}
