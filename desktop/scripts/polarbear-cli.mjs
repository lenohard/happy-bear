#!/usr/bin/env node
/**
 * polarbear CLI — remote control for the PolarBear read-only audiobook player.
 *
 * Usage:
 *   polarbear help                              show this help
 *   polarbear status                            show playback + library status
 *   polarbear folders                           list folders
 *   polarbear collections [--folder-id <id>] [--archived]   list collections
 *   polarbear tracks <collectionId> [--page N] [--page-size N]
 *   polarbear continue [limit]                  show continue-listening tracks
 *   polarbear favorites                         list favorite tracks
 *   polarbear search <query>                    search collections/tracks
 *   polarbear baidu-status                      show Baidu login status
 *   polarbear play --track-id <id>              play a single track
 *   polarbear play --collection-id <id>         play a whole collection
 *   polarbear play --query <query>              search & play first match
 *   polarbear toggle                            toggle play/pause
 *   polarbear pause                             pause playback
 *   polarbear resume                            resume playback
 *   polarbear next                              next track
 *   polarbear prev                              previous track
 *   polarbear volume <0..1>                     set volume
 *   polarbear seek <seconds> | +<seconds> | -<seconds>   seek (absolute or relative)
 *
 * JSON output: add --json or -j to any command.
 */

import { readFileSync } from 'fs'
import { homedir } from 'os'
import { join } from 'path'
import { execSync } from 'child_process'

const USER_DATA_DIRS = ['PolarBear', 'polarbear-desktop']

function userDataDirs() {
  return USER_DATA_DIRS.map(basename => join(homedir(), 'Library', 'Application Support', basename))
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}

function getPort() {
  for (const dir of userDataDirs()) {
    try {
      const port = parseInt(readFileSync(join(dir, 'cli-port'), 'utf8').trim(), 10)
      if (port) return port
    } catch {
      // 目录或文件不存在，继续
    }
  }
  return null
}

function getToken() {
  for (const dir of userDataDirs()) {
    try {
      const token = readFileSync(join(dir, 'cli-token'), 'utf8').trim()
      if (token) return token
    } catch {
      // 继续
    }
  }
  return null
}

function openApp() {
  try {
    execSync('open -a PolarBear', { stdio: 'ignore', timeout: 5000 })
  } catch {
    // app may not be installed — will be caught by waitForPort
  }
}

async function ensurePort() {
  let port = getPort()
  if (port) return port

  openApp()
  for (let i = 0; i < 15; i++) {
    await sleep(2000)
    port = getPort()
    if (port) return port
  }
  throw new Error('PolarBear app did not start in time (is the app installed / running?)')
}

async function request(path, method = 'GET', body = null) {
  const port = await ensurePort()
  const headers = {}
  if (body) headers['Content-Type'] = 'application/json'
  const token = getToken()
  if (token) headers['Authorization'] = `Bearer ${token}`
  const options = { method, headers }
  if (body) options.body = JSON.stringify(body)

  const res = await fetch(`http://127.0.0.1:${port}${path}`, options)
  const data = await res.json()
  if (!res.ok) {
    const msg = data.error || `HTTP ${res.status}`
    throw new Error(msg)
  }
  return data
}

function isJsonFlag(arg) {
  return arg === '--json' || arg === '-j'
}

// Positional args (excludes --json/-j, keeps everything else incl. negative numbers)
function positional(args) {
  return args.filter(a => !isJsonFlag(a))
}

function flagValue(args, name) {
  const index = args.indexOf(name)
  return index >= 0 && index + 1 < args.length ? args[index + 1] : null
}

function print(data, useJson) {
  if (useJson) {
    console.log(JSON.stringify(data, null, 2))
  } else {
    console.log(formatHuman(data))
  }
}

function formatTime(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return '0:00'
  const minutes = Math.floor(seconds / 60)
  const remaining = Math.floor(seconds % 60)
  return `${minutes}:${remaining.toString().padStart(2, '0')}`
}

function trackLine(t, index) {
  const num = index ? `${index}. ` : ''
  return `${num}${t.displayName} — ${t.chapter || t.locationType} [${t.locationType}] (id: ${t.id})`
}

