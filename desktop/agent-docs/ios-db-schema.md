# iOS AudiobookPlayer SQLite Schema (for desktop read-only access)

Sources: `AudiobookPlayer/DatabaseConfig.swift`, `DatabaseSchema.swift`,
`TranscriptionDatabaseSchema.swift`, `TrackSummaryDatabaseSchema.swift`,
`GRDBDatabaseManager.swift`, `iCloudStorage.swift`, `ContentView.swift`.

## 1. DB file 位置（单一 DB，转录表就在同一个文件里）

App 使用**单一 SQLite 文件 `library.sqlite`**，所有表（collections/tracks/transcripts/summaries…）都在这一个 DB 里。

- 主位置（iCloud Documents，Catalyst 路径）：
  `~/Library/Mobile Documents/iCloud~com~senaca~audiobookplayer/Documents/library.sqlite`
  （iOS 用 ubiquity API；容器 ID 也含 `iCloud.com.tortugapower.audiobookplayer`，点为 `~`）
- 兜底位置（iCloud 不可用时）：`Application Support/AudiobookPlayer/library.sqlite`
- 结论：桌面端从 iCloud Documents 复制的 `library.sqlite` **正是**包含转录/摘要表的那一个 DB，无需另找文件。
- 另注意同目录有 `-wal` / `-shm` 边车文件（Copy 时需一起，否则为不一致快照，最好 `sqlite3` 打开而非裸拷）。

## 2. 转录表（TranscriptionDatabaseSchema.swift）

所有 id 均为 TEXT（UUID 字符串）。

**transcripts**（每条 track 一条全文）
| 列 | 类型 | 说明 |
|---|---|---|
| id | TEXT PK | |
| track_id | TEXT NOT NULL | FK→tracks(id)，**关联 track 的关键列** |
| collection_id | TEXT NOT NULL | FK→collections(id) |
| language | TEXT NOT NULL | default 'en' |
| full_text | TEXT NOT NULL | 转录全文 |
| created_at / updated_at | DATETIME NOT NULL | |
| job_status | TEXT NOT NULL | default 'pending'（completed/failed…）|
| job_id | TEXT | |
| error_message | TEXT | |

**transcript_segments**（逐句 segment，含时间戳）
| 列 | 类型 | 说明 |
|---|---|---|
| id | TEXT PK | |
| transcript_id | TEXT NOT NULL | FK→transcripts(id)；**segment 不直接挂 track**，需经 transcripts 关联 |
| text | TEXT NOT NULL | **文本内容列** |
| start_time_ms | INTEGER NOT NULL | **开始时间戳（ms）**，排序字段：`ORDER BY start_time_ms ASC` |
| end_time_ms | INTEGER NOT NULL | 结束时间戳（ms）|
| confidence | REAL | |
| speaker | TEXT | |
| language | TEXT | |
| last_repair_model / last_repair_at | TEXT / DATETIME | |

无独立顺序列，按 `start_time_ms ASC` 排序（TranscriptSegmentManager.swift:18）。

**transcription_jobs**：异步任务表（id PK, track_id FK, soniox_job_id NOT NULL, soniox_file_id, status, progress, created_at, completed_at, error_message, retry_count, last_attempt_at, total/processed/pending_paragraphs）。

**transcript_corrections**：纠正表（id, track_id FK, incorrect_text, correct_text, is_applied, applied_at, created_at, updated_at）。

查询 segments 的 join：
```sql
SELECT s.* FROM transcript_segments s
JOIN transcripts t ON t.id = s.transcript_id
WHERE t.track_id = ? ORDER BY s.start_time_ms ASC;
```

## 3. 摘要表（TrackSummaryDatabaseSchema.swift）

