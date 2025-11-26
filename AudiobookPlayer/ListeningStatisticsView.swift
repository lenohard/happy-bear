import SwiftUI

struct ListeningStatisticsView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var summary: ListeningStatisticsSummary?
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading statistics...")
            } else if let errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    Text(errorMessage)
                        .foregroundColor(.secondary)
                }
                .padding()
            } else if let summary {
                statisticsContent(summary)
            }
        }
        .navigationTitle("Listening Statistics")
        .task {
            await loadStatistics()
        }
    }
    
    @ViewBuilder
    private func statisticsContent(_ summary: ListeningStatisticsSummary) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Total Listening Time")
                        .font(.headline)
                    Text(formatDuration(summary.totalDuration))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundColor(.accentColor)
                }
                .padding(.vertical, 8)
            }
            
            if !summary.collectionDurations.isEmpty {
                Section("By Collection") {
                    ForEach(sortedCollectionDurations(summary.collectionDurations), id: \.0) { collectionId, duration in
                        if let collection = library.collections.first(where: { $0.id == collectionId }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(collection.title)
                                        .font(.headline)
                                    if let author = collection.author {
                                        Text(author)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Text(formatDuration(duration))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func sortedCollectionDurations(_ durations: [UUID: TimeInterval]) -> [(UUID, TimeInterval)] {
        durations.sorted { $0.value > $1.value }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
    
    private func loadStatistics() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let totalDuration = try await GRDBDatabaseManager.shared.loadTotalListeningDuration()
            let collectionDurations = try await GRDBDatabaseManager.shared.loadListeningDurationsByCollection()
            
            let loadedSummary = ListeningStatisticsSummary(
                totalDuration: totalDuration,
                collectionDurations: collectionDurations
            )
            
            await MainActor.run {
                self.summary = loadedSummary
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to load statistics: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
}
