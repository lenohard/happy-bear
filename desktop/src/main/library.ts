import type { DatabaseSync } from 'node:sqlite'
import type { Collection, ContinueItem, Cover, Folder, LibraryStatus, Playback, PlaybackSource, SearchResult, Track, TrackDetail, TrackPage, TrackSummary, TrackTranscript } from '../shared/ipc'
import { SnapshotDatabase } from './library-db'

type Row = Record<string, any>
const json = (value: unknown): Record<string, unknown> | null => { if (typeof value !== 'string') return null; try { const out = JSON.parse(value); return out && typeof out === 'object' ? out : null } catch { return null } }
const cover = (kind: unknown, data: unknown, dominantColor: unknown): Cover => ({ kind: typeof kind === 'string' ? kind : null, data: json(data), dominantColor: typeof dominantColor === 'string' ? dominantColor : null })
const playback = (row: Row): Playback | null => row.playback_position == null ? null : ({ position: Number(row.playback_position) || 0, duration: row.playback_duration == null ? null : Number(row.playback_duration), updatedAt: row.playback_updated_at ?? null })

export class LibraryService {
  constructor(private readonly snapshot: SnapshotDatabase) {}
  status(): LibraryStatus { return this.snapshot.status() }
  refresh(): LibraryStatus { return this.snapshot.refresh(true) }
  private db(): DatabaseSync { const db = this.snapshot.getDatabase(); if (!db) throw new Error('数据库尚未就绪，请检查 iCloud 数据库路径。'); return db }
  folders(): Folder[] {
    return (this.db().prepare('SELECT * FROM collection_folders ORDER BY name COLLATE NOCASE').all() as Row[]).map(row => ({ id: String(row.id), name: String(row.name), cover: cover(row.cover_kind, row.cover_data, row.cover_dominant_color) }))
  }
  collections(folderId: string | null, includeArchived = false): Collection[] {
    const condition = folderId ? 'c.folder_id = ?' : '1=1'
    const archive = includeArchived ? '' : 'AND c.is_archived = 0'
    const trackArchive = includeArchived ? '' : ' AND COALESCE(t.is_archived,0)=0'
    const rows = this.db().prepare(`SELECT c.*, COUNT(t.id) AS track_count, SUM(CASE WHEN ps.track_id IS NOT NULL AND ps.position > 0 THEN 1 ELSE 0 END) AS listened_count, MAX(ps.updated_at) AS last_played FROM collections c LEFT JOIN tracks t ON t.collection_id=c.id${trackArchive} LEFT JOIN playback_states ps ON ps.collection_id=c.id WHERE ${condition} ${archive} GROUP BY c.id ORDER BY c.title COLLATE NOCASE`).all(...(folderId ? [folderId] : [])) as Row[]
    return rows.map(row => { const count = Number(row.track_count) || 0; const listened = Number(row.listened_count) || 0; return { id: String(row.id), title: String(row.title || '未命名合集'), author: row.author ?? null, description: row.description ?? null, folderId: row.folder_id ?? null, sourceType: String(row.source_type || ''), trackCount: count, listenedCount: listened, progress: count ? listened / count : 0, lastPlayed: row.last_played ?? null, isArchived: Number(row.is_archived) === 1, cover: cover(row.cover_kind, row.cover_data, row.cover_dominant_color) } })
  }
  tracks(collectionId: string, page = 0, pageSize = 200, includeArchived = false): TrackPage {
    const offset = Math.max(0, page) * Math.min(Math.max(1, pageSize), 500); const limit = Math.min(Math.max(1, pageSize), 500)
    const archive = includeArchived ? '' : ' AND COALESCE(t.is_archived,0)=0'
    const base = `FROM tracks t LEFT JOIN playback_states ps ON ps.track_id=t.id WHERE t.collection_id = ?${archive}`
    const db = this.db(); const total = Number((db.prepare(`SELECT COUNT(*) AS n ${base}`).get(collectionId) as Row).n) || 0
    const rows = db.prepare(`SELECT t.*, ps.position AS playback_position, ps.duration AS playback_duration, ps.updated_at AS playback_updated_at ${base} ORDER BY CASE WHEN t.track_number IS NULL THEN 1 ELSE 0 END, t.track_number, t.display_name COLLATE NOCASE LIMIT ? OFFSET ?`).all(collectionId, limit, offset) as Row[]
    return { tracks: rows.map(row => this.track(row)), total, page, pageSize: limit }
  }
  continueListening(limit = 20): ContinueItem[] {
    const rows = this.db().prepare(`SELECT t.*, c.title AS collection_title, c.author AS collection_author, ps.position AS playback_position, ps.duration AS playback_duration, ps.updated_at AS playback_updated_at FROM playback_states ps JOIN tracks t ON t.id=ps.track_id JOIN collections c ON c.id=t.collection_id WHERE ps.position > 0 AND COALESCE(t.is_archived,0)=0 AND COALESCE(c.is_archived,0)=0 ORDER BY ps.updated_at DESC LIMIT ?`).all(Math.min(Math.max(limit, 1), 100)) as Row[]
    return rows.map(row => ({ ...this.track(row), collectionTitle: String(row.collection_title || ''), collectionAuthor: row.collection_author ?? null }))
  }
  favorites(limit = 500): Track[] { const rows = this.db().prepare(`SELECT t.*, ps.position AS playback_position, ps.duration AS playback_duration, ps.updated_at AS playback_updated_at FROM tracks t LEFT JOIN playback_states ps ON ps.track_id=t.id WHERE t.is_favorite=1 AND COALESCE(t.is_archived,0)=0 ORDER BY t.display_name COLLATE NOCASE LIMIT ?`).all(limit) as Row[]; return rows.map(row => this.track(row)) }
  search(query: string, limit = 50): SearchResult[] {
    const trimmed = query.trim()
    if (!trimmed) return []
    const q = `%${trimmed}%`
    const trackLimit = Math.min(Math.max(limit, 1), 200)
    const collectionLimit = Math.min(Math.max(Math.floor(limit / 4), 5), 50)
    const trackRows = this.db().prepare(`SELECT t.*, ps.position AS playback_position, ps.duration AS playback_duration, ps.updated_at AS playback_updated_at FROM tracks t JOIN collections c ON c.id=t.collection_id LEFT JOIN playback_states ps ON ps.track_id=t.id WHERE COALESCE(t.is_archived,0)=0 AND COALESCE(c.is_archived,0)=0 AND (t.display_name LIKE ? OR t.filename LIKE ? OR c.title LIKE ? OR c.author LIKE ?) ORDER BY c.title COLLATE NOCASE, t.track_number LIMIT ?`).all(q, q, q, q, trackLimit) as Row[]
    const collectionRows = this.db().prepare(`SELECT c.*, COUNT(t.id) AS track_count, SUM(CASE WHEN ps.track_id IS NOT NULL AND ps.position > 0 THEN 1 ELSE 0 END) AS listened_count, MAX(ps.updated_at) AS last_played FROM collections c LEFT JOIN tracks t ON t.collection_id=c.id LEFT JOIN playback_states ps ON ps.collection_id=c.id WHERE COALESCE(c.is_archived,0)=0 AND (c.title LIKE ? OR c.author LIKE ? OR c.description LIKE ?) GROUP BY c.id ORDER BY c.title COLLATE NOCASE LIMIT ?`).all(q, q, q, collectionLimit) as Row[]
    const tracks: SearchResult[] = trackRows.map(row => ({ type: 'track', data: this.track(row) }))
    const collections: SearchResult[] = collectionRows.map(row => { const count = Number(row.track_count) || 0; const listened = Number(row.listened_count) || 0; return { type: 'collection', data: { id: String(row.id), title: String(row.title || '未命名合集'), author: row.author ?? null, description: row.description ?? null, folderId: row.folder_id ?? null, sourceType: String(row.source_type || ''), trackCount: count, listenedCount: listened, progress: count ? listened / count : 0, lastPlayed: row.last_played ?? null, isArchived: Number(row.is_archived) === 1, cover: cover(row.cover_kind, row.cover_data, row.cover_dominant_color) } } })
    return [...collections, ...tracks]
  }
  getTrack(trackId: string): Track | null { const row = this.db().prepare(`SELECT t.*, ps.position AS playback_position, ps.duration AS playback_duration, ps.updated_at AS playback_updated_at FROM tracks t LEFT JOIN playback_states ps ON ps.track_id=t.id WHERE t.id=?`).get(trackId) as Row | undefined; return row ? this.track(row) : null }
  getTrackDetail(trackId: string): TrackDetail | null {
    const row = this.db().prepare(`SELECT t.*, c.id AS c_id, c.title AS c_title, c.author AS c_author, c.description AS c_description, c.cover_kind AS c_cover_kind, c.cover_data AS c_cover_data, c.cover_dominant_color AS c_cover_dominant_color, c.folder_id AS c_folder_id, c.source_type AS c_source_type, c.is_archived AS c_is_archived, (SELECT COUNT(*) FROM tracks t2 WHERE t2.collection_id = c.id AND COALESCE(t2.is_archived,0)=0) AS c_track_count, ps.position AS playback_position, ps.duration AS playback_duration, ps.updated_at AS playback_updated_at FROM tracks t JOIN collections c ON c.id = t.collection_id LEFT JOIN playback_states ps ON ps.track_id = t.id WHERE t.id = ?`).get(trackId) as Row | undefined
    if (!row) return null
    const base = this.track(row)
    const metadata = json(row.metadata_json) as Record<string, string> | null
    const description = (() => {
      if (typeof row.description === 'string' && row.description) return row.description
      if (!metadata) return null
      for (const key of ['description', 'summary', 'subtitle', 'note', 'abstract']) {
        const value = metadata[key]
        if (typeof value === 'string' && value.trim()) return value
      }
      return null
    })()
    const collection = row.c_id ? { id: String(row.c_id), title: String(row.c_title || '未命名合集'), author: row.c_author ?? null, description: row.c_description ?? null, cover: cover(row.c_cover_kind, row.c_cover_data, row.c_cover_dominant_color), folderId: row.c_folder_id ?? null, trackCount: Number(row.c_track_count) || 0 } : null
    const listeningRow = this.db().prepare(`SELECT COUNT(*) AS sessions, MAX(end_time) AS last_listened FROM listening_statistics WHERE track_id = ?`).get(trackId) as Row | undefined
    const listening = { sessions: Number(listeningRow?.sessions) || 0, totalSec: 0, lastListenedAt: listeningRow?.last_listened ?? null }
    const transcriptRow = this.db().prepare(`SELECT tr.language, (SELECT COUNT(*) FROM transcript_segments s WHERE s.transcript_id = tr.id) AS cnt FROM transcripts tr WHERE tr.track_id = ? AND tr.job_status = 'complete' ORDER BY tr.updated_at DESC LIMIT 1`).get(trackId) as Row | undefined
    const transcript = transcriptRow && Number(transcriptRow.cnt) > 0 ? { segmentsCount: Number(transcriptRow.cnt), language: String(transcriptRow.language || '') } : null
    return { track: { ...base, fileSize: row.file_size == null ? null : Number(row.file_size), characterCount: row.character_count == null ? null : Number(row.character_count), checksum: typeof row.checksum === 'string' ? row.checksum : null, description, metadata, isArchived: Number(row.is_archived) === 1 }, collection, playback: playback(row), listening, transcript, summary: this.summary(trackId) }
  }
  getSummary(trackId: string): TrackSummary | null {
    return this.summary(trackId)
  }
  private summary(trackId: string): TrackSummary | null {
    const db = this.db()
    const row = db.prepare(`SELECT id, summary_title, summary_body, keywords_json FROM track_summaries WHERE track_id = ? AND status = 'complete' ORDER BY updated_at DESC LIMIT 1`).get(trackId) as Row | undefined
    if (!row) return null
    let keywords: string[] = []
    const parsed = json(row.keywords_json)?.keywords ?? json(row.keywords_json)
    if (Array.isArray(parsed)) keywords = parsed.filter((k): k is string => typeof k === 'string')
    const sections = (db.prepare(`SELECT title, summary, start_time_ms FROM track_summary_sections WHERE track_summary_id = ? ORDER BY order_index`).all(String(row.id)) as Row[]).map(s => ({ title: s.title ?? null, summary: String(s.summary || ''), startMs: Number(s.start_time_ms) || 0 }))
    return { title: row.summary_title ?? null, body: row.summary_body ?? null, keywords, sections }
  }
  getTranscript(trackId: string, includeFullText: boolean): TrackTranscript | null {
    const db = this.db()
    const row = db.prepare(`SELECT id, language, full_text FROM transcripts WHERE track_id = ? AND job_status = 'complete' ORDER BY updated_at DESC LIMIT 1`).get(trackId) as Row | undefined
    if (!row) return null
    const segments = (db.prepare(`SELECT text, start_time_ms, end_time_ms, speaker FROM transcript_segments WHERE transcript_id = ? ORDER BY start_time_ms`).all(String(row.id)) as Row[]).map(s => ({ startMs: Number(s.start_time_ms) || 0, endMs: Number(s.end_time_ms) || 0, text: String(s.text || ''), speaker: s.speaker ?? null }))
    return { language: String(row.language || ''), segments, fullText: includeFullText ? (typeof row.full_text === 'string' ? row.full_text : '') : null }
  }
  textContent(trackId: string): string | null { const row = this.db().prepare('SELECT location_type, location_payload FROM tracks WHERE id=?').get(trackId) as Row | undefined; if (!row || !['text', 'cachedText'].includes(row.location_type)) return null; const data = json(row.location_payload); return typeof data?.content === 'string' ? data.content : null }
  media(trackId: string): PlaybackSource | null { const row = this.db().prepare('SELECT location_type, location_payload FROM tracks WHERE id=?').get(trackId) as Row | undefined; if (!row) return null; const data = json(row.location_payload); if (row.location_type === 'baidu' && typeof data?.path === 'string') return { kind: 'baidu', value: data.path }; if (row.location_type === 'external' && typeof data?.url === 'string') return { kind: 'external', value: data.url }; return null }
  private track(row: Row): Track { const type = String(row.location_type || ''); return { id: String(row.id), collectionId: String(row.collection_id), displayName: String(row.display_name || row.filename || '未命名'), filename: String(row.filename || ''), locationType: type, duration: row.duration == null ? null : Number(row.duration), trackNumber: Number(row.track_number) || 0, chapter: row.chapter ?? null, mediaKind: String(row.media_kind || 'audio'), isFavorite: Number(row.is_favorite) === 1, isArchived: Number(row.is_archived) === 1, playback: playback(row), playable: type === 'baidu' || type === 'external' || type === 'text' } }
}