function formatHuman(data) {
  if (!data) return ''

  // collections list
  if (data.collections && Array.isArray(data.collections)) {
    if (data.collections.length === 0) return 'No collections.'
    return data.collections.map((c, i) =>
      `${i + 1}. ${c.title} — ${c.author || 'unknown'} (${c.trackCount} tracks, id: ${c.id})`
    ).join('\n')
  }

  // folder list
  if (data.folders && Array.isArray(data.folders)) {
    if (data.folders.length === 0) return 'No folders.'
    return data.folders.map((f, i) => `${i + 1}. ${f.name} (id: ${f.id})`).join('\n')
  }

  // track page / search / favorites (wrapped in { tracks })
  if (data.tracks && Array.isArray(data.tracks)) {
    if (data.tracks.length === 0) return 'No tracks found.'
    const total = data.total !== undefined ? ` (${data.total} total)` : ''
    return data.tracks.map((t, i) => trackLine(t, i + 1)).join('\n') + `\n${data.tracks.length} shown${total}`
  }

  // continue-listening entries
  if (data.entries && Array.isArray(data.entries)) {
    if (data.entries.length === 0) return 'No continue-listening items.'
    return data.entries.map((e, i) =>
      `${i + 1}. ${e.displayName} — ${e.collectionTitle || 'unknown'} (${formatTime(e.playback?.position ?? 0)} / ${formatTime(e.duration)})`
    ).join('\n')
  }

  // single track play result
  if (data.track && data.track.displayName) {
    return `▶ ${data.track.displayName} — ${data.track.chapter || data.track.locationType}`
  }

  // collection play result
  if (data.trackCount !== undefined && data.ok) {
    return `▶ Playing collection (${data.trackCount} tracks)`
  }

  // status
  if (data.ok !== undefined && data.running) {
    const lines = ['polarbear is running']
    const pb = data.playback
    if (pb) {
      const icon = pb.isPlaying ? '▶' : '⏸'
      if (pb.currentTrack) {
        lines.push(`  ${icon} ${pb.currentTrack.displayName} — ${pb.currentTrack.chapter || pb.currentTrack.locationType}`)
        lines.push(`    id: ${pb.currentTrack.id} | type: ${pb.currentTrack.locationType}`)
        lines.push(`    ${formatTime(pb.positionSec)} / ${formatTime(pb.durationSec)} | volume: ${Math.round((pb.volume ?? 1) * 100)}%`)
      } else {
        lines.push(`  ${icon} No track loaded`)
      }
      lines.push(`  queue: ${pb.queueLength} tracks | index: ${pb.currentIndex}`)
    } else {
      lines.push('  No playback info')
    }
    if (data.library) {
      lines.push(`  library: dbReady=${data.library.dbReady} | ${data.library.tracks} tracks | ${data.library.collections} collections`)
    }
    return lines.join('\n')
  }

  // baidu status
  if (data.configured !== undefined && data.connected !== undefined) {
    const expiry = data.expiresAt ? ` (expires ${new Date(data.expiresAt).toLocaleString()})` : ''
    return `Baidu: ${data.connected ? 'connected' : 'not connected'}${expiry}${data.configured ? '' : ' (not configured)'}`
  }

  // simple ok response
  if (data.ok !== undefined && data.ok) return 'OK'

  return JSON.stringify(data, null, 2)
}

const HELP = `polarbear CLI — remote control for the PolarBear read-only audiobook player

Usage:
  polarbear help                            show this help
  polarbear status                          show playback + library status
  polarbear folders                         list folders
  polarbear collections [--folder-id <id>] [--archived]   list collections
  polarbear tracks <collectionId> [--page N] [--page-size N]
  polarbear continue [limit]                show continue-listening tracks
  polarbear favorites                       list favorite tracks
  polarbear search <query>                  search collections/tracks
  polarbear baidu-status                    show Baidu login status
  polarbear play --track-id <id>            play a single track
  polarbear play --collection-id <id>       play a whole collection
  polarbear play --query <query>            search & play first match
  polarbear toggle                          toggle play/pause
  polarbear pause                           pause playback
  polarbear resume                          resume playback
  polarbear next                            next track
  polarbear prev                            previous track
  polarbear volume <0..1>                   set volume
  polarbear seek <sec> | +<sec> | -<sec>    seek absolute / relative

Add --json or -j to any command for JSON output.`

