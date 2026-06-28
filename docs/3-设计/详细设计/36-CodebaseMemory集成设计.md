# Starcat CodebaseMemory 集成设计

> **状态**：方案设计（2026-06-29 dong4j 拍板）
> **适用版本**：当前主线（dev 分支）
> **上游**：[DeusData/codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp)（MIT,静态 C 二进制,darwin-arm64 ~80MB 解压后）
> **关联文档**：
> - [需求讨论：CodebaseMemory 集成](../../2-产品/需求讨论/CodebaseMemory集成需求讨论.md)
> - [正式方案：CodebaseMemory 集成](../../2-产品/需求讨论/正式方案/CodebaseMemory集成正式方案.md)
> - [CodeFlowStorage 实现参考](../../Starcat/Features/CodeGraph/CodeFlowStorage.swift)
> - [RepoContextStorage 实现参考](../../Starcat/Shared/Services/RepoContextStorage.swift)
> - [StarcatMCPPortAvailability 实现参考](../../Starcat/Features/MCP/StarcatMCPPortAvailability.swift)

---

## 0. 背景与动机

### 0.1 为什么现在做

Starcat 现有两条代码分析管线：

| 管线 | 产物 | 能力 | 局限 |
|---|---|---|---|
| RepoContextPacker | `context.xml`(AI 摘要注入) | 文本级上下文(文件列表 + 全文) | 不懂代码语义,只是文件内容 |
| CodeFlow | 自建 HTML 调用图页 | 浏览器可视化,快速看结构 | 模板注入 base64 zip,不建设持久索引 |

**第三条管线**「深度代码查询 + 3D 图谱」需要更强的索引能力：

- **tree-sitter 语法解析** → 跨文件调用链 / 符号级搜索
- **Hybrid LSP** → 类型推断 / 接口实现关系,不启动独立 language server
- **Cypher 图查询** → 任意模式匹配(如「找到所有调用 `send()` 的 export 函数」)
- **3D force-directed 布局** → 浏览器交互探索

codebase-memory-mcp 刚好把这四条做进了**单文件 C 静态二进制**(tree-sitter + LSP + 图谱布局全内嵌,零运行时依赖)。直接打包进 Starcat 就是当前最快的路线。

### 0.2 前置条件（已经成立）

| 条件 | 现状 |
|---|---|
| 有 zipball 下载管线 | `SharedSnapshotService.archiveIfNeeded(repo:commitSHA:)` → 共享缓存 `Application Support/Starcat/archives/github.com/<owner>/<name>.zip` |
| 有解压管线 | `SourceZipExtractor.extract(_:)` 已踩过 ZIPFoundation allowUncontainedSymlinks 坑 |
| 有浏览器打开管线 | `CodeFlowStorage.openPage(_:)` → `NSWorkspace.shared.open(url)` |
| 有持久存储模式 | `CodeFlowStorage` / `RepoContextStorage` 两套 bookmark + summary + migrate 模板 |

---

## 1. 目标与非目标

### 1.1 目标

1. **P0**：把 `codebase` 二进制**手动打包**进 `Starcat/Resources/Codebase/`,App 启动时 lazy 拷贝到 sandbox container `+ chmod`
2. **P0**：用户在仓库详情页通过 ExternalLinksMenu 一键进入 3D 图谱 → Sheet 弹出 → 6 步进度 → 浏览器打开
3. **P0**：同一 repo/SHA 二次进入秒开（跳过解压 + 索引）
4. **P0**：设置页（IntegrationSettingsTab）显示输出目录 / 版本 / 统计；StorageSettingsTab 加清理行
5. **P0**：Pro 门控,免费版不可用
6. **P0**：严格禁用 `codebase update` 命令,版本升级跟随 App Store 主应用更新
7. **P1**：CLI 子命令查询（`search_graph` / `trace_path` 等）通过命令面板或 AI Chat 入口触达,**本期不实现 UI,只留 Runner API**

### 1.2 非目标

- ❌ 不内置 WebView（开系统浏览器）
- ❌ 不暴露 UI 端口给用户配置（随机生成,自动探测冲突）
- ❌ 不下载二进制（必须手动打包进 bundle）
- ❌ 不做本地代码库 index（只索引当前 repo 的 source）
- ❌ 不做远端 server 化、不暴露 LAN host
- ❌ 不做实时 FS watcher 增量更新
- ❌ 不调用 `update` 子命令（沙盒 + 审核禁止）

---

## 2. 模块划分与文件清单

### 2.1 新增模块

```
Starcat/Features/CodeGraph/CodebaseMemory/               ← 新增目录
├── CodebaseMemoryPortAvailability.swift                 ← POSIX bind() 端口占用探测
├── CodebaseMemoryStorage.swift                          ← 存储根 + bookmark + summary
├── CodebaseMemoryBinaryResolver.swift                   ← bundle → container 拷贝 + chmod
├── CodebaseMemoryExtractor.swift                        ← 持久解压到 source/
├── CodebaseMemoryRunner.swift                           ← Process spawn + CLI + UI 进程管理
├── CodebaseMemoryViewModel.swift                        ← 6 步状态机
├── CodebaseMemoryPanel.swift                            ← Sheet UI
└── CodebaseMemoryError.swift                            ← 错误类型 + l10n keys

StarcatTests/CodebaseMemoryRunnerTests.swift             ← 端口探测 + Process + 解压测试

scripts/fetch-codebase-binary.sh                         ← 下载脚本(dong4j 手动跑一次)

Starcat/Resources/Codebase/                              ← bundle 资源(脚本产物)
├── codebase                                             ← 二进制(已 chmod +x,已重命名)
├── STARCAT-INTEGRATION.md                               ← 版本/校验和/修改日期
└── UPSTREAM-README.md                                   ← provenance + cosign 验证步骤
```

