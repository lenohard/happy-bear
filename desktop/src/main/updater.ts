import { app } from 'electron'
import { autoUpdater } from 'electron-updater'

const STARTUP_DELAY_MS = 8_000
const CHECK_INTERVAL_MS = 60 * 60 * 1000 // 每小时

// 应用内热更新：仅打包后启用；provider github 由 electron-builder 的 publish 配置写成 app-update.yml
export function initUpdater(): void {
  if (!app.isPackaged) return

  autoUpdater.autoDownload = true
  autoUpdater.autoInstallOnAppQuit = true

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
