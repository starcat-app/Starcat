# Chrome Companion v1 专项进度

> 状态: 进行中
> 创建: 2026-07-01
> 需求讨论: `docs/2-产品/需求讨论/Chrome-Companion-v1-精简版需求讨论.md`
> 正式方案: `docs/2-产品/需求讨论/正式方案/Chrome-Companion-v1-正式方案.md`
> 详细设计: `docs/3-设计/详细设计/23-Chrome-插件方案.md`

## 1. 目标

实现 Chrome Companion v1, 只做 GitHub repo 页上的 Starcat 上下文增强:

1. 相似仓库推荐。
2. Wiki 入口。
3. 私人笔记读取与保存。
4. Health / OpenSSF 分数。
5. CodeFlow / Codebase 入口。

## 2. 不做范围

- [x] 不合并 `901efc38` 的旧 Chrome Companion 提交 — 2026-07-01
  > 实现: v1 方案已改为重写, 只复用产品启发, 不继承旧提交中的 Capture/AI Summary/Release badge/右键菜单等大而全能力。
- [ ] 不做 Inbox / Capture。
- [ ] 不做 AI Summary 触发。
- [ ] 不做 Release unread badge。
- [ ] 不做右键菜单。
- [ ] 不做插件直连 GitHub API / Starcat 后端 / OpenSSF / AI provider。

## 3. PR-1: Starcat 本机服务骨架

- [x] `CompanionConfiguration`: token / port / enabled / status。— 2026-07-01
  > 实现: 新增 Companion 专用 token 存储、端口和 enabled 持久化配置, 默认关闭本机服务入口, 避免未发布能力默认暴露。
- [x] `CompanionRequestParser`: HTTP request 解析, 重复 query/header 不崩溃。— 2026-07-01
  > 实现: 新增纯 Swift parser 与单测, query 重复 key 返回显式错误, header 重复保留 first value, 为本机服务安全解析打底。
- [x] `CompanionLocalServer`: loopback only + Bearer auth + Origin 限制。— 2026-07-01
  > 实现: 新增本机服务骨架, Network.framework 只绑定 IPv4 loopback, handler 层统一做 Bearer 与 extension Origin 校验。
- [x] `/local/v1/ping`: 插件 Options 连接测试。— 2026-07-01
  > 实现: 新增最小 ping 响应与 CORS Private Network Access 预检响应, 供后续插件 Options 做连接验证。
- [x] Debug / feature flag 启动门控, 测试 host 跳过。— 2026-07-01
  > 实现: 新增 DEBUG-only bootstrapper 与 Debug 菜单开关, 启动前先跳过测试 host, 再检查 Debug flag 与 Companion enabled 双门控。
- [x] 单测: parser / auth / origin / ping。— 2026-07-01
  > 实现: PR-1 已覆盖 parser、token auth、Origin 限制、PNA 预检和 ping 响应, 作为后续 repo-context/notes/actions 的回归基线。

## 4. PR-2: repo-context 聚合

- [x] `CompanionModels`: repo-context DTO。— 2026-07-01
  > 实现: 新增 ping 与 repo-context Codable DTO, 统一用 snake_case JSON 契约, 并补充 DTO 编码形状测试。
- [x] `CompanionContextProvider`: 聚合 Repo / Recommendations / Wiki / Notes / Health / OpenSSF / Actions。— 2026-07-01
  > 实现: 先落地 repo-context 聚合入口、GitHub owner/repo 校验、本地 Repo 映射与空分组 DTO, 后续按推荐/Wiki/Notes/Signals 分组补齐数据源。
- [x] `GET /local/v1/repo-context`: 接入本机服务 route。— 2026-07-01
  > 实现: 本机服务新增 repo-context route, 复用 provider 做 owner/repo 校验与 DTO 编码, 缺参或非法参数返回 400。
- [x] 生产依赖注入: 本机服务使用 Starcat AppDependencies。— 2026-07-01
  > 实现: AppDependencies 初始化成功后注入 bootstrapper, 本机服务启动时组装完整 CompanionContextProvider, 避免空 provider 上线。
