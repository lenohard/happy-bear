import { app } from 'electron'
import { copyFileSync, existsSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from 'fs'
import { homedir } from 'os'
import { join } from 'path'
import { DatabaseSync } from 'node:sqlite'
import type { LibraryStatus } from '../shared/ipc'

const defaultSourceDb = join(homedir(), 'Library/Mobile Documents/iCloud~com~senaca~audiobookplayer/Documents/library.sqlite')
export const SOURCE_DB = process.env.POLARBEAR_LIBRARY_DB?.trim() || defaultSourceDb

export class SnapshotDatabase {
  readonly path = join(app.getPath('userData'), 'library-snapshot.sqlite')
  private readonly metadataPath = `${this.path}.meta.json`
  private cachedTracks = 0
  private cachedCollections = 0
  private db: DatabaseSync | null = null
  private sourceMtime: number | null = null
  private sourceSize: number | null = null
  private snapshotTime: number | null = null
  private error: string | undefined

  initialize(): void {
    if (existsSync(this.path)) {
      try {
        const db = new DatabaseSync(this.path, { readOnly: true })
        db.prepare('SELECT count(*) FROM collections').get()
        this.db = db
        this.snapshotTime = statSync(this.path).mtimeMs
        this.loadSourceMetadata()
        this.updateCounts()
      } catch {
        this.db = null
        this.sourceMtime = null
        this.sourceSize = null
      }
    }
    this.refresh(false)
  }
  refresh(force = true): LibraryStatus {
    let source
    try { source = statSync(SOURCE_DB) } catch { this.error = `未找到 iCloud 数据库：${SOURCE_DB}`; return this.status() }
    if (!force && this.db && this.sourceMtime === source.mtimeMs && this.sourceSize === source.size) return this.status()
    const destination = `${this.path}.part`
    try {
      for (const suffix of ['', '-wal', '-shm']) {
        const src = `${SOURCE_DB}${suffix}`; const dst = `${destination}${suffix}`
        if (existsSync(src)) copyFileSync(src, dst)
        else if (existsSync(dst)) unlinkSync(dst)
      }
      const test = new DatabaseSync(destination, { readOnly: true })
      test.prepare('SELECT count(*) AS count FROM collections').get()
      test.close()
      renameSync(destination, this.path)
      for (const suffix of ['-wal', '-shm']) {
        const dst = `${this.path}${suffix}`
        if (existsSync(dst)) unlinkSync(dst)
        const part = `${destination}${suffix}`
        if (existsSync(part)) renameSync(part, dst)
      }
      this.db?.close()
      this.db = new DatabaseSync(this.path, { readOnly: true })
      this.sourceMtime = source.mtimeMs
      this.sourceSize = source.size
      this.snapshotTime = Date.now()
      this.error = undefined
      this.updateCounts()
      writeFileSync(this.metadataPath, JSON.stringify({ sourceMtime: this.sourceMtime, sourceSize: this.sourceSize }), { mode: 0o600 })
    } catch (error) {
      try { unlinkSync(destination) } catch { /* no temporary snapshot */ }
      this.error = `数据库快照失败：${String(error)}`
    }
    return this.status()
  }
  getDatabase(): DatabaseSync | null { return this.db }
  private loadSourceMetadata(): void {
    try {
      const value = JSON.parse(readFileSync(this.metadataPath, 'utf8')) as { sourceMtime?: unknown; sourceSize?: unknown }
      if (typeof value.sourceMtime === 'number' && typeof value.sourceSize === 'number') {
        this.sourceMtime = value.sourceMtime
        this.sourceSize = value.sourceSize
      }
    } catch { /* metadata is optional; refresh will rebuild it */ }
  }

  private updateCounts(): void {
    if (!this.db) return
    try {
      this.cachedTracks = Number((this.db.prepare('SELECT count(*) AS n FROM tracks').get() as { n: number }).n) || 0
      this.cachedCollections = Number((this.db.prepare('SELECT count(*) AS n FROM collections').get() as { n: number }).n) || 0
    } catch { /* status keeps the last known counts */ }
  }

  status(): LibraryStatus {
    return { dbReady: this.db !== null, snapshotTime: this.snapshotTime, sourceMtime: this.sourceMtime, tracks: this.cachedTracks, collections: this.cachedCollections, error: this.error }
  }
}
