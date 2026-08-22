import { existsSync } from 'fs'
import { DatabaseSync } from 'node:sqlite'
import { SOURCE_DB } from './library-db'
import type { PlaybackState } from '../shared/ipc'

const WRITE_INTERVAL_MS = 10_000

let lastTrackId: string | null = null
let lastWriteAt = 0
let lastPlaying = false

const sqliteDate = (): string => new Date().toISOString().replace('T', ' ').replace('Z', '')

export function persistPlaybackState(state: PlaybackState): void {
  const track = state.currentTrack
  const wasPlaying = lastPlaying
  lastPlaying = state.isPlaying
  if (!track || !track.collectionId || !Number.isFinite(state.positionSec)) return

  const now = Date.now()
  const trackChanged = track.id !== lastTrackId
  const paused = wasPlaying && !state.isPlaying
  if (!trackChanged && !paused && now - lastWriteAt < WRITE_INTERVAL_MS) return

  if (!existsSync(SOURCE_DB)) return

  const db = new DatabaseSync(SOURCE_DB)
  try {
    db.exec('PRAGMA busy_timeout = 5000')
    db.exec('BEGIN IMMEDIATE')
    const updatedAt = sqliteDate()
    db.prepare(`INSERT OR REPLACE INTO playback_states
      (track_id, collection_id, position, duration, updated_at)
      VALUES (?, ?, ?, ?, ?)`).run(
      track.id,
      track.collectionId,
      Math.max(0, state.positionSec),
      Number.isFinite(state.durationSec) && state.durationSec > 0 ? state.durationSec : null,
      updatedAt,
    )
    db.prepare(`UPDATE collections
      SET last_played_track_id = ?, updated_at = ?
      WHERE id = ?`).run(track.id, updatedAt, track.collectionId)
    db.exec('COMMIT')
    lastTrackId = track.id
    lastWriteAt = now
  } catch {
    try { db.exec('ROLLBACK') } catch { /* transaction may not have started */ }
  } finally {
    db.close()
  }
}
