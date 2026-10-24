import { app } from 'electron'
import { existsSync, readFileSync } from 'fs'
import { join } from 'path'

export interface ServerConfig {
  baseUrl: string
  token: string
}

interface ServerConfigFile {
  baseUrl?: string
  token?: string
  enabled?: boolean
}

/**
 * Optional Mac mini / library server connection.
 * Disabled by default: without a configured base URL and token the desktop
 * keeps reading the local iCloud snapshot.
 */
export function readServerConfig(): ServerConfig | null {
  let fileUrl = ''
  let fileToken = ''
  const file = join(app.getPath('userData'), 'server.json')
  if (existsSync(file)) {
    try {
      const parsed = JSON.parse(readFileSync(file, 'utf8')) as ServerConfigFile
      if (parsed.enabled !== false) {
        fileUrl = parsed.baseUrl?.trim() ?? ''
        fileToken = parsed.token?.trim() ?? ''
      }
    } catch {
      // invalid config file: fall back to environment variables
    }
  }
  const baseUrl = (fileUrl || process.env.POLARBEAR_SERVER_URL?.trim() || '').replace(/\/+$/, '')
  const token = fileToken || process.env.POLARBEAR_SERVER_TOKEN?.trim() || ''
  if (!baseUrl || !token) return null
  return { baseUrl, token }
}