- [x] 推荐: 复用 `RecommendationContextService` / `RecommendAPI`, 分组级降级。— 2026-07-01
  > 实现: provider 接入推荐 lookup, 生产路径 cache first/miss refresh, 输出最多 5 条推荐; 推荐失败只降级该分组为空。
- [x] Wiki: 复用 `WikiContextService` 缓存, 只返回 indexed links。— 2026-07-01
  > 实现: provider 读取 WikiContextService.cachedLinks, 不发起前台网络请求, 并为插件输出固定英文来源标题。
- [x] Notes: 已 star repo 返回 editable note。— 2026-07-01
  > 实现: provider 注入 note lookup, 仅本地已 star 的 repo 读取私人笔记并返回 editable note, unstarred/unknown repo 不暴露笔记内容。
- [x] Health / OpenSSF: 只读缓存, 不在 GitHub 页面请求中强制刷新。— 2026-07-01
  > 实现: provider 注入 Health/OpenSSF 缓存读取闭包, 只返回已有成功缓存, 缺失或失败态静默省略, 不触发网络刷新。
- [x] 单测: 局部失败不影响其他分组。— 2026-07-01
  > 实现: provider 对推荐、Notes、Health、OpenSSF 分组错误做局部降级, 单测覆盖失败分组不影响 repo 基础信息与其他成功分组。

## 5. PR-3: notes 写入与打开动作

- [x] `PATCH /local/v1/notes`: 保存私人笔记。— 2026-07-01
  > 实现: 本机服务新增 notes PATCH route, 解码 owner/repo/content 后委托 CompanionNoteWriter 保存并返回最新 note DTO。
- [x] 保存规则: repo 必须存在且 `isStarred == true`。— 2026-07-01
  > 实现: CompanionNoteWriter 先通过 RepoRepository 查本地 repo, 未命中返回 404, 已取消 star 返回 403。
- [x] 保存规则: 最大 20000 字符。— 2026-07-01
  > 实现: CompanionNoteWriter 在写库前校验 content.count, 超限返回 content_too_large。
- [x] 保存规则: 保留原有 `repo_notes.status`。— 2026-07-01
  > 实现: 保存仍走 RepoNoteRepository.updateContent, 只改 content 与 edited_at, 不覆盖 status。
- [x] `POST /local/v1/actions/open`: `open-repo` / `codeflow` / `codebase`。— 2026-07-01
  > 实现: 新增 CompanionActionHandler 与 MainActor dispatcher, HTTP 层只校验 repo 并投递动作, CodeFlow/Codebase 复用 RepoListView 现有 sheet 门控。
- [x] 单测: action route。— 2026-07-01
  > 实现: LocalServer 测试覆盖 action route 成功响应与未 star 拒绝, handler 通过记录器验证 codeflow 投递目标 repo。
- [x] 单测: note save / 未 star 拒绝。— 2026-07-01
  > 实现: 新增 CompanionNoteWriterTests 与 LocalServer PATCH notes 覆盖, 验证保存、未 star 拒绝、缺失 repo 与超长内容拒绝。

## 6. PR-4: Chrome Extension

- [ ] `extensions/starcat-companion/manifest.json`。
- [ ] `options.html/js/css`: 端口 + token + Test Connection。
- [ ] `shared.js`: connection / Starcat client / repo parser。
- [ ] `content-script.js/css`: GitHub repo 页注入 Starcat 面板。
- [ ] debounce + in-flight 去重 + 未配置 token 冷却。
- [ ] 面板分组: Similar / Wiki / Notes / Signals / Actions。
- [ ] 手测: App 未运行 / token 错误 / 正确配对 / 保存笔记 / 打开 CodeFlow/Codebase。

## 7. 验证记录

- [ ] `rtk git diff --check`
- [ ] `rtk xcodegen generate`
- [ ] `rtk jq empty Starcat/Resources/Localizable.xcstrings`
- [ ] Companion 定向单测
- [ ] `rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' build`

## 8. 变更记录

- 2026-07-01: 建立 Chrome Companion v1 专项进度, 明确重写路线与 PR 切分。
