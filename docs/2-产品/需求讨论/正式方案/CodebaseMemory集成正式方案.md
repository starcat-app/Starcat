# CodebaseMemory 集成正式方案

> 创建：2026-06-29
> 状态：方案稿,待 dong4j 拍板后转实施
> 上游：[CodebaseMemory 集成需求讨论](../CodebaseMemory集成需求讨论.md)
> 详细技术设计：[`docs/3-设计/详细设计/36-CodebaseMemory集成设计.md`](../../../3-设计/详细设计/36-CodebaseMemory集成设计.md)

---

## 1. 路线选择

采用 **「Starcat App 内置 Process spawn + 二进制打包进 bundle + UI 在系统浏览器打开」** 路线。

- **二进制打包进 bundle**:与 CodeFlow 的 `codeflow.html` 资源打包同款形态(`Starcat/Resources/Codebase/`),Xcode 启动时随 `.app/Contents/Resources/Codebase/` 一起发布。
- **首次使用 lazy 拷贝**:首次进入 `CodebaseMemoryPanel` 时,把 bundle 内 `codebase` 二进制复制到 `<container>/Starcat/codebasememory/.bin/codebase` + `chmod 0755`,**之后所有 Process spawn 都走 container 副本**(避免 Xcode strip 掉 +x 权限,避免 bundle 路径变化导致 Process 句柄漂移)。
- **UI 在系统浏览器**:与 CodeFlow 同款 `NSWorkspace.shared.open(URL)`,打开 `http://127.0.0.1:<port>/`。
- **不内置 WebView**:WKWebView 显示 localhost 在 sandbox 下需要额外配置同源策略,内存占用也不划算。
- **不下载二进制**:沙盒不允许下载可执行文件(App Store 审核也明确不允许),必须手动打包。

### 1.1 拒绝的备选

| 备选 | 不选理由 |
|---|---|
| 让用户自己装 `codebase-memory-mcp`,Starcat 通过 CLI 调用 | 增加用户安装步骤;Pro 用户期望开箱即用;与 CodeFlow 的"打包 HTML 资源"形态不一致 |
| 走 WebView 显示 3D graph | WKWebView 与 localhost 同源隔离需额外配置;内存常驻 |
| 让二进制只走 stdio / CLI 子命令,不暴露 UI 端口 | 用户原话:"那索引后拿来干嘛"——必须有可视化 |
| 端口固定 9749 | 与用户本机可能装的 `codebase-memory-mcp` 冲突 |

---

## 2. 模块划分

### 2.1 新增模块

```
Starcat/Features/CodeGraph/CodebaseMemory/
├── CodebaseMemoryPortAvailability.swift     # POSIX bind() 端口占用探测(抄 StarcatMCPPortAvailability)
├── CodebaseMemoryStorage.swift              # 存储根 + bookmark + summary(抄 CodeFlowStorage)
├── CodebaseMemoryBinaryResolver.swift       # bundle → container 拷贝 + chmod
├── CodebaseMemoryExtractor.swift            # 持久解压到 <codebasememory-root>/<owner>/<repo>/source/
├── CodebaseMemoryRunner.swift               # Process spawn + CLI 调用 + UI 子进程管理
├── CodebaseMemoryViewModel.swift            # 6 步状态机(对齐 CodeFlowViewModel)
├── CodebaseMemoryPanel.swift                # Sheet UI(对齐 CodeFlowPanel)
└── CodebaseMemoryError.swift                # 错误类型 + l10n

StarcatTests/CodebaseMemoryRunnerTests.swift # 端口探测 + Process + 解压测试

scripts/fetch-codebase-binary.sh             # 手动跑,拉最新二进制 + SHA-256 校验 + 重命名

Starcat/Resources/Codebase/                  # bundle 资源(scripts 产物)
├── codebase                                 # 二进制本体(已 chmod +x,已重命名)
├── STARCAT-INTEGRATION.md                   # 版本/校验和/修改日期
└── UPSTREAM-README.md                       # 上游 provenance + cosign 验证步骤
```

### 2.2 复用(零修改)

