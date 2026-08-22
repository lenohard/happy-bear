import { app, safeStorage } from 'electron'
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'fs'
import { join } from 'path'
import { randomUUID } from 'crypto'

export interface RemoteJobsConfig {
  baseUrl: string | null
  token: string | null
}

export type JobStatus = 'queued' | 'running' | 'succeeded' | 'failed' | 'canceled'

export interface RemoteJob {
  id: string
  status: JobStatus
  progress: number
  phase: string | null
  error: { code: string; message: string } | null
  title: string | null
  subtype: string | null
  createdAt: string
  updatedAt: string
}

export interface LedgerEntry {
  localId: string
  trackId: string
  transcriptId: string
  serverJobId: string | null
  status: JobStatus | 'auth_failed' | 'submit_failed'
  createdAt: string
  updatedAt: string
  rawResult: string | null
  errorMessage: string | null
}

const configPath = (): string => join(app.getPath('userData'), 'remote-jobs-config.json')
const ledgerPath = (): string => join(app.getPath('userData'), 'remote-jobs-ledger.json')

let cachedConfig: RemoteJobsConfig | null = null
let ledger: LedgerEntry[] = []

const loadConfig = (): RemoteJobsConfig => {
  if (cachedConfig) return cachedConfig
  const path = configPath()
  if (!existsSync(path)) {
    cachedConfig = { baseUrl: null, token: null }
    return cachedConfig
  }
  try {
    const raw = JSON.parse(readFileSync(path, 'utf8')) as { encrypted?: string }
    if (raw.encrypted && safeStorage.isEncryptionAvailable()) {
      const decrypted = safeStorage.decryptString(Buffer.from(raw.encrypted, 'base64'))
      cachedConfig = JSON.parse(decrypted) as RemoteJobsConfig
    } else {
      cachedConfig = { baseUrl: null, token: null }
    }
  } catch {
    cachedConfig = { baseUrl: null, token: null }
  }
  return cachedConfig!
}

export const getConfig = (): RemoteJobsConfig => ({ ...loadConfig() })

export const setConfig = (next: RemoteJobsConfig): void => {
  const dir = app.getPath('userData')
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true })
  if (safeStorage.isEncryptionAvailable() && (next.baseUrl || next.token)) {
    const encrypted = safeStorage.encryptString(JSON.stringify(next)).toString('base64')
    writeFileSync(configPath(), JSON.stringify({ encrypted }, null, 2), 'utf8')
  } else {
    writeFileSync(configPath(), JSON.stringify({ baseUrl: next.baseUrl, token: next.token }, null, 2), 'utf8')
  }
  cachedConfig = { ...next }
}

const loadLedger = (): LedgerEntry[] => {
  if (ledger.length) return ledger
  const path = ledgerPath()
  if (!existsSync(path)) return []
  try {
    ledger = JSON.parse(readFileSync(path, 'utf8')) as LedgerEntry[]
  } catch {
    ledger = []
  }
  return ledger
}

const saveLedger = (): void => {
  const dir = app.getPath('userData')
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true })
  writeFileSync(ledgerPath(), JSON.stringify(ledger, null, 2), 'utf8')
}

const authHeader = (): string | null => {
  const cfg = loadConfig()
  if (!cfg.token) return null
  return `Bearer ${cfg.token}`
}

const baseUrl = (): string => {
  const cfg = loadConfig()
  if (!cfg.baseUrl) throw new Error('Remote Jobs server URL is not configured.')
  return cfg.baseUrl.replace(/\/$/, '')
}

interface ServerJobResponse {
  id: string
  status: JobStatus
  progress: number
  phase: string | null
  error: { code: string; message: string } | null
  title: string | null
  subtype: string | null
  created_at: string
  updated_at: string
}

const toRemoteJob = (job: ServerJobResponse): RemoteJob => ({
  id: job.id,
  status: job.status,
  progress: Number(job.progress) || 0,
  phase: job.phase ?? null,
  error: job.error,
  title: job.title,
  subtype: job.subtype,
  createdAt: job.created_at,
  updatedAt: job.updated_at
})

const submitFetch = async (): Promise<{ ok: boolean; data?: ServerJobResponse; errorMessage?: string }> => {
  const auth = authHeader()
  if (!auth) return { ok: false, errorMessage: 'AUTH_NOT_CONFIGURED' }
  const entry: LedgerEntry = {
    localId: randomUUID(),
    trackId: '',
    transcriptId: '',
    serverJobId: null,
    status: 'queued',
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    rawResult: null,
    errorMessage: null
  }
  return { ok: true }
}

