# Starcat CLI 与外部 MCP 桥接设计

> **状态**：方案设计（2026-06-21 dong4j 拍板：先记录文档，CLI 不只解决当前 Codex 兼容问题，后续还要扩展为 `starcat` skill 的服务入口）
> **作者**：Claude Code
> **关联**：
> - 根因发现：[`docs/功能实现总览.md`](功能实现总览.md)（MCP Service 启动期 NWError 22 修复、重启端口占用修复）
> - 长期目标：`docs/发展规划.md` 中"为外部提供 skill / 自动化入口"路线

---

## 0. 背景与动机

### 0.1 当前已落地的 MCP Service

Starcat P0 已实现 [`StarcatMCPService`](../功能实现总览.md)（位于 `Starcat/Features/MCP/`）：

- 本机 loopback HTTP 监听 `127.0.0.1:5551/mcp`
- Bearer token 鉴权（`StarcatMCPTokenStore`，加密文件后端）
- `StatelessHTTPServerTransport` 协议（无 session、无 SSE，POST JSON-RPC 直接响应）
- 工具集：读类（搜索 / 详情 / tag / note）+ 写类（notes / status / tags，Pro 限定）

### 0.2 发现的客户端兼容性问题

dong4j 2026-06-21 反馈：

1. **Codex CLI 不支持 HTTP URL 形式的 MCP**——只支持 stdio transport（`[mcp_servers.xxx] command = "..."`），这是 Codex 当前的硬限制。
2. **Claude Code 的 MCP 配置**则完美支持 HTTP URL + Bearer token header——`{"type": "http", "url": "http://127.0.0.1:5551/mcp", "headers": {"Authorization": "Bearer ..."}}` 已能正确加载 Starcat MCP。
3. **未来还要把 Starcat 能力暴露给"非 Claude Code / Codex 客户端"**——如终端自动化脚本、外部 skill runtime、本地 agent 框架等，**必须有一个不绑 GUI App 生命周期的 CLI 入口**。

### 0.3 结论

**Starcat 需要一个独立的 CLI（`starcat` command）**，它有两个角色：

| 角色 | 场景 | 协议 |
|------|------|------|
| **stdio MCP adapter** | Codex / 老式 client 启动 | stdin/stdout JSON-RPC，forward 到 loopback HTTP |
| **外部 skill / 自动化入口** | 未来 skill runtime / 脚本调用 | stdio MCP / stdout CLI 双面 |

这不是"为单一 client 做的 workaround"——是为 Starcat **建立 headless 能力出口**的长期投资。

---

## 1. 目标与非目标

### 1.1 目标

1. **P0 stdio 桥接**：写一个独立 Swift 可执行文件 `starcat-mcp-stdio`，实现 MCP stdio transport，内部把请求 forward 到 `127.0.0.1:5551/mcp`。
2. **P0 沙盒打通**：解决 Starcat App 沙盒 + 独立进程 + token 共享的三角矛盾。
3. **P1 CLI 形态**：把 stdio bridge 升级为 `starcat` 命令，子命令涵盖 `mcp / version / status / doctor` 等。
4. **P1 Skill 化**：CLI 子命令 + 文档，让 `Claude Code` 的 `/skill` 机制可调用 Starcat 能力。

### 1.2 非目标

1. 不重写 MCP 协议层（直接复用 MCP Swift SDK 0.12.1）。
2. 不在 CLI 里实现业务逻辑（不读 DB / 不调 GitHub API / 不调 AI）——只做协议转发。
3. 不在 CLI 里处理 i18n / 设置 UI（CLI 是开发者工具，全英文 + flag 风格）。
4. **不开放公网端口**——CLI 只走 loopback，永远不暴露外部。

---

## 2. 沙盒约束与 token 共享方案

### 2.1 根因：沙盒把 Starcat 锁在 container 里

Starcat 启用 `com.apple.security.app-sandbox = true`（[`Starcat.entitlements`](../../Starcat/Starcat.entitlements)），导致：

- token 加密文件实际路径：`~/Library/Containers/com.starcat.app/Data/Library/Application Support/com.starcat.app/credentials.json`
- UserDefaults 实际路径：`~/Library/Containers/com.starcat.app/Data/Library/Preferences/com.starcat.app.plist`
- **不申请 app group entitlement** → 独立进程读不到

