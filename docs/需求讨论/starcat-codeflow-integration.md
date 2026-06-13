# Starcat 集成 CodeFlow 方案

> 本文档取代 CodeGraphContext 与 Git clone 方案。最终目标：点击一次，在默认浏览器直接看到代码可视化结果。

## 1. 最终链路

```text
用户点击「代码图谱」
        ↓
查询默认分支最新 commit SHA
        ↓
URLSession 请求 GitHub /repos/{owner}/{repo}/zipball/{sha}
        ↓
ZIP 写入共享源码快照缓存
        ↓
把 ZIP Base64 注入内置 CodeFlow HTML
        ↓
HTML 与 metadata.json 分别原子写入
        ↓
默认浏览器打开生成页
        ↓
CodeFlow 使用 JSZip 自动解压、分析并展示图谱
```

用户不需要安装 Git、CodeGraphContext 或解压工具，也不需要在 CodeFlow 页面选择目录、ZIP 或输入路径。

## 2. 为什么不用 Git

Mac App Store 要求 App Sandbox。沙箱中的 `/usr/bin/git clone` 会间接调用 `xcrun`，实际报错：

```text
xcrun: error: cannot be used within an App Sandbox.
```

这不是 Git 路径或权限位问题，继续配置用户 Git 环境也无法解决。因此仓库获取改成标准 HTTPS：

```http
GET https://api.github.com/repos/{owner}/{repo}/zipball
Accept: application/vnd.github+json
Authorization: Bearer <GitHub OAuth token>
```

公开仓库在无 token 时也能下载；登录态优先带现有 GitHub OAuth token，提高 API rate limit。GitHub 重定向到 archive host 时，URLSession 按跨域安全策略不转发 Authorization。

生成前先查询默认分支最新 commit：

```http
GET https://api.github.com/repos/{owner}/{repo}/commits/{defaultBranch}
Accept: application/vnd.github.sha
```

响应正文即完整 commit SHA。`Repo.defaultBranch` 已存在时直接使用；字段缺失时先通过仓库详情 API 获取 `default_branch`。拿到 SHA 后必须按固定 ref 下载：

```http
GET https://api.github.com/repos/{owner}/{repo}/zipball/{sha}
```

不能继续下载不带 ref 的 `/zipball`：查询 SHA 与下载 ZIP 是两次请求，若两次请求之间默认分支产生新提交，不带 ref 的 ZIP 内容可能与刚查询到的 SHA 不一致。

## 3. 为什么不在 Swift 中解压

CodeFlow 原版已经内置 JSZip 和 `readZipArchive`。Starcat 若再引入 ZIPFoundation 或调用 `/usr/bin/unzip`，只会增加依赖和 Sandbox 风险。

因此 Starcat 只负责下载和注入 ZIP；浏览器页面把 Base64 恢复成 `File(type: application/zip)`，直接复用 CodeFlow 原版 ZIP 分析链。ZIP 不归 CodeFlow 独占，而是 Starcat 的共享源码快照，后续 Repomix 等集成按同一 commit SHA 复用。

## 4. 文件位置与本地缓存

CodeFlow 相关文件分为三类。

### 4.1 随 App 打包的 CodeFlow 页面

```text
Starcat/Resources/CodeFlow/codeflow.html
```

CodeFlow 本身不会在运行时下载。该 HTML 已作为资源打包进 Starcat，运行时下载的只有待分析 GitHub 仓库 ZIP。

### 4.2 共享 GitHub 源码快照

ZIP 从 CodeFlow 目录移出，由 Starcat 的共享源码快照层统一管理。缓存键使用完整 commit SHA，不使用分支名：分支会移动，也可能包含 `/`；commit SHA 对应不可变源码内容，并允许不同分支或不同集成复用同一个 ZIP。

目录结构：

```text
~/Library/Containers/com.starcat.app/Data/Library/Application Support/Starcat/
└── repository-snapshots/github.com/<owner>/<repo>/<commit-sha>.zip
```

示例：

```text
repository-snapshots/github.com/addyosmani/agent-skills/51ab9708841e14258bebfb5fb326e8b37782d193.zip
```

下载时先写同目录临时文件 `<commit-sha>.zip.tmp`，校验非空且不超过 100 MB 后原子替换为 `<commit-sha>.zip`。下载失败或取消时删除 `.tmp`；正式 ZIP 成功落盘后不主动删除。

CodeFlow 与未来 Repomix 只能通过共享快照服务取得 ZIP URL，不直接拼接或删除快照路径。某个集成失败、重新生成或清理自身数据，都不能删除共享 ZIP。

