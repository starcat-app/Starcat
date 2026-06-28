# Starcat MCP Service 实施方案

> 创建：2026-06-20  
> 状态：v1.1 已实现只读 + 本地写入 P0  
> 目标：让用户的本机 Agent 通过 MCP 使用 Starcat 已缓存的 GitHub Star 知识库能力。

## 1. 路线选择

采用 **Starcat App 内置 localhost HTTP MCP Service**：

- Starcat 监听 `127.0.0.1:{port}/mcp`，默认端口 `8765`。
- MCP 协议层使用官方 `modelcontextprotocol/swift-sdk`。
- HTTP 监听层用 `Network.framework` 自实现极薄 loopback adapter，接 SDK 的 `StatelessHTTPServerTransport`。
- v1 不做独立 CLI 直读 SQLite；后续如某些 Agent 只支持 stdio，再加 `starcat-mcp` stdio proxy 转发到 App 内 HTTP service。

拒绝 v1 直接让外部进程读数据库，原因：

- 会绕过 App 内 `EntitlementGate`、用户设置、后续 audit 与确认机制。
- SQLite 多账号目录、App 生命周期、订阅状态都由 AppDependencies 管理，外部进程重复装配风险高。
- Starcat 尚未上线，无需为旧外部协议做兼容路径。

## 2. Pro 门控

MCP Service 是 Pro-only：

- 新增 `ProFeature.mcpService`。
- 设置页开关只保存用户意图，真实启动必须满足 `EntitlementGate.isProUser == true`。
- 每个 HTTP 请求都会重新检查：开关、Pro、Bearer token。
- 订阅失效后，即使旧 endpoint/token 仍在，也会返回 403。

## 3. 安全边界

- 只监听 `127.0.0.1`，不开放 LAN host 配置。
- 需要 `Authorization: Bearer <token>`。
- token 存在 Starcat 的加密凭据文件，设置页可 rotate。
- 私有笔记默认不暴露，用户必须在 Settings → MCP 显式开启读取。
- 写入能力默认关闭，用户必须显式开启 `允许本地写入`。
- 替换式写入默认关闭，用户必须额外开启 `允许替换/删除式写入`。
- 不暴露 GitHub token、AI API key、Keychain/凭据文件内容。

## 4. P0 暴露能力

### Tools

- `starcat.search_repos`：本地 FTS/关键词搜索 starred repos。
- `starcat.semantic_search`：使用 Starcat 语义索引搜索 starred repos。
- `starcat.get_repo`：按 `repo_id` 或 `owner + name` 获取 repo metadata。
- `starcat.get_readme`：读取已缓存 README HTML / markdown。
- `starcat.list_tags`：列出 Starcat 标签。
- `starcat.get_repo_note`：读取私有笔记和状态，仅在用户显式授权后可用。

### Resources

- `starcat://tags`
- `starcat://repos/{owner}/{repo}`
- `starcat://repos/{owner}/{repo}/readme`

## 5. 暂不做

- AI 摘要生成 / AI 标签推荐的 MCP 触发。
- Stateful HTTP/SSE。
- 远程网络访问。
- App Store Server API 订阅校验。
- GitHub 远端写入（star / unstar）。
- 真正的批量整理工具（当前已预留批量写入开关，但 P0 tools 仍按单 repo 执行）。

## 6. v1.1 本地写入 P0

### 写入权限

Settings → MCP 新增三层写入开关：

- `允许本地写入`：放行 notes / status / tags 这类本地用户数据写入。
- `允许批量写入`：为后续批量工具预留；P0 暂未开放真正 batch tool。
- `允许替换/删除式写入`：放行 `set_repo_tags` 这类会替换旧关联的工具，默认关闭。

私有笔记的读取和写入分开授权：

- `暴露私有笔记` 控制 `starcat.get_repo_note` 读取旧笔记。
- `允许本地写入` 控制 `starcat.upsert_repo_note` 写入新笔记。
- 因此外部 Agent 可以“写新整理结果”，但不能因为能写就自动读取用户旧笔记。

### 写入工具

- `starcat.upsert_repo_note`
  - 入参：`repo_id` 或 `owner + name`，`content`，`dry_run`。
  - 行为：复用 `RepoNoteRepository.updateContent`；空字符串清空 note body，但保留状态行。
  - 副作用：写入成功后触发单 repo 语义索引刷新。

- `starcat.set_repo_status`
  - 入参：`repo_id` 或 `owner + name`，`status = unread/read/using`，`dry_run`。
  - 行为：复用 `RepoNoteRepository.updateStatus`。
  - 副作用：发送 `.repoStatusDidChange`，让列表状态角标即时刷新；同时触发语义索引刷新。

- `starcat.create_tag`
  - 入参：`name`，可选 `color` / `icon`，`dry_run`。
  - 行为：复用注入后的 `GatedTagRepository`，因此不会绕过免费版标签数量限制。
  - 幂等：同名 tag 已存在时返回现有 tag，`changed = false`。

- `starcat.add_repo_tags`
  - 入参：`repo_id` 或 `owner + name`，`tags: [String]`，`create_missing`，`dry_run`。
  - 行为：默认自动创建缺失 tag，再用 `RepoTagRepository.addTag` 幂等关联 repo。
  - 副作用：触发单 repo 语义索引刷新。

- `starcat.remove_repo_tags`
  - 入参：`repo_id` 或 `owner + name`，`tags: [String]`，`dry_run`。
  - 行为：只移除已存在 tag；不存在的 tag name 被忽略。
  - 副作用：触发单 repo 语义索引刷新。

- `starcat.set_repo_tags`
  - 入参：`repo_id` 或 `owner + name`，`tags: [String]`，`create_missing`，`dry_run`。
  - 行为：替换该 repo 的完整标签集合，复用 `RepoTagRepository.setTags`。
  - 权限：必须同时开启 `允许本地写入` 与 `允许替换/删除式写入`。
  - 约束：这是 P0 唯一“替换式”工具，不默认开放。

### 审计

写入统一走 `StarcatMCPWriteFacade.perform(...)`：

- 每次成功 / 失败都会写入 JSONL 审计日志。
- 路径：`Application Support/com.starcat.app/mcp-audit/writes.jsonl`。
- 字段包括：tool、permission、dryRun、success、repoId、repoFullName、affectedTags、warnings、error、timestamp。
- P0 不做 UI 展示；后续 Settings 可读取这个 JSONL 或迁到 SQLite。

### 实现文件

- `Starcat/Features/MCP/StarcatMCPWriteFacade.swift`
- `Starcat/Features/MCP/StarcatMCPWriteModels.swift`
- `Starcat/Features/MCP/StarcatMCPAuditLog.swift`
- `Starcat/Features/MCP/StarcatMCPToolRegistry.swift`
- `Starcat/Features/MCP/MCPSettingsView.swift`
- `Starcat/Core/Settings/AppSettings.swift`
- `StarcatTests/StarcatMCPWriteFacadeTests.swift`

### 验证

- `xcodegen generate`
- `xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' build`
- `xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/StarcatMCPWriteFacadeTests test`
- `python3 -m json.tool Starcat/Resources/Localizable.xcstrings`
- i18n 禁用 API 扫描：新增范围无 `String(localized:)` / `NSLocalizedString` 代码命中。
