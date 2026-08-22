import { randomUUID } from 'crypto'
import { DatabaseSync } from 'node:sqlite'

// 摘要结果写回 iCloud 源库 track_summaries / track_summary_sections。
// 与 iOS TrackSummaryStore.persistTrackSummaryResult 的落库格式保持一致：
// status='complete'，id 默认等于 track_id，JSON 字段为纯数组/对象。
// 事务 + busy_timeout + updated_at 乐观锁：生成期间若 iOS 侧改动过转录或摘要则放弃写入。

export interface SummaryWritePayload {
  trackId: string
  transcriptId: string
  language: string
  expectedTranscriptUpdatedAt: string
  expectedSummary: { exists: boolean; updatedAt: string | null }
  summaryTitle: string | null
  summaryBody: string
  keywords: string[]
  mentionedItems: string[]
  suggestedCorrections: Record<string, string>
  translations: { orderIndex: number; startTimeMs: number; translation: string }[]
  sections: { orderIndex: number; startTimeMs: number; endTimeMs: number | null; title: string | null; summary: string; keywords: string[] }[]
  modelIdentifier: string | null
  jobId: string | null
}

type Row = Record<string, unknown>

const sqliteDate = (date = new Date()): string => date.toISOString().replace('T', ' ').replace('Z', '')

export function writeTrackSummary(dbPath: string, payload: SummaryWritePayload): void {
  const db = new DatabaseSync(dbPath)
  try {
    db.exec('PRAGMA busy_timeout = 5000')
    db.exec('BEGIN IMMEDIATE')

    const transcript = db.prepare('SELECT updated_at FROM transcripts WHERE id = ?').get(payload.transcriptId) as Row | undefined
    if (!transcript || String(transcript.updated_at) !== payload.expectedTranscriptUpdatedAt) {
      throw new Error('写入中止：转录在摘要生成期间已变化。')
    }
    const existing = db.prepare('SELECT id, created_at, updated_at, translation_segments_json FROM track_summaries WHERE track_id = ?').get(payload.trackId) as Row | undefined
    if (payload.expectedSummary.exists) {
      if (!existing || String(existing.updated_at) !== payload.expectedSummary.updatedAt) {
        throw new Error('写入中止：摘要在生成期间已被其他设备修改。')
      }
    } else if (existing) {
      throw new Error('写入中止：生成期间出现了新的摘要记录。')
    }

    const now = sqliteDate()
    const summaryId = existing ? String(existing.id) : payload.trackId
    const createdAt = existing ? String(existing.created_at) : now
    const sections = [...payload.sections].sort((a, b) => a.orderIndex - b.orderIndex)
    const translationsJson = payload.translations.length
      ? JSON.stringify(payload.translations.map(t => ({ id: randomUUID(), orderIndex: t.orderIndex, startTimeMs: t.startTimeMs, translation: t.translation })))
      : (typeof existing?.translation_segments_json === 'string' && existing.translation_segments_json) || null
    const keywordsJson = JSON.stringify(payload.keywords)
    const mentionedJson = JSON.stringify(payload.mentionedItems)
    const correctionsJson = JSON.stringify(payload.suggestedCorrections)

    if (existing) {
      db.prepare(`UPDATE track_summaries
        SET transcript_id = ?, language = ?, summary_title = ?, summary_body = ?, keywords_json = ?,
            mentioned_items_json = ?, suggested_corrections_json = ?, translation_segments_json = ?,
            section_count = ?, model_identifier = ?, generated_at = ?, status = 'complete',
            error_message = NULL, last_job_id = ?, updated_at = ?
        WHERE track_id = ?`).run(
        payload.transcriptId, payload.language, payload.summaryTitle, payload.summaryBody, keywordsJson,
        mentionedJson, correctionsJson, translationsJson,
        sections.length, payload.modelIdentifier, now,
        payload.jobId, now,
        payload.trackId
      )
    } else {
      db.prepare(`INSERT INTO track_summaries (
        id, track_id, transcript_id, language, summary_title, summary_body, keywords_json,
        mentioned_items_json, suggested_corrections_json, translation_segments_json, section_count,
        model_identifier, generated_at, status, error_message, last_job_id, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'complete', NULL, ?, ?, ?)`).run(
        summaryId, payload.trackId, payload.transcriptId, payload.language, payload.summaryTitle, payload.summaryBody, keywordsJson,
        mentionedJson, correctionsJson, translationsJson, sections.length,
        payload.modelIdentifier, now, payload.jobId, createdAt, now
      )
    }

    db.prepare('DELETE FROM track_summary_sections WHERE track_summary_id = ?').run(summaryId)
    const insertSection = db.prepare(`INSERT INTO track_summary_sections (
      id, track_summary_id, order_index, start_time_ms, end_time_ms, title, summary, keywords_json, created_at, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
    for (const section of sections) {
      insertSection.run(randomUUID(), summaryId, section.orderIndex, section.startTimeMs, section.endTimeMs, section.title, section.summary, JSON.stringify(section.keywords), now, now)
    }

    db.exec('COMMIT')
  } catch (error) {
    try { db.exec('ROLLBACK') } catch { /* 事务可能尚未开始 */ }
    throw error
  } finally {
    db.close()
  }
}