| 已有 | 用法 |
|---|---|
| `SharedSnapshotService.archiveIfNeeded(repo:commitSHA:)` | 拉共享 zipball,同 CodeFlow / RepoContext |
| `SourceZipExtractor` 的安全参数(`zipMaxBytes` / `allowUncontainedSymlinks`) | 解压时复用 `ZIPFoundation` 同款配置(已踩过 symlink 坑) |
| `StarcatMCPPortAvailability.unavailableMessage(for:)` 算法 | POSIX `bind()` + `SO_REUSEADDR`,**直接抄**到 `CodebaseMemoryPortAvailability` |
| `CodeFlowStorage` 的 `resolveOutputRoot` / `withOutputRoot` / `migrateProjects` / `summary` 模式 | `CodebaseMemoryStorage` 1:1 抄,改默认根 + 子目录名 |
| `SheetCloseButton` / `SyncIconButton` | UI 规范 |
| `String.l10n` / `Localizable.xcstrings` | i18n |

### 2.3 改动文件(最小化)

| 文件 | 改动 |
|---|---|
| `Starcat.entitlements` | **0 改**(sandbox 默认允许 spawn container 内 binary) |
| `project.yml` | **0 改**(sources 已 include `Resources/`) |
| `Shared/Components/Toolbar/ExternalLinksMenu.swift` | +1 callback + +1 Menu item |
| `Features/Home/RepoListView.swift` | +sheet(item:) 绑定 CodebaseMemoryPanel |
| `Features/Settings/IntegrationSettingsView.swift` | +1 个 Section(对齐 CodeFlow 段) |
| `Features/Settings/SettingsView.swift` (Storage Tab) | +1 个 usageRow + +1 个 PendingAction case |
| `App/AppDependencies.swift` | +注入 `CodebaseMemoryStorage.shared` |
| `Core/Settings/AppSettings.swift` | (可选)加 `codebaseMemoryUIPort` 持久化键(本方案不暴露给用户,只在 container 文件持久化) |
| `Core/Subscription/EntitlementGate.swift` | +`case codebaseMemory` |
| `docs/3-设计/详细设计/README.md` | 补登 36 文档索引 |

---

## 3. UX 流程

### 3.1 入口(对齐 CodeFlow)

```
仓库详情页 toolbar
└─ ExternalLinksMenu(safari icon)
   └─ FeaturedExternalLinksControl
      ├─ CodeFlow            ──→ CodeFlowPanel sheet
      ├─ CodebaseMemory 3D   ──→ CodebaseMemoryPanel sheet   ← 新增
      ├─ Divider
      ├─ Issues / PRs / Releases / Homepage(原样)
```

`FeaturedExternalLinksControl` 加一项;`codebaseMemoryRepo: Repo?` 参数,与现有 `codeFlowRepo` 同款传值模式;`onOpenCodebaseMemory(repo)` 回调。

### 3.2 6 步状态机

| Step | ID | 失败处理 |
|---|---|---|
| ① 解析 commit SHA | `resolveRevision` | 401/404 → 错误 sheet |
| ② 拉 zipball | `download` | 同 CodeFlow;命中缓存秒过 |
| ③ 持久解压到 `<root>/<owner>/<repo>/source/` | `extract` | zip 损坏/超限 → 清理 + 错误 |
| ④ `cli index_repository '{"repo_path": "..."}'` | `index` | binary 抛错 → 显示 stderr |
| ⑤ 启 UI 子进程 `--ui=true --port=<随机>` | `startUI` | 端口冲突重随机;最多 16 次 |
| ⑥ `NSWorkspace.shared.open("http://127.0.0.1:<port>/")` | `openBrowser` | 浏览器未配置 → 提示 |

二次进入(同 repo/SHA):① ② ③ ④ ⑤ 全部跳过,直接 ⑥ 秒开。

### 3.3 进程生命周期

- **不杀 UI 子进程**:Sheet 关闭 / 用户切走,UI 进程**保留运行**,用户继续在浏览器探索。
- **App 退出时杀**:`StarcatApp.willTerminate` 注册兜底,`CodebaseMemoryRunner.activeProcesses` 数组遍历 `process.terminate()`。
- **手动 "Re-generate"**:先 `terminate()` 旧进程,再走完整流程。
- **手动 "Reveal in Finder"**:打开 `<codebasememory-root>/<owner>/<repo>/`。

### 3.4 设置页布局(IntegrationSettingsTab)

```
┌─ CodebaseMemory ─────────────────────────────────┐
│ 二进制版本: v0.8.1 · SHA-256: a1b2c3d4e5f6  (l10n) │
│ 3D 代码图谱视图                                          │
│                                                       │
│ 输出目录: ~/Library/Application Support/...           │
│   [选择…] [显示] [重置]                               │
│                                                       │
│ 4 列统计:                                              │
│   项目数: N │ 占用: 234 MB │ 累计生成: N │ 最近: ... │
└──────────────────────────────────────────────────────┘
```

