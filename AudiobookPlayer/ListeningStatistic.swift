import Foundation

struct ListeningStatistic: Identifiable, Codable, Equatable {
    let id: UUID
    let trackId: UUID
    let collectionId: UUID
    let startTime: Date
    let endTime: Date
    let createdAt: Date
    
    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
}

struct ListeningStatisticsSummary {
    let totalDuration: TimeInterval
    let collectionDurations: [UUID: TimeInterval]
    let dailyDurations: [Date: TimeInterval]
    let recentWeekCollectionDurations: [UUID: TimeInterval]
}