async function main() {
  const args = process.argv.slice(2)
  if (args.length === 0) {
    console.log(HELP)
    process.exit(0)
  }

  const cmd = args[0]
  const rest = args.slice(1)
  const useJson = rest.some(isJsonFlag)
  const flags = positional(rest)

  try {
    switch (cmd) {
      case 'help':
      case '--help':
      case '-h':
        console.log(HELP)
        break

      case 'status': {
        const data = await request('/status')
        print(data, useJson)
        break
      }
      case 'folders': {
        const data = await request('/folders')
        print(data, useJson)
        break
      }
      case 'collections': {
        const folderId = flagValue(args, '--folder-id')
        const archived = args.includes('--archived') ? '1' : ''
        const query = new URLSearchParams()
        if (folderId) query.set('folderId', folderId)
        if (archived) query.set('archived', archived)
        const qs = query.toString()
        const data = await request(`/collections${qs ? `?${qs}` : ''}`)
        print(data, useJson)
        break
      }
      case 'tracks': {
        if (flags.length === 0) {
          console.error('Usage: polarbear tracks <collectionId> [--page N] [--page-size N]')
          process.exit(1)
        }
        const collectionId = flags[0]
        const page = flagValue(args, '--page') || '0'
        const pageSize = flagValue(args, '--page-size') || '200'
        const data = await request(`/tracks?collectionId=${encodeURIComponent(collectionId)}&page=${encodeURIComponent(page)}&pageSize=${encodeURIComponent(pageSize)}`)
        print(data, useJson)
        break
      }
      case 'continue': {
        const limit = flags[0] || '20'
        const data = await request(`/continue?limit=${encodeURIComponent(limit)}`)
        print(data, useJson)
        break
      }
      case 'favorites': {
        const data = await request('/favorites')
        print(data, useJson)
        break
      }
      case 'search': {
        if (flags.length === 0) {
          console.error('Usage: polarbear search <query>')
          process.exit(1)
        }
        const query = flags.join(' ')
        const data = await request(`/search?q=${encodeURIComponent(query)}&limit=50`)
        print(data, useJson)
        break
      }
      case 'baidu-status': {
        const data = await request('/baidu-status')
        print(data, useJson)
        break
      }
      case 'play': {
        const trackId = flagValue(args, '--track-id')
        const collectionId = flagValue(args, '--collection-id')
        const query = flagValue(args, '--query')

        if (trackId) {
          const data = await request('/play', 'POST', { trackId })
          print(data, useJson)
        } else if (collectionId) {
          const data = await request('/play', 'POST', { collectionId })
          print(data, useJson)
        } else if (query) {
          const data = await request('/play', 'POST', { query })
          print(data, useJson)
        } else {
          console.error('Usage: polarbear play --track-id <id> | --collection-id <id> | --query <query>')
          process.exit(1)
        }
        break
      }
      case 'toggle': {
        const data = await request('/toggle-play', 'POST')
        print(data, useJson)
        break
      }
      case 'pause': {
        const data = await request('/pause', 'POST')
        print(data, useJson)
        break
      }
      case 'resume': {
        const data = await request('/resume', 'POST')
        print(data, useJson)
        break
      }
      case 'next': {
        const data = await request('/next', 'POST')
        print(data, useJson)
        break
      }
      case 'prev': {
        const data = await request('/prev', 'POST')
        print(data, useJson)
        break
      }
      case 'volume': {
        if (flags.length === 0) {
          console.error('Usage: polarbear volume <0..1>')
          process.exit(1)
        }
        const volume = parseFloat(flags[0])
        if (!Number.isFinite(volume)) {
          console.error('Invalid volume (expected 0..1)')
          process.exit(1)
        }
        const data = await request('/volume', 'POST', { volume })
        print(data, useJson)
        break
      }
      case 'seek': {
        if (flags.length === 0) {
          console.error('Usage: polarbear seek <seconds> | +<seconds> | -<seconds>')
          process.exit(1)
        }
        const arg = flags[0]
        const value = parseFloat(arg)
        if (!Number.isFinite(value)) {
          console.error('Invalid seek position')
          process.exit(1)
        }
        const body = arg.startsWith('+') || arg.startsWith('-')
          ? { offsetSec: value }
          : { positionSec: value }
        const data = await request('/seek', 'POST', body)
        print(data, useJson)
        break
      }
      default:
        console.error(`Unknown command: ${cmd}`)
        console.error(HELP)
        process.exit(1)
    }
  } catch (error) {
    console.error(error.message)
    process.exit(1)
  }
}

main()