> 不加 "检查更新/下载" 按钮(二进制手动打包进 bundle,无网络需求)。
> 不加 UI 端口输入框(随机生成)。

### 3.5 StorageSettingsTab 新增行

```
| CodebaseMemory | <codebaseMemoryStorage.totalBytes> | [清理] |
```

仿 `aiContext` / `codeFlow` 现有 `usageRow` 模式;`PendingAction.codebaseMemory` case + `codebaseMemoryStorage.deleteAllProjects()`。

### 3.6 Pro gating

- 仿 `requireCodeFlowAccess()`,`requireCodebaseMemoryAccess()` 在 `CodebaseMemoryViewModel.prepare()` 入口调用。
- 未订阅 → 弹 `ProPaywallSheet`,Sheet 关闭后回到正常 UI,CodebaseMemory 按钮变灰。
- `EntitlementGate` 注册 `ProFeature.codebaseMemory`(新增 case)。

---

## 4. 数据结构

### 4.1 文件布局

```
<container>/
└── Starcat/
    └── codebasememory/                # CodebaseMemoryStorage.defaultOutputRoot()
        ├── .starcat-summary.json      # summary 缓存(HOM-203 同款)
        ├── .bin/                      # 二进制拷贝
        │   └── codebase               # chmod 0755
        ├── .internal-cache/           # CBM_CACHE_DIR(原 ~/.cache/codebase-memory-mcp/)
        └── <owner>/
            └── <repo>/
                ├── source/            # 持久解压目录
                │   └── <commit-SHA>/
                │       └── (解压后的 repo 内容)
                │   └── .codebase-memory/      # 二进制写回的产物
                │       └── graph.db.zst
                │   └── .codebase-memory.json  # 二进制配置
                │   └── .zip.sha256             # 我们写,做幂等
                └── metadata.json     # CodebaseMemoryMetadata(我们自己的)
```

### 4.2 Metadata

```swift
struct CodebaseMemoryMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int                  // 当前 1
    let repository: Repository
    let sourceRevision: SourceRevision      // branch + commitSHA + commitURL
    let lastIndexing: Execution              // 单条记录
    let generation: Generation               // 同 CodeFlow,generationCount
    let binaryVersion: String               // "v0.8.1"
    let binarySHA256: String                // bundle 内 binary 的 SHA-256
}

struct Repository: Codable, Equatable, Sendable {
    let githubID: Int64
    let owner: String
    let name: String
    let fullName: String
    let htmlURL: String
}

struct SourceRevision: Codable, Equatable, Sendable {
    let branch: String
    let commitSHA: String
    let commitURL: String
    var shortSHA: String { String(commitSHA.prefix(7)) }
}

struct Execution: Codable, Equatable, Sendable {
    let startedAt: Date
    let finishedAt: Date
    let durationMs: Int
    let steps: [CodebaseMemoryExecutionStep] // 6 步
    let indexedNodeCount: Int?              // binary 报告
    let indexedEdgeCount: Int?
}

struct Generation: Codable, Equatable, Sendable {
    let generatedAt: Date
    let generationCount: Int
}

struct CodebaseMemoryExecutionStep: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case pending, running, succeeded, failed, handedOff }
    enum ID: String, Codable, Sendable {
        case resolveRevision, download, extract, index, startUI, openBrowser
    }
    let id: ID
    var status: Status
    var detail: String?                     // 人类可读进度
    var durationMs: Int?
}
```

### 4.3 缓存命中判定

```swift
func isCacheHit(metadata: CodebaseMemoryMetadata?, requestedSHA: String) -> Bool {
    guard let metadata else { return false }
    return metadata.sourceRevision.commitSHA == requestedSHA
}
```

命中 → 跳过 ① ② ③ ④ ⑤,直接 ⑥ `openBrowser`(前提:`<port>` 文件存在且 binary 还在跑,否则重启 UI 子进程)。

---

## 5. 端口管理

### 5.1 算法

```swift
func reservePort() throws -> Int {
    // 1. 读 <codebasememory-root>/.port 文件
    //    若存在且 CodebaseMemoryPortAvailability.check(port) == nil → 用
    // 2. 否则 Int.random(in: 40000..50000) 循环最多 16 次
    //    直到 check 通过
    // 3. 写回 .port 文件
}
```

### 5.2 POSIX bind 探测(直接抄 MCP)