### 2.2 改动现有文件（最小化）

| 文件 | 改动 |
|---|---|
| `Starcat.entitlements` | **0 改**（已有 `network.server` + `network.client` + sandbox） |
| `project.yml` | **0 改**（sources pattern 已 include `Resources/`） |
| `Features/CodeGraph/CodeFlowStorage.swift` | **0 改** |
| `Shared/Components/Toolbar/ExternalLinksMenu.swift` | +1 callback `onOpenCodebaseMemory` + +1 Menu item |
| `Features/Home/RepoListView.swift` | +sheet(item:) 绑定 |
| `Features/Settings/IntegrationSettingsView.swift` | +1 Section（对齐 CodeFlow 段） |
| `Features/Settings/SettingsView.swift`(Storage Tab) | +1 usageRow + +1 PendingAction case |
| `App/AppDependencies.swift` | +注入 `CodebaseMemoryStorage.shared` |
| `Core/Subscription/EntitlementGate.swift` | +`case codebaseMemory` |

---

## 3. 沙盒与签名策略（App Store 上架前提）

### 3.1 二进制在 bundle 内的部署

```
Starcat.app/Contents/Resources/Codebase/codebase → (0 权限被 Xcode strip)
```

`CodebaseMemoryBinaryResolver` **不直接 spawn bundle 内的 `codebase`**,而是首次使用时做两步：

```swift
// ① 拷贝到 container
try FileManager.default.copyItem(
    at: bundleCodebaseURL,          // Resources/Codebase/codebase
    to: containerCodebaseURL        // <codebasememory-root>/.bin/codebase
)
// ② 显式写回可执行权限
try FileManager.default.setAttributes(
    [.posixPermissions: 0o755],
    ofItemAtPath: containerCodebaseURL.path
)
```

之后所有 `Process.run()` 都指向 container 副本。为什么需要拷贝：

1. Xcode 打包时会 strip **所有** bundle 资源文件的 `+x` 权限(即使脚本里已设 `chmod 0755`)
2. `Process` spawn 要求可执行文件带 `+x`,`fileIsNotExecutable` 错误没有 fallback
3. container 副本只在 .bin/ 下,不占额外目录污染

### 3.2 codesign 要求

> 本节只记录**技术设计**,实际 codesign 在 release archive 流程中由 Xcode 自动执行。开发阶段 ad-hoc 签名即可。

上架 App Store 时,`codebase` 必须被独立 codesign：

```bash
# 在 Xcode archive 的 post-build 或 Sign to Run(archive 阶段自动),必须走以下等效命令:
codesign -s "Apple Distribution: ..." \
  --entitlements Starcat/Resources/Codebase/codebase.entitlements \
  --deep \
  Starcat.app/Contents/Resources/Codebase/codebase
```

二进制专用的 entitlement 文件（`codebase.entitlements`）：

```xml
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.inherit</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

关键字段：

| 字段 | 作用 |
|---|---|
| `com.apple.security.app-sandbox` | 声明该二进制也在沙盒内运行 |
| `com.apple.security.inherit` | **继承主应用沙盒**（= 能读主应用 container 文件,走同一 IPC 策略） |
| `com.apple.security.network.server` | 允许绑定 `127.0.0.1:<port>` |
| `com.apple.security.network.client` | 允许 outbound (只是 localhost,但声明保底) |

> 不声明 `com.apple.security.inherit` → 子进程走独立沙盒 → 读不到 container 内的 source 解压目录 → `cli index_repository` 失败。

### 3.3 安全约束

- Spawn **只走 container 内 `.bin/codebase` 副本**,绝不 spawn bundle 内未经 chmod 的资源文件
- 环境变量 `CBM_CACHE_DIR` 注入为 `<codebasememory-root>/.internal-cache/`（sandbox 容器内）
- **永远不调用** `codebase update` 子命令（`CodebaseMemoryRunner` 不暴露、不过桥）
- 子进程生命周期由 `CodebaseMemoryRunner.activeProcesses` 统一管理,App 退出时 `willTerminate` 兜底 kill

---

## 4. CodebaseMemoryPortAvailability — 端口占用探测

### 4.1 设计

100% 抄 `StarcatMCPPortAvailability`,仅改名：

```swift
import Darwin
import Foundation

enum CodebaseMemoryPortAvailability {
    /// 返回 nil = 可绑定;返回 String = 友好错误消息
    static func unavailableMessage(for port: Int) -> String? {
        guard (1024...65_535).contains(port) else {
            return String(format: "Port %d out of range", port)
        }

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return "Port check failed" }
        defer { close(fd) }

