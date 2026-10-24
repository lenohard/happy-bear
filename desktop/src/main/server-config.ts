import { app } from 'electron'
import { existsSync, readFileSync, writeFileSync } from 'fs'
import { join } from 'path'
import type { ServerSettings } from '../shared/ipc'

export interface ServerConfig {
  baseUrl: string
  token: string
}

interface ServerConfigFile {
  baseUrl?: string
  token?: string
  enabled?: boolean
}

function configPath(): string {
  return join(app.getPath('userData'), 'server.json')
}

/** Optional Mac mini / library server connection. Disabled by default. */
export function readServerConfig(): ServerConfig | null {
  const settings = readServerSettings()
  if (!settings.enabled || !settings.baseUrl || !settings.token) return null
  return { baseUrl: settings.baseUrl.replace(/\/+$/, ''), token: settings.token }
}

export function readServerSettings(): ServerSettings {
  const file = configPath()
  let baseUrl = ''
  let token = ''
  let enabled = false
  let hasFile = false
  if (existsSync(file)) {
    try {
      const parsed = JSON.parse(readFileSync(file, 'utf8')) as ServerConfigFile
      hasFile = true
      baseUrl = parsed.baseUrl?.trim() ?? ''
      token = parsed.token?.trim() ?? ''
      enabled = parsed.enabled === true
    } catch {
      // invalid config file: fall back to environment variables
    }
  }
  if (!baseUrl || !token) {
    const envUrl = process.env.POLARBEAR_SERVER_URL?.trim() ?? ''
    const envToken = process.env.POLARBEAR_SERVER_TOKEN?.trim() ?? ''
    if (!hasFile && envUrl && envToken) {
      baseUrl = envUrl
      token = envToken
      enabled = true
    }
  }
  if (!baseUrl || !token) enabled = false
  return { enabled, baseUrl, token }
}

export function saveServerSettings(settings: ServerSettings): ServerSettings {
  const next: ServerSettings = {
    enabled: settings.enabled && !!settings.baseUrl && !!settings.token,
    baseUrl: settings.baseUrl.trim().replace(/\/+$/, ''),
    token: settings.token.trim()
  }
  writeFileSync(configPath(), JSON.stringify(next, null, 2), { mode: 0o600 })
  return next
}
