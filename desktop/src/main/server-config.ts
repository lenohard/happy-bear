import { app } from 'electron'
import { existsSync, readFileSync, writeFileSync } from 'fs'
import { join } from 'path'
import type { ServerSettings } from '../shared/ipc'

export interface ServerConfig {
  baseUrl: string
}

interface ServerConfigFile {
  baseUrl?: string
  enabled?: boolean
}

function configPath(): string {
  return join(app.getPath('userData'), 'server.json')
}

/** Optional Mac mini / library server connection. Disabled by default. */
export function readServerConfig(): ServerConfig | null {
  const settings = readServerSettings()
  if (!settings.enabled || !settings.baseUrl) return null
  return { baseUrl: settings.baseUrl.replace(/\/+$/, '') }
}

export function readServerSettings(): ServerSettings {
  const file = configPath()
  let baseUrl = ''
  let enabled = false
  let hasFile = false
  if (existsSync(file)) {
    try {
      const parsed = JSON.parse(readFileSync(file, 'utf8')) as ServerConfigFile
      hasFile = true
      baseUrl = parsed.baseUrl?.trim() ?? ''
      enabled = parsed.enabled === true
    } catch {
      // invalid config file: fall back to environment variables
    }
  }
  if (!baseUrl) {
    const envUrl = process.env.POLARBEAR_SERVER_URL?.trim() ?? ''
    if (!hasFile && envUrl) {
      baseUrl = envUrl
      enabled = true
    }
  }
  if (!baseUrl) enabled = false
  return { enabled, baseUrl }
}

export function saveServerSettings(settings: ServerSettings): ServerSettings {
  const next: ServerSettings = {
    enabled: settings.enabled && !!settings.baseUrl,
    baseUrl: settings.baseUrl.trim().replace(/\/+$/, '')
  }
  writeFileSync(configPath(), JSON.stringify(next, null, 2), { mode: 0o600 })
  return next
}
