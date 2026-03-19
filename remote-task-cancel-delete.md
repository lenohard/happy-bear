# Remote Task: 缺少终止和删除功能

**Created**: 2026-03-19
**Status**: Pending
**Priority**: Medium

## 问题描述

Remote Task（远程任务）目前缺少终止（cancel）和删除（delete）功能。服务端有 cancel 端点但 iOS 客户端从未调用；delete 功能完全缺失。

## 修复范围

### 1. 服务端 (`server/app/main.py`)

#### 现状
- ✅ `POST /v1/jobs/{job_id}/cancel` — 已实现，将状态改为 `canceled`
- ❌ `DELETE /v1/jobs/{job_id}` — 未实现
- ❌ Cancel 时**没有终止运行中的后台任务**（`run_job` 使用 FastAPI `BackgroundTasks`，无取消机制）

#### 需要修复
- [ ] 增加 `DELETE /v1/jobs/{job_id}` 端点
  - 删除数据库记录
  - 清理对应的 `storage/` 文件（input + result）
  - 仅允许删除已完成/失败/取消的任务
- [ ] Cancel 时真正终止运行中的任务
  - 方案：用 `asyncio.Event` 或全局 `dict[task_id, cancel_flag]` 标记
  - `run_job` 循环中检查取消标记，提前退出
  - 或改用 `multiprocessing` / `subprocess` 管理长时间任务

### 2. 服务端 (`server/app/db.py`)

#### 需要修复
- [ ] 增加 `delete_job(job_id)` 方法，删除 jobs 表记录

### 3. 服务端 (`server/app/storage.py`)

#### 需要修复
- [ ] 增加 `delete_job_files(job_id)` 方法，清理 storage 下该 job 的所有文件

### 4. iOS 客户端 (`AudiobookPlayer/RemoteJobsStore.swift`)

#### 现状
- 只有 `testConnection` 和 `@Published jobs: [RemoteJob]`
- 没有 cancel / delete / list jobs 方法

#### 需要修复
- [ ] 增加 `fetchJobs()` — 从服务器拉取 job 列表（调用 `GET /v1/jobs`）
- [ ] 增加 `cancelJob(_ jobId: String)` — 调用 `POST /v1/jobs/{job_id}/cancel`
- [ ] 增加 `deleteJob(_ jobId: String)` — 调用 `DELETE /v1/jobs/{job_id}`
- [ ] 考虑增加自动轮询（Timer / async）刷新 job 状态

### 5. iOS 客户端 — UI

#### 需要修复
- [ ] `TTSJobProgressSheet.swift` — 增加取消按钮（仅 queued/running 状态显示）
- [ ] 考虑增加 Remote Jobs 列表页面，支持滑动删除
- [ ] `AIGenerationJobExecutor.swift` 中的 `pollRemoteAIJob` 应支持取消（检查 Task.isCancelled）

## 关键文件

| 文件 | 路径 | 作用 |
|------|------|------|
| main.py | `~/projects/happy-bear/server/app/main.py` | API 端点定义 |
| db.py | `~/projects/happy-bear/server/app/db.py` | 数据库操作 |
| storage.py | `~/projects/happy-bear/server/app/storage.py` | 文件存储路径 |
| workers.py | `~/projects/happy-bear/server/app/workers.py` | 后台任务执行 |
| RemoteJobsStore.swift | `~/projects/happy-bear/AudiobookPlayer/RemoteJobsStore.swift` | iOS 远程任务状态管理 |
| AIGenerationJobExecutor.swift | `~/projects/happy-bear/AudiobookPlayer/AIGenerationJobExecutor.swift` | iOS AI 任务执行器 |
| TTSJobProgressSheet.swift | `~/projects/happy-bear/AudiobookPlayer/TTSJobProgressSheet.swift` | TTS 进度 UI |
| models.py | `~/projects/happy-bear/server/app/models.py` | Pydantic 数据模型 |

## 当前 API 端点（参考）

```
POST   /v1/jobs                    — 创建任务
POST   /v1/jobs/{job_id}/upload    — 上传文件
GET    /v1/jobs/{job_id}           — 查询任务状态
GET    /v1/jobs                    — 列出任务（支持 status/type 过滤 + cursor 分页）
POST   /v1/jobs/{job_id}/cancel    — 取消任务（仅 queued/running）
GET    /v1/jobs/{job_id}/result    — 获取结果
GET    /v1/jobs/{job_id}/result/file — 下载结果文件
```

## 测试要点

- [ ] Cancel queued job — 状态应变为 canceled
- [ ] Cancel running job — 后台任务应真正停止
- [ ] Delete succeeded job — 数据库记录和文件都应清理
- [ ] Delete running job — 应拒绝或先 cancel 再 delete
- [ ] iOS 端取消按钮 — 仅在 queued/running 时显示
- [ ] iOS 端删除 — 仅在 completed/failed/canceled 时允许