CLI / adapter 启动后**无沙盒 / 有沙盒**两种情况：

| 场景 | 进程身份 | 能读沙盒文件？ |
|------|--------|--------------|
| 由 Codex / Claude Code 启动 | 父进程是终端 / CLI runtime，**无沙盒** | ❌（不在 container 内） |
| 由 Starcat App fork | 父进程是沙盒 App，**子进程继承沙盒** | ✅（共享 container） |
| 走 Launch Services open | Launch Services 在沙盒外 spawn | ❌ |

**结论**：让外部进程直接读沙盒文件 = **永远做不到**（即便加 app group，也只能解决"主 App 写到 group container"，不能解决"外部进程主动去 group container 拿实时 token"——**token 轮换后还要通知 adapter 重新读**，复杂度爆炸）。

### 2.2 选定方案：D 方案 — 主 App 起独立进程时显式传参 + 沙盒外 socket 通道

**核心思路**：

- **CLI 由 Starcat App 自己 fork**，不是由 Codex / Claude Code 启动
- 父进程 → 子进程 通过 **环境变量** 传 token / port，**子进程** 再去 stdin/stdout 跑 stdio
- 父进程把子进程 stdio 重定向到 **Unix Domain Socket**（沙盒内 + 沙盒外的 IPC）
- 外部 client 启动的是**沙盒外的 proxy 二进制**（或 shim 脚本），proxy 连 Unix Domain Socket

但这有个**根本问题**：Codex / Claude Code 是**启动方**，不是 Starcat；Starcat **无法**控制 fork 时机。

**所以必须换思路**：

### 2.3 真正可落地的方案：A + B 混合

1. **加 app group entitlement**（**只这一次性改动**）
   - `com.apple.security.application-groups = ["group.com.starcat.shared"]`
   - App + CLI 都能读写 group container `~/Library/Group Containers/group.com.starcat.shared/`
2. **token / port / server-state 全部迁移到 group container**
   - 加密文件路径常量改 `containerURL(forSecurityApplicationGroupIdentifier: "group.com.starcat.shared")?.appendingPathComponent("credentials.json")`
   - port 状态同上
3. **CLI 直接读 group container**（不再 spawn 父 App、不再走 IPC）
4. **CLI 启动时检测 Starcat App 是否在跑**
   - 不在跑 → `open -a Starcat`（让主 App 启动并 bind 端口）
   - 在跑 → 直接 forward 请求

### 2.4 app group 改动的成本

| 成本项 | 评估 |
|--------|------|
| entitlement 加 1 行 | 极小 |
| KeychainManager 路径常量改 1 行 | 极小 |
| AppSettings UserDefaults 走 shared suite | 1~2 处 |
| Apple ID Team 重新签名 | **必需**（沙盒 App 改 entitlement 必须 resign） |
| 重新测沙盒行为（文件、网络、agent 调起） | 一次性回归测试 |

**评估**：app group 是 macOS sandboxed App 与外部进程共享状态的**官方正解**，改一次永久受益。

### 2.5 安全性

| 风险 | 缓解 |
|------|------|
| group container 里 token 是明文风险 | 继续用 CryptoManager AES-GCM 加密，密钥绑硬件 UUID |
| 同一台 Mac 上其他 user 能读 group container | macOS app group 严格按 user 隔离，**不影响** |
| 恶意进程读 group container | 走 `setPermissions([.posixPermissions: 0o600])`，只 owner 可读 |

---

## 3. 架构

### 3.1 进程拓扑

```
┌─────────────────────────────────────┐
│ Starcat App (沙盒 + app group)      │
│   ├── StarcatMCPService (loopback)  │ ← 监听 127.0.0.1:5551
│   ├── KeychainManager → group 容器  │
│   └── AppSettings → group UserDefaults
└──────────────┬──────────────────────┘
               │ group container 共享
┌──────────────┴──────────────────────┐
│ starcat CLI (无沙盒)                 │
│   ├── read token from group 容器    │
│   ├── read port from group UserDefaults │
│   ├── stdin/stdout JSON-RPC ↔ HTTP  │
│   └── subcommands: mcp / version /  │
│                   status / doctor   │
└──────────────┬──────────────────────┘
               │ fork+exec
┌──────────────┴──────────────────────┐
│ Codex / Claude Code / Skill runtime │
└─────────────────────────────────────┘
```