### 4.3 生成的可视化页面

默认情况下，CodeFlow 生成物仍保存到 App Container：

```text
~/Library/Containers/com.starcat.app/Data/Library/Application Support/Starcat/
└── codeflow/<owner>/<repo>/index.html
```

完整路径示例：

```text
~/Library/Containers/com.starcat.app/Data/Library/Application Support/Starcat/codeflow/addyosmani/agent-skills/index.html
```

最终单项目目录结构：

```text
codeflow/<owner>/<repo>/
├── index.html
└── metadata.json
```

用户也可以在「设置 → 集成 → CodeFlow」中选择自定义输出目录。选择后，该目录本身就是 CodeFlow 输出根目录，不再额外拼接隐藏的容器路径。例如用户选择：

```text
~/Documents/Starcat CodeFlow/
```

则项目生成物保存为：

```text
~/Documents/Starcat CodeFlow/<owner>/<repo>/
├── index.html
└── metadata.json
```

自定义目录只存放 CodeFlow 生成物。`repository-snapshots/` 下供 CodeFlow、Repomix 等集成共用的源码 ZIP 仍保存在 App Container，不跟随 CodeFlow 输出目录迁移，避免用户移动或删除可视化页面时误伤共享缓存。

当前 ZIP 下载上限为 100 MB。由于项目尚未上线，不兼容或迁移现有旧目录结构，开发阶段直接清理旧缓存后使用新结构。

共享 ZIP 的整体统计与清理不属于 CodeFlow 数据管理范围，后续应放到统一「源码快照缓存」管理入口；否则从 CodeFlow 页面删除 ZIP 会误伤 Repomix 等其它使用方。

### 4.4 自定义输出目录与沙箱授权

Mac App Store 允许沙箱应用访问用户主动选择的目录，但不能通过文本框直接输入任意路径并长期访问。Starcat 必须使用 `NSOpenPanel` 让用户选择目录，并保存 security-scoped bookmark，后续启动时再恢复授权。

Starcat 当前 entitlement 已包含：

