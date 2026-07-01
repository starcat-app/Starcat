# 23. Chrome Companion v1 详细设计

> 状态: v1 精简版详细设计
> 日期: 2026-07-01
> 产品方案: `docs/2-产品/需求讨论/正式方案/Chrome-Companion-v1-正式方案.md`
> 需求讨论: `docs/2-产品/需求讨论/Chrome-Companion-v1-精简版需求讨论.md`
> 旧方案: `docs/2-产品/需求讨论/_archive/chrome插件-最终方案.md`

## 1. 目标

Chrome Companion v1 在 GitHub repo 页面展示 Starcat 已有上下文:

1. 相似仓库推荐。
2. Wiki 入口。
3. 私人笔记。
4. Health / OpenSSF 分数。
5. CodeFlow / Codebase 入口。

本设计重写旧版 Chrome 插件方案。旧版方案中的 Inbox、Capture、AI Summary、Release badge、右键菜单等能力暂不进入 v1。

## 2. 架构原则

### 2.1 插件只做上下文增强

插件不持有 Starcat 业务状态。GitHub 页面上展示的所有数据都来自 Starcat App 的本机服务。

### 2.2 Starcat App 是唯一业务执行方

以下能力全部留在 App 内:

- Recommend API 调用。
- Wiki API 调用。
- Repo notes 读写。
- Repo Health 计算与缓存。
- OpenSSF 缓存读取。
- CodeFlow / Codebase 打开与运行。
- GitHub Token、AI Key、服务 API Key 管理。

### 2.3 本机 HTTP 是唯一通信通道

v1 不用无鉴权 deeplink 执行写入。所有读取和写入都走本机 HTTP Bearer 鉴权。

deeplink 只可作为打开 App 的兜底入口, 不承担写入语义。

## 3. 总体结构

```text
GitHub repo page
  ↓ content-script 解析 owner/repo
Chrome Extension
  ↓ Bearer token
http://127.0.0.1:{port}/plugin/v1/repo-context?owner=&repo=
  ↓
Starcat CompanionLocalServer
  ├── RepoRepository
  ├── RepoNoteRepository
  ├── RecommendationContextService / RecommendAPI
  ├── WikiAPI
  ├── RepoHealthService
  ├── OpenSSFScoreRepository
  └── CodeFlow / Codebase open actions
```

## 4. Starcat App 侧设计

### 4.1 新增模块

建议新增目录:

```text
Starcat/Features/Companion/
  CompanionConfiguration.swift
  CompanionLocalServer.swift
  CompanionRequestParser.swift
  CompanionContextProvider.swift
  CompanionModels.swift
  CompanionActionRouter.swift
```

职责:

| 文件 | 职责 |
|---|---|
| `CompanionConfiguration` | 管理端口、token、server status |
| `CompanionLocalServer` | Network.framework 本机 HTTP server |
| `CompanionRequestParser` | HTTP request 解析, 避免重复 query/header 崩溃 |
| `CompanionContextProvider` | 聚合 repo-context DTO |
| `CompanionModels` | 本机 API DTO |
| `CompanionActionRouter` | 执行打开 CodeFlow / Codebase / Starcat 详情页等动作 |

### 4.2 启动策略

v1 建议默认不暴露在普通设置页, 先挂在 Debug 或 feature flag 下。

原因:

1. Chrome 插件尚未发布。
2. 本机 HTTP 服务属于新攻击面。
3. 需要先验证 GitHub DOM 注入稳定性。

启动规则:

```swift
guard !TestEnvironment.isRunning else { return }
guard settings.companionEnabled else { return }
server.start()
```

测试 host 必须跳过, 避免命令行测试期启动端口监听。

### 4.3 配置存储

配置项:

| 字段 | 存储 | 说明 |
|---|---|---|
| `port` | UserDefaults | 默认 5051, 自动尝试 5051...5060 |
| `token` | AES-GCM 凭证文件 | Companion 专用 bearer token |
| `enabled` | UserDefaults | Debug/feature flag 阶段默认 false |
| `serverStatus` | 内存状态 | `stopped/starting/running/failed` |

Companion token 不复用 GitHub Token、AI Key 或服务 API Key。

## 5. 本机 API

### 5.1 通用要求

所有接口:

```text
Host: 127.0.0.1
Authorization: Bearer <companion-token>
Origin: chrome-extension://...
```

响应头:

