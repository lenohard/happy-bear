# PolarBear Desktop

## 命令

```bash
npm install
npm run dev       # electron-vite 开发模式
npm run typecheck # main/preload/renderer TypeScript
npm run build     # electron-vite 生产构建
npm run dist      # macOS dmg + zip（本地不签名/不公证）
```

## CLI（命令行控制）

PolarBear 内置一个命令行接口，让 agent/终端查询信息并控制播放，架构移植自 corner（HTTP 服务端仅监听 `127.0.0.1`，随机端口写入 `userData/cli-port`，Bearer token 写入 `userData/cli-token`，防误触发）。

- 服务端：`src/main/cli-server.ts`；`whenReady` 启动，`before-quit` 停止（接线见 `src/main/index.ts`）。
- 客户端：`scripts/polarbear-cli.mjs`。开发时用 `node scripts/polarbear-cli.mjs`；打包版经 `electron-builder.yml` 的 `extraResources` 打进 app（`Contents/Resources/polarbear-cli.mjs`），并可用 `npm install -g`（package.json `bin` 字段）装成 `polarbear` 命令。所有命令加 `--json` 输出 JSON。
- 查询走 app 内已有的 `LibraryService`（只读，CLI 绝不直接写 sqlite）；播放命令经 IPC 发到 renderer 控制 HTMLAudio。

常用命令：

```bash
# 状态
polarbear status                                   # 当前播放 + 库状态
polarbear baidu-status                             # 百度登录状态
# 库查询（只读）
polarbear folders
polarbear collections [--folder-id <id>] [--archived]
polarbear tracks <collectionId> [--page N] [--page-size N]
polarbear search <query>
polarbear favorites
polarbear continue [limit]
# 播放控制
polarbear play --track-id <id>
polarbear play --collection-id <id>
polarbear play --query <query>
polarbear toggle | pause | resume
polarbear next | prev
polarbear volume <0..1>
polarbear seek <sec> | +<sec> | -<sec>
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

## 发布流程（tag → CI 构建签名公证 → 应用内热更新）

流程参考 corner 仓库（`lenohard/macos-player`），已移植到本仓库 `.github/workflows/release.yml` + `desktop/electron-builder.yml` + `desktop/src/main/updater.ts`（electron-updater provider github）。

```bash
# 在 desktop/ 下
npm install          # 首次，拉取 electron-updater
npm run dist         # 本地：出 unsigned dmg/zip（CSC_IDENTITY_AUTO_DISCOVERY=false，不签名/不公证/不发布）
```

发布一个版本：

1. 改 `desktop/package.json` 的 `version`（如 `0.1.0` → `0.1.1`）。
2. commit 改动并 push：`git add -A && git commit -m "chore(desktop): release v0.1.1" && git push`。
3. 打 tag（必须匹配 `v*.*.*`）触发 `.github/workflows/release.yml`：
   ```bash
   git tag v0.1.1
   git push origin v0.1.1
   ```
4. CI 在 `macos-latest` 上 `npm run release`：electron-builder 用 CSC_LINK 签名 + APPLE_API_* 公证，产出 `polarbear-{version}-mac-{arch}.{ext}`（dmg+zip），用 GH_TOKEN 发布到当前 tag 的 GitHub Release。
5. 已安装用户启动/每小时检查更新，electron-updater 自动下载并在退出时安装。

CI 需要在这个 GitHub 仓库（`lenohard/happy-bear`）配以下 secrets（corner 仓库 `lenohard/macos-player` 已有同名 secrets，可直接复制值）：

| secret | 含义 |
|---|---|
| `GH_TOKEN` | 用 `secrets.GITHUB_TOKEN`（自动注入，无需手动配） |
| `CSC_LINK` | Developer ID 证书 p12（base64），用于签名 |
| `CSC_KEY_PASSWORD` | p12 密码 |
| `APPLE_API_KEY` | App Store Connect API p8 的 base64（Prepare 步骤解码到 `/tmp/asc/AuthKey_3474G52856.p8`） |
| `APPLE_API_KEY_ID` | p8 key id（如 3474G52856） |
| `APPLE_API_ISSUER` | App Store Connect issuer id |
| `BAIDU_CLIENT_ID` | 百度网盘 OAuth client id（构建时 `loadEnv` 注入 renderer/main） |
| `BAIDU_CLIENT_SECRET` | 百度网盘 OAuth client secret |
| `BAIDU_REDIRECT_URI` | 百度网盘 OAuth 回调 uri |
| `BAIDU_SCOPE` | 百度网盘 OAuth scope |

注意：CI 环境不会读取本地 `.env`，百度配置全部来自上述 secrets 注入的 `process.env`。