```xml
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

因此不需要新增沙箱权限，实现时遵循以下约束：

1. 目录只能通过系统目录选择器授权，不提供可编辑路径输入框；
2. 使用 `.withSecurityScope` 创建 bookmark data，并持久化到应用配置；
3. 每次读写前解析 bookmark，调用 `startAccessingSecurityScopedResource()`，结束后调用 `stopAccessingSecurityScopedResource()`；
4. bookmark 过期时重新保存；目录被删除、移动或授权失效时，明确提示「CodeFlow 输出目录不可用，请重新选择」；
5. 用户从未选择自定义目录，或主动恢复默认时，继续使用 App Container；
6. 已配置自定义目录后写入失败，不静默回退到 App Container，避免用户误判文件保存位置。

设置页展示当前输出目录的只读路径，并提供「选择目录」「在 Finder 中显示」「恢复默认」操作。选择新目录或恢复 App Container 默认目录时，先把当前目录中可识别的 CodeFlow 项目完整复制到目标目录，全部成功后再删除源项目并更新 bookmark；迁移失败时保留旧目录配置和源文件。共享 ZIP 不参与迁移。

### 4.5 执行状态恢复

每次打开 CodeFlow 面板时，Starcat 先检查对应项目的生成页面：

```text
codeflow/<owner>/<repo>/index.html
```

文件存在且非空时，面板直接恢复为「本地代码图谱已就绪」：三步均显示已完成，执行详情展示本地页面位置，主按钮变为「打开已有图谱」。点击后直接用默认浏览器打开现有 HTML，不重新下载 ZIP，也不重新生成页面。

这里不新增数据库表。HTML 与同目录 `metadata.json` 共同组成一个可独立扫描、打开和删除的项目缓存包，文件系统仍是实际状态。

### 4.6 项目元数据

成功生成 `index.html` 后，原子写入同目录 `metadata.json`：

```json
{
  "schemaVersion": 1,
  "repository": {
    "githubId": 123456,
    "owner": "addyosmani",
    "name": "agent-skills",
    "fullName": "addyosmani/agent-skills",
    "htmlUrl": "https://github.com/addyosmani/agent-skills"
  },
  "artifact": {
    "page": "index.html",
    "pageBytes": 2345678,
    "sourceArchiveBytes": 1234567,
    "sourceArchiveKey": "github.com/addyosmani/agent-skills/51ab9708841e14258bebfb5fb326e8b37782d193.zip"
  },
  "generation": {
    "generatedAt": "2026-06-13T03:00:02Z",
    "generationCount": 1,
    "lastDurationMilliseconds": 1250
  },
  "sourceRevision": {
    "branch": "main",
    "commitSha": "51ab9708841e14258bebfb5fb326e8b37782d193",
    "commitShortSha": "51ab970",
    "commitUrl": "https://github.com/addyosmani/agent-skills/commit/51ab9708841e14258bebfb5fb326e8b37782d193"
  },
  "lastExecution": {
    "startedAt": "2026-06-13T03:00:01Z",
    "finishedAt": "2026-06-13T03:00:02Z",
    "steps": [
      {
        "id": "resolveRevision",
        "status": "succeeded",
        "durationMilliseconds": 180,
        "summary": "默认分支 main 最新提交为 51ab970"
      },
      {
        "id": "download",
        "status": "succeeded",
        "durationMilliseconds": 620,
        "summary": "GitHub ZIP 下载完成"
      },
      {
        "id": "writeTemporaryArchive",
        "status": "succeeded",
        "durationMilliseconds": 8,
        "summary": "ZIP 已写入共享源码快照缓存"
      },
      {
        "id": "generatePage",
        "status": "succeeded",
        "durationMilliseconds": 510,
        "summary": "ZIP Base64 已注入 CodeFlow HTML"
      },
      {
        "id": "persistArtifacts",
        "status": "succeeded",
        "durationMilliseconds": 18,
        "summary": "CodeFlow HTML 与元数据写入完成"
      },
      {
        "id": "openBrowser",
        "status": "succeeded",
        "durationMilliseconds": 12,
        "summary": "默认浏览器已打开生成页"
      },
      {
        "id": "browserAnalysis",
        "status": "handedOff",
        "durationMilliseconds": null,
        "summary": "已交给 CodeFlow 页面解压、分析和渲染"
      }
    ]
  },
  "generator": {
    "codeFlowCommit": "51ab9708841e14258bebfb5fb326e8b37782d193",
    "integrationVersion": 1
  }
}
```

字段约束：

- `generatedAt` 表示 HTML 最后成功生成时间，不记录最近打开时间；
- `sourceArchiveBytes` 记录本次使用的共享 ZIP 大小，仅用于说明源码快照规模，不计入 CodeFlow 自身磁盘占用；
- `sourceArchiveKey` 保存共享快照逻辑键，不让 CodeFlow 持有快照删除权；
- `pageBytes` 和扫描到的 `index.html` 实际大小不一致时，以文件实际大小为准；
- `generationCount` 在重新生成成功后递增；
- `sourceRevision.commitSha` 必须是生成该 HTML 所使用 ZIP 的确切 commit SHA；
- `sourceRevision.branch` 保存生成时默认分支名称，默认分支后续改名也不影响历史说明；
- `lastExecution.steps` 保存最近一次成功生成的流程快照，不保存无限增长的历史记录；
- step 状态使用 `pending`、`running`、`succeeded`、`failed`、`handedOff`；
- `index.html` 与 `metadata.json` 使用临时文件加 rename 分别原子替换；无论 CodeFlow 生成成功或失败，都不删除已落盘的共享 ZIP；
- 默认浏览器打开成功后，再原子更新一次 `metadata.json.lastExecution`，补齐 `openBrowser` 与 `browserAnalysis` 最终状态；
- 失败不写入 `metadata.json`，失败原因仅在当前执行面板展示并提示用户重试；
- 不维护无限增长的执行历史列表。

## 5. CodeFlow 改造

内置资源：

```text
Starcat/Resources/CodeFlow/codeflow.html
```

固定上游提交：

```text
51ab9708841e14258bebfb5fb326e8b37782d193
```

Starcat 增加一个 ZIP 注入协议：

```js
window.__STARCAT_CODEFLOW_ZIP_BASE64__ = "...";
```

页面启动后自动：

1. Base64 解码 ZIP；
2. 构造浏览器 ZIP `File`；
3. 调用上游 `readZipArchive`；
4. JSZip 解压并过滤代码文件；
5. 分析并展示图谱。

Starcat 注入模式跳过 CodeFlow 的大 ZIP二次确认框，确保打开后无需再次点击。分析器、依赖识别、图谱渲染和导出逻辑保持上游实现。

## 6. UI

CodeFlow 入口位于 Manage 页顶部 toolbar 的「打开浏览器」菜单中，在 Releases 下方以独立分组展示。仅公开仓库显示该菜单项，详情页 hero 区不再单独放置「代码图谱」按钮。

点击菜单项后，紧凑执行面板显示当前仓库名。主区域只展示三段概览状态：下载仓库、生成图谱页面、浏览器打开；「执行详情」则展示完整流水线，不再展示原始日志字符串。

### 6.1 执行详情时间线

执行详情使用与概览卡片同宽的独立边框区域，每一步展示状态图标、动作说明、结果摘要和耗时：

```text
✓ 查询默认分支最新提交                              180 ms
  main · 51ab970

