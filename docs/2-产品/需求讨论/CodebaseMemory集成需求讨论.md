# CodebaseMemory 集成需求讨论

> 创建：2026-06-29
> 状态：讨论稿 → 待 dong4j 拍板后转正式方案
> 关联上游：[https://deusdata.github.io/codebase-memory-mcp/](https://deusdata.github.io/codebase-memory-mcp/)（MIT,DeusData 出品）

---

## 1. 我想做什么

把 [codebase-memory-mcp](https://deusdata.github.io/codebase-memory-mcp/) 的二进制打包进 Starcat,让用户在 Starcat 内部就能对一个已 star 的仓库做 **3D 图谱可视化 + 深度代码查询**(函数调用路径 / Cypher 图查询 / 架构摘要 / 代码片段定位),而不必切到外部工具或自己手动跑 CLI。

为什么现在做:

- **数据基础已经齐**:Starcat 现有的 RepoContext / CodeFlow 已经在下载并解压 GitHub zipball,产物可以在磁盘上"被另一个程序读"。这两个前提现在都成立。
- **CodeFlow 自建 HTML** 只解决了"快速看仓库结构",**深度查询**(跨文件调用链、符号级搜索、Cypher 图查询)需要更重的索引能力。codebase-memory-mcp 用 tree-sitter + Hybrid LSP 直接做这件事,**单文件 C 静态二进制**,零运行时依赖。
- **目标用户对得上**:技术博主 / 媒体需要"看完 README → 立刻深入源码 → 立刻能引用"的链路。

---

## 2. 核心需求

### 2.1 必须有(必做)

1. **从 Starcat 仓库详情页一键进入**:沿用 CodeFlow 的入口形态(toggle 菜单的同组里加一项,Sheet 弹出)。
2. **复用现成的 zipball 缓存**:不重复下载。`SharedSnapshotService.archiveIfNeeded(...)` 已经管这件事,CodebaseMemory 直接消费。
3. **3D 图谱可视化 UI**:用户索引完必须能在浏览器里看到图,否则"索引"毫无意义(用户原话:"那索引后拿来干嘛")。
4. **可视化在系统浏览器打开**:与 CodeFlow HTML 页面同款形态(`NSWorkspace.shared.open(url)`),不开内置 WebView(避免 WKWebView 同源隔离 / 内存占用问题)。
5. **索引产物持久化**:同一 repo / 同一 commit SHA 二次进入秒开(不重新索引)。需要持久解压 + 持久图谱产物。
6. **二进制不上网下载**:沙盒 + App Store 审核都不允许 App 内下载可执行文件。必须**手工下载 → 打包进 bundle → App 启动时 lazy 拷贝到 sandbox container + chmod**。
7. **Pro 门控**:与 CodeFlow 同款(`EntitlementGate.ProFeature.codebaseMemory`),免费版不开放。

### 2.2 应该做(强烈建议)

8. **下载脚本可复用**:`scripts/fetch-codebase-binary.sh`,跑一次自动从 GitHub releases 拉最新 → SHA-256 校验 → 解压 → 重命名 → chmod。后续更新二进制只改脚本顶部 VERSION / 不指定版本直接拉 latest。
9. **写一份资源自带 `UPSTREAM-README.md`**:写清上游 commit / 校验和 / cosign 验证步骤 / 重命名理由,App Store 审核问"为什么打包二进制"时有据可查。
10. **设置页 + 缓存清理两处入口**:
    - IntegrationSettingsTab 新增段(对齐 CodeFlow 段,显示输出目录 + 4 列统计 + 二进制版本号)
    - StorageSettingsTab 新增清理行(对齐 aiContext / codeFlow 现有模式)
11. **端口必须不和用户本机冲突**:用户在终端可能已经装了 `codebase-memory-mcp`(默认占 9749)。我们启动 UI 时**传随机端口** + **复用 MCP Service 已有的 POSIX bind 探测**(避免依赖 `nc`,沙盒里也没这个命令)。

### 2.3 可选(看时间)

12. **CLI 子命令查询界面**:进 Starcat 的命令面板,用 binary 的 `cli search_graph` / `trace_path` 等查询命令,在 SwiftUI 里自渲染结果。**优先级低于 UI 入口**。
13. **AI Chat 注入 graph 摘要**:把 `cli get_architecture` 的结果喂给 AI Chat system prompt。**P1 之后再考虑**。

### 2.4 不做

- ❌ **不内置二进制**改走 `~/.cache/...` 默认路径(sandbox 写不进去,必须重定向)
- ❌ **不暴露 UI 端口给用户改**(dong4j 明确拍板,避免心智负担)
- ❌ **不做 Safari 扩展 / Chrome 插件**(上游也没有,价值不大)
- ❌ **不做远端 server 化部署**(纯本机)
- ❌ **不做实时索引**(`cli index_repository` 已经够用,不需要 FS watcher)

---

## 3. App Store 沙盒与审核约束（dong4j 补充）

将 codebase-memory-mcp 这类第三方 C 二进制内置到准备上架 macOS App Store 的应用中，必须对苹果的 **App Sandbox** 和 **审核规范** 做前置应对。

### 3.1 签名与 Entitlements（最关键）

App Store 上的应用必须启用 App Sandbox。不能直接把下载的二进制塞进 Bundle 丢上去，必须做独立签名：

- **独立签名**：在打包主应用时，必须用 `Apple Distribution` 证书对 codebase-memory-mcp 二进制做**单独的 codesign**。
- **继承沙盒权限**：二进制需要声明 `com.apple.security.inherit` entitlement，以便继承主应用的沙盒上下文。
- **网络权限**：尽管项目声称所有操作本地化，但它包含一个 3D 可视化本地 HTTP 服务器。在沙盒下绑定本地端口（`localhost:<port>`），主应用和该二进制都需要 `com.apple.security.network.server` + `com.apple.security.network.client` 权限。

### 3.2 沙盒下的文件访问受限（最容易导致功能失效）

codebase-memory-mcp 的核心功能是扫描用户的代码库：

- **无法自动扫描**：沙盒内应用默认无法读取用户磁盘上的任意目录（如 `~/Projects`）。
- **解决方案**：Starcat 通过 `NSOpenPanel` 显式引导用户选择输出目录。主应用获得该目录的 bookmark 持久化访问权限。
- **传递权限**：启动 codebase-memory-mcp 子进程时，将该目录作为工作目录或参数传递。同时，默认写入路径 `~/.cache` 在沙盒外**不可写**，必须通过 `CBM_CACHE_DIR` 环境变量将缓存重定向到沙盒 container 内（如 `Library/Caches/`），否则子进程会因无写入权限而崩溃。

### 3.3 禁用增量更新

该工具内置 `codebase-memory-mcp update` 命令来从 GitHub 下载并覆盖更新二进制：

- **App Store 禁忌**：苹果严厉禁止 App Store 应用在运行时从外部下载并执行可执行代码。
- **解决方案**：Starcat **完全屏蔽** `update` 命令，**不调用、不暴露、不过桥**。所有版本升级跟随 Starcat 主应用通过 App Store 正常应用更新完成。

### 3.4 开源协议合规（MIT）

codebase-memory-mcp 采用 **MIT 开源协议**：

- 在 Starcat 的 About 页面、致谢（Acknowledgements）中包含该项目的版权声明和 MIT 许可文本。

### 3.5 App Store 审核时的解释说明（Review Notes）

因为应用会在后台拉起第三方二进制子进程 + 打开本地端口，在机审或人工审核时可能触发警告。提交审核时**必须在 Review Notes 中主动说明**：

> "应用内包含一个纯本地运行的、用于构建代码结构知识图谱的静态 C 二进制组件。该组件 100% 在本地沙盒内运行，不依赖任何外部 LLM，不向外传输任何代码数据。"

这能极大减少被误判为违反 5.1.1 隐私或 2.5.2 软件完整性的概率。

---

## 4. 现有功能边界对照

| 现有 | CodebaseMemory 接入后 |
|---|---|
| `SharedSnapshotService.archiveIfNeeded()` 下载 zipball | **复用**,不动 |
| CodeFlow 把 zip 整包 base64 嵌入 HTML | **复用 zipball**,但解压方式不同(持久解压) |
| RepoContext 把 zip 解到 tmp 走 XML pipeline | **复用安全参数**(zipMaxBytes / allowUncontainedSymlinks),但目标目录持久化 |
| ExternalLinksMenu 同组的 CodeFlow 入口 | **新增同组项**,不替换 |
| IntegrationSettingsTab 的 CodeFlow 段 | **新增段**,不替换 |
| StorageSettingsTab 的 `codeFlow` 行 | **新增行**,不替换 |

---

## 5. 用户故事

| # | 作为 | 我想 | 以便 |
|---|---|---|---|
| U1 | Pro 用户 | 在仓库详情页点 CodebaseMemory 按钮 | 进入可视化面板 |
| U2 | Pro 用户 | 点"开始"后看到 6 步进度(解析 SHA / 拉 zip / 解压 / 索引 / 启 UI / 开浏览器) | 知道卡在哪一步 |
| U3 | Pro 用户 | 二次进入同一 repo 看到"秒开"(跳过 4 个步骤,直接打开浏览器) | 不重复等待 |
| U4 | Pro 用户 | 在 IntegrationSettingsTab 看到输出目录大小 / 项目数 | 知道占多少磁盘 |
| U5 | Pro 用户 | 想清理时在 StorageSettingsTab 看到 CodebaseMemory 行 + 清理按钮 | 一键清理 |
| U6 | Free 用户 | 在仓库详情页看不到 CodebaseMemory 入口,或看到 Pro 引导 | 知道升级路径 |
| U7 | 用户 | 系统浏览器弹出 3D 图谱页面 | 看到节点关系图 |
| U8 | 用户 | 关闭 sheet 时浏览器还开着,我能继续交互 | 不打断探索 |

---

## 6. 验收标准

- [ ] 打开任意已 star 仓库详情页 → ExternalLinksMenu 出现 "CodebaseMemory 3D Graph" 按钮
- [ ] 点按钮 → Sheet 弹出 → 6 步进度跑完 → 系统浏览器自动打开 3D 图谱页面
- [ ] 二次点同 repo 同一 SHA → 4 个步骤跳过,直接打开浏览器
- [ ] 关闭 sheet → 不杀 UI 子进程(允许用户在浏览器里继续交互)
- [ ] 退出 Starcat App → UI 子进程被兜底 kill(不留 zombie)
- [ ] IntegrationSettingsTab 显示当前二进制版本(v0.8.1)+ SHA-256 前 12 位
- [ ] StorageSettingsTab "清理"按钮能删干净所有 `<codebasememory-root>/<owner>/<repo>/`
- [ ] Free 用户点入口看到 Pro 引导 sheet,Sheet 关闭后回到正常 UI
- [ ] 用户本机装了 codebase-memory-mcp(占 9749)→ Starcat 启动 UI 时随机选 4xxxx 端口,不冲突
- [ ] 单测全绿,`xcodebuild build` 通过,`Starcat/Resources/Localizable.xcstrings` 合法

---

## 7. 后续动作

1. dong4j 拍板后 → 转 [`docs/2-产品/需求讨论/正式方案/CodebaseMemory集成正式方案.md`](正式方案/CodebaseMemory集成正式方案.md)
2. 实施前再写 [`docs/3-设计/详细设计/36-CodebaseMemory集成设计.md`](../3-设计/详细设计/36-CodebaseMemory集成设计.md)
3. 在 [`docs/功能实现总览.md`](../功能实现总览.md) §3 加 `- [ ]` 条目 + 完成后打勾 + `> 实现:` 行
4. `scripts/fetch-codebase-binary.sh` 由 dong4j 手动跑一次,产物进 `Starcat/Resources/Codebase/`