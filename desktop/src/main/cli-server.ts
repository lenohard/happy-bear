import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'http'
import { writeFileSync, unlinkSync } from 'fs'
import { randomBytes, randomUUID, timingSafeEqual } from 'crypto'
import { join } from 'path'
import { app, type BrowserWindow } from 'electron'
import {
  PLAYBACK_REMOTE_COMMAND_CHANNEL,
  type PlaybackState,
  type RemoteCommand
} from '../shared/ipc'
import type { LibraryService } from './library'
import type { BaiduService } from './baidu'

const COMMAND_ACK_TIMEOUT_MS = 3000

interface CliServerContext {
  library: LibraryService
  baidu: BaiduService
  getMainWindow: () => BrowserWindow | null
}

interface PendingCommand {
  resolve: (ok: boolean) => void
  timer: NodeJS.Timeout
}

let server: Server | null = null
let playbackState: PlaybackState | null = null
let authToken: string | null = null
const pendingCommands = new Map<string, PendingCommand>()

export function setPlaybackState(state: PlaybackState | null): void {
  playbackState = state
}

export function ackRemoteCommand(commandId: string): void {
  const pending = pendingCommands.get(commandId)
  if (!pending) return
  clearTimeout(pending.timer)
  pendingCommands.delete(commandId)
  pending.resolve(true)
}

function portFilePath(): string {
  return join(app.getPath('userData'), 'cli-port')
}

function tokenFilePath(): string {
  return join(app.getPath('userData'), 'cli-token')
}

function writePortFile(port: number): void {
  writeFileSync(portFilePath(), String(port), 'utf8')
}

function writeTokenFile(token: string): void {
  writeFileSync(tokenFilePath(), token, { mode: 0o600, encoding: 'utf8' })
}

function removePortFile(): void {
  try {
    unlinkSync(portFilePath())
  } catch {
    // 文件不存在，忽略
  }
}

function removeTokenFile(): void {
  try {
    unlinkSync(tokenFilePath())
  } catch {
    // 文件不存在，忽略
  }
}

function readJsonBody(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    req.on('data', (chunk: Buffer) => chunks.push(chunk))
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8')
      if (!raw.trim()) return resolve(null)
      try {
        resolve(JSON.parse(raw))
      } catch {
        reject(new Error('Invalid JSON body'))
      }
    })
    req.on('error', reject)
  })
}

function jsonReply(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { 'Content-Type': 'application/json' })
  res.end(JSON.stringify(body))
}

function isAuthorized(req: IncomingMessage): boolean {
  if (!authToken) return false
  const header = req.headers['authorization']
  if (!header) return false
  const actual = Buffer.from(header)
  const expected = Buffer.from(`Bearer ${authToken}`)
  if (actual.length !== expected.length) return false
  return timingSafeEqual(actual, expected)
}

function dispatchRemoteCommand(win: BrowserWindow, command: RemoteCommand): Promise<boolean> {
  const commandId = randomUUID()
  return new Promise<boolean>(resolve => {
    const timer = setTimeout(() => {
      pendingCommands.delete(commandId)
      resolve(false)
    }, COMMAND_ACK_TIMEOUT_MS)
    pendingCommands.set(commandId, { resolve, timer })
    if (win.isDestroyed()) {
      clearTimeout(timer)
      pendingCommands.delete(commandId)
      resolve(false)
      return
    }
    try {
      win.webContents.send(PLAYBACK_REMOTE_COMMAND_CHANNEL, { ...command, id: commandId })
    } catch {
      clearTimeout(timer)
      pendingCommands.delete(commandId)
      resolve(false)
    }
  })
}