```text
Content-Type: application/json; charset=utf-8
Access-Control-Allow-Headers: Authorization, Content-Type
Access-Control-Allow-Methods: GET, PATCH, POST, OPTIONS
Access-Control-Allow-Private-Network: true
```

Origin 策略:

- `nil` Origin: 允许, 便于本机调试。
- `chrome-extension://...`: 允许。
- 其他 Origin: 403。

### 5.2 `GET /plugin/v1/ping`

用于插件 Options 测试连接。

响应:

```json
{
  "schema_version": 1,
  "status": "ok",
  "app": "Starcat",
  "capabilities": ["repo-context", "notes", "actions"]
}
```

### 5.3 `GET /plugin/v1/repo-context?owner=&repo=`

核心聚合接口。

请求约束:

- `owner` 和 `repo` 只能包含 GitHub repo 合法字符集: `[A-Za-z0-9._-]`。
- 缺失或非法返回 400。
- 重复 query key 返回 400, 不能 crash。

响应:

```json
{
  "schema_version": 1,
  "repo": {
    "owner": "apple",
    "name": "swift",
    "full_name": "apple/swift",
    "repo_id": 44838949,
    "html_url": "https://github.com/apple/swift",
    "known_to_starcat": true,
    "is_starred": true
  },
  "recommendations": [
    {
      "repo_id": 1,
      "full_name": "owner/repo",
      "description": "Short description",
      "language": "Swift",
      "stars": 1200,
      "score": 0.91,
      "reason": "被相似 GitHub 用户共同 star"
    }
  ],
  "wiki_links": [
    {
      "source": "deepwiki",
      "title": "DeepWiki",
      "url": "https://deepwiki.com/apple/swift"
    }
  ],
  "note": {
    "editable": true,
    "content": "private note",
    "edited_at": "2026-07-01T10:00:00Z"
  },
  "health": {
    "score": 82.0,
    "grade": "B",
    "computed_at": "2026-07-01T10:00:00Z"
  },
  "openssf": {
    "score": 7.4,
    "score_date": "2026-06-30"
  },
  "actions": {
    "open_in_starcat": true,
    "codeflow": true,
    "codebase": true
  }
}
```

字段策略:

- 分组无数据时返回空数组或 `null`。
- 插件按字段存在与否决定显示。
- 推荐接口失败不影响 note/wiki/health 返回。
- Wiki 接口失败不影响其他分组。
- Health 缓存缺失时不强制前台刷新。

### 5.4 `PATCH /plugin/v1/notes`

保存私人笔记。

请求:

```json
{
  "owner": "apple",
  "repo": "swift",
  "content": "new note content"
}
```

规则:

1. repo 必须已存在于 Starcat 本地库。
2. repo 必须 `isStarred == true`。
3. `content` 最大 20000 字符。
4. 保存走 `RepoNoteRepository.updateContent(repoId:content:)`。
5. 保留原有 status。

响应:

```json
{
  "schema_version": 1,
  "note": {
    "editable": true,
    "content": "new note content",
    "edited_at": "2026-07-01T10:10:00Z"
  }
}
```

错误:

| 场景 | 状态码 |
|---|---:|
| 未鉴权 | 401 |
| 非 extension Origin | 403 |
| repo 不存在 | 404 |
| repo 未 star | 409 |
| content 超长 | 413 |

### 5.5 `POST /plugin/v1/actions/open`

让 Starcat App 打开对应能力。

请求:

```json
{
  "owner": "apple",
  "repo": "swift",
  "action": "codeflow"
}
```

action 枚举:

```text
open-repo
codeflow
codebase
```

行为:

| action | Starcat 行为 |
|---|---|
| `open-repo` | 激活 App 并打开 repo 详情 |
| `codeflow` | 激活 App, 打开 CodeFlow 面板 |
| `codebase` | 激活 App, 打开 CodebaseMemory 面板 |

如果 repo 不在本地:

- `open-repo`: 可打开 GitHub fallback 或返回 404, 实现时二选一。
- `codeflow/codebase`: 返回 404, 因为分析能力依赖 Starcat repo 上下文。

## 6. Context 聚合逻辑

### 6.1 Repo 解析

流程:

```text
owner/repo
  ↓
RepoRepository.findByOwnerName
  ↓
local repo?
  ├── yes: known_to_starcat=true
  └── no: known_to_starcat=false, 只允许推荐/Wiki 查询
```

建议 v1 对陌生 repo 仍允许推荐和 Wiki:

- 推荐需要 GitHub repo id, 如果本地不知道 repo id, 可以不展示推荐。
- Wiki 只需要 owner/repo, 可展示。
- 笔记、Health、OpenSSF、CodeFlow、Codebase 需要本地 repo, 陌生 repo 不展示。

### 6.2 推荐

复用现有推荐边界:

- `RecommendationContextService.cachedSnapshot(repoID:)`
- 必要时调用 `refresh(repoID:)`

v1 建议:

1. 先读 cache。
2. cache miss 时可以后台 refresh, 但当前响应不等待超过 800ms。
3. 超时或失败时返回空推荐。

这样 GitHub 页面不会因为推荐服务冷启动卡住。

### 6.3 Wiki

复用:

- `WikiAPI.fetchStatus(owner:repo:)`
- `WikiStatusItem.status == .indexed`
- `WikiLink`

Wiki 不依赖本地 repo id, 可以对未 star repo 展示。

### 6.4 私人笔记

复用:

- `RepoNoteRepository.find(repoId:)`
- `RepoNoteRepository.updateContent(repoId:content:)`

显示规则:

```text
repo exists && repo.isStarred == true -> editable=true
otherwise -> note=null
```

### 6.5 Health

复用:

- `RepoHealthService.cachedSnapshot(for:)`

v1 不在 `repo-context` 请求里触发 `refreshWithLatestSignals`, 避免用户打开 GitHub 页面时产生网络放大。

### 6.6 OpenSSF

复用:

- `OpenSSFScoreRepository.record(for:)`
- `OpenSSFScoreRecord.badgeData`

v1 只读缓存。

### 6.7 CodeFlow / Codebase

入口可用条件:

```text
repo exists && repo.isStarred == true
```

如果后续决定支持未 star repo 分析, 应先在 Starcat App 内补齐显式导入/临时分析语义, 不在插件里直接做。

## 7. Chrome Extension 设计

### 7.1 目录结构

```text
supports/extensions/starcat-chrome-plugin/
  manifest.json
  README.md
  src/
    content/
      content-script.js
      content-script.css
    shared/
      shared.js
    options/
      options.html
      options.js
      options.css
```

v1 不需要 popup 和 service-worker。原因:

- 不做右键菜单。
- 不做 badge。
- 不做后台轮询。
- 所有能力都在 content script 和 options 内完成。

### 7.2 Manifest

```json
{
  "manifest_version": 3,
  "name": "Starcat Companion",
  "version": "0.1.0",
  "permissions": ["storage"],
  "host_permissions": [
    "https://github.com/*",
    "http://127.0.0.1:*/*"
  ],
  "content_scripts": [
    {
      "matches": ["https://github.com/*"],
      "js": ["src/shared/shared.js", "src/content/content-script.js"],
      "css": ["src/content/content-script.css"],
      "run_at": "document_idle"
    }
  ],
  "options_page": "src/options/options.html"
}
```

### 7.3 GitHub repo 解析

解析函数:

```javascript
function parseGitHubRepo(urlString) {
  const url = new URL(urlString);
  if (url.hostname !== "github.com") return null;
  const parts = url.pathname.split("/").filter(Boolean);
  if (parts.length < 2) return null;
  if (["settings", "marketplace", "orgs", "topics", "trending"].includes(parts[0])) return null;
  return { owner: parts[0], repo: parts[1], fullName: `${parts[0]}/${parts[1]}` };
}
```

### 7.4 DOM 注入

容器优先级:

1. `#readme`
2. `div[data-testid='readme']`
3. `article.markdown-body` 的父节点
4. repo header 下方 fallback

找不到容器时不注入。

### 7.5 刷新策略

GitHub 是 PJAX/动态页面, 需要监听 URL 和 DOM 变化, 但必须防抖。

规则:

1. `MutationObserver` 只触发 schedule, 不直接 fetch。
2. debounce 500ms。
3. 同一 `fullName` 60s 内不重复请求, 除非保存笔记后 force refresh。
4. 同一 repo 同一时间只允许一个 in-flight 请求。
5. 未配置 token 时设置 60s 冷却, 避免每次 DOM mutation 都读 storage。

### 7.6 面板渲染

分组:

```text
Starcat
  Similar
  Wiki
  Notes
  Signals
  Actions
```

渲染规则:

- recommendations 非空 -> 显示 Similar。
- wiki_links 非空 -> 显示 Wiki。
- note.editable -> 显示 Notes。
- health 或 openssf 存在 -> 显示 Signals。
- actions 中至少一个 true -> 显示 Actions。
- 所有分组为空 -> 不显示面板。