✓ 请求 GitHub 仓库 ZIP                              620 ms
  GET /repos/addyosmani/agent-skills/zipball/51ab970…

✓ ZIP 写入共享源码快照缓存                            8 ms
  repository-snapshots/…/51ab970….zip

✓ 生成 CodeFlow 页面                                510 ms
  ZIP Base64 已注入内置 CodeFlow HTML

✓ 写入 CodeFlow 项目产物                              18 ms
  index.html 与 metadata.json 已写入

✓ 默认浏览器打开生成页                                12 ms
  index.html 已交给系统默认浏览器

→ CodeFlow 浏览器端处理
  已交给 JSZip 解压、代码分析和图谱渲染
```

状态表现：

- `pending`：灰色空心圆，尚未执行；
- `running`：强调色 spinner，显示当前动作；
- `succeeded`：绿色勾选，显示实际耗时和结果；
- `failed`：红色错误图标，停在失败步骤，后续步骤保持 pending；
- `handedOff`：蓝色箭头，表示任务已经交给外部 CodeFlow 页面，但 Starcat 无法确认浏览器内部最终渲染结果。

失败示例：

```text
✓ 查询默认分支最新提交                              180 ms
  main · 51ab970

✕ 请求 GitHub 仓库 ZIP                              340 ms
  HTTP 403：GitHub API 请求次数已达上限

○ ZIP 写入共享源码快照缓存
○ 生成 CodeFlow 页面
○ 写入 CodeFlow 项目产物
○ 默认浏览器打开生成页
○ CodeFlow 浏览器端处理
```

首次执行时执行详情默认展开，使用户能实时看到流程推进；检测到已有页面时，从 `metadata.json.lastExecution` 恢复最近一次成功生成的时间线。失败过程只保留在当前面板，不落盘；关闭后再次进入时回到未生成状态。

面板底部另设简短执行结果摘要，例如「生成成功 · HTML 2.5 MB · 总耗时 1.2 秒」，但结果摘要不能替代上述过程时间线。

支持取消、失败重试、打开已有图谱和重新打开。

检测到已有图谱时，入口执行面板额外提供「重新生成」按钮。该操作先删除当前项目的 `index.html` 与 `metadata.json`，再重新下载 ZIP、生成 HTML 并打开；若重新下载或生成失败，项目保持未生成状态，面板展示错误并提示用户重试。

### 6.2 版本检查与更新提示

检测到已有 `index.html` 与 `metadata.json` 时，面板打开后异步查询默认分支最新 commit SHA，并与 `metadata.sourceRevision.commitSha` 对比：

- **一致**：显示「已是最新版本」，同时展示分支与短 SHA；
- **不一致**：显示「仓库有新提交，建议重新生成」，展示“生成版本 → 最新版本”，并突出「重新生成」按钮；
- **检查失败**：显示「暂时无法检查更新」，保留现有图谱的打开能力，不把网络失败误判为仓库已更新；
- **本地 metadata 缺少 SHA**：视为版本未知，提示重新生成，不为旧开发数据增加迁移逻辑。

示意：

```text
仓库有新提交，建议重新生成
main · 生成版本 51ab970 → 最新版本 7c2d4f1