        var reuseAddr: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                Darwin.bind(fd, sockAddr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result == 0 { return nil }
        if errno == EADDRINUSE {
            return String(format: "Port %d is already in use", port)
        }
        return "Port check failed"
    }
}
```

关键点（和 MCP 完全对齐）：

- **必须设 `SO_REUSEADDR`**：与 NWListener 默认行为对齐,避免重启瞬间 TIME_WAIT 端口被误判为占用
- **只探测 127.0.0.1**：UI 二进制只 loopback,不开放 LAN
- **不依赖 `nc` / SystemConfiguration / NSTask**：纯 POSIX,无外部依赖

### 4.2 端口选择算法（在 ViewModel 层）

```swift
struct CodebaseMemoryPortPicker {
    static let range = 40000..<50000
    static let maxAttempts = 16

    /// - Returns: 可用端口号
    static func pick(previousPort: Int?) -> Int {
        // 1. 上次用的端口还在可用 → 复用（保持浏览器书签稳定）
        if let previous = previousPort,
           CodebaseMemoryPortAvailability.unavailableMessage(for: previous) == nil {
            return previous
        }
        // 2. 随机碰撞
        for _ in 0..<maxAttempts {
            let candidate = Int.random(in: range)
            if CodebaseMemoryPortAvailability.unavailableMessage(for: candidate) == nil {
                return candidate
            }
        }
        // 3. 16 次全部占满（40k-50k 全在 listen,极端场景),返回固定兜底
        //    此时 binary 自己的 bind 会失败,上层捕获后转 failed 态
        return 41934
    }
}
```

---

## 5. CodebaseMemoryStorage — 存储层

### 5.1 骨架

`CodebaseMemoryStorage` 直接抄 `CodeFlowStorage` 的 **95%** 骨架：

```swift
@MainActor
@Observable
final class CodebaseMemoryStorage {
    static let shared = CodebaseMemoryStorage()

    // --- bookmark 持久化 ---
    private static let bookmarkKey = "settings.codebaseMemory.outputDirectoryBookmark.v1"

    // --- 状态 ---
    private(set) var summary: CodebaseMemorySummary = .empty
    private(set) var lastErrorMessage: String?
    private(set) var directoryConfigurationRevision: Int = 0

    // --- 注入(testing only) ---
    var fixedRootURL: URL?  // 单测 bypass bookmark

    // --- 查询 ---
    var outputDirectoryDisplayPath: String { ... }
    var projectCount: Int { summary.projectCount }
    var totalBytes: Int64 { summary.totalBytes }
    var totalGenerationCount: Int { summary.totalGenerationCount }
    var latestGeneratedAt: Date? { summary.latestGeneratedAt }
    var hasCustomOutputDirectory: Bool { ... }

    // --- 目录切换 ---
    func setCustomOutputDirectory(_ url: URL) throws { ... }
    func resetOutputDirectory() throws { ... }

    // --- CRUD ---
    func existingProject(owner: String, name: String) throws -> CodebaseMemoryStoredProject?
    func write(...) throws -> CodebaseMemoryStoredProject
    func deleteProject(owner: String, name: String) throws
    func deleteAllProjects() throws

    // --- 工具 ---
    func outputRootURL() throws -> URL
    func revealOutputRoot() throws
    func reload()
    func rebuildSummary()

    // --- 内部 ---
    private func defaultOutputRoot() throws -> URL
    private func customOutputRoot(for selectedURL: URL) -> URL
    private func resolveOutputRoot() throws -> ResolvedOutputRoot
    private func withOutputRoot<T>(_ operation: (URL) throws -> T) throws -> T
    private func migrateProjects(...)
    // summary HOM-203 同款 loadOrRebuildSummary / rebuildSummaryOnDisk /
    // updateSummaryAfterWrite / updateSummaryAfterDelete / readSummary / writeSummary
}
```

### 5.2 差异点(vs CodeFlowStorage)

| 维度 | CodeFlowStorage | CodebaseMemoryStorage |
|---|---|---|
| bookmark key | `settings.codeflow.outputDirectoryBookmark.v1` | `settings.codebaseMemory.outputDirectoryBookmark.v1` |
| 默认根 | `Application Support/Starcat/codeflow` | `Application Support/Starcat/codebasememory` |
| `customOutputRoot` 子目录 | `codeflow` | `codebasememory` |
| project 目录结构 | `<root>/<owner>/<repo>/{index.html, metadata.json}` | `<root>/<owner>/<repo>/{source/, .codebase-memory/, metadata.json}` |
| summary model | `CodeFlowSummary` | `CodebaseMemorySummary` |
| stored project model | `CodeFlowStoredProject` | `CodebaseMemoryStoredProject` |
| `openPage(_:)` 方法 | 无 | 无(不打开本地文件,UI 走浏览器) |

### 5.4 Summary

```swift
struct CodebaseMemorySummary: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let projectCount: Int
    let totalBytes: Int64
    let totalGenerationCount: Int
    let latestGeneratedAt: Date?
    let updatedAt: Date

    static let currentSchemaVersion: Int = 1
    static let filename: String = ".starcat-summary.json"
    static let empty: CodebaseMemorySummary = .init(
        schemaVersion: currentSchemaVersion,
        projectCount: 0,
        totalBytes: 0,
        totalGenerationCount: 0,
        latestGeneratedAt: nil,
        updatedAt: .distantPast
    )
}
```

### 5.5 StoredProject

```swift
struct CodebaseMemoryStoredProject: Identifiable, Equatable, Sendable {
    /// `<owner>/<repo>` 子目录绝对路径
    let directoryURL: URL
    /// `metadata.json` 绝对路径
    let metadataURL: URL
    /// 解码后的 metadata（不用读写文件）
    let metadata: CodebaseMemoryMetadata

