import SwiftUI
import Charts

// MARK: - Time Period Enum

enum StatisticsPeriod: String, CaseIterable, Identifiable {
    case daily
    case weekly
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .daily:
            return NSLocalizedString("listening_statistics_week_tab", comment: "Listening statistics daily tab label")
        case .weekly:
            return NSLocalizedString("listening_statistics_total_tab", comment: "Listening statistics weekly tab label")
        }
    }
    
    var windowSize: Int {
        switch self {
        case .daily: return 7
        case .weekly: return 6
        }
    }
}

// MARK: - Data Point Model

struct StatisticsDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let duration: TimeInterval
}

// MARK: - ViewModel

@MainActor
class StatisticsViewModel: ObservableObject {
    @Published var dailyDurations: [Date: TimeInterval] = [:]
    @Published var collectionDurations: [UUID: TimeInterval] = [:]
    @Published var topCollectionsTotal: [(collection: AudiobookCollection, duration: TimeInterval)] = []
    @Published var topCollectionsRecentPeriod: [(collection: AudiobookCollection, duration: TimeInterval)] = []
    @Published var recentPeriodTotalDuration: TimeInterval = 0
    @Published var earliestDate: Date?

    private let databaseManager = GRDBDatabaseManager.shared
    
    func loadStatistics(period: StatisticsPeriod = .weekly) async {
        do {
            let summary = try await databaseManager.loadListeningStatisticsSummary()
            let earliest = try await databaseManager.getEarliestListeningDate()

            self.dailyDurations = summary.dailyDurations
            self.collectionDurations = summary.collectionDurations
            self.earliestDate = earliest

            let days = period == .daily ? 7 : 42
            await loadTopCollections(recentDays: days)

        } catch {
            print("Error loading statistics: \(error)")
        }
    }
    
    func loadTopCollections(recentDays: Int) async {
        do {
            let calendar = Calendar.current
            let now = Date()
            let startDate = calendar.date(byAdding: .day, value: -recentDays, to: now) ?? now

            let recentCollectionDurations = try await databaseManager.loadListeningDurationsByCollection(from: startDate, to: now)
            let allCollections = try await databaseManager.loadAllCollections()

            let total = allCollections.compactMap { collection -> (collection: AudiobookCollection, duration: TimeInterval)? in
                guard let duration = collectionDurations[collection.id], duration > 0 else { return nil }
                return (collection: collection, duration: duration)
            }.sorted { $0.duration > $1.duration }

            let recent = allCollections.compactMap { collection -> (collection: AudiobookCollection, duration: TimeInterval)? in
                guard let duration = recentCollectionDurations[collection.id], duration > 0 else { return nil }
                return (collection: collection, duration: duration)
            }.sorted { $0.duration > $1.duration }

            self.topCollectionsTotal = total
            self.topCollectionsRecentPeriod = recent
            self.recentPeriodTotalDuration = recent.reduce(0) { $0 + $1.duration }
        } catch {
            print("Error loading collections for stats: \(error)")
        }
    }
    
    func getDataPoints(for period: StatisticsPeriod) -> [StatisticsDataPoint] {
        let calendar = Calendar.current
        let now = Date()
        let windowSize = period.windowSize
        
        switch period {
        case .daily:
            // Last 7 days (sliding window)
            return (0..<windowSize).reversed().compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
                let dayKey = calendar.startOfDay(for: date)
                let duration = dailyDurations[dayKey] ?? 0
                return StatisticsDataPoint(date: dayKey, duration: duration)
            }
            
        case .weekly:
            // Last 6 weeks (sliding window)
            return (0..<windowSize).reversed().compactMap { weekOffset in
                guard let weekStart = calendar.date(byAdding: .weekOfYear, value: -weekOffset, to: now) else { return nil }
                let weekStartNormalized = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: weekStart)) ?? weekStart
                
                // Sum all days in this week
                var weekTotal: TimeInterval = 0
                for dayOffset in 0..<7 {
                    if let day = calendar.date(byAdding: .day, value: dayOffset, to: weekStartNormalized) {
                        let dayKey = calendar.startOfDay(for: day)
                        weekTotal += dailyDurations[dayKey] ?? 0
                    }
                }
                