[打开现有图谱]  [重新生成]
```

版本检查只在打开具体仓库的 CodeFlow 面板时触发，不在设置页批量请求所有项目，避免无意义消耗 GitHub API rate limit。设置页仍仅展示 metadata 中记录的生成版本。

### 6.3 分支选择

CodeFlow 执行面板增加分支选择控件。面板打开后通过 GitHub API 获取仓库全部分支：

```http
GET https://api.github.com/repos/{owner}/{repo}/branches?per_page=100&page={page}
```

GitHub 单页最多返回 100 条，必须读取分页信息直到最后一页，不能假设仓库分支数量不超过 100。公开仓库可匿名请求；登录态复用现有 OAuth token。响应中每个分支包含名称与当前 commit SHA。

分支控件建议使用可搜索的菜单 / popover，而不是普通 Picker：大型仓库可能有几十到数百个分支，纯下拉列表不便查找。排序规则：

1. 当前已生成分支；
2. 仓库默认分支；
3. 其余分支按名称排序。

首次生成默认选中 `Repo.defaultBranch`；字段缺失时以仓库详情 API 返回的 `default_branch` 为准。已有图谱时默认选中 `metadata.sourceRevision.branch`。

#### 6.3.1 生成流程

用户点击生成或重新生成时，不直接相信分支列表加载时携带的 SHA，而是再次解析所选分支当前 HEAD，避免用户停留窗口期间分支已经推进：

```http
GET https://api.github.com/repos/{owner}/{repo}/branches/{branch}
```

拿到 `commit.sha` 后使用固定快照下载：

```http
GET https://api.github.com/repos/{owner}/{repo}/zipball/{sha}
```

分支名可能包含 `/`，构造 API URL 时必须把分支作为单独 path parameter 正确 percent-encode，不能直接字符串拼接。

完整执行时间线增加两个步骤：

```text
✓ 加载仓库分支
✓ 解析所选分支 HEAD       dev · 7c2d4f1
✓ 获取固定 commit ZIP（缓存命中或下载）
✓ ZIP 写入共享源码快照缓存
✓ 生成 CodeFlow 页面
✓ 写入 CodeFlow 项目产物
✓ 默认浏览器打开
→ CodeFlow 浏览器端处理
```

#### 6.3.2 产物模型

首版采用“每个仓库只保留一份当前图谱”，不做多分支图谱并存：

```text
codeflow/<owner>/<repo>/
├── index.html
└── metadata.json
```

`metadata.sourceRevision.branch` 表示这份图谱使用的分支，`commitSha` 表示该分支生成时的精确 HEAD。用户选择另一个分支并重新生成时，覆盖该仓库原有 HTML 与 metadata。

不推荐首版使用 `codeflow/<owner>/<repo>/<branch>/` 保存多份图谱，因为分支名可包含 `/`，还会引入同仓库多行统计、分支删除后的孤儿缓存、逐分支清理和磁盘占用快速增长等问题。后续若明确需要分支间图谱对比，再升级为多产物模型。

#### 6.3.3 已有图谱与分支切换

面板已有图谱时：

- 当前选择等于生成分支：查询该分支最新 SHA，与生成 SHA 比较；
- 当前选择不同于生成分支：立即显示「当前图谱来自 main，已选择 dev，需要重新生成」；
- 所选分支已被删除：显示「生成分支已不存在」，仍允许打开旧图谱，并要求选择其它分支重新生成；
- 分支列表加载失败：保留旧图谱打开能力；若 metadata 中有生成分支，可继续显示，但禁止发起依赖未知分支状态的重新生成。

示意：

```text
生成分支   main · 51ab970
选择分支   dev  · 7c2d4f1