function sendRemoteCommand(ctx: CliServerContext, command: RemoteCommand): Promise<boolean> {
  const win = ctx.getMainWindow()
  if (!win || win.isDestroyed()) return Promise.resolve(false)
  // 新建窗口刚触发时渲染进程尚未就绪，等待页面加载完成再发命令，避免消息丢失
  if (win.webContents.isLoading()) {
    return new Promise<boolean>(resolve => {
      const onLoaded = (): void => {
        win.webContents.removeListener('did-finish-load', onLoaded)
        resolve(dispatchRemoteCommand(win, command))
      }
      const timeout = setTimeout(() => {
        win.webContents.removeListener('did-finish-load', onLoaded)
        resolve(false)
      }, COMMAND_ACK_TIMEOUT_MS)
      win.webContents.once('did-finish-load', () => {
        clearTimeout(timeout)
        onLoaded()
      })
    })
  }
  return dispatchRemoteCommand(win, command)
}

function clampVolume(value: unknown): number {
  const number = typeof value === 'number' ? value : NaN
  if (!Number.isFinite(number)) throw new Error('音量必须是 0~1 之间的数字。')
  return Math.min(1, Math.max(0, number))
}

async function handleRequest(
  ctx: CliServerContext,
  req: IncomingMessage,
  res: ServerResponse
): Promise<void> {
  const url = new URL(req.url ?? '/', `http://127.0.0.1`)
  const method = req.method ?? 'GET'
  const path = url.pathname

  try {
    // GET /health — liveness probe, no auth
    if (method === 'GET' && path === '/health') {
      return jsonReply(res, 200, { ok: true })
    }

    if (!isAuthorized(req)) {
      return jsonReply(res, 401, { error: 'Unauthorized' })
    }

    // GET /status — 播放状态 + 库状态（只读）
    if (method === 'GET' && path === '/status') {
      return jsonReply(res, 200, {
        ok: true,
        running: true,
        playback: playbackState,
        library: ctx.library.status()
      })
    }

    // GET /folders
    if (method === 'GET' && path === '/folders') {
      return jsonReply(res, 200, { folders: ctx.library.folders() })
    }

    // GET /collections?folderId=...&archived=1
    if (method === 'GET' && path === '/collections') {
      const folderId = url.searchParams.get('folderId')
      const includeArchived = url.searchParams.get('archived') === '1'
      return jsonReply(res, 200, { collections: ctx.library.collections(folderId, includeArchived) })
    }

    // GET /tracks?collectionId=...&page=...&pageSize=...
    if (method === 'GET' && path === '/tracks') {
      const collectionId = url.searchParams.get('collectionId') ?? ''
      if (!collectionId) return jsonReply(res, 400, { error: 'Missing collectionId' })
      const page = parseInt(url.searchParams.get('page') ?? '0', 10) || 0
      const pageSize = parseInt(url.searchParams.get('pageSize') ?? '200', 10) || 200
      return jsonReply(res, 200, ctx.library.tracks(collectionId, page, pageSize))
    }

    // GET /continue?limit=20
    if (method === 'GET' && path === '/continue') {
      const limit = parseInt(url.searchParams.get('limit') ?? '20', 10) || 20
      return jsonReply(res, 200, { entries: ctx.library.continueListening(limit) })
    }

    // GET /favorites
    if (method === 'GET' && path === '/favorites') {
      return jsonReply(res, 200, { tracks: ctx.library.favorites() })
    }

    // GET /search?q=...&limit=50
    if (method === 'GET' && path === '/search') {
      const query = url.searchParams.get('q') ?? ''
      const limit = Math.min(parseInt(url.searchParams.get('limit') ?? '50', 10) || 50, 200)
      return jsonReply(res, 200, { tracks: ctx.library.search(query, limit) })
    }

    // GET /baidu-status
    if (method === 'GET' && path === '/baidu-status') {
      return jsonReply(res, 200, await ctx.baidu.getStatus())
    }

    // POST /play — body { trackId } | { collectionId } | { query }
    if (method === 'POST' && path === '/play') {
      const body = (await readJsonBody(req)) as Record<string, unknown> | null
      if (!body) return jsonReply(res, 400, { error: 'Missing request body' })

      if (body.trackId) {
        const track = ctx.library.getTrack(String(body.trackId))
        if (!track) return jsonReply(res, 404, { error: 'Track not found' })
        const sent = await sendRemoteCommand(ctx, { action: 'playSingle', track })
        return jsonReply(res, 200, { ok: sent, track })
      }

      if (body.collectionId) {
        const page = ctx.library.tracks(String(body.collectionId), 0, 500)
        if (page.tracks.length === 0) {
          return jsonReply(res, 404, { error: 'Collection not found or empty' })
        }
        const sent = await sendRemoteCommand(ctx, { action: 'play', tracks: page.tracks })
        return jsonReply(res, 200, { ok: sent, trackCount: page.tracks.length })
      }

      if (body.query) {
        const tracks = ctx.library.search(String(body.query), 1)
        if (tracks.length === 0) return jsonReply(res, 404, { error: 'No tracks found' })
        const sent = await sendRemoteCommand(ctx, { action: 'playSingle', track: tracks[0] })
        return jsonReply(res, 200, { ok: sent, track: tracks[0] })
      }

      return jsonReply(res, 400, { error: 'Provide trackId, collectionId, or query' })
    }

    // POST /toggle-play / pause / resume
    if (method === 'POST' && (path === '/toggle-play' || path === '/pause' || path === '/resume')) {
      const command: RemoteCommand = path === '/toggle-play'
        ? { action: 'togglePlay' }
        : path === '/pause' ? { action: 'pause' } : { action: 'resume' }
      const sent = await sendRemoteCommand(ctx, command)
      return jsonReply(res, 200, { ok: sent })
    }

    // POST /next
    if (method === 'POST' && path === '/next') {
      const sent = await sendRemoteCommand(ctx, { action: 'next' })
      return jsonReply(res, 200, { ok: sent })
    }

    // POST /prev
    if (method === 'POST' && path === '/prev') {
      const sent = await sendRemoteCommand(ctx, { action: 'prev' })
      return jsonReply(res, 200, { ok: sent })
    }

    // POST /volume — body { volume: 0..1 }
    if (method === 'POST' && path === '/volume') {
      const body = (await readJsonBody(req)) as Record<string, unknown> | null
      if (!body || typeof body.volume !== 'number') {
        return jsonReply(res, 400, { error: 'Provide volume (0..1)' })
      }
      const volume = clampVolume(body.volume)
      const sent = await sendRemoteCommand(ctx, { action: 'setVolume', volume })
      return jsonReply(res, 200, { ok: sent, volume })
    }

    // POST /seek — body { positionSec } (absolute) or { offsetSec } (relative)
    if (method === 'POST' && path === '/seek') {
      const body = (await readJsonBody(req)) as Record<string, unknown> | null
      let positionSec: number
      if (body && typeof body.positionSec === 'number') {
        positionSec = body.positionSec
      } else if (body && typeof body.offsetSec === 'number') {
        positionSec = (playbackState?.positionSec ?? 0) + body.offsetSec
      } else {
        return jsonReply(res, 400, { error: 'Provide positionSec or offsetSec' })
      }
      positionSec = Math.max(0, positionSec)
      const sent = await sendRemoteCommand(ctx, { action: 'seek', positionSec })
      return jsonReply(res, 200, { ok: sent, positionSec })
    }

    return jsonReply(res, 404, { error: 'Not found' })
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Internal error'
    jsonReply(res, 500, { error: message })
  }
}

export function startCliServer(library: LibraryService, baidu: BaiduService, getMainWindow: () => BrowserWindow | null): void {
  const ctx: CliServerContext = { library, baidu, getMainWindow }

  authToken = randomBytes(16).toString('hex')
  writeTokenFile(authToken)

  server = createServer((req, res) => {
    void handleRequest(ctx, req, res)
  })

  server.listen(0, '127.0.0.1', () => {
    const addr = server!.address()
    if (addr && typeof addr === 'object') {
      writePortFile(addr.port)
      console.log(`[CLI] server listening on 127.0.0.1:${addr.port}`)
    }
  })

  server.on('error', error => {
    console.error('[CLI] server error:', error.message)
  })
}

export function stopCliServer(): void {
  removePortFile()
  removeTokenFile()
  for (const pending of pendingCommands.values()) {
    clearTimeout(pending.timer)
    pending.resolve(false)
  }
  pendingCommands.clear()
  if (server) {
    server.close()
    server = null
  }
}