    var id: String { "\(metadata.repository.owner)/\(metadata.repository.name)" }
    var totalBytes: Int64 {
        (try? directorySize(directoryURL)) ?? 0
    }
    var lastActiveAt: Date { metadata.generation.generatedAt }
}
```

### 5.6 Metadata 结构

```swift
struct CodebaseMemoryMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int                                   // 当前 1
    let repository: Repository
    let sourceRevision: SourceRevision                       // branch + commitSHA + commitURL
    let lastIndexing: Execution
    let generation: Generation
    let binaryVersion: String                                // "v0.8.1"
    let binarySHA256: String                                 // bundle 内 binary 的 SHA-256(前 12 位)
    let lastUIPort: Int?                                     // 上次 UI 进程的端口(方便复用,同书签)
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
    let steps: [CodebaseMemoryExecutionStep]
    let indexedNodeCount: Int?
    let indexedEdgeCount: Int?
}

struct Generation: Codable, Equatable, Sendable {
    let generatedAt: Date
    let generationCount: Int
}

struct CodebaseMemoryExecutionStep: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case pending, running, succeeded, failed, skipped, handedOff
    }
    enum ID: String, Codable, Sendable {
        case resolveBinary, resolveRevision, download, extract, index, startUI, openBrowser
    }
    let id: ID
    var status: Status
    var detail: String?
    var durationMs: Int?
}
```

### 5.7 缓存命中判定

```swift
func isCacheHit(existing: CodebaseMemoryStoredProject?, commitSHA: String) -> Bool {
    guard let existing else { return false }
    return existing.metadata.sourceRevision.commitSHA == commitSHA
}
```

命中 → 跳过 ① resolveRevision / ② download / ③ extract / ④ index / ⑤ startUI,直接打开浏览器。

---

## 6. CodebaseMemoryBinaryResolver — 二进制解析

```swift
actor CodebaseMemoryBinaryResolver {
    private let storage: CodebaseMemoryStorage
    private let fileManager: FileManager

    // MARK: - Bundle 内资源路径
    var bundleCodebaseURL: URL? {
        Bundle.main.url(forResource: "codebase", withExtension: nil, subdirectory: "Codebase")
    }

    // MARK: - Container 内副本路径
    func containerCodebaseURL() throws -> URL {
        try storage.outputRootURL()
            .appendingPathComponent(".bin/codebase", isDirectory: false)
    }

    // MARK: - 首次启动时 lazy 拷贝 + chmod
    func resolveExecutable() throws -> URL {
        let containerURL = try containerCodebaseURL()

        // 已存在且可执行 → 直接返回
        if fileManager.isExecutableFile(atPath: containerURL.path) {
            return containerURL
        }

        // 不存在 → 从 bundle 拷贝
        guard let bundleURL = bundleCodebaseURL else {
            throw CodebaseMemoryError.binaryMissing
        }
        try fileManager.createDirectory(
            at: containerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: containerURL.path) {
            try fileManager.removeItem(at: containerURL)
        }
        try fileManager.copyItem(at: bundleURL, to: containerURL)

        // 显式 chmod（bundle 内的资源被 Xcode strip 了 x 权限）
        let attrs = try fileManager.attributesOfItem(atPath: bundleURL.path)
        try fileManager.setAttributes(
            [.posixPermissions: attrs[.posixPermissions] ?? 0o755],
            ofItemAtPath: containerURL.path
        )

        /* 最终兜底：直接硬设 0755 */
        var perms = attrs[.posixPermissions] as? Int ?? 0
        if perms & 0o111 == 0 {
            perms = 0o755
            try fileManager.setAttributes(
                [.posixPermissions: perms],
                ofItemAtPath: containerURL.path
            )
        }

        return containerURL
    }
}
```

---

## 7. CodebaseMemoryExtractor — 持久解压

### 7.1 与 SourceZipExtractor 的差异

| 维度 | SourceZipExtractor | CodebaseMemoryExtractor |
|---|---|---|
| 目标目录 | `temporaryDirectory/.../UUID/`(临时) | `<codebasememory-root>/<owner>/<repo>/source/`(持久) |
| cleanup 闭包 | ✅ 返回 `ExtractedSourceDirectory` 带 `cleanup` 闭包 | ❌ 不返回 cleanup（持久化） |
| 幂等判断 | 无（每次创建新 tmp） | **有**（写 `.zip.sha256` 文件,比较后跳过解压） |
| 安全参数 | `zipMaxBytes(100MB)` / `allowUncontainedSymlinks(true)` | **同款** |

### 7.2 接口

```swift
struct CodebaseMemoryExtractor {
    struct ExtractedSource: Sendable {
        let sourceURL: URL
        let wasCached: Bool
    }