当前图谱与所选分支不一致，需要重新生成
[打开现有图谱]  [重新生成 dev]
```

“重新生成”继续采用删除优先语义：只删除当前仓库的 CodeFlow HTML 与 metadata，再按选中分支解析最新 SHA，从共享快照缓存复用 ZIP 或下载后生成。失败后 CodeFlow 项目保持未生成状态，但共享 ZIP 不受影响。

### 6.4 设置页数据管理

在独立的「设置 → 集成」Tab 增加 CodeFlow 输出目录与数据管理入口，不与第三方后端 URL/API Key 的「服务」Tab 混放。

输出目录区域展示：

- 当前输出目录的只读路径；
- **选择目录**：通过 `NSOpenPanel` 选择或新建目录并保存 security-scoped bookmark；
- **在 Finder 中显示**：打开当前输出根目录；
- **恢复默认**：清除自定义目录授权，后续生成物重新保存到 App Container。

恢复默认或切换目录只改变后续扫描和写入位置，不自动搬迁或删除原目录中的文件。数据管理区域基于当前有效输出根目录扫描，并展示：

- 已处理项目数量；
- CodeFlow HTML 与元数据当前磁盘占用；
- 所有项目累计生成次数；
- 最近一次 HTML 成功生成时间。

项目列表每行展示：项目名、生成分支、生成版本短 SHA、使用的共享 ZIP 大小、当前 HTML 大小、HTML 最后生成时间，并提供：

- **预览**：在默认浏览器打开现有 `index.html`；
- **打开**：在 Finder 中定位现有 `index.html`；
- **详情**：查看文件路径、大小、生成次数和生成器版本；
- **删除**：删除当前输出根目录下该项目整个 `<owner>/<repo>/` 目录。

设置页不提供「重新生成」操作。重新生成属于具体仓库的 CodeFlow 执行流程，只放在 toolbar 入口打开的 CodeFlow 面板中，避免数据管理页同时承担任务执行职责。

页面提供「一键清除」危险操作，确认后只删除当前输出根目录下能够通过非空 `index.html` 与有效 `metadata.json` 识别出的 CodeFlow 项目，然后立即刷新统计与列表。用户可能直接选择 Documents 等已有目录，因此不能按 owner 顶层目录盲删：未知目录、损坏或非 CodeFlow 文件必须保留。不得删除 `repository-snapshots/` 下的共享 ZIP，也不得删除用户选择的输出根目录本身。

## 7. 明确不做

- 不执行 Git、xcrun 或 unzip；
- 不嵌入 WKWebView；
- 不运行本地 HTTP Server；
- 不通过路径参数绕过浏览器权限；
- 不允许通过文本框输入任意输出路径，目录访问必须由系统选择器授权；
- 不由 CodeFlow 管理或删除共享 ZIP；
- 不记录最近打开时间和完整执行历史；
- 不兼容开发阶段旧缓存结构；
- 首版不支持私有仓库；
- 不改 CodeFlow 分析算法和图谱 UI。

## 8. 开源合规

CodeFlow 上游 README 声明 MIT，但固定提交中没有 `LICENSE` 文件。Starcat 保留上游 README，并在 `STARCAT-INTEGRATION.md` 与 About Credits 中如实记录来源和许可证现状。

## 9. 验收标准

- [x] 沙箱中不调用 Git / xcrun；
- [x] 首次点击通过 GitHub API 下载 ZIP；
- [x] 生成前查询默认分支 HEAD SHA，并使用 `zipball/{sha}` 下载完全一致的源码快照；
- [x] ZIP 按 commit SHA 写入独立 `repository-snapshots` 共享缓存，供 CodeFlow 与 Repomix 复用；
- [x] 下载失败或取消时清理 `.zip.tmp`，正式共享 ZIP 不由 CodeFlow 删除；
- [x] 已生成 HTML 再次打开面板时恢复为完成状态，并直接打开已有页面；
- [x] 默认浏览器自动打开生成的 CodeFlow 页面；
- [x] 页面不要求选择目录或 ZIP；
- [x] 页面自动解压、分析并展示图谱；
- [x] HTTP 错误、空 ZIP、超过 100 MB 均显示明确错误；
- [x] 私有仓库不展示代码图谱入口。
- [x] CodeFlow 入口位于 toolbar「打开浏览器」菜单的 Releases 下方，不再占用详情 hero。
- [x] 每个成功项目同目录写入 `metadata.json`，记录最后生成时间、生成时 ZIP 大小和生成次数；
- [x] 已有图谱的 CodeFlow 入口面板提供「重新生成」，按删除旧产物后重新执行完整流程；
- [x] 打开已有图谱面板时比较生成 SHA 与最新 SHA，准确展示最新、有更新或检查失败；
- [x] 执行面板通过分页 GitHub API 加载全部分支，并支持搜索选择；
- [x] 生成时重新解析所选分支 HEAD，使用 `zipball/{sha}` 下载精确快照；
- [x] 每个仓库首版只保留一份图谱，切换分支重新生成时覆盖原产物；
- [x] 已有图谱正确处理分支切换、分支删除和分支列表加载失败；
- [x] 独立的设置 → 集成 Tab 可统计、浏览器预览、Finder 打开、查看详情和删除单个项目，不提供重新生成；
- [x] CodeFlow 单项删除和一键清除只删除 CodeFlow HTML、metadata 与自身临时文件，不删除共享 ZIP。
- [x] 设置 → 集成允许通过 `NSOpenPanel` 选择 CodeFlow 输出目录，并持久化 security-scoped bookmark；
- [x] 应用重启后能够恢复自定义目录授权，bookmark 失效时提示用户重新选择；
- [x] 设置页支持在 Finder 中显示当前输出目录和恢复 App Container 默认目录；
- [x] 切换或恢复输出目录时迁移现有 CodeFlow 生成物，全部成功后才删除源项目并更新目录配置；
- [x] 自定义目录中的项目删除与一键清除不删除输出根目录、无关文件，也不影响容器中的共享 ZIP。
