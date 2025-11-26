import SwiftUI
import Charts

// MARK: - ViewModel

@MainActor
class StatisticsViewModel: ObservableObject {
    @Published var dailyDurations: [Date: TimeInterval] = [:]
    @Published var weeklyDurations: [WeeklyListeningDuration] = []
    @Published var collectionDurations: [UUID: TimeInterval] = [:]
    @Published var weeklyCollectionDurations: [UUID: TimeInterval] = [:]
    @Published var topCollectionsTotal: [(collection: AudiobookCollection, duration: TimeInterval)] = []
    @Published var topCollectionsRecentWeek: [(collection: AudiobookCollection, duration: TimeInterval)] = []
    
    private let databaseManager = GRDBDatabaseManager.shared
    
    func loadStatistics() async {
        do {
            let summary = try await databaseManager.loadListeningStatisticsSummary()
            
            self.dailyDurations = summary.dailyDurations
            self.weeklyDurations = summary.weeklyDurations
            self.collectionDurations = summary.collectionDurations
            self.weeklyCollectionDurations = summary.recentWeekCollectionDurations
            
            await loadTopCollections()
            
        } catch {
            print("Error loading statistics: \(error)")
        }
    }
    
    private func loadTopCollections() async {
        do {
            let allCollections = try await databaseManager.loadAllCollections()
            let total = allCollections.compactMap { collection -> (collection: AudiobookCollection, duration: TimeInterval)? in
                guard let duration = collectionDurations[collection.id], duration > 0 else { return nil }
                return (collection: collection, duration: duration)
            }.sorted { $0.duration > $1.duration }
            
            let recent = allCollections.compactMap { collection -> (collection: AudiobookCollection, duration: TimeInterval)? in
                guard let duration = weeklyCollectionDurations[collection.id], duration > 0 else { return nil }
                return (collection: collection, duration: duration)
            }.sorted { $0.duration > $1.duration }
            
            self.topCollectionsTotal = Array(total.prefix(5))
            self.topCollectionsRecentWeek = Array(recent.prefix(5))
        } catch {
            print("Error loading collections for stats: \(error)")
        }
    }
    
    func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: duration) ?? "0m"
    }
}

// MARK: - Main View

struct ListeningStatisticsView: View {
    @StateObject private var viewModel = StatisticsViewModel()
    @State private var selectedTab: StatisticsTab = .recentWeeks
    
    var body: some View {
        List {
            Section {
                Picker("", selection: $selectedTab) {
                    ForEach(StatisticsTab.allCases) { tab in
                        Text(tab.title)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 12)
                
                if selectedTab == .recentWeeks {
                    weeklyChart()
                } else {
                    currentWeekChart()
                }
            }

            if selectedTab == .recentWeeks {
                Section {
                    ForEach(viewModel.topCollectionsTotal, id: \.collection.id) { item in
                        ListeningStatisticsCollectionRow(item: item, formatter: viewModel.formatDuration(_:))
                    }
                } header: {
                    Text(NSLocalizedString("listening_statistics_top_collections_header", comment: "Listening statistics total time section header"))
                }
            } else {
                Section {
                    ForEach(viewModel.topCollectionsRecentWeek, id: \.collection.id) { item in
                        ListeningStatisticsCollectionRow(item: item, formatter: viewModel.formatDuration(_:))
                    }
                } header: {
                    Text(NSLocalizedString("listening_statistics_week_top_collections", comment: "Listening statistics current week top collections header"))
                }
            }
        }
        .navigationTitle("Listening Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadStatistics()
        }
    }

    private func weeklyChart() -> some View {
        Chart {
            ForEach(viewModel.weeklyDurations) { week in
                BarMark(
                    x: .value("Week", week.startDate, unit: .weekOfYear),
                    y: .value("Duration", week.totalDuration / 3600)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(6)
            }
        }
        .frame(height: 220)
        .chartXAxis {
            AxisMarks(values: viewModel.weeklyDurations.map { $0.startDate }) { value in
                if let dateValue = value.as(Date.self) {
                    AxisValueLabel(dateValue.formatted(.dateTime.month(.abbreviated).day()))
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                if let hours = value.as(Double.self) {
                    AxisValueLabel("\(hours.formatted(.number.precision(.fractionLength(0...1))))h")
                }
            }
        }
    }

    private func currentWeekChart() -> some View {
        Chart {
            ForEach(currentWeekDays(), id: \.self) { date in
                let dayKey = Calendar.current.startOfDay(for: date)
                let duration = viewModel.dailyDurations[dayKey] ?? 0
                LineMark(
                    x: .value("Day", date, unit: .day),
                    y: .value("Duration", duration / 3600)
                )
                .foregroundStyle(Color.accentColor)
                AreaMark(
                    x: .value("Day", date, unit: .day),
                    y: .value("Duration", duration / 3600)
                )
                .foregroundStyle(Color.accentColor.opacity(0.2))
            }
        }
        .frame(height: 220)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { value in
                AxisValueLabel(format: .dateTime.weekday(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                if let hours = value.as(Double.self) {
                    AxisValueLabel("\(hours.formatted(.number.precision(.fractionLength(0...1))))h")
                }
            }
        }
    }
    
    private func currentWeekDays() -> [Date] {
        let calendar = Calendar.current
        guard let weekStart = calendar.date(from: calendar.dateComponents([.calendar, .yearForWeekOfYear, .weekOfYear], from: Date())) else {
            return []
        }
        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: weekStart)
        }
    }
}
enum StatisticsTab: String, CaseIterable, Identifiable {
    case recentWeeks
    case currentWeek

    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .recentWeeks:
            return NSLocalizedString("listening_statistics_total_tab", comment: "Listening statistics total timeline tab label")
        case .currentWeek:
            return NSLocalizedString("listening_statistics_week_tab", comment: "Listening statistics current week tab label")
        }
    }
}

struct ListeningStatisticsCollectionRow: View {
    let item: (collection: AudiobookCollection, duration: TimeInterval)
    let formatter: (TimeInterval) -> String
    
    var body: some View {
        HStack(spacing: 12) {
            CollectionCoverArtView(
                cover: item.collection.coverAsset,
                title: item.collection.title,
                size: 40,
                cornerRadius: 8
            )
            
            VStack(alignment: .leading, spacing: 2) {
                Text(item.collection.title)
                    .font(.body)
                    .lineLimit(1)
                if let author = item.collection.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            Text(formatter(item.duration))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