    /// 持久解压 ZIP 到 `<outputRoot>/<owner>/<repo>/source/`
    /// - 幂等：source/.zip.sha256 == sha256(zip) → 跳过,返回 wasCached = true
    func extractIfNeeded(
        zipURL: URL,
        outputDirectory: URL,  // = <codebasememory-root>/<owner>/<repo>/
        fileManager: FileManager = .default
    ) async throws -> ExtractedSource {
        // 1. 大小预检（100MB zip 上限,同 SharedSnapshotService）
        let zipSize = try fileManager.attributesOfItem(atPath: zipURL.path)[.size] as? Int ?? 0
        guard zipSize > 0 else { throw CodebaseMemoryError.emptyArchive }
        guard zipSize <= SharedSnapshotService.maximumArchiveBytes else {
            throw CodebaseMemoryError.archiveTooLarge(actualBytes: zipSize)
        }

        // 2. 计算 zip SHA-256 并写入 .sha256
        let shaFileURL = outputDirectory.appendingPathComponent(".zip.sha256")
        let zipSHA = try sha256(of: zipURL)
        if fileManager.fileExists(atPath: shaFileURL.path),
           let stored = try? String(contentsOf: shaFileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           stored == zipSHA {
            let sourceDir = outputDirectory.appendingPathComponent("source", isDirectory: true)
            if fileManager.fileExists(atPath: sourceDir.path) {
                return ExtractedSource(sourceURL: sourceDir, wasCached: true)
            }
        }

        // 3. 删除旧 source 目录 + 创建新目录
        let sourceDir = outputDirectory.appendingPathComponent("source", isDirectory: true)
        try? fileManager.removeItem(at: sourceDir)
        try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        // 4. ZIPFoundation 解压(复用 allowUncontainedSymlinks 决策)
        try await Task.detached(priority: .userInitiated) {
            try fileManager.unzipItem(
                at: zipURL,
                to: sourceDir,
                allowUncontainedSymlinks: true   // 同 SourceZipExtractor §3 的踩坑注释
            )
        }.value

        // 5. ZIP bomb 兜底(500MB extracted limit,inherited)
        let extractedBytes = Self.directorySize(of: sourceDir)
        guard extractedBytes <= 524_288_000 else {
            try? fileManager.removeItem(at: sourceDir)
            throw CodebaseMemoryError.extractedTooLarge(actualBytes: extractedBytes)
        }

        // 6. 写 .zip.sha256(快)
        try zipSHA.write(to: shaFileURL, atomically: true, encoding: .utf8)

        return ExtractedSource(sourceURL: sourceDir, wasCached: false)
    }

    /// SHA-256 over file（分块读,不进整包内存）
    private func sha256(of url: URL) throws -> String { ... }

    /// 递归目录大小（同 SourceZipExtractor.directorySize）
    static func directorySize(of url: URL) -> Int { ... }
}
```

---

## 8. CodebaseMemoryRunner — Process 管理

### 8.1 核心设计

```swift
@MainActor
final class CodebaseMemoryRunner {
    /// 所有活跃的 UI 子进程,proc → (repoFullName, startedAt)
    private var activeProcesses: [Process: (String, Date)] = [:]

    /// 入口 1: index_repository
    /// - binary: container 内可执行文件路径
    /// - repoPath: 持久解压后的 <outputDir>/source/<commit-SHA>/
    func runIndex(
        binaryURL: URL,
        repoPath: URL,
        cacheDir: URL
    ) async throws -> IndexResult {
        // Process.stdout → pipe → JSON parse → IndexResult
    }

    /// 入口 2: 启动 UI long-lived 进程
    /// - 返回 (Process, port) —— cailler 负责 openBrowser + 管理进程
    func startUI(
        binaryURL: URL,
        port: Int,
        cacheDir: URL
    ) throws -> Process {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["--ui=true", "--port=\(port)"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CBM_CACHE_DIR": cacheDir.path
        ]) { _, new in new }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.removeProcess(process) }
        }
        try process.run()
        activeProcesses[process] = (repoIdentifier, Date())
        return process
    }

    /// 入口 3: 通用 CLI 查询(P1,预留)
    func runQuery(
        binaryURL: URL,
        tool: String,              // "search_graph" / "trace_path" / "query_graph" / ...
        jsonArgs: String,          // '{"name_pattern": "...", "label": "Function"}'
        cacheDir: URL
    ) async throws -> Data {      // stdout raw JSON
        // codebase-memory-mcp cli <tool> '<jsonArgs>'
    }

    /// 停止指定 UI 进程
    func stopUI(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
        removeProcess(process)
    }

    /// App 退出前调用
    func stopAll() {
        for (process, _) in activeProcesses where process.isRunning {
            process.terminate()
        }
        activeProcesses.removeAll()
    }
}
```

### 8.2 关键约束

- `runIndex` **不要在主 actor 上 await stdout**：超大 repo 索引可能耗时:先 `Task.detached { ... }` 拿 `Data`,再回到 MainActor 解析 JSON
- `startUI` 返回的 Process **不自动 terminate**：由 ViewModel 持有,用户关闭 Sheet 时视状态决定杀不杀
- `terminationHandler` **弱引用 self**：避免 Process → closure → Runner 引用循环
- `CBM_CACHE_DIR` 直接传 container 内路径：`.` 开头不会被 Finder 显示,用户清理时统一走 `deleteAllProjects()`

### 8.3 IndexResult 模型

```swift
struct IndexResult: Sendable {
    let repoPath: String
    let nodeCount: Int
    let edgeCount: Int
    let durationMs: Int
    let errors: [String]   // stderr lines
}
```

从 `cli index_repository` 的 stdout JSON 解析：`{ "repo_path": "...", "node_count": N, "edge_count": M, "duration_ms": D }`。

---

## 9. CodebaseMemoryViewModel — 状态机

### 9.1 状态 enum

```swift
@MainActor
@Observable
final class CodebaseMemoryViewModel {
    enum State: Equatable {
        case idle
        case preparing                          // 解析二进制 + 分支
        case downloading                        // 拉 zipball
        case extracting                         // 持久解压
        case indexing                           // cli index_repository
        case startingUI                         // 启动 UI 子进程
        case ready(port: Int, pageURL: URL)     // 浏览器打开,等用户交互
        case succeeded                          // 浏览器已打开
        case failed(message: String)            // 任何步骤失败
    }

