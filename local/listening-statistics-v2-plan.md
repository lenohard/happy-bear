# Listening Statistics V2 Plan
## Goal
Enhance the listening statistics feature to match the visual style and functionality of iOS "Screen Time", as requested. This includes daily usage bar charts, weekly trends, and usage breakdown by collection (book) and category (tags).

## Feasibility Analysis
The current `listening_statistics` table in `GRDBDatabaseManager` stores individual sessions with `start_time` and `end_time`. This raw data is sufficient to derive all requested metrics:
- **Daily Average**: Aggregate session durations by day.
- **Weekly Trend**: Compare current weeks
total
vs.
previous
weeks total.
- **Usage by Collection**: Aggregate durations grouped by `collection_id`.
- **Usage by Category**: Join with `tags` table or use `AudiobookCollection.tags` to group durations by category.

## Implementation Plan

### 1. Backend Updates (GRDBDatabaseManager)

We need to extend `GRDBDatabaseManager` with advanced aggregation methods.

- **Daily Statistics**:
  - Implement `loadDailyListeningDurations(from: Date, to: Date) -> [Date: TimeInterval]`.
  - This method will fetch sessions within the date range and sum durations per day.
  - *Note*: We will handle date grouping in Swift to avoid complex SQLite date string manipulation, ensuring timezone correctness.

- **Category Statistics**:
  - Implement `loadListeningDurationsByCategory() -> [String: TimeInterval]`.
  - This involves fetching listening stats joined with collection tags.
  - If a collection has multiple tags, the duration can be attributed to the primary tag or split (decision: attribute to the first tag or "Uncategorized" if empty).

- **Summary Model Update**:
  - Update `ListeningStatisticsSummary` to include:
    - `dailyDurations: [Date: TimeInterval]`
    - `categoryDurations: [String: TimeInterval]`
    - `previousWeekTotalDuration: TimeInterval` (for trend calculation)
    - `weeklyDurations: [WeeklyListeningDuration]` (pairs of week ranges for timeline tabs)

- **Weekly Aggregation Struct**:
  - Added `WeeklyListeningDuration` (with `startDate`, `endDate`, `totalDuration`, `id`) to standardize data transfer to SwiftUI views.
  - Next step: backfill GRDB queries to populate this array for both total and current-week tabs.

### 2. UI Implementation (SwiftUI)

Create a new set of views mimicking the Screen Time aesthetic.

- **StatisticsOverviewView** (Main Entry):
  - **Header**: "Daily Average" (e.g., "7h 12m") with a trend indicator (e.g., "12% up").
  - **Chart**: A bar chart showing the last 7 days.
    - Use `Charts` framework (if iOS 16+) or custom `Rectangle` bars.
    - Highlight the current day.
    - Show "Average" dashed line.
  - **Link**: "See All Activity" button.

- **StatisticsDetailView**:
  - **Chart Section**: Interactive bar chart (switch between "Week" and "Day" views if needed, or just Week).
  - **Most Used Section**:
    - List of collections sorted by listening time.
    - Each row shows: Cover icon, Title, Progress bar, Duration.
  - **Categories Section**:
    - Stacked bar or list showing breakdown by Tag (e.g., "Social", "Entertainment" -> "Fiction", "Non-Fiction").

### 3. Data Logic & ViewModel

- **StatisticsViewModel**:
  - Fetch data using `GRDBDatabaseManager`.
  - Calculate "Daily Average" = Total Duration / 7 (or number of days with data).
  - Calculate Trend = ((Current Week - Last Week) / Last Week) * 100.
  - Format durations (e.g., "2h 39m").

### 4. Integration

- Replace or update the existing `ListeningStatisticsView` link in `PersonalView`.
- Ensure the new views are accessible and responsive.

## Next Steps
1.  **Backend**: Implement the new aggregation methods in `GRDBDatabaseManager`. [Completed]
2.  **ViewModel**: Create `StatisticsViewModel` to process and format the data. [Completed]
3.  **UI**: Build the `StatisticsOverviewView` and `StatisticsDetailView`. [Completed]
4.  **Integration**: Replace or update the existing `ListeningStatisticsView` link in `PersonalView`. [Completed]
5.  **Weekly Timeline Data**: Wire new `weeklyDurations` data from GRDB through the summary model into the UI tabs. [In Progress]
6.  **Testing**: Verify with sample data (generate fake listening sessions if needed).

## 2025-11-27 Update
- Added `weeklyDurations` to `ListeningStatisticsSummary` and introduced `WeeklyListeningDuration` model to match the new Total/Week tab design.
- Next action is to implement aggregation queries and formatting logic so charts can show rolling 7-day blocks and the current week breakdown.