### 7.7 笔记保存

交互:

1. textarea 编辑。
2. Save 按钮。
3. 保存中按钮 disabled。
4. 成功显示 `Saved` 2s。
5. 失败显示 `Save failed`。

保存后不需要 reload 整个页面, 直接更新本地 state 即可。

## 8. 安全设计

### 8.1 重复 key 防崩溃

HTTP parser 禁止使用:

```swift
Dictionary(uniqueKeysWithValues:)
```

因为重复 query/header 会触发运行时 trap。

应实现:

```swift
enum DuplicateKeyPolicy {
    case reject
    case firstWins
}
```

本机 API 对 query 使用 `reject`, 对 headers 使用 `firstWins` 或 `reject` 均可, 但不能 crash。

### 8.2 请求体限制

限制:

- header 最大 16KB。
- body 最大 64KB。
- note content 最大 20000 字符。

超过返回 413。

### 8.3 Origin 与 Host

服务端监听:

```swift
NWParameters.tcp.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
```

请求校验:

- Host 必须是 `127.0.0.1:{port}` 或 `localhost:{port}`。
- Origin 必须为空或 `chrome-extension://...`。

### 8.4 写入权限

v1 只有一个写入接口:

```text
PATCH /plugin/v1/notes
```

写入前必须确认:

```text
repo exists
repo.isStarred == true
token valid
origin allowed
```

## 9. 测试计划

### 9.1 Swift 单测

新增:

```text
StarcatTests/CompanionRequestParserTests.swift
StarcatTests/CompanionContextProviderTests.swift
StarcatTests/CompanionNotesTests.swift
```

覆盖:

1. duplicate query 返回 400, 不 crash。
2. missing auth 返回 401。
3. forbidden origin 返回 403。
4. unknown repo 不返回 note/health/actions。
5. starred repo 返回 editable note。
6. note save 保留 status。
7. recommendation failure 不影响 wiki/note。
8. wiki failure 不影响 recommendation/note。

### 9.2 插件手测

1. 未配置 token 打开 GitHub repo 页面: 不报错。
2. 配置错误 token: 显示连接失败。
3. 配置正确 token: 面板出现。
4. 推荐为空: Similar 分组隐藏。
5. Wiki 有结果: Wiki 按钮可打开。
6. 已 star repo: Notes 可编辑保存。
7. 未 star repo: Notes 不显示。
8. CodeFlow/Codebase 点击后 Starcat 激活。

### 9.3 验证命令

实现后至少跑:

```bash
rtk xcodegen generate
rtk jq empty Starcat/Resources/Localizable.xcstrings
rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' \
  -only-testing:StarcatTests/CompanionRequestParserTests \
  -only-testing:StarcatTests/CompanionContextProviderTests \
  -only-testing:StarcatTests/CompanionNotesTests test
```

如果新增 Swift 文件, `xcodegen generate` 必跑。

## 10. PR 切分建议

### PR-1 Starcat 本机服务骨架

- CompanionConfiguration
- CompanionLocalServer
- CompanionRequestParser
- `/ping`
- Settings Debug 入口
- parser/auth/origin 单测

### PR-2 repo-context 聚合

- CompanionModels
- CompanionContextProvider
- recommendations/wiki/note/health/openssf DTO
- context provider 单测

### PR-3 notes 写入与 actions

- `PATCH /notes`
- `POST /actions/open`
- CodeFlow/Codebase App 内打开路由
- note save 单测

### PR-4 Chrome 插件

- manifest
- options
- content script
- panel UI
- debounce / in-flight / storage cooldown

## 11. 风险与约束

| 风险 | 应对 |
|---|---|
| GitHub DOM 变化 | 找不到容器时不注入, 面板逻辑与 GitHub 原功能解耦 |
| 本机服务新增攻击面 | loopback only + Bearer token + Origin 限制 + body 限制 |
| recommend/wiki 冷启动慢 | repo-context 分组级降级, 不让单个服务拖慢整个面板 |
| 用户误以为插件是独立产品 | Options 和连接失败文案明确要求 Starcat App 运行 |
| 笔记保存冲突 | v1 覆盖保存, 后续如接 CloudKit 冲突再由 App 层处理 |

## 12. 后续版本

v1 稳定后再评估:

1. GitHub star list 推荐。
2. GitHub topic 页推荐。
3. 未 star repo 临时笔记。
4. Capture to Starcat。
5. 页面内展示 CodeFlow/Codebase 摘要。
6. Safari extension。