    enum VersionStatus: Equatable {
        case unknown, checking
        case current                            // 已生成最新
        case updateAvailable(generated: String, latest: String)  // commit 更新了
        case branchChanged(generated: String, selected: String)  // 分支变了
        case unavailable(String)                // 分支加载失败
    }
}
```

### 9.2 步骤模型

```swift
struct CodebaseMemoryStep: Identifiable {
    enum ID: String, CaseIterable {
        case resolveBinary, resolveRevision, download, extract, index, startUI, openBrowser
    }
    enum Status { case pending, running, succeeded, failed, skipped, handedOff }
    let id: ID
    var status: Status
    var detail: String?
    var durationMs: Int?
}
```

### 9.3 核心流程

```swift
func start() {
    task?.cancel()
    task = Task {
        let startedAt = Date()
        do {
            // Step 0: 解析二进制
            let binaryURL = try await binaryResolver.resolveExecutable()

            // Step 1: 解析分支 + commit SHA
            let branch = try await runner.resolveBranch(repo: repo, name: selectedBranch)

            // Step 2: 缓存命中判断
            if let existing = try? storage.existingProject(owner: repo.owner, name: repo.name),
               existing.metadata.sourceRevision.commitSHA == branch.commitSHA {
                // → 全部跳过,直接到 openBrowser
                let port = existing.metadata.lastUIPort ?? portPicker.pick()
                // 如果旧 UI 进程还在,直接打开
                // 否则启动新的
                return
            }

            // Step 3: 拉 zipball(共享缓存,秒过)
            let archive = try await snapshotService.archiveIfNeeded(repo: repo, commitSHA: branch.commitSHA)

            // Step 4: 持久解压
            let outDir = try storage.projectDirectory(root: root, owner: repo.owner, name: repo.name)
            let source = try await extractor.extractIfNeeded(zipURL: archive.url, outputDirectory: outDir)

            // Step 5: 索引
            let cacheDir = root.appendingPathComponent(".internal-cache")
            let result = try await runner.runIndex(binaryURL: binaryURL, repoPath: source.sourceURL, cacheDir: cacheDir)

            // Step 6: 启动 UI
            let port = portPicker.pick(previousPort: storedProject?.metadata.lastUIPort)
            let process = try runner.startUI(binaryURL: binaryURL, port: port, cacheDir: cacheDir)

            // Step 7: 保存 metadata
            let metadata = makeMetadata(branch: branch, result: result, port: port)
            try storage.write(metadata: metadata, sourceRevision: ..., owner: repo.owner, name: repo.name)

            // Step 8: 打开浏览器
            let pageURL = URL(string: "http://127.0.0.1:\(port)/")!
            NSWorkspace.shared.open(pageURL)

            state = .succeeded
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }
}
```

### 9.4 Pro gating

```swift
private func requireCodebaseMemoryAccess() -> Bool {
    guard entitlementGate.isProUser else {
        paywallContext = .codebaseMemory
        return false
    }
    return true
}
```

`EntitlementGate` 新增 `case codebaseMemory`,UI 列在 Pro 订阅权益中和 CodeFlow 并列。

---

## 10. CodebaseMemoryPanel — Sheet UI

### 10.1 布局（对齐 CodeFlowPanel）

```
┌─ CodebaseMemory 3D Graph ────────────────── ✕ ─┐
│ 📍 point.3.connected.trianglepath.dotted       │
│    3D 代码图谱视图                                │
│    Detail for {owner}/{repo}                    │
│──────────────────────────────────────────────────│
│ Branch: [main ▾]                                │
│ {'versionBanner': commit SHA 已更新 / 当前已是最新} │
│                                                  │
│ ┌─ Overview ─────────────────────────────────┐  │
│ │ 1. Resolve Revision    ✓ main · d187883   │  │
│ │    ─────────────────────────────────────  │  │
│ │ 2. Download Archive    ✓ 2.3 MB (cached)  │  │
│ │    ─────────────────────────────────────  │  │
│ │ 3. Extract Source      ✓ 247 files        │  │
│ │    ─────────────────────────────────────  │  │
│ │ 4. Index Repository    ✓ 1,234 nodes      │  │
│ │    ─────────────────────────────────────  │  │
│ │ 5. Start UI Server     ✓ localhost:42531  │  │
│ │    ─────────────────────────────────────  │  │
│ │ 6. Open in Browser     → handed to browser│  │
│ └────────────────────────────────────────────┘  │
│                                                  │
│ {"failed": "Zip extraction failed: ..." 红色 banner}│
│                                                  │
│ ▸ Execution Details                              │
│                                                  │
│ Generation 3 · last 12s ago       [Cancel] [Re-generate]│
└──────────────────────────────────────────────────┘
```

### 10.2 组件组成

```swift
struct CodebaseMemoryPanel: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: CodebaseMemoryViewModel
    @State private var showsDetails: Bool
    @State private var paywallContext: ProPaywallContext?

    var body: some View {
        VStack(spacing: 0) {
            header        // SheetCloseButton + 标题
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    branchSection     // Branch picker (默认为 defaultBranch,允许换分支重新生成)
                    versionBanner     // 当前 / 已有更新 / 分支变更 / unavailable
                    overviewCard      // 7 步 overview rows
                    failureBanner     // state == .failed(message:) → 红色 banner
                    executionDetails  // DisclosureGroup 折叠
                }
                .padding(14)
            }
            Divider()
            footer           // status text + Cancel + Re-generate + Start
        }
        .frame(width: 520)  // 与 CodeFlowPanel 同宽
        .task { requireCodebaseMemoryAccess(); await viewModel.prepare() }
        .sheet(item: $paywallContext) { ProPaywallSheet.hosted(context: $0) }
        .onDisappear { viewModel.cancel() }
    }
}
```

---

## 11. 现有文件改动

### 11.1 ExternalLinksMenu.swift

```swift
// 原 FeaturedExternalLinksControl 加:
let codebaseMemoryRepo: Repo?
let onOpenCodebaseMemory: (Repo) -> Void