### 3.2 CLI 子命令设计

```
starcat
├── mcp                 # stdio MCP server 入口（Codex / Claude Code 用）
│   --port 5551         # 覆盖默认端口
│   --token-from-app    # 从 group 容器读 token（默认）
│   --token XXX         # 直接传（CI / 测试用）
│   --no-auto-launch    # Starcat App 没启时不自动 open
├── status              # 一行展示当前 Starcat App 状态（run / stop / failed）
│   --json              # 机器可读
├── doctor              # 检查 group container 可访问 / port 可用 / token 有效
├── version             # CLI 版本号
└── help
```

### 3.3 stdio → HTTP 桥接实现要点

```swift
// 伪代码，仅说明流程
while let line = readLine() {  // stdin 一行 = 一条 JSON-RPC 请求
    let request = try JSONDecoder().decode(JSONRPCRequest.self, from: line.data(using: .utf8)!)

    // 转发到 loopback HTTP
    var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    urlRequest.httpBody = line.data(using: .utf8)

    let (data, response) = try await URLSession.shared.data(for: urlRequest)
    // response 写回 stdout（一行）
    print(String(data: data, encoding: .utf8)!)
    fflush(stdout)
}
```

**关键约束**：

1. stdin/stdout 必须**纯 JSON-RPC line**——不能 log 到 stdout（会被 client 当 JSON-RPC 解析失败）
2. 所有诊断信息 → **stderr**（Codex 等 client 会把 stderr 当日志处理）
3. **不能用 SwiftUI / Combine / @MainActor**（CLI 是 headless，没主线程）
4. stdin EOF → graceful shutdown
5. 一次只处理一个连接（Codex / Claude Code 都是单进程 client）

### 3.4 进程生命周期

```
启动 Codex → spawn starcat mcp → exec
                                        ↓
                              read token from group
                                        ↓
                              探测 127.0.0.1:5551
                                        ↓
                              失败 → open -a Starcat
                                        ↓
                              等待端口 ready（最多 5s）
                                        ↓
                              while read stdin line
                                        ↓
                              POST 127.0.0.1:5551/mcp
                                        ↓
                              print response to stdout
                                        ↓
                              循环 → stdin EOF → exit
```

---

## 4. 工程实施

### 4.1 涉及文件

**新增**：

| 文件 | 职责 | 行数估算 |
|------|------|---------|
| `StarcatCLI/Package.swift` | Swift Package 描述，executable target | ~30 |
| `StarcatCLI/Sources/starcat/main.swift` | argparse + subcommand dispatch | ~120 |
| `StarcatCLI/Sources/starcat/MCPStdioServer.swift` | stdio ↔ HTTP bridge | ~150 |
| `StarcatCLI/Sources/starcat/GroupContainerAccess.swift` | 读 token / port | ~80 |
| `StarcatCLI/Sources/starcat/StarcatAppLauncher.swift` | `open -a Starcat` + 等待端口 | ~60 |
| `StarcatTests/StarcatCLITests/` | MCPStdioServer 单元测试 | ~200 |

**修改**：

| 文件 | 改动 |
|------|------|
| `Starcat/Starcat.entitlements` | 加 `application-groups` |
| `Starcat/Core/Keychain/KeychainManager.swift` | `credentialsFileURL()` 改 group container |
| `Starcat/Core/Settings/AppSettings.swift` | UserDefaults 走 `UserDefaults(suiteName: "group.com.starcat.shared")` |
| `Starcat/App/AppDependencies.swift` | 注入共享 UserDefaults |
| `project.yml` | 加 `starcat-cli` target |
| `Starcat/Features/About/AboutView.swift` | 加一行致谢（不需新增第三方，是自有代码） |

### 4.2 实施顺序

1. **Phase 1：app group 落地**（基础）
   - entitlement 改 + KeychainManager 路径迁移 + UserDefaults suite 迁移
   - 单测：KeychainManagerTests + AppSettingsTests
