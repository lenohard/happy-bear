# PolarBear Desktop

## 命令

```bash
npm install
npm run dev       # electron-vite 开发模式
npm run typecheck # main/preload/renderer TypeScript
npm run build     # electron-vite 生产构建
npm run dist      # macOS dmg + zip（本地不签名/不公证）
```

## 架构

- `src/main/index.ts` 注册 `hb-media`、`hb-cover` privileged protocol，创建 sandbox BrowserWindow，并注册 IPC。
- `src/main/library-db.ts` 将 iCloud `library.sqlite`（及 wal/shm）复制到 `app.getPath('userData')/library-snapshot.sqlite`，验证后以 `node:sqlite` `readOnly` 打开。源库和快照绝不执行写操作；每 30 秒、窗口聚焦或手动刷新检查 mtime+size。
- `src/main/library.ts` 只读分页查询合集、曲目、搜索、继续收听、收藏和播放 payload。
- `src/main/baidu.ts` 移植 corner OAuth；凭据仅在 main 中由 Electron `safeStorage` 加密到 userData，播放使用带 Range 的 dlink 代理，不保存签名 URL。
- `src/main/media-net.ts` 使用 Electron `net.request` 转发外部媒体，避免把 renderer 请求头转发到上游。
- `src/shared/ipc.ts` 是 main/preload/renderer 的唯一 DTO/IPC 合约；preload 仅暴露类型化 API。
- renderer 为 React 18 暗色 UI，HTMLAudio 播放 `hb-media://track/{id}`，播放进度只从 `playback_states` resume，不写回数据库。

## 数据模型注意

iOS 数据库含 8 个 folder、collections、tracks、playback_states 等表；JSON payload 的 `location_type` 为 `baidu`、`external`、`text`、`local`、`cachedText`。桌面只播放 baidu/external，text 以阅读器显示，local/cachedText 标记不支持。归档合集/曲目默认隐藏。日期值是 SQLite DATETIME 字符串。

## 安全和经验

renderer 必须保持 `contextIsolation:true`、`nodeIntegration:false`、`sandbox:true`。不要读取或提交 `.env`（vite `loadEnv` 负责百度配置注入）。不要在 renderer 接触 token；不要持久化签名下载 URL。`hb-cover` 必须限制在 iCloud Documents 根目录内。Phase 1 严格只读：不要在任何 `DatabaseSync` 实例上调用 INSERT/UPDATE/DELETE/PRAGMA 写操作。