**track_summaries**（每条 track 一条）
| 列 | 类型 | 说明 |
|---|---|---|
| id | TEXT PK | |
| track_id | TEXT NOT NULL, UNIQUE | 与 track 关联 |
| transcript_id | TEXT NOT NULL | FK→transcripts(id) |
| language | TEXT NOT NULL | default 'en' |
| summary_title | TEXT | 摘要标题 |
| summary_body | TEXT | **摘要正文** |
| keywords_json | TEXT | JSON |
| mentioned_items_json | TEXT | JSON（可选迁移列）|
| suggested_corrections_json | TEXT | JSON |
| translation_segments_json | TEXT | JSON |
| section_count | INTEGER NOT NULL | default 0 |
| model_identifier | TEXT | |
| generated_at | DATETIME | |
| status | TEXT NOT NULL | default 'idle'（completed…）|
| error_message / last_job_id | TEXT | |
| created_at / updated_at | DATETIME NOT NULL | |

**track_summary_sections**（分节摘要）
| 列 | 类型 |
|---|---|
| id | TEXT PK |
| track_summary_id | TEXT NOT NULL FK→track_summaries(id) |
| order_index | INTEGER NOT NULL（排序字段）|
| start_time_ms | INTEGER NOT NULL |
| end_time_ms | INTEGER |
| title | TEXT |
| summary | TEXT NOT NULL（小节正文）|
| keywords_json | TEXT |
| created_at / updated_at | DATETIME NOT NULL |

## 4. tracks / collections（DatabaseSchema.swift）

**tracks**（列全）：id PK, collection_id NOT NULL, display_name NOT NULL, filename NOT NULL,
location_type NOT NULL, location_payload NOT NULL, file_size INTEGER NOT NULL, duration REAL,
track_number INTEGER NOT NULL, checksum, **metadata_json**, media_kind TEXT default 'audio',
is_favorite INTEGER default 0, favorited_at, character_count INTEGER, chapter TEXT, is_archived INTEGER default 0.
> 说明：tracks **没有** description 列；描述在 collections.description。

**collections**（列全）：id PK, title NOT NULL, author, **description**,
cover_kind NOT NULL, cover_data, cover_dominant_color, created_at NOT NULL, updated_at NOT NULL,
source_type NOT NULL, source_payload NOT NULL, last_played_track_id, shuffle_enabled INTEGER default 0,
is_music INTEGER default 0, preferred_sort_order, folder_id, is_archived INTEGER default 0,
auto_update_enabled INTEGER default 1, last_rss_check_date DATETIME。
> 桌面已知列 id/title/author/description/cover_kind/cover_data/cover_dominant_color/source_type/is_archived/folder_id/updated_at **全部属实**。
> 额外有用：created_at, source_payload, last_played_track_id, shuffle_enabled, is_music, preferred_sort_order, auto_update_enabled, last_rss_check_date。

**collection_folders**：id PK, name NOT NULL, created_at, updated_at, cover_kind, cover_data, cover_dominant_color。

其他表：playback_states(track_id PK, collection_id, position, duration, updated_at), tags, listening_statistics,
schema_state, ai_generation_jobs（含 streamed_reasoning），track_chat，listen_queue。

## 5. iOS「正在播放」页（播放页区块）

主页面 = **ContentView.swift 的 `struct PlayingView`**（line 287，"播放" 标签页）。
- `primaryCard`：live 时 `livePlaybackCard`（合集标题、track 名、视频标签、chat 按钮、transcript 按钮、`liveTimeline` 播放时间线、`controlButtons` 控制按钮）；非 live 时 `resumeCard`（继续收听、合集名、track 名、收藏切换、进度、继续/随机/打开合集按钮）。
- `standaloneSummaryCard` → **TrackSummaryCard.swift**：AI 摘要卡片（summary_title/summary_body、分节 `TrackSummarySection` 行、关键词、提及项、翻译、任务状态）。
- `TranscriptCorrectionsCard`（纠正，若转录可用）。
- `ListenQueueSummaryCard`（听单）。
- `listeningHistorySection`（收听历史）。
- transcript 按钮打开 **TranscriptionSheet.swift**（转录任务进度 sheet）。
- 转录展示页 = **TranscriptViewerSheet.swift**：LazyVStack + ForEach 渲染 segments（`TranscriptSegmentRowView`），含搜索、AI 修复、跳转时间点。
- 封面数据在 collections.cover_data（播放卡本身主要用文字卡片，封面详情在 CollectionDetailView）。