```swift
enum CodebaseMemoryPortAvailability {
    static func unavailableMessage(for port: Int) -> String? {
        guard (1024...65_535).contains(port) else { return ... }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return ... }
        defer { close(fd) }
        var reuseAddr: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r == 0 { return nil }
        if errno == EADDRINUSE { return "端口被占用" }
        return "检查失败"
    }
}
```

> **不依赖 nc 命令**(沙盒限制 + 用户可能未装)。

---

## 6. 二进制打包与脚本

### 6.1 下载脚本

`scripts/fetch-codebase-binary.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
# 用法:
#   ./scripts/fetch-codebase-binary.sh                 # 拉 latest
#   ./scripts/fetch-codebase-binary.sh v0.8.1          # 拉指定版本
#   ./scripts/fetch-codebase-binary.sh latest /custom/path  # 自定义目标

VERSION="${1:-latest}"
TARGET_ROOT="${2:-$(dirname "$0")/../Starcat/Resources/Codebase}"

# 1. 解析 VERSION → tag (latest 用 GitHub API 拿 tag_name)
if [ "$VERSION" = "latest" ]; then
  VERSION=$(curl -fsSL https://api.github.com/repos/DeusData/codebase-memory-mcp/releases/latest \
            | python3 -c "import json,sys;print(json.load(sys.stdin)['tag_name'])")
fi

# 2. 下载 tarball + checksums
mkdir -p /tmp/codebase-fetch
cd /tmp/codebase-fetch
ASSET="codebase-memory-mcp-darwin-arm64.tar.gz"
curl -fsSL -o "$ASSET" "https://github.com/DeusData/codebase-memory-mcp/releases/download/$VERSION/$ASSET"
curl -fsSL -o checksums.txt "https://github.com/DeusData/codebase-memory-mcp/releases/download/$VERSION/checksums.txt"

# 3. SHA-256 校验(强校验,失败立即退出)
grep "$ASSET" checksums.txt | sha256sum -c --strict -

# 4. 解压 + 重命名 + chmod
tar -xzf "$ASSET"
mv codebase-memory-mcp codebase
chmod 0755 codebase

# 5. 拷贝到 bundle 资源目录
mkdir -p "$TARGET_ROOT"
mv codebase "$TARGET_ROOT/codebase"

# 6. 自动写 STARCAT-INTEGRATION.md
SHA=$(shasum -a 256 "$TARGET_ROOT/codebase" | awk '{print $1}')
cat > "$TARGET_ROOT/STARCAT-INTEGRATION.md" <<EOF
# CodebaseMemory Integration

- 上游: DeusData/codebase-memory-mcp
- 版本: $VERSION
- 二进制 SHA-256: \`$SHA\`
- 重新生成: \`./scripts/fetch-codebase-binary.sh $VERSION\`
- 上次更新: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

# 7. 复制 UPSTREAM-README.md(若不存在,从模板拷贝)
if [ ! -f "$TARGET_ROOT/UPSTREAM-README.md" ]; then
  cp "$(dirname "$0")/../Starcat/Resources/Codebase/UPSTREAM-README.md.template" \
     "$TARGET_ROOT/UPSTREAM-README.md"
fi

echo "✅ Done. Binary at: $TARGET_ROOT/codebase"
echo "   SHA-256: $SHA"
```

### 6.2 资源自带 `UPSTREAM-README.md`(首次落地手写)

```markdown
# CodebaseMemory 上游 Provenance

本目录的 `codebase` 二进制是 Starcat 从
[DeusData/codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp)
打包进 App 的。

## 许可

MIT License © DeusData

## 重命名说明

上游二进制名 `codebase-memory-mcp` → Starcat 内统一改名为 `codebase`:
- 短名,避免和"项目代码库"语义混淆
- 与 `starcat-mcp-stdio` 等其他 Starcat 自有二进制风格一致

## 完整性验证

每次重新生成都用 `scripts/fetch-codebase-binary.sh` 跑:
1. 下载 GitHub releases 的 `checksums.txt`
2. `sha256sum -c --strict -` 校验
3. 上游 release 同时提供 SLSA Level 3 + Sigstore cosign 签名:
   \`\`\`bash
   cosign verify-blob \
     --bundle checksums.txt.bundle \
     --certificate-identity-regexp 'https://github.com/DeusData/.*' \
     --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
     checksums.txt
   \`\`\`

## 已知约束

- App 内调用走 `Process` spawn,**只 spawn container 内 .bin/codebase 副本**
  (沙盒限制 + App Store 审核要求"不下载可执行文件")
- 不修改上游二进制,纯打包
```

