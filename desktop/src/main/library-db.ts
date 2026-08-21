import { app } from 'electron'
import { copyFileSync, existsSync, renameSync, statSync, unlinkSync } from 'fs'
import { homedir } from 'os'
import { join } from 'path'
import { DatabaseSync } from 'node:sqlite'
import type { LibraryStatus } from '../shared/ipc'

export const SOURCE_DB = join(homedir(), 'Library/Mobile Documents/iCloud~com~senaca~audiobookplayer/Documents/library.sqlite')

export class SnapshotDatabase {
  readonly path = join(app.getPath('userData'), 'library-snapshot.sqlite')
  private db: DatabaseSync | null = null
  private sourceMtime: number | null = null
  private sourceSize: number | null = null
  private snapshotTime: number | null = null
  private error: string | undefined

  initialize(): void {
    if (existsSync(this.path)) {
      try { const db = new DatabaseSync(this.path, { readOnly: true }); db.prepare('SELECT count(*) FROM collections').get(); this.db = db; this.snapshotTime = statSync(this.path).mtimeMs } catch { this.db = null }
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
      this.db?.close(); this.db = new DatabaseSync(this.path, { readOnly: true })
      this.sourceMtime = source.mtimeMs; this.sourceSize = source.size; this.snapshotTime = Date.now(); this.error = undefined
    } catch (error) {
      try { unlinkSync(destination) } catch { /* no temporary snapshot */ }
      this.error = `数据库快照失败：${String(error)}`
    }
    return this.status()
  }
  getDatabase(): DatabaseSync | null { return this.db }
  status(): LibraryStatus {
    let tracks = 0, collections = 0
    try { if (this.db) { tracks = Number((this.db.prepare('SELECT count(*) AS n FROM tracks').get() as {n:number}).n); collections = Number((this.db.prepare('SELECT count(*) AS n FROM collections').get() as {n:number}).n) } } catch { /* status remains unavailable */ }
    return { dbReady: this.db !== null, snapshotTime: this.snapshotTime, sourceMtime: this.sourceMtime, tracks, collections, error: this.error }
  }
}