2. **Phase 2：CLI skeleton**
   - `starcat version` 先跑通
   - 单测：argparse 路径
3. **Phase 3：stdio bridge**
   - `starcat mcp` 接 stdin/stdout + forward 到 HTTP
   - 单测：mock HTTP server + stdin pipe
4. **Phase 4：auto-launch + 等待端口**
   - `open -a Starcat` + `nc -z 127.0.0.1 5551` polling
5. **Phase 5：集成测试**
   - 启动 Starcat App → 启动 `starcat mcp` → 模拟 client 发 initialize / tools/list
6. **Phase 6：项目健康度 + skill 文档**
   - CLI 加 `doctor` 子命令
   - 写 `docs/3-设计/详细设计/35-starcat-skill使用指南.md`（如果有需求）

### 4.3 单测策略

- `MCPStdioServerTests`：用 `Pipe` mock stdin/stdout + `URLProtocolStub` mock HTTP（参考已有 `StarcatTests/URLProtocolStub.swift` 样板）
- `GroupContainerAccessTests`：临时 group container 路径 + 加密 round-trip
- `StarcatAppLauncherTests`：`open -a` 在 test 环境跳过，验证 polling 逻辑
- **不需要**集成 Codex（CI 环境跑 Codex 是过度耦合）

---

## 5. 风险与缓解

| 风险 | 缓解 |
|------|------|
| app group 改了之后 release 签名失败 | CI 加 `xcodebuild -resolvePackageDependencies` + codesign 验证 |
| 旧用户升级后 token / settings 迁移失败 | 启动时检测 group container 为空时 fallback 到原沙盒路径 read-then-write 一次（铁律 #1 不写"兼容代码"但**首次迁移**是必要的一次性迁移，不算"保留旧 API"） |
| 多个 Starcat App 实例同时 bind 5551 | 沿用现有 `StarcatMCPPortAvailability` 预检 + `SO_REUSEADDR` |
| CLI 在 CI / Linux 跑（开发机是 macOS） | target 限定 `platforms: [.macOS(.v15)]`，CI 加 platform guard |
| Codex 未来支持 HTTP 后 CLI 冗余 | 不冗余——`starcat mcp` 还是 Skill runtime 的入口，HTTP client 走原生 `mcp` 协议直连 5551 |
| fork 进程泄漏 | CLI 是无状态 forwarder，stdin EOF / process kill 都 graceful shutdown |

---

## 6. 与 StarcatMCPService 现有关系

**`StarcatMCPService`（loopback HTTP 5551）是 single source of truth**。CLI 不实现任何 MCP 业务逻辑：

- ❌ 不重新实现 `StatelessHTTPServerTransport`
- ❌ 不重读 tool registry
- ❌ 不绕过主 App 的 Pro / 写权限 / audit 日志校验

CLI **只是**把 stdio ↔ HTTP 翻译一次。所有鉴权、限流、audit 都在主 App 走。这样保证：

- 主 App 设置页 rotate token 后 CLI 立即生效（重读 group container）
- 主 App 写工具 audit 日志完整保留
- 主 App Pro 校验是唯一门控

---

## 7. 时间线（预估）

| Phase | 预计工时 | 阻塞点 |
|-------|---------|--------|
| 1. app group 落地 | 0.5 天 | 重新签名（一次性） |
| 2. CLI skeleton | 0.5 天 | 无 |
| 3. stdio bridge | 1 天 | Phase 1 + 2 |
| 4. auto-launch | 0.5 天 | Phase 1 + 3 |
| 5. 集成测试 | 0.5 天 | Phase 4 |
| 6. skill 文档（可选） | 0.5 天 | 用户需求 |

**总计 P0：~3 天**，P0+P1：**~3.5 天**。

---

## 8. 后续 TODO

1. **app group entitlement 重新签名**（dong4j 持有 Apple ID Team）
2. **首次启动数据迁移**（group container 读到旧 sandbox container 的 credentials）
3. **CI 加 macOS sandbox 回归测试**
4. **写给 Skill runtime 的 `starcat-skill` 文档**
5. **CLI 国际化**（pre-launch 不做）

---

## 9. 变更日志

- 2026-06-21 初稿：dong4j 拍板 CLI 长期要做，先记录 P0 方案