export const submitSummary = async (params: { trackId: string; transcriptId: string; messages: Array<{ role: string; content: string }>; model: string; title: string; temperature?: number }): Promise<LedgerEntry> => {
  const auth = authHeader()
  if (!auth) throw new Error('未配置 Remote Jobs 凭据。')
  const entry: LedgerEntry = {
    localId: randomUUID(),
    trackId: params.trackId,
    transcriptId: params.transcriptId,
    serverJobId: null,
    status: 'queued',
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    rawResult: null,
    errorMessage: null
  }
  const response = await fetch(`${baseUrl()}/v1/jobs`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: auth },
    body: JSON.stringify({
      type: 'ai',
      task_id: params.trackId,
      input: { kind: 'text' },
      params: {
        model: params.model,
        temperature: params.temperature ?? 0.4,
        messages: params.messages
      },
      auto_ai_params: { title: params.title, subtype: 'track_summary' }
    })
  })
  if (response.status === 401) {
    entry.status = 'auth_failed'
    entry.errorMessage = '鉴权失败：检查 token。'
    ledger.push(entry)
    saveLedger()
    return entry
  }
  if (!response.ok) {
    const text = await response.text()
    entry.status = 'submit_failed'
    entry.errorMessage = `提交失败 ${response.status}: ${text.slice(0, 200)}`
    ledger.push(entry)
    saveLedger()
    return entry
  }
  const data = await response.json() as { data: { job: ServerJobResponse } }
  entry.serverJobId = data.data.job.id
  entry.status = data.data.job.status
  entry.updatedAt = new Date().toISOString()
  ledger.push(entry)
  saveLedger()
  return entry
}

export const pollJob = async (serverJobId: string): Promise<RemoteJob | null> => {
  const auth = authHeader()
  if (!auth) throw new Error('未配置 Remote Jobs 凭据。')
  const response = await fetch(`${baseUrl()}/v1/jobs/${serverJobId}`, { headers: { Authorization: auth } })
  if (response.status === 404) return null
  if (response.status === 401) {
    const entry = ledger.find(e => e.serverJobId === serverJobId)
    if (entry) {
      entry.status = 'auth_failed'
      entry.errorMessage = '鉴权失败：检查 token。'
      entry.updatedAt = new Date().toISOString()
      saveLedger()
    }
    throw new Error('鉴权失败。')
  }
  if (!response.ok) throw new Error(`状态查询失败 ${response.status}。`)
  const data = await response.json() as { data: { job: ServerJobResponse } }
  const job = toRemoteJob(data.data.job)
  const entry = ledger.find(e => e.serverJobId === serverJobId)
  if (entry) {
    entry.status = job.status
    entry.updatedAt = new Date().toISOString()
    saveLedger()
  }
  return job
}

export const fetchResult = async (serverJobId: string): Promise<string> => {
  const auth = authHeader()
  if (!auth) throw new Error('未配置 Remote Jobs 凭据。')
  const response = await fetch(`${baseUrl()}/v1/jobs/${serverJobId}/result`, { headers: { Authorization: auth } })
  if (!response.ok) throw new Error(`结果获取失败 ${response.status}。`)
  const data = await response.json() as { data: { result: { text?: string } } }
  const text = data.data.result.text ?? ''
  const entry = ledger.find(e => e.serverJobId === serverJobId)
  if (entry) {
    entry.rawResult = text
    entry.updatedAt = new Date().toISOString()
    saveLedger()
  }
  return text
}

export const cancelJob = async (serverJobId: string): Promise<void> => {
  const auth = authHeader()
  if (!auth) throw new Error('未配置 Remote Jobs 凭据。')
  await fetch(`${baseUrl()}/v1/jobs/${serverJobId}/cancel`, { method: 'POST', headers: { Authorization: auth } })
}

export const getLedger = (): LedgerEntry[] => [...loadLedger()]
export const getEntry = (localId: string): LedgerEntry | null => loadLedger().find(e => e.localId === localId) ?? null

export const startPolling = (
  serverJobId: string,
  onUpdate: (job: RemoteJob | null) => void,
  onResult: (text: string) => void,
  onError: (error: Error) => void
): { stop: () => void } => {
  let stopped = false
  let attempts = 0
  const tick = async () => {
    if (stopped) return
    try {
      const job = await pollJob(serverJobId)
      if (!job) {
        onError(new Error('服务器找不到该任务（可能已被删除）。'))
        return
      }
      onUpdate(job)
      if (job.status === 'succeeded') {
        const text = await fetchResult(serverJobId)
        onResult(text)
        return
      }
      if (job.status === 'failed' || job.status === 'canceled') {
        onError(new Error(job.error?.message ?? `任务 ${job.status}。`))
        return
      }
      attempts += 1
      const delay = Math.min(5000 * Math.pow(1.5, Math.min(attempts, 6)), 30000)
      setTimeout(tick, delay)
    } catch (error) {
      onError(error instanceof Error ? error : new Error(String(error)))
    }
  }
  setTimeout(tick, 1500)
  return { stop: () => { stopped = true } }
}