// Menu 的 CodeFlow 同组：
Button {
    onOpenCodeFlow()
} label: {
    Label("CodeFlow", systemImage: "point.3.connected.trianglepath.dotted")
}
Button {
    if let codebaseMemoryRepo { onOpenCodebaseMemory(codebaseMemoryRepo) }
} label: {
    Label("CodebaseMemory", systemImage: "point.3.filled.connected.trianglepath.dotted")
}
Divider()
```

### 11.2 RepoListView.swift

```swift
// 新增 sheet item 绑定
@State private var codebaseMemoryItem: CodebaseMemorySheetItem?

// .sheet(item: $codebaseMemoryItem) { item in CodebaseMemoryPanel(repo: item.repo) }

// ExternalLinksMenu 传 callback
ExternalLinksMenu(
    ...,
    onOpenCodebaseMemory: { repo in codebaseMemoryItem = CodebaseMemorySheetItem(repo: repo) }
)
```

### 11.3 IntegrationSettingsView.swift

对齐 CodeFlow 现有段,新增 block：

```swift
// ☰ CodebaseMemory
// 二进制版本: v0.8.1 · SHA-256: a1b2c3d4e5f6
// 3D 代码图谱
// <路径显示> [选择...] [📂] [↺]
// 项目数 | 占用 | 累计生成 | 最近
```

`stat` helper 复用现有 `IntegrationSettingsTab.stat()`。`chooseOutputDirectory()` / `revealOutputDirectory()` / `resetOutputDirectory()` delegate 到 `CodebaseMemoryStorage.shared`。

### 11.4 SettingsView.swift (Storage Tab)

```swift
// usageRow 同款:
usageRow(
    titleKey: "settings.storage.codebaseMemory",
    usageText: codebaseMemoryUsageText,
    isEmpty: codebaseMemoryStorage.projectCount == 0,
    action: .codebaseMemory
)
```

`PendingAction.codebaseMemory` case + `perform(action:)` 匹配 → `codebaseMemoryStorage.deleteAllProjects()`。

### 11.5 AppDependencies.swift

```swift
// CodebaseMemory
let codebaseMemoryStorage = CodebaseMemoryStorage.shared
```

### 11.6 EntitlementGate.swift

```swift
enum ProFeature {
    // ... existing
    case codebaseMemory
}
```

---

## 12. 进程生命周期总控

### 12.1 创建 → 运行 → 终止

```
CodebaseMemoryPanel 打开
  └─ ViewModel.start()
       └─ Runner.startUI()  → 创建 Process,加入 activeProcesses
            └─ 用户关闭 Sheet  → ViewModel.cancel()
                 └─ **不杀 Process**（用户继续在浏览器交互）
                      └─ 用户点 Re-generate
                           └─ Runner.stopUI(old) + startUI(new)
                                └─ StarcatApp.willTerminate
                                     └─ Runner.stopAll()
```

### 12.2 为什么关闭 Sheet 不杀 Process

用户原话：**"关闭 sheet 时浏览器还开着,我能继续交互,不打断探索"**。

- UI 页面是本机 loopback `http://127.0.0.1:<port>/`,没有 session / token / origin 问题
- 关闭 Sheet 只是 SwiftUI dismiss 浮层,不影响后台 binary 继续 serving
- 退出 App 时统一 kill（`StarcatApp.willTerminate` 兜底）

### 12.3 StarcatApp willTerminate 挂钩

```swift
// StarcatApp.swift
import Cocoa

final class AppTerminationHandler {
    static func install() {
        NSApplication.shared.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            // 仅 UI 进程需要杀,index 进程寿命很短(await 完就结束了)
            CodebaseMemoryRunner.shared.stopAll()
        }
    }
}
```

---

## 13. 测试策略

### 13.1 单元测试矩阵