---

## 7. 风险与缓解

| # | 风险 | 等级 | 缓解 |
|---|---|---|---|
| R1 | 沙盒不允许下载可执行文件 | 高 | **必须手动打包进 bundle**(本方案基础) |
| R2 | 用户本机装了 codebase-memory-mcp 占 9749 | 中 | **随机端口 40000–50000** + POSIX bind 探测,不撞 |
| R3 | `~/.cache` 默认路径 sandbox 写不进去 | 高 | **`CBM_CACHE_DIR` env 重定向**到 container `.internal-cache/` |
| R4 | App Store 审核问"为什么打包二进制" | 中 | UPSTREAM-README.md + STARCAT-INTEGRATION.md 写清 provenance |
| R5 | 二进制被 Xcode strip `+x` 权限 | 高 | **运行时拷贝到 container + chmod 0755** |
| R6 | 进程 zombie(用户杀 App 后 UI 进程残留) | 中 | `StarcatApp.willTerminate` 兜底 kill |
| R7 | UI 端口暴露本机网络服务 | 低 | **只监听 127.0.0.1**(已有 `network.server` entitlement) |
| R8 | 二进制内部 spawn 子进程(违反沙盒) | 低 | 上游设计"no Docker, no runtime, no API keys",**单进程**,已确认 |
| R9 | 持久解压膨胀磁盘(1000 个 repo × 50MB) | 中 | Storage Tab 清理 + 单项目删除(同 CodeFlowStorage) |
| R10 | binary 启动慢 | 低 | 接受,前台跑,UI 打开后用户继续浏览器交互 |
| R11 | binary 报告的 14 个 MCP tool 升级破坏 schema | 中 | 我们的 `cli <tool> '<json>'` 用宽松 JSONDecoder,只取需要字段 |
| R12 | macOS Gatekeeper 拦 bundle 内 binary | 低 | 不走系统路径,Process 直接 spawn container 内 file,Gatekeeper 不查 |

---

## 8. 与上游 CodeFlow / RepoContext 的关系

| 维度 | CodeFlow | RepoContext | **CodebaseMemory** |
|---|---|---|---|
| 解压目录 | tmp(整包 base64 嵌 HTML) | tmp(走 XML pipeline) | **持久**(source/) |
| 产物 | index.html | context.xml | **.codebase-memory/** |
| 子进程 | ❌ | ❌ | **✅**(--ui=true) |
| 网络端口 | ❌ | ❌ | **✅**(UI) |
| ZIP 复用 | ✅ | ✅ | **✅** |
| Settings Tab | ✅ | ❌(只在 Storage) | **✅**(对齐 CodeFlow) |
| Storage Tab | ✅ | ✅ | **✅** |
| Pro gating | ✅ | ✅ | **✅** |

**结论**:平行存在,不替代;ExternalLinksMenu 同组双入口让用户自选。

---

## 9. 实施 checklist

```
□ 1. scripts/fetch-codebase-binary.sh 写完(dong4j 手动跑)
□ 2. Starcat/Resources/Codebase/ 三个文件就位
□    ├─ codebase (二进制)
□    ├─ STARCAT-INTEGRATION.md
□    └─ UPSTREAM-README.md
□ 3. xcodegen generate 一次(让 project.yml 认资源)
□ 4. 写 CodebaseMemoryStorage / PortAvailability / BinaryResolver
□ 5. 写 CodebaseMemoryExtractor / Runner / Error
□ 6. 写 CodebaseMemoryViewModel / Panel
□ 7. 改 EntitlementGate + AppDependencies
□ 8. 改 ExternalLinksMenu / RepoListView 加入口
□ 9. 改 IntegrationSettingsView 加段
□ 10. 改 SettingsView Storage Tab 加行
□ 11. 写 CodebaseMemoryRunnerTests
□ 12. xcodegen generate + xcodebuild build 通过
□ 13. 补登 README 索引(36 文档)
□ 14. docs/功能实现总览.md 加条目 + 完成后勾选 + > 实现:
```

---

## 10. 文档变更

- 本文件 `docs/2-产品/需求讨论/正式方案/CodebaseMemory集成正式方案.md`(新增)
- 详细技术设计 `docs/3-设计/详细设计/36-CodebaseMemory集成设计.md`(新增)
- `docs/3-设计/详细设计/README.md` 索引补登 36 文档
- `docs/功能实现总览.md` §10 变更日志 + §3 P0/P1 加条目