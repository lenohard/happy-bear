import { app } from 'electron'
import { autoUpdater } from 'electron-updater'
import type { UpdateState } from '../shared/ipc'

const STARTUP_DELAY_MS = 8_000
const CHECK_INTERVAL_MS = 60 * 60 * 1000 // 每小时

let state: UpdateState = { checking: false, updateAvailable: false, downloading: false, readyToInstall: false, latestVersion: null, error: null }
const listeners = new Set<(s: UpdateState) => void>()
function setState(patch: Partial<UpdateState>): void { state = { ...state, ...patch }; for (const fn of listeners) fn(state) }
export function getUpdateState(): UpdateState { return state }
export function onUpdateState(fn: (s: UpdateState) => void): () => void { listeners.add(fn); return () => { listeners.delete(fn) } }

// 应用内热更新：仅打包后启用；provider github 由 electron-builder 的 publish 配置写成 app-update.yml
export function initUpdater(): void {
  if (!app.isPackaged) return
  autoUpdater.autoDownload = true
  autoUpdater.autoInstallOnAppQuit = true
  autoUpdater.on('checking-for-update', () => setState({ checking: true, error: null }))
  autoUpdater.on('update-available', info => setState({ checking: false, updateAvailable: true, downloading: true, latestVersion: info.version }))
  autoUpdater.on('update-not-available', () => setState({ checking: false, updateAvailable: false, downloading: false }))
  autoUpdater.on('update-downloaded', info => setState({ downloading: false, readyToInstall: true, latestVersion: info.version }))
  autoUpdater.on('error', err => setState({ checking: false, downloading: false, error: err.message }))
  const check = (): void => {
    try {
      void autoUpdater.checkForUpdates()
    } catch {
      // 网络/服务器错误静默忽略，等下一轮再试
    }
  }
  setTimeout(check, STARTUP_DELAY_MS)
  setInterval(check, CHECK_INTERVAL_MS)
}

export function checkForUpdatesNow(): UpdateState {
  if (!app.isPackaged) { setState({ error: '开发模式下不支持更新检查' }); return state }
  try {
    void autoUpdater.checkForUpdates()
  } catch (err) {
    setState({ error: String(err) })
  }
  return state
}

export function installUpdate(): void {
  if (state.readyToInstall) autoUpdater.quitAndInstall()
}