                return StatisticsDataPoint(date: weekStartNormalized, duration: weekTotal)
            }
        }
    }
    
    func calculateAverage(for period: StatisticsPeriod) -> TimeInterval {
        guard let earliest = earliestDate else { return 0 }
        
        let calendar = Calendar.current
        let now = Date()
        let dataPoints = getDataPoints(for: period)
        
        // Calculate how many complete periods have passed since data collection started
        let daysSinceStart = calendar.dateComponents([.day], from: calendar.startOfDay(for: earliest), to: calendar.startOfDay(for: now)).day ?? 0
        
        switch period {
        case .daily:
            // For daily: calculate average of previous 6 days (excluding today)
            let previousDays = min(6, daysSinceStart)
            guard previousDays > 0 else {
                // If this is the first day, return current day's value
                return dataPoints.last?.duration ?? 0
            }
            
            let previousDataPoints = dataPoints.dropLast()
            let total = previousDataPoints.reduce(0) { $0 + $1.duration }
            return total / Double(previousDays)
            
        case .weekly:
            // For weekly: calculate average of previous weeks (excluding current week)
            let weeksSinceStart = daysSinceStart / 7
            let previousWeeks = min(period.windowSize - 1, weeksSinceStart)
            guard previousWeeks > 0 else {
                // If this is the first week, return current week's value
                return dataPoints.last?.duration ?? 0
            }
            
            let previousDataPoints = dataPoints.dropLast()
            let total = previousDataPoints.reduce(0) { $0 + $1.duration }
            return total / Double(previousWeeks)
        }
    }
    
    func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: duration) ?? "0m"
    }
    
    func deleteStatistics(for collection: AudiobookCollection) async {
        do {
            try await databaseManager.deleteStatistics(for: collection.id)
            await loadStatistics()
        } catch {
            print("Error deleting statistics: \(error)")
        }
    }
}

// MARK: - Main View

struct ListeningStatisticsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var viewModel = StatisticsViewModel()
    @State private var selectedPeriod: StatisticsPeriod = .weekly

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM.dd"
        return formatter
    }()

    var body: some View {
        List {
            Section {
                Picker("", selection: $selectedPeriod) {
                    ForEach(StatisticsPeriod.allCases) { period in
                        Text(period.title)
                            .tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 12)

                chartView(for: selectedPeriod)
            }
            .listRowBackground(themeManager.colors.isFestive ? themeManager.colors.secondaryBackground.opacity(0.8) : nil)

            Section {
                ForEach(viewModel.topCollectionsRecentPeriod, id: \.collection.id) { item in
                    ListeningStatisticsCollectionRow(item: item, formatter: viewModel.formatDuration(_:))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task {
                                    await viewModel.deleteStatistics(for: item.collection)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .labelStyle(.iconOnly)
                        }
                        .listRowBackground(themeManager.colors.isFestive ? themeManager.colors.secondaryBackground.opacity(0.8) : nil)
                }
            } header: {
                let headerKey = selectedPeriod == .daily ? "listening_statistics_week_top_collections" : "listening_statistics_top_collections_header"
                HStack {
                    Text(NSLocalizedString(headerKey, comment: "Top collections header"))
                    Spacer()
                    Text(viewModel.formatDuration(viewModel.recentPeriodTotalDuration))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .textCase(nil)
            }
        }
        .scrollContentBackground(themeManager.colors.isFestive ? .hidden : .visible)
        .background(themeManager.colors.isFestive ? Color.clear : Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Listening Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadStatistics(period: selectedPeriod)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                Task {
                    await viewModel.loadStatistics(period: selectedPeriod)
                }
            }
        }
        .onChange(of: selectedPeriod) { newPeriod in
            Task {
                let days = newPeriod == .daily ? 7 : 42
                await viewModel.loadTopCollections(recentDays: days)
            }
        }
    }
    
    @ViewBuilder
    private func chartView(for period: StatisticsPeriod) -> some View {
        let dataPoints = viewModel.getDataPoints(for: period)
        let average = viewModel.calculateAverage(for: period)
        
        Chart {
            ForEach(dataPoints) { point in
                BarMark(
                    x: .value("Date", point.date, unit: period == .daily ? .day : .weekOfYear),
                    y: .value("Duration", point.duration / 3600)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(6)
            }
            
            if average > 0 {
                RuleMark(y: .value("Average", average / 3600))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5]))
                    .foregroundStyle(.gray.opacity(0.8))
                    .annotation(position: .leading, alignment: .bottom) {
                        Text("Avg")
                            .font(.caption2)
                            .foregroundStyle(.gray)
                    }
            }
        }
        .frame(height: 220)
        .chartXAxis {
            AxisMarks(values: dataPoints.map { $0.date }) { value in
                if let dateValue = value.as(Date.self) {
                    AxisValueLabel {
                        Text(Self.dateFormatter.string(from: dateValue))
                    }
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