| 被测模块 | 测试文件 | 关键场景 |
|---|---|---|
| PortAvailability | `CodebaseMemoryRunnerTests` | port 可用返回 nil;port 被占返回描述;out of range 返回描述;SO_REUSEADDR 不会误报 TIME_WAIT |
| Storage(CRUD) | `CodebaseMemoryStorageTests` | 插入 → existingProject 返回;deleteProject → 不再存在;deleteAll → 0;summary 同步 |
| Extractor | `CodebaseMemoryRunnerTests` | 幂等(write .sha256 → 二次调用返回 wasCached=true);zipbomb(>500MB → throw);allowUncontainedSymlinks 不可失败 |
| BinaryResolver | `CodebaseMemoryBinaryResolverTests` | bundle 有文件 → 拷贝 + chmod;bundle 无文件 → binaryMissing;已存在 → 不重新拷贝 |
| Runner | `CodebaseMemoryRunnerTests` | runIndex 成功 → 正确 node/edge count;startUI → process.isRunning=true;stopAll → 全部 terminate;terminationHandler 回调 |
| ViewModel | `CodebaseMemoryViewModelTests` | 空 repo → resolveBranch 失败;hit cache → .ready state;miss cache → .indexing→.succeeded;Pro check 失败 → paywallContext |
| EntitlementGate | `EntitlementGateTests` | codebaseMemory case 正确映射到 Pro tier |

### 13.2 测试复用的 fixture

- `MockCodebaseMemoryBinary`:写一个 dummy shell 脚本代替 binary
- `MockCodeFlowDownloader`(已存在)
- `TemporaryDirectory` helper(已存在)

### 13.3 测试环境

```bash
xcodegen generate                    # 新增 swift 文件后必跑
xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' \
  -only-testing:StarcatTests/CodebaseMemoryRunnerTests test
```

---

## 14. i18n 新增 key 清单

| Key | 用途 |
|---|---|
| `codebaseMemory.panel.title` | Sheet 标题 |
| `codebaseMemory.panel.start` | 主按钮文案 |
| `codebaseMemory.panel.regenerate` | 重新生成 |
| `codebaseMemory.panel.cancel` | 取消 |
| `codebaseMemory.runtime.resolveRevision` | 步骤 1 运行中 |
| `codebaseMemory.runtime.downloadingZip` | 步骤 2 运行中 |
| `codebaseMemory.runtime.cachedArchivedFormat` | 命中缓存格式 |
| `codebaseMemory.runtime.downloadedArchivedFormat` | 下载完成格式 |
| `codebaseMemory.runtime.extracting` | 步骤 3 运行中 |
| `codebaseMemory.runtime.indexing` | 步骤 4 运行中 |
| `codebaseMemory.runtime.startingUI` | 步骤 5 运行中 |
| `codebaseMemory.runtime.openBrowser` | 步骤 6 运行时 / 已移交 |
| `codebaseMemory.error.binaryMissing` | 二进制缺失 |
| `codebaseMemory.error.indexFailed` | 索引失败 |
| `codebaseMemory.error.uiStartFailed` | UI 启动失败 |
| `codebaseMemory.error.emptyArchive` | 空 zip |
| `codebaseMemory.error.archiveTooLarge` | zip 过大 |
| `codebaseMemory.error.extractedTooLarge` | 解压内容过大 |
| `codebaseMemory.error.browserOpenFailed` | 浏览器未配置 |
| `codebaseMemory.error.checkFailed` | 端口探测失败 |
| `settings.integration.codebaseMemory.title` | 设置段标题 |
| `settings.integration.codebaseMemory.help` | 设置段说明 |
| `settings.integration.codebaseMemory.version` | 二进制版本行 |
| `settings.integration.codebaseMemory.port` | UI 端口行 |
| `settings.integration.codebaseMemory.openPanel.title` | 选择目录 |
| `settings.integration.codebaseMemory.openPanel.prompt` | "选择"按钮 |
| `settings.integration.codebaseMemory.actionFailedTitle` | 错误标题 |
| `settings.storage.codebaseMemory` | Storage Tab 行标题 |
| `settings.storage.clearCodebaseMemory.confirm` | 确认标题 |
| `settings.storage.clearCodebaseMemory.message` | 确认消息 |

---

## 15. 实施顺序（按依赖关系）

```
Phase A: 基础设施（无 UI）
  A1: scripts/fetch-codebase-binary.sh → dong4j 手动跑一次
  A2: Starcat/Resources/Codebase/ 三文件就位
  A3: CodebaseMemoryError.swift
  A4: CodebaseMemoryPortAvailability.swift
  A5: CodebaseMemoryStorage.swift(with tests)
  A6: CodebaseMemoryBinaryResolver.swift(with tests)

Phase B: 核心管线（无 UI）
  B1: CodebaseMemoryExtractor.swift
  B2: CodebaseMemoryRunner.swift(with tests)

Phase C: UI + 入口
  C1: CodebaseMemoryViewModel.swift + CodebaseMemoryPanel.swift
  C2: EntitlementGate.codebaseMemory
  C3: ExternalLinksMenu / RepoListView 加入口

Phase D: 设置 + 清理
  D1: IntegrationSettingsView 加段
  D2: SettingsView Storage Tab 加行
  D3: AppDependencies 装配

Phase E: 验证
  E1: xcodegen generate + xcodebuild build
  E2: xcodebuild test (全部)
  E3: Localizable.xcstrings python3 -m json.tool 验证
  E4: i18n 禁用 API 扫描
```

---

## 16. 文档变更记录

| 日期 | 更新 |
|---|---|
| 2026-06-29 | 新建：CodebaseMemory 集成需求讨论 + 正式方案 + 本详细设计 |

---

*最后更新：2026-06-29*
