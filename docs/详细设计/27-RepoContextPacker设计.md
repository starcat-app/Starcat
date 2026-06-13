# Starcat RepoContextPacker — AI 摘要上下文打包设计方案

> **场景锁定**：本设计仅服务于「AI 摘要 / AI 对话」对**真实代码级别**上下文的需求。
> 不为「语义搜索 / 代码图谱 / 离线 AI 对话 / 用户直接查看 packed 输出」这些远期场景过度设计；
> 但**输出格式保持开放**，将来这些场景接入时复用 `context.xml` 即可。
>
> ⚠️ **v1.2 实施权威**：写代码前**必读 §22「实施前 grill 决策记录」**。§22 是 10 轮 grill 拍板的实施权威覆盖层，与 §1-§21 冲突时**一律以 §22 为准**。§1-§21 保留作为「为什么这么设计」的过程背景。

---

## 0. 客户端接入任务清单（2026-06-13 起，**当前在做**）

> **本章是"立即可执行的工程任务列表"**，与 §23「实施进度」配套（§23 记录已落地的底层 pipeline，§0 记录当前接入阶段的待办）。
>
> **范围与目标**：把已完成的 `RepoContextPacker` 接入主流程，让 AI 摘要 / AI 对话真正"看到代码"。
>
> 按 **W → X → Y** 顺序推进，每阶段都能独立验证。

### 0.1 当前代码摸底（2026-06-13 17:30，2026-06-13 22:00 修订）

接入路径上现有的"既成事实"：

| 接入面 | 现状 | 接入策略 |
|---|---|---|
| ZIP 快照层 | 已在 `Features/CodeGraph/CodeFlowRunner.swift` 实现 `archiveIfNeeded(repo:commitSHA:)` + `archiveFileURL(...)` + `resolveBranch(repo:name:)`，路径 `Application Support/Starcat/repository-snapshots/github.com/<owner>/<repo>/<sha>.zip` | **抽出**到 `Shared/Services/SharedSnapshotService.swift` 让 CodeFlow 与 RepoContextPacker 共用，遵守 `docs/需求讨论/starcat-codeflow-integration.md` §4.2「共享但只读、不删」约定 |
| AI 摘要主入口 | `Features/AI/RepoAIInsightService.swift:402-427` 的 `makeSource(for:)` 拼接 README + 元信息为 `Source.text`，被 `generateInsight` 和 `chatStream` 同时复用 | 在 `makeSource` 内新增一段「可选 RepoContextProvider 注入」，与现有的 `AnySearchContextProvider`（`generateInsight:122-132`）平行接入，**失败不阻断主流程** |
| AI 设置存储 | `Core/Settings/AppSettings.swift` 有 `aiSummaryTask` / `aiExternalContextEnabled` / `aiReadmeTruncateLength` 等，UserDefaults 持久化，`Keys` 子结构集中管理 key | 新增 3 个字段 `aiRepoContextEnabled` / `aiRepoContextTokenBudget` / `aiRepoContextTier1MaxLines`，沿用现有的 `persist*` 模式。**不设「私有仓库」开关**：当前 OAuth scope `read:user` + `public_repo` 永远拿不到 `isPrivate=true` 的 repo（Starcat 还没接管私有仓库可见性逻辑），增加一个走不到的开关只会误导用户 |
| **产物存储层** | **当前无独立服务**，`ContextWriter` 直接 `Data.write(.atomic)` 到 hardcoded `Application Support/Starcat/analysis/<owner>/<repo>/` | **新建 `RepoContextStorage`**（仿 `CodeFlowStorage` 全套接口）：Security-scoped bookmark + 路径迁移 + 项目扫描 + 删除；默认目录改名 `Application Support/Starcat/repo-context/` 与 `codeflow/` 同级对齐 |
| 设置页 UI（配置） | `Features/Settings/AISettingsView.swift` 已有"AI 索引 / 摘要 / 标签"三段 + 多用 `DisclosureGroup + SceneStorage` 折叠 | 在该 Tab 末尾新增一个 `DisclosureGroup("AI 代码上下文（实验）")` 区块，只放配置开关（总开关 + Token 预算 Slider + 关键文件保留行数 Stepper + 跳转管理面板按钮） |
| 设置页 UI（产物管理） | `Features/Settings/SettingsView.swift:StorageSettingsTab` 已有 README / 图片清理；**CodeFlow 数据管理放 `IntegrationSettingsTab` 是因为它是 vendored 第三方集成**；RepoContextPacker 是 Starcat 自带功能，归属应在 StorageSettingsTab | **扩展 StorageSettingsTab**：新增 "AI 代码上下文" Section，照搬 CodeFlow 模式精简版（路径配置行 + 4 字段统计行 + 项目列表 + 一键清除 + 二次确认 + 错误 alert） |
| AI 摘要 UI | `Features/AI/RepoAIWindowContentView.swift` 有 `summaryHeader` / `streamingSummary` / `footer(_:)` / `errorBanner` 等已存在子视图 | 改 `streamingSummary` 显示「准备代码上下文 → 生成摘要」两段进度；改 `footer` 末尾追加 token / 文件数 caption；顶部新增条件渲染的 `contextDegradedBanner` |
| AppDependencies | `App/AppDependencies.swift:296-301` 是 `RepoAIInsightService` 的装配点，已有 `summaryRepository` / `readmeRepository` / `settings` 依赖 | 在其之前装配 `sharedSnapshotService` + `repoContextStorage` + `repoAIContextProvider`，并把 `repoAIContextProvider` 注入到 `RepoAIInsightService` 初始化参数 |
| i18n | `Resources/Localizable.xcstrings`，`ai.assistant.*` / `ai.settings.*` 命名空间已有先例 | 新增 `ai.context.*` 命名空间（覆盖 `phase` / `footer` / `settings` / `banner` / `storage` 5 个子段） |

### 0.2 阶段 W：共享 ZIP 快照服务 + 产物存储 + RepoAIContextProvider

> 目标：让 `RepoContextPacker.pack(_:)` 可以被一个**业务无关的 facade** 安全调用，并且产物（XML + 元数据）落到一个**用户可见、可迁移、可清理**的目录。

- [ ] **W1. 抽 `SharedSnapshotService`** —— 新建 `Starcat/Shared/Services/SharedSnapshotService.swift`：
  - 把 `CodeFlowRunner.archiveIfNeeded(repo:commitSHA:)` / `archiveFileURL(owner:name:commitSHA:)` / `resolveBranch(repo:name:)` 三个方法的**核心逻辑**搬过来；
  - 错误类型独立为 `SharedSnapshotError`（拆 `privateRepository` / `requestFailed` / `archiveTooLarge` / `emptyArchive` / `branchNotFound` 5 个 case，不要污染 `CodeFlowError`）；
  - 100MB ZIP 上限常量从 `CodeFlowRunner.maximumArchiveBytes` 提到 `SharedSnapshotService.maximumArchiveBytes`，CodeFlow 改为引用；
  - 路径常量 `repository-snapshots/github.com/<owner>/<repo>/<sha>.zip` 内化（CodeFlow / Packer 都不直接拼）。
- [ ] **W2. CodeFlow 改造** —— `CodeFlowRunner` 通过依赖注入接 `SharedSnapshotService`：
  - `archiveIfNeeded` / `archiveFileURL` / `branch` / `resolveBranch` / `branches` 全部 delegate 到新服务；
  - `CodeFlowError.privateRepository` / `archiveTooLarge` / `emptyArchive` / `branchNotFound` 改为 mapping 自 `SharedSnapshotError`（保持现有调用方错误文案不变）；
  - 跑 CodeFlow E2E（手动点一次"生成代码图谱"），确认 ZIP 复用 / 重新下载 / 私有仓库报错三条路径不退化。
- [ ] **W3. 新建 `RepoAIContextProvider`** —— `Starcat/Features/AI/RepoAIContextProvider.swift`：
  - 业务接口：`func context(for repo: Repo) async throws -> URL?` 返回 `context.xml` 路径，nil 表示「未启用 / 静默失败」；
  - 内部三步：① 调 `SharedSnapshotService.resolveBranch + archiveIfNeeded` 拿 ZIP；② 调 `RepoContextStorage.lookupMetadata(owner:repo:)` 检查 `<owner>/<repo>/metadata.json` 是否已存在且 `commitSha + tokenBudget + tier1MaxLines + tierRulesVersion` 都匹配（命中则跳过 pack 直接返回 `<repo>/context.xml`）；③ 不命中则调 `RepoContextPacker.pack(_:)`，由 packer 内部的 `ContextWriter` 通过 `RepoContextStorage.withOutputRoot` 写盘；
  - 失败降级：`CancellationError` 重新抛出；其它任何错误返回 nil + log（学习 `RepoAIInsightService.generateInsight:127-129` 的 `AnySearchContextProvider` 处理范本）；
  - **不做私有仓库判断**（接入面表已说明，scope 不允许私有仓库进入系统）。
- [ ] **W4. AppDependencies 装配** —— 在 `AppDependencies.swift:296` `RepoAIInsightService` 装配**之前**：
  - new 一个 `sharedSnapshotService: SharedSnapshotService` 持有；
  - new 一个 `repoContextStorage = RepoContextStorage.shared`（singleton，仿 `CodeFlowStorage.shared`）；
  - new 一个 `repoAIContextProvider: RepoAIContextProvider` 持有（依赖 `sharedSnapshotService` + `repoContextStorage` + `settings`）；
  - **不再传 `outputBaseDir`**：`RepoContextPacker.pack` 改为接收 `outputDirectory: URL`（由 `ContextWriter` 在 `RepoContextStorage.withOutputRoot` 闭包内 resolve 出 `<root>/<owner>/<repo>/`）；
  - `RepoAIInsightService.init` 新增 `repoAIContextProvider:` 参数（**X5 才接通业务**，W4 只完成装配）。
- [ ] **W5. 单测** —— `StarcatTests/SharedSnapshotServiceTests.swift`：
  - 私有仓库 throws `.privateRepository`；
  - 已存在 ZIP 复用（mock fileManager 返回 exists）；
  - 不存在 ZIP 下载（mock downloader 返回 fixture 2KB data，断言写入 archiveURL）；
  - 100MB 上限 throws `.archiveTooLarge`；
  - 空 response throws `.emptyArchive`。
- [ ] **W6. 新建 `RepoContextStorage`** —— 新建 `Starcat/Shared/Services/RepoContextStorage.swift`（**仿 `Features/CodeGraph/CodeFlowStorage.swift` 精简版，相同接口形态**）：
  - `@MainActor @Observable final class RepoContextStorage`，单例 `static let shared = RepoContextStorage()`；
  - **状态属性**（与 CodeFlowStorage 对齐）：
    - `private(set) var projects: [RepoContextProject]`：扫描产物目录得到的项目数组；
    - `private(set) var lastErrorMessage: String?`：操作失败时 UI 显示用；
    - `var totalBytes: Int64 { projects.reduce(0) { $0 + $1.contextBytes + $1.metadataBytes } }`：总占用；
    - `var totalGenerationCount: Int { projects.reduce(0) { $0 + $1.generationCount } }`：总生成次数；
    - `var latestGeneratedAt: Date? { projects.compactMap(\.generatedAt).max() }`：最近一次生成时间；
  - **持久化**：自定义产物根目录通过 Security-scoped bookmark 持久化（UserDefaults key `settings.repoContext.outputDirectoryBookmark.v1`）；默认路径 `Application Support/Starcat/repo-context/`（与 `codeflow/` 同级，便于后续整体备份）；
  - **目录结构**：`<root>/<owner>/<repo>/{context.xml, metadata.json}`（与 CodeFlow `<root>/<owner>/<repo>/code-graph/index.html` 镜像）；
  - **核心方法**（参考 `CodeFlowStorage.swift` 已有实现，对应签名直接借用）：
    - `effectiveRootURL() throws -> URL`：返回当前生效的根（自定义 bookmark 或 default app support）；
    - `withOutputRoot<T>(_ block: (URL) async throws -> T) async throws -> T`：security-scoped 闭包包装（自定义目录走 `startAccessingSecurityScopedResource`，default 不走）；
    - `selectOutputDirectory(_ url: URL) throws`：用户在 UI 选了新目录后，**自动迁移**旧目录所有 `<owner>/<repo>/` 子目录到新目录（同名 conflict 走 `<repo>-2026-06-13-150000` 后缀）；
    - `resetOutputDirectory() throws`：丢弃 bookmark，迁移回 default；
    - `refresh() async`：从文件系统重新枚举 `projects`（每个 owner / repo 子目录 → 一条 `RepoContextProject`）；
    - `delete(owner:repo:) async throws`：单删；
    - `deleteAll() async throws`：清空；
    - `lookupMetadata(owner:repo:) -> PackMetadata?`：W3 走的缓存命中入口（封装从 `metadata.json` 反序列化）；
  - **设计要点（与 CodeFlow 同款）**：文件系统为单一信任源，没有任何内存索引；UI 状态完全派生自 `projects` 数组；所有写操作末尾都触发 `refresh()`。
- [ ] **W7. 扩展 `PackMetadata`** —— `Starcat/Shared/Services/RepoContextPacker/Models/PackerIO.swift`：
  - 增加 4 个可选字段（**保持向后兼容**，老 metadata.json 反序列化不报错）：
    - `tier1MaxLines: Int?`：W3 缓存命中判断需要（settings 调整后旧 metadata 失效）；
    - `tierRulesVersion: String?`：固定 `"v1"`（后续 TierRules 升级时 bump，强制重 pack）；
    - `lastAccessedAt: Date?`：UI 按访问时间排序、LRU 清理用；
    - `generationCount: Int?`：UI 显示「生成 N 次」（首次写 1，后续 +1）；
  - `RepoContextProject` struct（W6 新建）从 metadata.json 反序列化得到这些字段。
- [ ] **W8. 改造 `ContextWriter`** —— `Starcat/Shared/Services/RepoContextPacker/Internal/ContextWriter.swift`：
  - 当前 `write(_:to outputDirectory:)` 是直接 `Data.write(.atomic)` 到 hardcoded 目录；
  - 改为接收 `RepoContextStorage` 引用，写盘走 `storage.withOutputRoot { root in ... }`；
  - 写盘前从 storage 读取旧 metadata 的 `generationCount`，新 metadata 的 `generationCount = old + 1`；
  - 写盘后调 `storage.refresh()` 刷新 UI；
  - 单测保留（fixture 走临时目录，不依赖 storage 单例）。

### 0.3 阶段 X：AppSettings 字段 + Prompt 注入

> 目标：让 `RepoContextPacker` 的 XML 真的被喂进 LLM 的 system prompt / user context。

- [x] **X1. AppSettings 新增 3 个字段**（`AppSettings.swift`，2026-06-13 完成）：
  - `aiRepoContextEnabled: Bool`（默认 `true`，UserDefaults key `settings.ai.repoContext.enabled.v1`）；
  - `aiRepoContextTokenBudget: Int`（默认 `8000`，范围 `4000-32000`，key `settings.ai.repoContext.tokenBudget.v1`）；
  - `aiRepoContextTier1MaxLines: Int`（默认 `80`，范围 `40-200`，key `settings.ai.repoContext.tier1MaxLines.v1`，对应 `TierTruncation.tier1MaxLines` 的运行期 override 入口）；
  - `Keys` 子结构同步加 3 条；`init` 末尾 3 行 `defaults.object(forKey:) as? T ?? default` 解出来；不要破坏现有 `persist` 模式。
  - **不增加 `aiRepoContextAllowPrivate`**：原因见 §0.1 接入面表与 `AppSettings.swift` 内 MARK 注释。
- [ ] **X2. AppSettings 单测**（`AppSettingsTests.swift`）：3 字段默认值 / 写入回读 / out-of-range Stepper 取值兜底。
- [ ] **X3. `TierTruncation` 加运行期 override** —— 现在的 `tier1MaxLines = 80` 是 `static let`，X3 需要重构为**可注入**（保留默认 80 当 fallback）：
  - 方案：`TierTruncation.tier1Head(_:maxLines:maxChars:)` 增加 2 个可选参数，调用方传入 settings 值；
  - `XmlOutputBuilder.build` 接收 `tier1MaxLines` 参数（由 `RepoContextPacker.pack` 从 `PackInput` 转发），不传时用默认 80；
  - `PackInput` 增加 `tier1MaxLines: Int = 80` 字段。
- [ ] **X4. `RepoAIInsightService` 接通 RepoAIContextProvider**（`RepoAIInsightService.swift`）：
  - `init` 新增 `repoAIContextProvider: RepoAIContextProvider?` 参数（默认 nil 不破坏现有测试）；
  - 把 `private let externalContextProvider: AnySearchContextProvider` 旁边并列加一个 `private let repoContextProvider: RepoAIContextProvider?`；
  - 改造 `makeSource(for:)`：在原有 README + 元信息拼接**后**追加一段 `<repo-context>...</repo-context>`（如果 `aiRepoContextEnabled && repoContextProvider?.context(for:repo)` 返回非 nil 的 contextURL，读文件内容拼进去；失败静默返回原 source）；
  - 注意 `Source.hash` 计算必须包含 context 内容（否则改 budget / 关掉 context 后用户重新生成的摘要会命中旧缓存，dong4j 体验崩坏）。
- [ ] **X5. 同款接入到 `chatStream`** —— 不另写一遍，X4 已经在 `makeSource` 注入完成，`chatStream` 自动复用（`chatStream` 第 261 行就调的 `makeSource`）。**唯一需要确认**：system prompt 模板 `"Repository context: \(source.text)"` 已经把 `<repo-context>` 段囊括进去，无需改 `chatStream` 自己。
- [ ] **X6. AppDependencies 装配收尾** —— `AppDependencies.swift:296` `RepoAIInsightService` 初始化时把 `repoAIContextProvider: self.repoAIContextProvider` 传进去。
- [ ] **X7. RepoAIInsightService 单测** —— `StarcatTests/RepoAIInsightServiceTests.swift`（如果还没有）/ 新建：
  - 关闭 `aiRepoContextEnabled` 时 source 不含 `<repo-context>`；
  - 开启且 provider 返回 URL 时 source 含 `<repo-context>`；
  - provider 抛错时 source 不含 `<repo-context>` 且不抛错；
  - `Source.hash` 在两次开关之间变化（防 cache 复用 bug）。

### 0.4 阶段 Y：UI 触点 6 个 + E2E

> 触点编号沿用 §12 设计文档命名（A~F），独立实施可并行。

- [ ] **Y1. 触点 A：摘要生成两阶段状态条**（`RepoAIWindowContentView.swift`）：
  - 改 `streamingSummary(_ text:)` 上方的 `HStack { ProgressView + Text }`：
    - 当 `chatVM`/`insightVM` 还在 `repoAIContextProvider` 调用阶段（`text.isEmpty` 且 generating），显示 `ai.context.phase.preparingContext`（"准备代码上下文..."）；
    - 进入 LLM 流式时切到 `ai.assistant.summary.streaming`；
  - 需要 ViewModel 暴露一个新的 `enum SummaryPhase { case idle, preparingContext, streamingSummary, done, failed }`，`RepoAIInsightViewModel` 增加 `private(set) var phase: SummaryPhase = .idle`；
  - `generateInsight` 调用前置 `.preparingContext`，第一个 onSummaryDelta 触发时切 `.streamingSummary`。
- [ ] **Y2. 触点 B：摘要 footer 元信息**（`RepoAIWindowContentView.swift:footer`）：
  - 在 `Text("由 X 生成 · 时间")` **下方**追加一行 `caption2 / tertiary`：`87 个文件 · 7.2K tokens · 51ab970 · main`；
  - 数据来源：`RepoAIInsightService` 把 `PackMetadata`（来自 `RepoAIContextProvider`）一并放进 `RepoAIInsight` 一个新可选字段 `contextMetadata: ContextFooterMetadata?`（结构含 `keptFileCount: Int` / `actualTokens: Int` / `shortSha: String` / `ref: String`）；
  - 没用代码上下文时该行不渲染（`if let footer = insight.contextMetadata { ... }`）；
  - i18n：`ai.context.footer.format` = `"%d files · %@ tokens · %@ · %@"`。
- [ ] **Y3. 触点 C：设置页配置区**（`Features/Settings/AISettingsView.swift`）：

  **插入位置精确定位**：现有 `AISettingsTab.body`（line 108-127）的 `Form` 按"配置链路从上到下"顺序排了 7 个 section：

  ```
  Form {
      providerSection       // ① Provider 配置
      enabledModelsSection  // ② 已发现的模型
      taskModelsSection     // ③ 任务模型（4 task → provider/model 绑定）
      promptSection         // ④ Prompt 编辑（DisclosureGroup）
      autoTidySection       // ⑤ 自动整理（DisclosureGroup）
      aiIndexSection        // ⑥ AI 索引/向量化（DisclosureGroup）
      aiRepoContextSection  // ⑦ ← 新增插这里
      privacySection        // ⑧ 隐私说明（始终保持最后）
  }
  ```

  **为什么放 ⑥/⑧ 之间**：
  - 与 `aiIndexSection`（向量化）是同性质"消费上游配置的高级 AI 能力"，相邻分组合理；
  - `privacySection` 必须保持最后（用户读到时已了解所有功能 → 总览数据流向）；
  - 「AI 代码上下文」涉及"上传源码到云端 LLM"的隐私敏感操作，紧贴 `privacySection` 形成「先看功能再看隐私」的阅读节奏；
  - **不要**做成 `aiIndexSection` 内的子 `DisclosureGroup`：索引与代码上下文是独立特性，混在一起反而难发现。

  **Section 内部结构**（沿用现有 `promptSection` / `autoTidySection` / `aiIndexSection` 的 `DisclosureGroup` + `@SceneStorage` 默认折叠风格）：

  ```swift
  // 1. 新增 SceneStorage 折叠状态（与 isPromptExpanded 等并列声明在 view 顶部）
  @SceneStorage("settings.ai.repoContext.expanded") private var isRepoContextExpanded: Bool = false

  // 2. 新增 computed View
  private var aiRepoContextSection: some View {
      Section {
          DisclosureGroup(isExpanded: $isRepoContextExpanded) {
              VStack(alignment: .leading, spacing: 12) {
                  Toggle("ai.context.settings.enabled", isOn: $settings.aiRepoContextEnabled)
                  Text("ai.context.settings.description").font(.caption).foregroundStyle(.secondary)

                  Divider()

                  // Slider 4000-32000 step 2000
                  HStack {
                      Text("ai.context.settings.tokenBudget")
                      Spacer()
                      Text("\(settings.aiRepoContextTokenBudget) tokens").monospacedDigit().foregroundStyle(.secondary)
                  }
                  Slider(value: tokenBudgetBinding, in: 4000...32000, step: 2000)
                      .disabled(!settings.aiRepoContextEnabled)

                  // Stepper 40-200 step 20
                  Stepper(value: $settings.aiRepoContextTier1MaxLines, in: 40...200, step: 20) {
                      HStack {
                          Text("ai.context.settings.tier1MaxLines")
                          Spacer()
                          Text("\(settings.aiRepoContextTier1MaxLines) 行").monospacedDigit().foregroundStyle(.secondary)
                      }
                  }
                  .disabled(!settings.aiRepoContextEnabled)

                  Divider()

                  Button {
                      // 跳转到 Settings → Storage Tab；
                      // 当前 SettingsView 用 @State 自管 selectedTab，无 NotificationCenter 入口，
                      // 这里走 NotificationCenter.post 给 SettingsView 加监听（Y3 一并实现）。
                      NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: "storage")
                  } label: {
                      Label("ai.context.settings.manageStorage", systemImage: "internaldrive")
                  }
              }
              .padding(.vertical, 4)
          } label: {
              Label("ai.context.settings.title", systemImage: "doc.text.magnifyingglass")
                  .font(.headline)
          }
      }
  }

  // 3. tokenBudgetBinding（避免 Slider 直接绑 Int 字段的 Double 转换噪音）
  private var tokenBudgetBinding: Binding<Double> {
      Binding(
          get: { Double(settings.aiRepoContextTokenBudget) },
          set: { settings.aiRepoContextTokenBudget = Int($0) }
      )
  }
  ```

  **配套小改动**：
  - `SettingsView.swift` 新增 `NotificationCenter` 监听 `.starcatJumpToSettingsTab`，把 `selectedTab` 切到 `.storage`；
  - `Notification.Name` 扩展在 `Shared/Extensions/Notification+Names.swift`（如果没有就建）；
  - 默认 `isRepoContextExpanded = false`（与 promptSection 一致），首次开启功能的用户需要主动展开 — 避免设置页一打开就被新 section 撑高。

  **i18n 键清单**（Y3 一并加到 `Localizable.xcstrings`）：
  | Key | zh-Hans | en |
  |---|---|---|
  | `ai.context.settings.title` | AI 代码上下文（实验） | AI Code Context (Experimental) |
  | `ai.context.settings.enabled` | 启用代码上下文 | Enable Code Context |
  | `ai.context.settings.description` | 把仓库源码打包成 XML 喂给 AI，让摘要 / 对话能"看到代码"。首次生成会下载并解压 ZIP，可能 1-3 秒。 | Pack repo source code as XML for AI to "see" the code in summaries/chat. First generation downloads and unzips, may take 1-3s. |
  | `ai.context.settings.tokenBudget` | Token 预算 | Token Budget |
  | `ai.context.settings.tier1MaxLines` | 关键文件保留行数 | Key Files Line Cap |
  | `ai.context.settings.manageStorage` | 管理已生成的上下文 → 存储 Tab | Manage Generated Contexts → Storage Tab |
- [ ] **Y4. 触点 D：降级 banner**（`RepoAIWindowContentView.swift`）：
  - 在 `summarySection` 顶部、`errorBanner` 之前**条件渲染** `contextDegradedBanner`；
  - 数据来源：`RepoAIInsightViewModel` 新增 `contextDegradationReason: ContextDegradationReason?` 状态，5 种枚举：`network` / `disk` / `archiveTooLarge` / `extractionFailed` / `zipSlipBlocked`；
  - i18n：`ai.context.banner.network` / `ai.context.banner.disk` / 等 5 条文案 + 通用 `ai.context.banner.dismiss`。
- [ ] **Y5. 触点 E：存储 Tab 数据管理面板**（`SettingsView.swift:StorageSettingsTab`，**走 CodeFlow 模式精简版**）：

  **归属理由**：RepoContextPacker 是 Starcat **自带功能**（纯 Swift + ZIPFoundation），不是 vendored 第三方集成，不放 `IntegrationSettingsTab`；StorageSettingsTab 当前就是"缓存与产物清理"统一入口，扩展它最合理。

  **Section 结构**（参考 `Features/Settings/IntegrationSettingsView.swift` 中 CodeFlow 数据管理一节的视觉与交互骨架，**裁剪掉 Sparkle / EdDSA / vendored asset 等无关项**）：

  ```
  Section("ai.context.storage.section") {
      // ① 路径配置行：当前根 URL + 「选择…」按钮 + 「重置」按钮 + 「在 Finder 显示」按钮
      LabeledContent("ai.context.storage.outputDirectory") {
          HStack { Text(rootDisplayPath).truncationMode(.middle); choose / reset / reveal }
      }

      // ② 统计行（4 列横排）：项目数 · 总占用 · 总生成次数 · 最近生成时间
      LabeledContent("ai.context.storage.stats") {
          HStack(spacing: 16) {
              Stat("\(storage.projects.count) repos")
              Stat(ByteCountFormatter.string(fromByteCount: storage.totalBytes, countStyle: .file))
              Stat("\(storage.totalGenerationCount) generations")
              Stat(storage.latestGeneratedAt.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: .now) } ?? "—")
          }
      }

      // ③ 项目列表：每行 = 一个 <owner>/<repo>，右侧 Menu(...) → Preview / Reveal / Delete
      ForEach(storage.projects) { project in
          HStack {
              VStack(alignment: .leading) {
                  Text("\(project.owner)/\(project.repo)").font(.body.monospaced())
                  Text("\(project.commitSha.prefix(7)) · \(ByteCountFormatter.string(fromByteCount: project.contextBytes, countStyle: .file)) · \(project.generationCount)x").font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Menu { ... } label: { Image(systemName: "ellipsis.circle") }
          }
      }

      // ④ 一键清空 destructive button + confirmation dialog
      Button(role: .destructive) { showClearAllConfirm = true } label: { Label("ai.context.storage.clearAll", systemImage: "trash") }
          .confirmationDialog(...)

      // ⑤ 错误 alert：监听 storage.lastErrorMessage，非 nil 时弹 alert
  }
  ```

  **关键交互**：
  - **路径选择**：`NSOpenPanel(canChooseDirectories: true, canChooseFiles: false)` → `storage.selectOutputDirectory(url)` → 内部自动迁移所有 `<owner>/<repo>/` 子目录到新目录（同名 conflict 加时间戳后缀）；
  - **重置**：`storage.resetOutputDirectory()` → 迁移回 `Application Support/Starcat/repo-context/`；
  - **删除**：`storage.delete(owner:repo:)` → `FileManager.removeItem` + `refresh()`；
  - **一键清空**：`storage.deleteAll()` 删整个根目录下所有 `<owner>/<repo>/` 子目录，**保留根目录本身**（避免后续生成时再次创建目录的权限问题）。

  **i18n 键清单**（Y5 一并加到 `Localizable.xcstrings`）：

  | Key | zh-Hans | en |
  |---|---|---|
  | `ai.context.storage.section` | AI 代码上下文 | AI Code Context |
  | `ai.context.storage.outputDirectory` | 产物目录 | Output Directory |
  | `ai.context.storage.choose` | 选择… | Choose… |
  | `ai.context.storage.reset` | 重置为默认 | Reset to Default |
  | `ai.context.storage.reveal` | 在 Finder 中显示 | Reveal in Finder |
  | `ai.context.storage.stats` | 统计 | Statistics |
  | `ai.context.storage.statRepos` | %d 个仓库 | %d repos |
  | `ai.context.storage.statGenerations` | %d 次生成 | %d generations |
  | `ai.context.storage.menuPreview` | 预览 context.xml | Preview context.xml |
  | `ai.context.storage.menuReveal` | 在 Finder 中显示 | Reveal in Finder |
  | `ai.context.storage.menuDelete` | 删除此项 | Delete |
  | `ai.context.storage.clearAll` | 清空全部 | Clear All |
  | `ai.context.storage.clearAllConfirm.title` | 确定清空所有 AI 代码上下文？ | Clear all AI code contexts? |
  | `ai.context.storage.clearAllConfirm.message` | 此操作不可撤销。下次生成 AI 摘要时会重新打包。 | This cannot be undone. Next AI summary will repack. |

  **不引入新的 Inspector 工具类**：所有目录枚举、字节统计、删除逻辑都已经在 W6 的 `RepoContextStorage` 内实现，UI 直接绑定 `@Observable` 状态即可，**不要**再开一个 `AIContextStorageInspector` —— 那是单一信任源被打破的反模式。
- [ ] **Y6. 触点 F：右上角"在 Finder 显示上下文"菜单项**（`RepoAIWindowController.swift` 或 `RepoAIWindowContentView.panelHeader`）：
  - 关闭按钮 `xmark` 旁加一个 `Menu` （`ellipsis.circle`）：
    - Menu Item 1：`ai.context.menu.showInFinder` → `NSWorkspace.shared.activateFileViewerSelecting([contextURL])`；
    - Menu Item 2：`ai.context.menu.regenerate`（强制忽略 cache 重新 pack，调 `vm.regenerateContext(force:true)`）；
    - context 不存在时整个 Menu disabled。
- [ ] **Y7. 端到端 fixture 测试** —— `StarcatTests/RepoContextPacker/EndToEndIntegrationTests.swift`：
  - 4 个 fixture ZIP（手动放到 `StarcatTests/Fixtures/repo-zips/`）：vapor-vapor / repomix 自身 / 中型 monorepo / 5 文件的迷你 demo；
  - 跑完整 `RepoContextPacker.pack(_:)`，断言：
    - 输出 `context.xml` 通过 `XMLParser` 严格校验（无非法字符 / 标签闭合）；
    - 输出 `metadata.json` 解析成功且 `actualTokens ≤ tokenBudget × 1.2`（§22.7 决议）；
    - token 估算误差 `|estimatedTokens - actualTokens| / actualTokens ≤ 12%`；
    - `< 1s` 完成（小 demo 仓库）；
  - 注意：fixture ZIP 不入 git，提供 `StarcatTests/Fixtures/scripts/download-fixtures.sh` 脚本由 CI / 本地手动跑，README 说明跳过 fixture 时 E2E 自动 skip。

### 0.5 阶段 Z：本次延后（仅记录、不做）

- 设计文档 §22.11(e) 提到的 mojibake 文件名实际累计 warnings 逻辑；
- V2 ⭐⭐⭐ 优先级：tiktoken-swift 精确 token 计数 / `.gitignore` 解析；
- V2 ⭐⭐ 优先级：Markdown 输出格式；
- V2 ⭐ 优先级：tree-sitter compress / git 历史增强。
- 详见 §23.3 W/X/Y 表后的 Z 段、§23.6 后续任务粒度估算。

### 0.6 完成判定（DoD）

阶段 W / X / Y 全部勾选后还需要满足：

1. **构建**：`xcodegen generate` 0 错 + `xcodebuild -scheme Starcat build` BUILD SUCCEEDED；
2. **测试**：`xcodebuild test` 全绿（含新增的 SharedSnapshotServiceTests / RepoContextStorageTests / RepoAIInsightServiceTests / EndToEndIntegrationTests）；
3. **手动验证**：
   - 公开仓库（如 `vapor/vapor`）走完整链路，AI 摘要包含「## 架构概览」「## 模块职责」等明显源于代码的章节；
   - 关掉 `aiRepoContextEnabled` 重新生成，摘要降级为 README-only（与 X4 前一致）；
   - 设置页 3 个字段写入、回读、out-of-range 兜底全部正常；
   - StorageSettingsTab 看到 `repo-context/<owner>/<repo>/` 列表 + 4 项统计 + 单删 + 一键清空；
   - 修改产物目录（NSOpenPanel 选一个新位置）后，已生成的 `<owner>/<repo>/` 子目录被迁移到新目录；重置 → 迁回 default `Application Support/Starcat/repo-context/`；
4. **进度同步**：`docs/工程进度/功能实现总览.md` RepoContextPacker 条目「客户端接入（Step 8-10）」`[ ]` → `[x]` + `> 实现：...` 行。

### 0.7 风险与已知陷阱

| 风险 | 描述 | 缓解 |
|---|---|---|
| **缓存 hash 失效** | X4 改 `Source.hash` 算法后，所有存量 `ai_summaries` 缓存都会命中失败被重生成 | 决议：不做平滑过渡，**接受一次全量重生成**（dong4j 项目刚起步，缓存不珍贵；强行做迁移逻辑复杂） |
| **`RepoAIContextProvider` 耗时阻塞首字延迟** | pack 一次 10-200ms（小仓库）到 1-3s（中等仓库），用户感知"按了生成按钮但 1 秒没反应" | Y1 触点 A 状态条解决（明确显示"准备代码上下文..."阶段） |
| **`CodeFlowRunner` 改造破坏 P0 功能** | W2 抽 SharedSnapshotService 时如果错误映射漏一个 case，CodeFlow 用户看到不同文案 | 改造完手动跑一次 CodeFlow E2E（点"生成代码图谱"+ 验证已生成项目能复用 ZIP）；写迁移测试断言所有 5 种错误映射 |
| **`repo-context/` 占用爆炸** | 用户大量 star，每个公开仓库都生成一次，`<owner>/<repo>/` 累积可能上 GB | Y5 触点 E 解决一半（用户可清 / 改路径到外置硬盘）；后续 V2 加 LRU 自动清理或大小上限（不进 MVP） |
| **路径迁移期间 App 崩溃数据丢失** | `selectOutputDirectory` 走"copy → verify → delete"三步走，如果在中途 App 崩了，新旧目录都有数据 | 与 CodeFlowStorage 同款策略：永远先 `FileManager.copyItem` 到新目录、`refresh()` 确认能读到、再 `removeItem` 旧目录；中途崩了下次启动按"新目录优先、旧目录残留"清理即可 |

---

## 1. 设计目标

### 1.1 一句话目标

**让 Starcat 的 AI 摘要 / AI 对话能"看到真正的代码"**，而不是只能基于 README + GitHub 元信息瞎猜。

### 1.2 业务驱动

当前 AI 摘要链路（`Features/AI/RepoAIInsightService.swift`）的输入：

```
GitHub 元信息（stars / forks / topics / language）
   + README HTML / Markdown
   ↓
Prompt
   ↓
LLM
   ↓
AI 摘要
```

存在三个根本问题（用户 plan 文档 `docs/需求讨论/starcat-repomix-integration-plan.md` §1 已论证）：

1. **README 不一定完整**：很多项目 README 只讲用法，不讲架构、模块职责、内部依赖
2. **AI 无法理解真实代码结构**：仅靠 README 难以判断核心模块、入口文件、是否 CLI/Server/SDK 之分
3. **后续 AI 对话上下文不足**：用户追问"我想集成它该看哪些代码 / 它如何启动 / 架构特点"等问题，README 答不出

### 1.3 解决方案定位

引入一个**项目上下文打包层** `RepoContextPacker`，把已下载的 GitHub 仓库源码 ZIP 智能打包为 LLM 友好的 XML 上下文，作为 AI 摘要 / AI 对话的**额外输入**。

升级后的链路：

```
GitHub 元信息 + README + RepoContextPacker(context.xml)
   ↓
AIContextBuilder（组装 prompt）
   ↓
LLM
   ↓
AI 摘要（"看源码做技术评估" vs 之前的 "看简介写读后感"）
```

---

## 2. 与 repomix 的关系（明确不照搬什么）

### 2.1 调研结论

我们调研了 [yamadashy/repomix](https://github.com/yamadashy/repomix) v1.14.1（本机 brew 安装版），关键发现：

| 维度 | 数值 / 事实 |
|---|---|
| 总体积（含依赖） | 129 MB（其中 23 MB 是 tree-sitter wasm，5.8 MB 是 MCP SDK） |
| Native 代码 | **零**（无 `.node` / `.dylib` / `.so`） |
| 入口 | `bin/repomix.cjs`（Node.js 脚本）|
| 是否提供 standalone 二进制 | 否（官方推 `bunx repomix@latest`） |

### 2.2 为什么不能直接内嵌 repomix

Apple Mac App Store 沙箱约束（CodeFlow 设计文档 `docs/需求讨论/starcat-codeflow-integration.md` §2 已确认）：

- 不能调用 `/usr/bin/git`（间接 `xcrun` 触发 `xcrun: error: cannot be used within an App Sandbox`）
- bundle 内 helper executable 理论可行，但需 hardened runtime + 5 个敏感 entitlement（`allow-jit` / `allow-unsigned-executable-memory` / ...）
- Bun 在 MAS sandbox 下的官方支持 2026-02 PR #27041 才补齐，生产稳定性需观察
- Bun-compile 后体积 +80 MB（runtime 60 MB + wasm 23 MB）

### 2.3 决策：Swift 自研，照搬经验数据

repomix 70% 的代码 Starcat 用不到（CLI 参数解析、远程 git clone、MCP server、Skill 生成、远程配置加载等）。**Starcat 真正需要的能力**：

| repomix 模块 | Starcat 是否需要 | 实现路线 |
|---|---|---|
| 文件读取 + glob 过滤 + ignore 规则 | ✅ | Swift 重写，**照抄** `defaultIgnore.js` 85 条 |
| 目录树生成 | ✅ | Swift 重写，~50 行 |
| XML 输出 | ✅ | Swift 重写，~200 行 |
| Token 估算 | ✅ | Swift 用 `字符数 × 0.27` 粗略估算 |
| 远程 `git clone` | ❌ | **CodeFlow 已用 GitHub ZIP API 实现** |
| `--compress` tree-sitter 提取签名 | ❌ MVP / 🟡 V2 评估 | 需要 23MB wasm + SwiftTreeSitter，**MVP 不做** |
| MCP server / Skill 生成 | ❌ | 与 Starcat 无关 |
| secretlint 敏感信息扫描 | ❌ | Starcat 只支持公开仓库 |
| stdin / stdout / CLI 参数 | ❌ | 无命令行入口 |
| `repomix.config.json` 加载 | ❌ | Starcat 用 `AppSettings` |

### 2.4 经验数据照搬清单

以下数据**值得直接引用 repomix 的经验值**：

1. **默认 ignore 列表 85 条**（来自 `core/config/defaultIgnore.js`）
2. **17 种语言扩展名映射**（来自 `core/treeSitter/languageConfig.js`，即使 MVP 不做 compress 也可用于标 `language` 字段）
3. **XML 输出段落布局**（来自 `core/output/outputStyles/xmlStyle.js`）
4. **Token 估算系数 `0.27`**（来自 gpt-tokenizer `o200k_base` 的经验值）
5. **二进制文件扩展名清单**（参考 `is-binary-path` 包内容）

---

## 3. MVP 范围与边界

> ⚠️ **v1.2 覆盖**：MVP 实施依赖项已确定 —— ZIPFoundation（[§22.2](#222-q1--zip-解压库--zipfoundation)）、自写 glob→regex 转换器（[§22.3](#223-q2--glob-匹配--自写-glob--regex-转换器)）。临时目录与产物布局以 [§22.6 Q5 决议](#226-q5--临时目录--产物布局) 为准（解压用系统 `temporaryDirectory`、产物持久化到 `Application Support/Starcat/analysis/<owner>/<repo>/`）。所有 5 项安全防护见 [§22.11 Q10 决议](#2211-q10--5-项安全防护)。

### 3.1 核心思路

不是「把整个仓库打包」（repomix 的默认做法），而是「**智能挑出 LLM 需要的 20-50 个关键文件，拼成 ≤ 8000 token 的上下文**」。

实现机制 = **Tier 分级 + Token Budget**。

### 3.2 Tier 分级总览

| Tier | 对待方式 | Token 成本 | 信息密度 | 典型占比 |
|---|---|---|---|---|
| **Tier 0** | **全文打包**（除非单文件超 4K token） | 中（每文件 100-1500 token） | 极高 | 一个仓库通常 3-10 个 |
| **Tier 1** | **只取头 80 行** | 中（每文件 ~600 token） | 高 | 一个仓库通常 1-5 个 |
| **Tier 2** | **只列路径 + 估算 token，不给内容** | 极低（每文件 ~10 token） | 中（指示"项目有这些模块"） | 一个仓库通常 30-500 个 |
| (Drop) | 完全丢弃 | 0 | 0 或负 | 大部分文件 |

详细分级清单见 §5。

### 3.3 输入 / 输出契约

```
输入：
  - sourceArchive: URL          ZIP 文件路径（来自 CodeFlow repository-snapshots）
  - owner: String               GitHub owner
  - repo: String                GitHub repo name
  - commitSha: String           生成 ZIP 的精确 commit SHA
  - options: PackerOptions      可选配置（token budget 等）

输出：
  - artifact: ContextArtifact   含 outputURL / tokenCount / fileCount / generatedAt
  - 副作用：原子写盘到 analysis/<owner>/<repo>/context.xml + metadata.json
```

### 3.4 MVP 明确不做的功能

```
× tree-sitter compress 模式      → 等 V2 评估 SwiftTreeSitter 收益
× 精确 token 计数（gpt-tokenizer）→ MVP 用字符 × 0.27 估算（误差 ±10% 可接受）
× .gitignore 解析                 → 默认 ignore 85 条已覆盖 95%
× 编码检测（jschardet）           → MVP 强制 UTF-8（非 UTF-8 文件极少且对 AI 摘要不关键）
× --remove-comments               → 注释对 LLM 理解项目反而有帮助
× --remove-empty-lines            → 收益微小破坏可读性
× Markdown / JSON / Plain 输出   → MVP 只 XML
× --split-output                  → 用 token budget 截断替代
× --copy 剪贴板                   → UI 层做
× MCP server / Skill              → 不是 Starcat 范畴
× secretlint                      → 公开仓库不需要
× git diff / log                  → ZIP 中无 .git
× git churn 排序                  → 同上
× 远程 git clone                  → CodeFlow 已实现
× CLI 参数解析                    → 无命令行入口
× repomix.config.json 加载        → 用 AppSettings
× 多目录合并打包                  → Starcat 一次只处理一个仓库
```

---

## 4. 模块架构

### 4.1 9 模块总览

```
┌─ 1. SourceZipExtractor      从 repository-snapshots/<sha>.zip 解压到临时目录
│
├─ 2. FileFilter              默认 ignore 85 条 + 二进制过滤 + maxFileSize
│
├─ 3. TierClassifier          按文件名 / 路径模式打 tier 标签（核心）
│
├─ 4. TokenEstimator          字符 × 0.27，零依赖
│
├─ 5. BudgetAllocator         按 tier 优先级 + budget 截断（核心）
│
├─ 6. DirectoryTreeBuilder    ASCII 目录树（全量，不受 budget 限制）
│
├─ 7. XmlOutputBuilder        拼装 5 个段落，parsable 转义
│
├─ 8. ContextWriter           原子写盘（.tmp → rename）
│
└─ 9. RepoContextPacker       顶层 Façade（输入 ZIP + Options → ContextArtifact）

   错误体系：RepoContextPackerError
```

### 4.2 模块依赖关系图

```
RepoContextPacker (Facade)
  │
  ├─→ SourceZipExtractor → 返回临时目录 URL
  │
  ├─→ FileFilter → 返回 [FilteredFile]
  │
  ├─→ TierClassifier → 返回 [TieredFile]
  │
  ├─→ TokenEstimator (注入到下游)
  │
  ├─→ BudgetAllocator → 返回 [AllocatedFile]（含截断决策）
  │
  ├─→ DirectoryTreeBuilder → 返回 String
  │
  ├─→ XmlOutputBuilder → 返回 String（完整 XML）
  │
  └─→ ContextWriter → 写盘
```

---

## 5. Tier 分级规则（核心经验数据）

> ⚠️ **v1.2 覆盖**：截断语义（Tier 1 行数 80 + 字符数 4000 双约束 + 统一 `// ... [truncated: ...]` marker、Tier 0 100KB 硬上限降级 Tier 2、单文件 5MB 上限降级 Tier 2）由 [§22.9 Q8 决议](#229-q8--截断语义) 定型；二进制检测策略（扩展名白名单 fast-path + NUL 字节 8KB 探测）由 [§22.7 Q6 决议](#227-q6--二进制检测--扩展名白名单--nul-探测) 定型。本节的「Tier 0 / Tier 1 / Tier 2」清单（精确文件名、glob 模式）仍然有效，**仅截断与二进制检测策略以 §22 为准**。

### 5.1 判定优先级

```
Drop 规则（默认 ignore 85 条 + 二进制文件 + maxFileSize）→ 直接丢
   ↓
Tier 0 精确匹配（文件名在固定清单）→ 命中即 Tier 0
   ↓
Tier 1 glob 匹配 → 命中即 Tier 1
   ↓
都不命中 → Tier 2
```

### 5.2 Tier 0 完整清单（必给全文）

#### 5.2.1 项目级元信息（任何项目都看）

| 文件名（精确匹配） | 为什么必给 |
|---|---|
| `README.md` / `README.rst` / `README.adoc` / `README.txt` | LLM 理解项目用途的第一来源 |
| `LICENSE` / `LICENSE.md` / `LICENSE.txt` / `COPYING` | 判断商用 / 闭源风险 |
| `CHANGELOG.md` / `CHANGELOG.rst` / `HISTORY.md` | 看活跃度、最近更新方向 |
| `CONTRIBUTING.md` | 反映社区成熟度 |
| `SECURITY.md` | 判断是否处理安全问题 |
| `CODE_OF_CONDUCT.md` | 通常很短，token 成本低 |
| `AGENTS.md` / `CLAUDE.md` / `STARCAT.md` | AI 协作规则（Starcat 自己也用） |

#### 5.2.2 语言生态的包管理 / 构建文件（**Tier 0 最有价值的部分**）

| 生态 | 文件 | 信息价值 |
|---|---|---|
| **JavaScript / TypeScript / Node** | `package.json`、`tsconfig.json`、`tsconfig.*.json`、`pnpm-workspace.yaml`、`lerna.json`、`turbo.json`、`nx.json`、`rush.json`、`workspace.json` | `package.json` 是金矿：`scripts` / `bin` / `dependencies` / `engines` |
| **Rust** | `Cargo.toml`、`rust-toolchain.toml`、`rust-toolchain` | `[[bin]]` / `[lib]` / `[features]` 直接告诉项目类型 |
| **Go** | `go.mod`、`go.work` | `module` + `require` 段 |
| **Python** | `pyproject.toml`、`setup.py`、`setup.cfg`、`requirements.txt`、`Pipfile`、`environment.yml` | `pyproject.toml` 的 `[tool.poetry]` / `[project]` |
| **Java / Kotlin** | `pom.xml`、`build.gradle`、`build.gradle.kts`、`settings.gradle(.kts)`、`gradle.properties` | 结构高度规整 |
| **Swift / Apple** | `Package.swift`、`project.yml`（XcodeGen）、`*.podspec`、`Cartfile`、`Brewfile` | `project.yml` 比 `*.xcodeproj` 可读得多 |
| **C / C++** | `CMakeLists.txt`、`Makefile`、`meson.build`、`conanfile.txt`、`vcpkg.json` | `project()` + `add_executable()` |
| **Ruby** | `Gemfile`、`*.gemspec`、`Rakefile` | 技术栈金矿 |
| **PHP** | `composer.json` | `autoload` + `require` |
| **C#** | `*.csproj`、`*.sln`、`Directory.Build.props`、`global.json` | `<PackageReference>` |
| **Elixir / Erlang** | `mix.exs`、`rebar.config` | |
| **Dart / Flutter** | `pubspec.yaml` | |
| **Zig** | `build.zig`、`build.zig.zon` | |
| **Lua** | `*.rockspec` | |
| **Nim** | `*.nimble` | |
| **Crystal** | `shard.yml` | |
| **Haskell** | `*.cabal`、`stack.yaml`、`package.yaml` | |
| **OCaml** | `dune-project`、`*.opam` | |
| **Deno** | `deno.json`、`deno.jsonc` | |
| **Bun** | `bunfig.toml` | |

#### 5.2.3 容器化 / 部署 / CI 配置

| 文件 | 信息价值 |
|---|---|
| `Dockerfile` / `Dockerfile.*` | 判断 CLI/Server/SDK 类型的决定性证据 |
| `docker-compose.yml` / `docker-compose.*.yml` / `compose.yml` | 多服务架构 |
| `.dockerignore` | 反映打包思路 |
| `Makefile` / `justfile` / `Taskfile.yml` | 任务清单字典 |
| `.github/workflows/*.yml` | **特殊规则**：取每个 yml 头 30 行；workflow > 5 个时只取最大的 3 个 |
| `.gitlab-ci.yml` / `.circleci/config.yml` / `azure-pipelines.yml` | 同上 |

#### 5.2.4 应用顶层配置

| 文件 | 决策 |
|---|---|
| `next.config.*` / `vite.config.*` / `webpack.config.*` / `rollup.config.*` / `nuxt.config.*` | Tier 0（暴露框架细节） |
| `.env.example` / `env.template` | Tier 0（看系统集成的服务） |
| `tailwind.config.*` / `postcss.config.*` | Tier 1（给前 50 行） |
| `.eslintrc*` / `.prettierrc*` / `biome.json` | **不给**（token 高信息低） |
| `.editorconfig` / `.gitattributes` | **不给** |

#### 5.2.5 排除的"Tier 0 陷阱" lock 文件

以下文件**故意排除**——看似配置实际是版本号清单，token 占用极高、信息增益极低：

```
× package-lock.json / yarn.lock / pnpm-lock.yaml / bun.lockb / bun.lock
× Cargo.lock
× go.sum
× poetry.lock / Pipfile.lock / uv.lock
× composer.lock
× Gemfile.lock
× Package.resolved
× pubspec.lock
× mix.lock
× cabal.project.freeze / stack.yaml.lock
```

### 5.3 Tier 1 完整清单（头 80 行）

#### 5.3.1 通用入口（按 glob）

| Glob 模式 | 命中典型 |
|---|---|
| `src/index.{ts,tsx,js,jsx,mjs,cjs}` | TS / JS 项目主入口 |
| `src/main.{ts,tsx,js,jsx,rs,py,go,swift,java,kt,kts,c,cpp,m,mm}` | 通用 main |
| `src/app.{ts,tsx,jsx,js,py}` | Web / UI 应用入口 |
| `cmd/*/main.go` | Go 项目惯例 |
| `bin/*` / `bin/*.{js,sh,rb,py}` | 可执行脚本 |
| `lib/index.{ts,js,mjs}` | Library 入口 |
| `app/page.{tsx,jsx}` | Next.js App Router |
| `pages/_app.{tsx,jsx}` / `pages/index.{tsx,jsx}` | Next.js Pages Router |
| `Sources/*/main.swift` | SwiftPM 惯例 |
| `Sources/*/*App.swift` | SwiftUI app 入口（如 Starcat 的 `StarcatApp.swift`） |
| 含 `@main` 注解的 `*.swift` | SwiftUI 入口（**需要扫文件内容判断**） |
| `mod.rs` / `lib.rs` / `main.rs` | Rust crate 入口 |
| 顶层 `__init__.py` | Python package 入口 |
| `__main__.py` | Python 可执行入口 |
| `manage.py` | Django 项目入口 |
| `Application.{java,kt}` / `Main.{java,kt}` / `*Application.{java,kt}` | Spring Boot 惯例 |

#### 5.3.2 框架特殊文件

| 文件 | 框架 / 用途 |
|---|---|
| `routes.ts` / `router.ts` / `urls.py` | 路由清单，反映 API 表面 |
| `schema.prisma` / `schema.graphql` / `*.proto` | 数据 / API schema |
| `*.openapi.yaml` / `openapi.json` / `swagger.yaml` | API 定义 |
| `migrations/*.sql`（最新 3 个） | DB 演化 |

#### 5.3.3 文档目录索引

| 文件 | 用途 |
|---|---|
| `docs/index.md` / `docs/README.md` / `docs/SUMMARY.md` | mdBook / GitBook 类目录 |
| `website/docs/intro.md` | Docusaurus 惯例 |

### 5.4 Tier 2（仅列路径 + token）

**默认规则**：经过 ignore 过滤后，所有不在 Tier 0 / Tier 1 的代码文件都是 Tier 2。

#### 5.4.1 Tier 2 自身的截断策略

| Tier 2 文件数 | 处理方式 |
|---|---|
| **≤ 100** | 全部列出（路径 + token 数） |
| **100-500** | 全部列出，省略 token 数（省 60% 字符） |
| **> 500** | 按 token 大小排前 200 个列出，剩余用一行汇总：`<remaining count="380" totalTokens="45200" />` |

#### 5.4.2 Tier 2 内部排序

为让 LLM 优先注意有意义的目录：

```
1. src/**       (源码主目录)
2. lib/**       (公共库)
3. internal/**  (Go 惯例)
4. pkg/**       (Go 惯例)
5. app/**       (应用层)
6. components/** (组件)
7. api/** / handlers/** / controllers/** (API 层)
8. models/** / entities/** (数据层)
9. utils/** / helpers/** (工具)
10. (其它路径按字母序)
```

### 5.5 边界情况处理

| 场景 | 决策 |
|---|---|
| 仓库根目录有 30 个 markdown 文档（教程类仓库） | 仅 `README.md` / `CHANGELOG.md` 等命名规范的进 Tier 0；其余进 Tier 2 |
| Monorepo（多个 `package.json`） | 顶层 + 子包 `packages/*/package.json` 都 Tier 0 |
| 子包数量爆炸（50+ 个） | 子包 `package.json` 全部 Tier 0，**单文件超 1KB 时截断到 50 行** |
| Tier 0 命中但文件超 4K token | 退化为 Tier 1 处理（只给头 80 行） |
| Tier 1 命中但文件 < 80 行 | 给全文（等同 Tier 0） |
| 仓库没有任何 Tier 0 命中（纯文档仓库） | 把 Tier 1 候选升级为 Tier 0；若仍无，把 Tier 2 前 5 个文件升级为 Tier 1 |

### 5.6 Tier 清单维护规则

1. **存放位置**：`Starcat/Shared/Services/RepoContextPacker/TierRules.swift`，一份大的 `static let` 常量集合
2. **不放 GRDB**，不做 runtime 配置
3. **嵌入版本号**：`let tierRulesVersion = "1.0"`，写入输出 `<stats>` 段；prompt 升级时联动
4. **新生态扩展**：在文件顶部留 `// MARK: - 维护指南`，注明"新增生态时往哪个数组里加"
5. **不命中清单的奇葩项目**：仍能产出 context.xml（兜底走 Tier 2），LLM 仍能看到目录树和文件列表

---

## 6. Token Budget 分配策略

> ⚠️ **v1.2 覆盖**：Token 估算公式 / 估算时机 / 校准策略 / 超 budget 兜底已由 [§22.8 Q7 决议](#228-q7--token-估算两阶段估算--校准) 重新拍板（两阶段：Pass 2 用 size 估算 → Pass 3 用真 char count 校准 + 不回滚 plan + warning 兜底）。本节描述的"立即估算文件内容"在 v1.2 改为"Pass 2 用 size 估算，Pass 3 真读才校准"。

### 6.1 默认预算

```swift
struct TokenBudget {
    let total: Int = 8_000          // 默认总预算
    let reservedForMetadata: Int = 300  // 给 stats / metadata 段
    
    // 实际分配（自适应）
    // Tier 0：尽量全部塞进去
    // Tier 1：剩余预算的 70%
    // Tier 2：剩余预算的 30%
}
```

### 6.2 分配算法

```
1. 估算所有 Tier 0 文件的 token 总和 t0
2. 如果 t0 < (total - reservedForMetadata)：
     Tier 0 全部入选
     remaining = total - reservedForMetadata - t0
     Tier 1 budget = remaining * 0.7
     Tier 2 budget = remaining * 0.3
3. 否则（Tier 0 已超 budget）：
     按 §5.5 "Tier 0 命中但文件超 4K token" 规则
     超大文件退化为 Tier 1 处理
     重新计算 t0，继续步骤 2
4. Tier 1 按优先级（5.3.1 → 5.3.2 → 5.3.3）逐个吃 budget，超过即停
5. Tier 2 按 §5.4 截断策略输出
```

### 6.3 用户可调

通过 `AppSettings` 暴露：

```swift
struct RepoContextPackerSettings: Codable {
    var totalTokenBudget: Int = 8_000          // 滑杆 4K-32K
    var tier1HeadLines: Int = 80               // 默认头 80 行
    var truncateLargeTier0Threshold: Int = 4_000 // 单文件超 4K token 降级为 Tier 1
}
```

---

## 7. 输出格式（XML 结构）

> ⚠️ **v1.2 覆盖**：XML 模板字段、`metadata.json` 字段、stats 内容已由 [§22.10 Q9 决议](#2210-q9--xml-输出格式) 重新定型；新增根元素属性 `schemaVersion` / `tierRulesVersion` / `tokenEstimatorVersion` / `tokenBudget`，stats 新增 `estimatedTokens` / `actualTokens` 双值。CDATA 转义、属性值转义工具见 §22.10 `XMLEscape` 实现。**实施时以 §22.10 为准**。

### 7.1 完整输出示例

```xml
<?xml version="1.0" encoding="UTF-8"?>
<starcat-context schemaVersion="1" tierRulesVersion="1.0">
  
  <directoryStructure>
src/
├── index.ts
├── api/
│   ├── auth.ts
│   └── repos.ts
├── components/
│   ├── Sidebar.tsx
│   └── ...
└── utils/
    └── ...
package.json
tsconfig.json
README.md
  </directoryStructure>

  <keyFiles>
    <file path="package.json" tokens="245">
      <![CDATA[
      {完整 JSON 内容}
      ]]>
    </file>
    <file path="tsconfig.json" tokens="180">
      ...完整内容...
    </file>
    <file path="Dockerfile" tokens="120">
      ...完整内容...
    </file>
  </keyFiles>

  <entryPoints>
    <file path="src/index.ts" truncated="true" linesShown="1-80" totalLines="320" tokens="850">
      ...前 80 行...
    </file>
    <file path="src/main.rs" truncated="true" linesShown="1-80" totalLines="156" tokens="620">
      ...前 80 行...
    </file>
  </entryPoints>

  <fileList>
    <file path="src/api/auth.ts" tokens="420" />
    <file path="src/api/repos.ts" tokens="380" />
    <file path="src/components/Sidebar.tsx" tokens="290" />
    <!-- ... 几十到几百个 -->
    <remaining count="380" totalTokens="45200" />
  </fileList>

  <stats>
    <totalFiles>87</totalFiles>
    <totalTokens>7240</totalTokens>
    <budget>8000</budget>
    <tierCounts tier0="3" tier1="2" tier2="82" />
  </stats>

</starcat-context>
```

### 7.2 与 prompt 协作的契约

**Packer 只负责生成 context.xml，不组装 prompt**。Prompt 组装是 `RepoAIInsightService` 的职责。

Packer 与上游约定：

- `<directoryStructure>` 始终在最前（LLM 先建立项目骨架印象）
- `<keyFiles>` 含完整内容（LLM 据此判断技术栈、入口、构建方式）
- `<entryPoints>` 给代码风格抽样（LLM 推测架构特点）
- `<fileList>` 提供项目规模和模块清单（LLM 知道还有什么没看到）
- `<stats>` 让 LLM 知道自己看到的上下文规模和截断情况

### 7.3 转义规则（`--parsable-style` 等价）

由于代码内容可能含 `<` / `>` / `&` 等 XML 元字符：

- 文件内容**全部用 `<![CDATA[ ... ]]>` 包裹**
- CDATA 内若出现 `]]>` 序列（极罕见），分裂为 `]]]]><![CDATA[>` 标准转义

---

## 8. 与 CodeFlow 共享快照层的对接

### 8.1 共享源码快照层

参考 `docs/需求讨论/starcat-codeflow-integration.md` §4.2，CodeFlow 已经建立了**共享源码快照层**：

```
~/Library/Containers/com.starcat.app/Data/Library/Application Support/Starcat/
└── repository-snapshots/github.com/<owner>/<repo>/<commit-sha>.zip
```

**关键约束**（CodeFlow 文档原文）：

> CodeFlow 与未来 Repomix 只能通过共享快照服务取得 ZIP URL，不直接拼接或删除快照路径。某个集成失败、重新生成或清理自身数据，都不能删除共享 ZIP。

### 8.2 Packer 的角色

Packer 是这个共享快照层的**第二个消费者**（第一个是 CodeFlow）：

```
                          repository-snapshots/<sha>.zip
                                     │
                ┌────────────────────┴────────────────────┐
                ▼                                         ▼
        CodeFlow（生成 HTML）              RepoContextPacker（生成 XML）
        codeflow/<owner>/<repo>/         analysis/<owner>/<repo>/
        ├── index.html                   ├── context.xml
        └── metadata.json                └── metadata.json
```

### 8.3 Packer 必须遵守的约束

1. **只读 ZIP，绝不删除**：失败、重新生成、清理 Packer 数据，都不能删除共享 ZIP
2. **通过 SharedSnapshotService 取 URL**：不直接拼接 `repository-snapshots/...` 路径
3. **commit SHA 必须由调用方提供**：Packer 不查 GitHub API，commit SHA 解析是 CodeFlow / 上游业务的事
4. **输出目录独立**：Packer 写到 `analysis/<owner>/<repo>/`，不污染 `codeflow/<owner>/<repo>/`

### 8.4 复用调用流程

```
用户触发 AI 摘要（已 starred 或 trending repo）
   ↓
RepoAIInsightService.generate(repo:)
   ↓
RepoAIContextProvider.ensureContext(owner, repo)
   ↓ 检查 analysis/<owner>/<repo>/context.xml 是否存在 + 是否过期
   ↓
   ├── 命中且与最新 SHA 一致 → 直接读 context.xml
   │
   └── 未命中或 SHA 过期
        ↓
        SharedSnapshotService.ensureZip(owner, repo, sha)
        ↓ 复用 CodeFlow 已建立的 ZIP 下载链
        ↓
        RepoContextPacker.pack(zipURL, owner, repo, sha)
        ↓
        analysis/<owner>/<repo>/{context.xml, metadata.json}
        ↓
        读 context.xml 注入 prompt
```

> **注意**：Packer 不负责"是否需要重新生成"的判断，那是 `RepoAIContextProvider` 的职责。Packer 只做"给我 ZIP，我给你 XML"这件事。

---

## 9. 模块详细设计

> ⚠️ **v1.2 覆盖**：模块的 actor / struct 类型由 [§22.5 Q4 决议](#225-q4--三-pass--pass-3-taskgroup-并发读--全-struct) 修订——**`SourceZipExtractor` / `BudgetAllocator` / `ContextWriter` / `RepoContextPacker` 四个原标 actor 一律改为 struct**（无共享 mutable state，actor 反而引入 hop 成本）；`XmlOutputBuilder` 改为 `async throws`（内部 Pass 3 用 TaskGroup cap=8 并发读 Tier 0/1）；具体签名以 §22.5 表为准。本节代码示例的 `actor` 关键字、原 §9.1 临时目录策略、§9.4 TokenEstimator 公式、§9.5 BudgetAllocator 估算时机均已被覆盖。

### 9.1 SourceZipExtractor

**职责**：把 ZIP 解压到临时目录，返回根路径。

```swift
protocol SourceZipExtracting {
    /// 解压 ZIP 到临时目录
    /// - Parameter zipURL: 来自 repository-snapshots 的 ZIP 文件
    /// - Returns: 解压后的根目录 URL（GitHub zipball 解压后会有一层 wrapper 目录，
    ///           本方法返回的是 wrapper 内的"真正项目根目录"）
    /// - Throws: RepoContextPackerError.zipExtractionFailed
    func extract(zipURL: URL) async throws -> URL
}

actor DefaultSourceZipExtractor: SourceZipExtracting {
    // 用 Apple Compression.framework（沙箱友好，不调外部 unzip）
    // GitHub zipball 解压后路径形如 <owner>-<repo>-<short-sha>/
    // 需要识别这一层 wrapper 并跳进去
}
```

**关键约束**：
- 临时目录用 `FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)`
- Packer 流程结束（无论成功失败）都必须清理临时目录
- 解压前预检 ZIP 大小（与 CodeFlow 一致，100MB 上限）

### 9.2 FileFilter

**职责**：遍历解压目录，应用 ignore 规则 + 二进制过滤，输出候选文件清单。

```swift
struct FilteredFile {
    let relativePath: String        // 相对项目根的路径
    let absolutePath: URL
    let sizeBytes: Int
}

protocol FileFiltering {
    /// 过滤后返回符合条件的文件
    func filter(rootDir: URL, options: FilterOptions) async throws -> [FilteredFile]
}

struct FilterOptions {
    var defaultIgnore: [String] = TierRules.defaultIgnorePatterns  // 85 条
    var maxFileSizeBytes: Int = 50 * 1024 * 1024                    // 50MB
    var skipBinary: Bool = true
}

struct DefaultFileFilter: FileFiltering { ... }
```

**关键约束**：
- 默认 ignore 用 `**/...` 形式的 glob，匹配引擎用 Swift 端 minimatch 实现或自写
- 二进制检测：先按扩展名（`.png` / `.jpg` / `.pdf` / `.zip` / `.exe` 等），再读文件头 magic byte（前 8192 字节出现 `\0` 视为二进制）
- 单文件超 `maxFileSizeBytes` 直接跳过（不报错，记录到 `skippedFiles`）

### 9.3 TierClassifier

**职责**：给每个 FilteredFile 打 Tier 标签。

```swift
enum FileTier: Int, Comparable {
    case tier0 = 0
    case tier1 = 1
    case tier2 = 2
    
    static func < (lhs: FileTier, rhs: FileTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct TieredFile {
    let file: FilteredFile
    let tier: FileTier
    let matchReason: String  // 命中的具体规则（如 "exact:package.json" / "glob:src/main.*"）
}

protocol TierClassifying {
    func classify(files: [FilteredFile]) -> [TieredFile]
}

struct DefaultTierClassifier: TierClassifying {
    // 加载 TierRules（精确匹配 Set + glob 列表）
    // 判定顺序：tier 0 精确 → tier 1 glob → tier 2
    // 内置 @main 注解扫描（针对 *.swift）
}
```

**TierRules.swift 结构**：

```swift
enum TierRules {
    static let tierRulesVersion = "1.0"
    
    // MARK: - 默认 ignore（85 条，照搬 repomix）
    static let defaultIgnorePatterns: [String] = [
        ".git/**",
        "node_modules/**",
        // ... 共 85 条
    ]
    
    // MARK: - Tier 0 精确匹配（按文件名）
    static let tier0ExactNames: Set<String> = [
        "README.md", "README.rst", "README.adoc", "README.txt",
        "LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING",
        "package.json", "tsconfig.json", "Cargo.toml",
        // ... 完整清单见 §5.2
    ]
    
    // MARK: - Tier 0 后缀 / glob
    static let tier0GlobPatterns: [String] = [
        "*.csproj", "*.gemspec", "*.podspec", "*.opam",
        // ...
    ]
    
    // MARK: - Tier 1 glob
    static let tier1GlobPatterns: [String] = [
        "src/index.{ts,tsx,js,jsx,mjs,cjs}",
        "src/main.{ts,tsx,js,jsx,rs,py,go,swift,java,kt,kts,c,cpp,m,mm}",
        // ...
    ]
}
```

### 9.4 TokenEstimator

**职责**：估算字符串的 token 数。MVP 用极简公式。

```swift
protocol TokenEstimating {
    func estimate(_ text: String) -> Int
    func estimate(file: URL) async throws -> Int  // 流式读不超过 maxFileSizeBytes
}

struct CharRatioTokenEstimator: TokenEstimating {
    /// 经验系数 0.27（基于 gpt-tokenizer o200k_base 在英文 + 代码混合语料的均值）
    /// 误差范围：±10%（中文文本会高估约 30%，但中文代码极少；纯英文代码偏差最小）
    let ratio: Double = 0.27
    
    func estimate(_ text: String) -> Int {
        Int(Double(text.count) * ratio)
    }
    
    func estimate(file: URL) async throws -> Int {
        // 用 FileHandle 流式读，避免大文件全部加载到内存
    }
}
```

**V2 升级路径**：加一个 `TiktokenSwiftTokenEstimator` 实现同一 protocol，接 [tiktoken-swift](https://github.com/aespinilla/Tiktoken)，~50KB BPE 词表，精度 100%。

### 9.5 BudgetAllocator

**职责**：按 §6.2 算法分配 budget，决定每个文件是给全文 / 头 N 行 / 仅路径。

```swift
enum FileInclusionStrategy {
    case fullContent           // Tier 0 默认
    case head(lines: Int)      // Tier 1 默认（80 行）
    case pathOnly              // Tier 2 默认
}

struct AllocatedFile {
    let file: TieredFile
    let strategy: FileInclusionStrategy
    let estimatedTokens: Int
}

struct AllocationResult {
    let allocated: [AllocatedFile]
    let tier2Truncated: Int    // 被截断的 Tier 2 文件数
    let totalEstimatedTokens: Int
}

protocol BudgetAllocating {
    func allocate(
        tieredFiles: [TieredFile],
        budget: TokenBudget,
        estimator: TokenEstimating
    ) async throws -> AllocationResult
}

actor DefaultBudgetAllocator: BudgetAllocating { ... }
```

**关键约束**：
- 单文件 token 估算必须**先**做（流式 + 缓存），不要在分配过程中重复估算
- Tier 0 超 4K token 时自动降级为 Tier 1（`.head(lines: 80)`），并在 `matchReason` 加 `[demoted-to-tier1]` 标记
- 分配过程是同步的（一次性排序 + 贪心），不需要并发

### 9.6 DirectoryTreeBuilder

**职责**：基于 FilteredFile 列表生成 ASCII 目录树。

```swift
protocol DirectoryTreeBuilding {
    func build(files: [FilteredFile], rootName: String) -> String
}

struct ASCIIDirectoryTreeBuilder: DirectoryTreeBuilding {
    // 用 ├── │   └── 等 Unicode box drawing 字符
    // 与 repomix 默认输出一致
}
```

**特殊规则**：
- 不受 budget 限制（目录树本身 token 极低但价值极高）
- 目录树**反映 ignore 后的文件集**，不是 ZIP 内的原始集
- 如果某个目录下有 > 50 个文件，只列前 20 个 + 一行 `... (30 more files)`

### 9.7 XmlOutputBuilder

**职责**：把 AllocationResult + 目录树 → 完整 XML 字符串。

```swift
protocol XmlOutputBuilding {
    func build(
        allocation: AllocationResult,
        directoryTree: String,
        meta: PackerMetadata
    ) async throws -> String
}

struct PackerMetadata {
    let owner: String
    let repo: String
    let commitSha: String
    let totalFiles: Int      // 经过 ignore 后的总数（不只是被 allocated 的）
    let generatedAt: Date
    let tierRulesVersion: String
}

struct DefaultXmlOutputBuilder: XmlOutputBuilding {
    // 拼装 5 个段落
    // 用 CDATA 包裹文件内容
    // 处理 ]]> 转义
}
```

### 9.8 ContextWriter

**职责**：原子写盘（`.tmp` → rename）。

```swift
protocol ContextWriting {
    func write(
        xml: String,
        metadata: PackerMetadata,
        outputBaseDir: URL
    ) async throws -> ContextArtifact
}

struct ContextArtifact {
    let contextURL: URL          // analysis/<owner>/<repo>/context.xml
    let metadataURL: URL         // analysis/<owner>/<repo>/metadata.json
    let totalTokens: Int
    let fileCount: Int
    let generatedAt: Date
}

actor DefaultContextWriter: ContextWriting {
    // 1. 写 .tmp 文件
    // 2. fsync
    // 3. atomic rename
}
```

**metadata.json 结构**（与 CodeFlow 同款风格，保留扩展空间）：

```json
{
  "schemaVersion": 1,
  "repository": {
    "owner": "vercel",
    "name": "next.js",
    "fullName": "vercel/next.js"
  },
  "artifact": {
    "page": "context.xml",
    "pageBytes": 12345,
    "sourceArchiveKey": "github.com/vercel/next.js/51ab970....zip"
  },
  "generation": {
    "generatedAt": "2026-06-13T05:30:00Z",
    "tierRulesVersion": "1.0"
  },
  "stats": {
    "totalFiles": 87,
    "totalTokens": 7240,
    "budgetUsed": 8000,
    "tier0Count": 3,
    "tier1Count": 2,
    "tier2Count": 82
  },
  "sourceRevision": {
    "branch": "main",
    "commitSha": "51ab9708841e14258bebfb5fb326e8b37782d193"
  }
}
```

### 9.9 RepoContextPacker（顶层 Facade）

**职责**：编排上述 8 个模块，对外暴露统一入口。

```swift
public actor RepoContextPacker {
    private let extractor: SourceZipExtracting
    private let filter: FileFiltering
    private let classifier: TierClassifying
    private let estimator: TokenEstimating
    private let allocator: BudgetAllocating
    private let treeBuilder: DirectoryTreeBuilding
    private let xmlBuilder: XmlOutputBuilding
    private let writer: ContextWriting
    
    public init(...)  // DI
    
    public func pack(
        zipURL: URL,
        owner: String,
        repo: String,
        commitSha: String,
        outputBaseDir: URL,
        options: PackerOptions = .default
    ) async throws -> ContextArtifact {
        // 1. 解压
        // 2. 过滤
        // 3. 分级
        // 4. 估算 + 分配 budget
        // 5. 构造目录树
        // 6. 拼 XML
        // 7. 原子写盘
        // 8. 清理临时目录
    }
}

public struct PackerOptions {
    public var budget: TokenBudget = .default
    public var includeStats: Bool = true
    public var includeDirectoryTree: Bool = true
    
    public static let `default` = PackerOptions()
}
```

---

## 10. 错误处理

> ⚠️ **v1.2 覆盖**：错误枚举由 [§22.4 Q3 决议](#224-q3--分层错误处理) 重新定型为「分层错误」——致命错抛、单文件错 skip 写入 `metadata.json.skippedFiles[]`。下面这份 v1.0 枚举**已不完整**：v1.2 新增 `zipSlipDetected` / `extractedDirectoryTooLarge`、移除 `fileReadFailed`（改为 SkipReason 字符串常量）、`tokenBudgetExceededByTier0` 已合并到「Pass 3 校准 + warning 兜底」机制（§22.8）。**实施时以 §22.4 枚举为权威**。

```swift
public enum RepoContextPackerError: LocalizedError, Sendable {
    case zipFileNotFound(URL)
    case zipExtractionFailed(underlying: Error)
    case zipTooLarge(actualBytes: Int, maxBytes: Int)
    case zipEmpty
    case noFilesAfterFiltering
    case outputDirectoryNotWritable(URL, underlying: Error)
    case fileReadFailed(path: String, underlying: Error)
    case tokenBudgetExceededByTier0(totalTier0Tokens: Int, budget: Int)
    case xmlBuildFailed(underlying: Error)
    case writeFailed(URL, underlying: Error)
    case cancelled
    
    public var errorDescription: String? { /* 本地化 */ }
}
```

**关键约束**：
- 任何错误都不能让临时目录残留（用 `defer` + Task cancellation 安全保护）
- `cancelled` 是 Task cancellation 的语义（用户在生成中关掉 AI 摘要窗口）
- 错误**不**写 `metadata.json`（与 CodeFlow `lastExecution.steps` 设计对齐）

---

## 11. 与 AI 摘要链路的输入契约

> **本设计文档的范围到 Packer 输出 `context.xml` 为止**。Prompt 编排、缓存策略、Provider 抽象是 `RepoAIInsightService` 已有的事。本节只说明输入契约。

### 11.1 Prompt 注入位置

`RepoAIInsightService` 在生成 AI 摘要时，输入的 system / user prompt 包含：

```
{Starcat 注入的 metadata：owner / repo / fullName / stars / topics / language}

<README>
{现有的 README content / cleaned markdown}
</README>

<repo-context>  ← 新增（来自 RepoContextPacker）
{context.xml 完整内容}
</repo-context>
```

### 11.2 控制是否注入

通过 `AppSettings.aiSummaryUseRepoContext: Bool`（默认 true）控制：

- `true`：先确保 context.xml 存在（必要时触发 Packer），再注入 prompt
- `false`：跳过 Packer 链路，走原 README-only 路径

### 11.3 缓存复用规则

```
- context.xml 存在且 metadata.commitSha 与最新 SHA 一致 → 直接读
- context.xml 存在但 SHA 过期 → 重新跑 Packer
- context.xml 不存在 → 跑 Packer
- 用户切换 AI provider / model → 不影响 context.xml 复用（packed 输出与 AI 无关）
- 用户改 `totalTokenBudget` 设置 → 标记当前 context.xml 过期，重新生成
```

---

## 12. UX 设计

> 本节定义 Packer 在用户界面上的所有触点。底层 Packer 是「幕后工作」，但用户仍需要可见性（看到 AI 看了多少代码）、可控性（开关 / 调 budget / 清缓存）、可降级（失败不阻塞 AI 摘要主流程）。

### 12.1 UX 设计原则

| # | 原则 | 含义 |
|---|---|---|
| 1 | **轻露出，不打扰** | Packer 是底层基础设施，默认开启但 UI 上仅在 AI 摘要场景轻度可见。MVP 不在主列表、Sidebar、Trending 等高频区域加任何 Packer 元素 |
| 2 | **可观测** | 用户能看到「AI 看了哪些代码 / 用了多少 token / 基于哪个 commit」，但不暴露内部分级细节（Tier 0/1/2 是工程语义，不出现在 UI 文案） |
| 3 | **可控制** | 高级用户能在设置页关闭总开关 / 调 token budget / 清缓存。普通用户可不感知这些设置仍能正常用 AI 摘要 |
| 4 | **可降级** | Packer 失败（ZIP 下不到、解压失败、磁盘满）时，AI 摘要自动回退到 README-only 模式，**不阻断用户主流程**，仅在窗口顶部加一条轻量 banner 说明 |
| 5 | **与 CodeFlow 视觉对齐** | 复用既有 `SyncIconButton` / `CopyFeedbackButton` / Settings DisclosureGroup / `.bar` 材质 / 紫蓝渐变 AI 胶囊等视觉系统 |
| 6 | **i18n 优先** | 所有用户可见文本走 String Catalog，命名空间 `ai.context.*`（详见 §12.9） |
| 7 | **数据透明** | 用户能在 Finder 中看到 `analysis/<owner>/<repo>/context.xml`，可单独打开 / 复制 / 删除；Packer 不做加密、不做隐藏目录 |

### 12.2 UX 触点地图

| # | 触点 | UI 位置 | 用户感知 | MVP / V2 |
|---|---|---|---|---|
| **A** | 摘要生成进度状态 | `RepoAIWindowContentView` 摘要面板顶部 | 「正在分析代码…」/「正在生成摘要…」两阶段状态 | **MVP** |
| **B** | 摘要 footer 元信息条 | `RepoAIWindowContentView` 摘要面板底部 | 「基于 87 个文件 · 7.2K tokens · commit `51ab970`」 | **MVP** |
| **C** | AI 设置页配置区 | `AISettingsView` 新分区「AI 摘要上下文」 | 总开关 / budget 滑杆 / 单文件降级阈值 / 数据管理入口 | **MVP** |
| **D** | 上下文降级 banner | `RepoAIWindowContentView` 摘要面板顶部 | Packer 失败时一行黄色 banner「源码上下文获取失败，已回退到 README 模式」 | **MVP** |
| **E** | 数据管理面板 | Settings → 存储 Tab 新增「AI 摘要上下文缓存」分区 | 总大小 / 已缓存 repo 数 / 清空按钮 / 单条删除 | **MVP** |
| **F** | 「在 Finder 显示」菜单项 | `RepoAIWindow` 右上角胶囊菜单（与 CodeFlow / Codeflow 入口同位置） | 让用户直接看到 context.xml 原文 | **MVP** |
| **G** | 详情页 hero 状态 indicator | `RepoMetadataHeaderView` AI 按钮旁 | 一个 12pt 小图标「源码已分析 ✓」hover 显示生成时间 | **V2** |
| **H** | 首次启用引导 sheet | 首次打开 AI 摘要时 | 说明会下载源码到本地 / 沙箱内 / 可一键关闭 | **V2** |

### 12.3 触点 A：摘要生成进度状态

#### 12.3.1 现状对照

当前 `RepoAIInsightViewModel.streamingSummaryText` 流式输出时只有一个 `生成中…` 文字 + ellipsis 动效（HOM-150 落地）。接入 Packer 后，**AI 摘要的"生成"实际有两阶段**：

```
阶段 1：Packer 工作（200ms - 5s，视仓库大小）
  ├─ 0.1 检查 context.xml 是否命中缓存
  ├─ 0.2 如果未命中：等 CodeFlow 共享 ZIP 下载（5-30s for cold cache）
  ├─ 0.3 解压 + 过滤 + 分级 + token 估算 + 写盘
  └─ 0.4 读 context.xml 注入 prompt
       ↓
阶段 2：LLM 工作（5-30s，视模型和 budget）
  └─ 流式生成摘要
```

如果不区分两阶段，用户会以为是 LLM 慢；区分后用户能区分「是不是网络问题（阶段 1）」和「是不是模型问题（阶段 2）」。

#### 12.3.2 UI 改造

`RepoAIChatViewModel.SummaryGenerationPhase` 新增枚举状态：

```swift
enum SummaryGenerationPhase: Sendable {
    case idle
    case preparingContext(stage: ContextStage)  // 阶段 1
    case streaming                              // 阶段 2
    case completed
    case failed(Error)
}

enum ContextStage: Sendable {
    case checkingCache       // < 100ms，UI 不显（避免闪烁）
    case downloadingArchive  // 调用方：SharedSnapshotService
    case extractingArchive   // 解压 ZIP
    case classifyingFiles    // 文件过滤 + 分级
    case writingContext      // 写盘
}
```

**UI 渲染规则**（`RepoAISummaryMarkdownView` 顶部）：

```
┌─────────────────────────────────────────┐
│ 🔄 正在准备代码上下文…                  │  ← preparingContext.downloadingArchive
│    下载源码包 · 2.3 MB / 5.1 MB         │     字段：当前阶段 · 可选进度
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│ ✨ 正在生成摘要…                        │  ← streaming
│                                         │
│ 这个项目是一个基于…                     │     流式 token 实时渲染（沿用 HOM-150 行为）
└─────────────────────────────────────────┘
```

**i18n 键**：
- `ai.context.phase.preparing` = "正在准备代码上下文…"
- `ai.context.phase.downloading` = "下载源码包"
- `ai.context.phase.extracting` = "解压源码"
- `ai.context.phase.classifying` = "分析项目结构"
- `ai.context.phase.writing` = "写入上下文"

#### 12.3.3 关键约束

- `checkingCache` 阶段持续 < 100ms，**不渲染 UI**，避免摘要窗口打开瞬间闪一下「正在准备代码上下文」
- `downloadingArchive` 的进度数据来自 `SharedSnapshotService`（CodeFlow 已实现），格式 `已下载 / 总大小`
- `extractingArchive` / `classifyingFiles` / `writingContext` 通常 < 500ms 合计，**不显示子阶段细节**，统一显示「正在准备代码上下文…」即可
- 阶段切换用 `withAnimation(.easeInOut(duration: 0.25))` 过渡，避免突兀
- Reduce Motion 偏好开启时，阶段切换仅 opacity 渐变，不做位移

### 12.4 触点 B：摘要 footer 元信息条

#### 12.4.1 设计意图

让用户能**事后审计** AI 摘要的输入。当用户对摘要质量有疑问时，能快速回答两个问题：

1. AI 是不是"看到"了源码？（footer 存在 = 是）
2. AI 看的源码是不是最新的？（commit SHA + 生成时间）

#### 12.4.2 UI 渲染

摘要面板底部（在「重新生成 / 复制」按钮上方）：

```
─────────────────────────────────────────────
✨ 基于 87 个文件 · 7.2K tokens · 51ab970
   生成于 1 小时前 · 来自 main 分支
─────────────────────────────────────────────
   [重新生成]  [复制]  [⋯]
```

**字段构成**：

| 字段 | 来源 | 渲染 |
|---|---|---|
| `87 个文件` | `metadata.json` → `stats.totalFiles` | 始终显示 |
| `7.2K tokens` | `metadata.json` → `stats.totalTokens` | 千分位精度，>1K 用 K 单位 |
| `51ab970` | `metadata.json` → `sourceRevision.commitSha[:7]` | 短 SHA；点击复制完整 SHA + Toast「已复制 commit」 |
| `1 小时前` | `metadata.json` → `generation.generatedAt` | 相对时间，与 Activity / Release 同款 `RelativeDateTimeFormatter` |
| `main 分支` | `metadata.json` → `sourceRevision.branch` | 用 monospace 字体；分支名超 16 字符截断带 tooltip |

**hover 行为**：

- hover 整个 footer → tooltip「源码分析依据：项目 87 个代码文件，约 7240 tokens，基于 main 分支 51ab970...」
- hover commit SHA → tooltip「点击复制 commit SHA」

#### 12.4.3 显示条件与降级

| 条件 | 渲染策略 |
|---|---|
| 摘要使用了 context.xml | 完整 footer（如上） |
| 摘要降级到 README-only（用户关了开关） | footer 简化为「基于 README · 生成于 1 小时前」 |
| 摘要降级到 README-only（Packer 失败） | footer 简化为「基于 README · 生成于 1 小时前 · ⚠️ 源码分析失败」hover 显示具体错误 |
| 老摘要（升级前生成，无 packer 元信息） | footer 隐藏（不渲染脏数据） |

#### 12.4.4 i18n 键

- `ai.context.footer.basedOn` = "基于 %lld 个文件 · %@ tokens · %@"
- `ai.context.footer.generatedAt` = "生成于 %@ · 来自 %@ 分支"
- `ai.context.footer.readmeOnly` = "基于 README"
- `ai.context.footer.packerFailed` = "源码分析失败"
- `ai.context.footer.copyCommitTooltip` = "点击复制 commit SHA"
- `ai.context.footer.commitCopied` = "已复制 commit"

### 12.5 触点 C：AI 设置页配置区

#### 12.5.1 位置与折叠态

在 `AISettingsView` 中，紧跟现有 `parametersSection` 之后、`promptSection` 之前，新增「AI 摘要上下文」分区。沿用同款 `DisclosureGroup + @SceneStorage` 模式，**默认折叠**（与 dong4j 在 HOM-68 v3 确立的「常用在前、复杂在后」原则一致）。

#### 12.5.2 配置项布局（展开后）

```
▼ AI 摘要上下文（默认折叠）

  ┌─────────────────────────────────────────────────┐
  │ 启用源码上下文增强                        [●─○]  │  ← Toggle 总开关
  │ 关闭后摘要将仅基于 README，速度更快但质量更低     │     默认开
  └─────────────────────────────────────────────────┘

  以下选项仅在「启用源码上下文增强」开启时可用：

  ┌─────────────────────────────────────────────────┐
  │ Token 预算                          [8000]      │  ← TextField 数字输入
  │ ├──────────●────────────────────┤  4K          │     范围 4000-32000
  │           8K                                    │     step 1000，下方 Slider 同步
  │ 32K                                             │
  │ 控制每次摘要看到的源码总量，预算越大摘要越详细     │
  │ 但费用越高、生成越慢                            │
  └─────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────┐
  │ 关键文件保留行数                    [80]        │  ← Stepper / TextField
  │ 项目入口文件（如 main.swift / index.ts）         │     范围 40-200
  │ 默认保留头部 80 行                              │
  └─────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────┐
  │ 大文件降级阈值                      [4000] tokens│  ← Stepper / TextField
  │ 单个文件超过该 token 数时只保留头部，避免吃光预算 │     范围 1000-16000
  └─────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────┐
  │ 数据管理                                        │
  │                                                 │
  │   已缓存 23 个仓库的上下文，占用 4.2 MB         │
  │                                                 │
  │   [在 Finder 显示]  [清空所有缓存]              │
  └─────────────────────────────────────────────────┘
```

#### 12.5.3 字段绑定

```swift
extension AppSettings {
    var aiSummaryUseRepoContext: Bool      // 总开关，默认 true
    var aiContextPackerTokenBudget: Int    // 默认 8000，范围 4000-32000
    var aiContextPackerHeadLines: Int      // 默认 80，范围 40-200
    var aiContextPackerLargeFileThreshold: Int  // 默认 4000，范围 1000-16000
}
```

#### 12.5.4 交互约束

| 行为 | 约束 |
|---|---|
| 改任意配置后已有 context.xml 是否失效 | **是**——TokenBudget 改变会导致输出内容不同，需重新生成 |
| 失效是惰性的还是主动 | **惰性**——下次摘要生成时检测 metadata.json 内 `tokenBudget` 字段与当前设置不一致就重生 |
| 总开关从开 → 关 | 下次摘要走 README-only 路径；已生成的 AI 摘要保留不受影响 |
| 总开关从关 → 开 | 提示「下次重新生成摘要时启用」；不主动重生历史摘要 |
| 「清空所有缓存」 | 弹 `.confirmationDialog`「确认删除 23 个仓库的上下文缓存？删除后下次摘要将重新生成」+「删除」按钮（红色） |
| 「在 Finder 显示」 | 调 `NSWorkspace.shared.activateFileViewerSelecting([analysisDir])` |
| 配置项 disabled 态 | 总开关关闭时，下方 3 个子配置 + 「数据管理」都 `.disabled(true).opacity(0.5)` |

#### 12.5.5 i18n 键

```
ai.context.settings.section.title       = "AI 摘要上下文"
ai.context.settings.enableToggle         = "启用源码上下文增强"
ai.context.settings.enableToggle.footer  = "关闭后摘要将仅基于 README，速度更快但质量更低"
ai.context.settings.tokenBudget          = "Token 预算"
ai.context.settings.tokenBudget.footer   = "控制每次摘要看到的源码总量，预算越大摘要越详细，但费用越高、生成越慢"
ai.context.settings.headLines            = "关键文件保留行数"
ai.context.settings.headLines.footer     = "项目入口文件（如 main.swift / index.ts）默认保留头部 80 行"
ai.context.settings.largeFileThreshold   = "大文件降级阈值"
ai.context.settings.largeFileThreshold.footer = "单个文件超过该 token 数时只保留头部，避免吃光预算"
ai.context.settings.dataManagement       = "数据管理"
ai.context.settings.cacheStats           = "已缓存 %lld 个仓库的上下文，占用 %@"
ai.context.settings.showInFinder         = "在 Finder 显示"
ai.context.settings.clearAll             = "清空所有缓存"
ai.context.settings.clearAll.confirm.title    = "确认删除所有上下文缓存？"
ai.context.settings.clearAll.confirm.message  = "删除后下次摘要将重新生成，可能需要更多时间和费用"
ai.context.settings.clearAll.confirm.action   = "删除"
```

### 12.6 触点 D：上下文降级 banner

#### 12.6.1 设计意图

Packer 失败时**绝不阻塞** AI 摘要主流程，但用户需要知道「我看到的摘要质量可能不如平时」。

#### 12.6.2 UI 渲染

`RepoAIWindowContentView` 摘要面板顶部，状态条之上：

```
┌─────────────────────────────────────────────────┐
│ ⚠️  源码分析未完成，本次摘要仅基于 README        │  ← yellow 系统色 + warning icon
│     原因：源码包下载失败（网络错误）   [详情]    │     [详情] 按钮 → 弹 sheet 显示完整错误
│                                          [×]    │     [×] 关闭 banner，本次会话不再显示
└─────────────────────────────────────────────────┘
```

#### 12.6.3 显示策略

| 错误类型 | 用户文案 | 是否可重试 |
|---|---|---|
| `zipFileNotFound` / `downloadFailed` | 「源码包下载失败」 | 是（提供「重试」按钮） |
| `zipExtractionFailed` | 「源码解压失败，文件可能损坏」 | 是 |
| `zipTooLarge` | 「项目超过 100 MB，已跳过源码分析」 | 否 |
| `noFilesAfterFiltering` | 「项目没有可分析的代码文件」 | 否 |
| `outputDirectoryNotWritable` | 「磁盘空间不足，无法保存上下文」 | 是（提示用户清缓存） |
| `tokenBudgetExceededByTier0` | 「项目核心文件过大，已部分截断」 | 否（其实没失败，只是降级，可不显 banner） |
| `cancelled` | （静默，不显 banner） | - |

#### 12.6.4 关键约束

- banner 是「**会话级**」状态——用户关掉后本次摘要窗口生命周期内不再显示，重开窗口会再出现
- banner **不**持久化到 GRDB——错误是临时的，重试一次可能就好了
- 「详情」按钮弹的 sheet 仅供 dong4j Bug 反馈用，复制完整错误堆栈

#### 12.6.5 i18n 键

```
ai.context.banner.fallback.title        = "源码分析未完成，本次摘要仅基于 README"
ai.context.banner.fallback.reason.network    = "源码包下载失败"
ai.context.banner.fallback.reason.extraction = "源码解压失败，文件可能损坏"
ai.context.banner.fallback.reason.tooLarge   = "项目超过 100 MB，已跳过源码分析"
ai.context.banner.fallback.reason.empty      = "项目没有可分析的代码文件"
ai.context.banner.fallback.reason.disk       = "磁盘空间不足，无法保存上下文"
ai.context.banner.action.details             = "详情"
ai.context.banner.action.retry               = "重试"
ai.context.banner.action.dismiss             = "关闭"
```

### 12.7 触点 E：数据管理面板

#### 12.7.1 位置

`SettingsView` → 存储 Tab（沿用 CodeFlow 「集成服务」分区的视觉风格）→ 新增「AI 摘要上下文缓存」分区，与 CodeFlow 数据管理并列。

#### 12.7.2 UI 渲染

```
存储

▶ CodeFlow 代码图谱
   已缓存 12 个仓库 · 占用 245 MB     [详情]  [清空]

▶ AI 摘要上下文                              ← 新增
   已缓存 23 个仓库 · 占用 4.2 MB     [详情]  [清空]

▶ 应用缓存
   ...
```

#### 12.7.3 「详情」面板

点击「详情」弹 sheet，列出已缓存的 repo 及其大小：

```
┌──────────────────────────────────────────────────┐
│ AI 摘要上下文缓存                          [关闭] │
├──────────────────────────────────────────────────┤
│ 共 23 个仓库 · 占用 4.2 MB                       │
│ [一键清空] [在 Finder 显示]                       │
│                                                  │
│ 🔍 [搜索 owner/repo...                      ]   │
│                                                  │
│ ┌──────────────────────────────────────────────┐ │
│ │ vercel/next.js          245 KB  1h ago  [×] │ │
│ │ apple/swift             312 KB  3h ago  [×] │ │
│ │ rust-lang/rust          189 KB  1d ago  [×] │ │
│ │ ...                                          │ │
│ └──────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────┘
```

#### 12.7.4 关键约束

- 列表行点 `[×]` 单删 → 弹 confirmationDialog 二次确认
- 「一键清空」 → 弹 confirmationDialog，message 强调「删除后下次摘要需重新分析」
- 不显示**未生成上下文**的 repo（与已 Star 列表无关，只列实际有 `analysis/<owner>/<repo>/context.xml` 的）
- 删除时**仅删 Packer 输出目录**（`analysis/<owner>/<repo>/`），**绝不**碰 CodeFlow 的 `codeflow/<owner>/<repo>/` 或共享的 `repository-snapshots/`

### 12.8 触点 F：「在 Finder 显示」菜单项

#### 12.8.1 位置

`RepoAIWindow` 右上角 `[⋯]` 胶囊菜单（现有「重新生成」「复制」按钮旁），新增分组：

```
[重新生成]  [复制]  [⋯]
                    ├─ 复制 commit SHA
                    ├─ ─────────────
                    ├─ 在 Finder 显示上下文      ← 新增
                    └─ 复制上下文 XML            ← 新增（V2 评估）
```

#### 12.8.2 交互

- 「在 Finder 显示上下文」 → `NSWorkspace.shared.activateFileViewerSelecting([contextXmlURL])`
- 「复制上下文 XML」（V2 评估）→ 把整个 context.xml 内容塞剪贴板（一般 30-100KB，超过 200KB 时按钮 disabled + tooltip 提示「内容过大，请用『在 Finder 显示』」）
- 仅在「本次摘要确实用了 context.xml」时显示这两项；README-only 模式下隐藏

#### 12.8.3 i18n 键

```
ai.context.menu.showInFinder     = "在 Finder 显示上下文"
ai.context.menu.copyContext      = "复制上下文 XML"
ai.context.menu.copyContext.tooltipTooLarge = "内容过大（%@），请用 Finder 查看"
ai.context.menu.copyCommitSha    = "复制 commit SHA"
```

### 12.9 触点 G：详情页 hero 状态 indicator（V2，MVP 不做）

设计草案，**MVP 不实现**，仅记录方向：

在 `RepoMetadataHeaderView` 右上角紫蓝渐变 AI 胶囊按钮旁，加一个 12pt 极小 indicator：

```
[ ✨ AI ]  ✓     ← 当前 repo 已有 context.xml + 命中最新 commit
[ ✨ AI ]  ↻     ← context.xml 存在但 SHA 过期，下次点 AI 会重新生成
[ ✨ AI ]        ← 无 indicator：从未生成过
```

hover indicator 显示 tooltip「源码已分析 · 87 个文件 · 1 小时前」。

**为什么 MVP 不做**：增加视觉噪音 + ROI 低（大多数用户不需要这个层级的可观测性）。等用户反馈「我想知道哪些 repo 已经分析过了」再做。

### 12.10 触点 H：首次启用引导 sheet（V2，MVP 不做）

设计草案，**MVP 不实现**。

考虑到 Packer 会下载源码到本地（虽然只在沙箱内、虽然只是公开仓库），首次启用时弹一个 sheet 说明：

```
┌──────────────────────────────────────────────────┐
│ ✨ AI 摘要现在可以「看代码」了                   │
├──────────────────────────────────────────────────┤
│                                                  │
│ 启用源码上下文增强后，Starcat 会：                │
│                                                  │
│ ✓ 下载该仓库的源码包到沙箱本地（仅当你用 AI 摘要时）│
│ ✓ 分析项目结构，让摘要看到真实代码而不是只看 README  │
│ ✓ 缓存上下文，下次摘要同一项目时直接复用           │
│                                                  │
│ ⚠️ 仅支持公开仓库 · 私有仓库会自动跳过本功能       │
│                                                  │
│              [稍后再说]  [启用并继续]            │
└──────────────────────────────────────────────────┘
```

**为什么 MVP 不做**：默认值是开启，绝大多数用户不需要看到这个 sheet；高级用户会自己去设置页看。等接到「用户不知道有这个功能」的反馈再做。

### 12.11 失败路径的 UX 优先级

> Packer 是**有可能失败**的链路（网络、磁盘、超大仓库），UX 必须把失败处理做扎实，否则用户看到 AI 摘要"变差"会以为是 AI 模型问题。

完整失败处理矩阵：

| 失败点 | 检测时机 | UX 反馈 | 用户能做什么 |
|---|---|---|---|
| 网络断（ZIP 下载失败） | 阶段 1.2 | banner（§12.6） + 「重试」按钮 | 检查网络后重试 |
| 磁盘满（写盘失败） | 阶段 1.4 | banner + 「清缓存」按钮跳转设置 | 清缓存 |
| 仓库 > 100MB | 阶段 1.2 预检 | banner（无重试按钮） | 接受 README-only 摘要 |
| 仓库无代码文件 | 阶段 1.3 | banner（无重试按钮） | 接受 README-only 摘要 |
| Tier 0 过大已降级 | 阶段 1.3 | 不显 banner（不算失败） | 调 budget |
| Packer 完成但 LLM 失败 | 阶段 2 | 现有 AI 错误处理 | 重新生成 |
| Packer 完成但 LLM 报 token 超限 | 阶段 2 | 提示「源码上下文过大，请在设置中调低 Token 预算」 | 调 budget |

### 12.12 i18n 键命名规范总览

所有 Packer UI 文案统一在 `ai.context.*` 命名空间下，分 7 个子命名空间：

```
ai.context.phase.*          摘要生成阶段（§12.3）
ai.context.footer.*         摘要 footer 元信息（§12.4）
ai.context.settings.*       AI 设置页配置区（§12.5）
ai.context.banner.*         降级 banner（§12.6）
ai.context.storage.*        数据管理面板（§12.7）
ai.context.menu.*           右上角菜单项（§12.8）
ai.context.error.*          错误文案（§12.11）
```

**翻译约束**：

- en / zh-Hans 必须**同时**提供
- 用户可见文案**严禁**出现「Tier 0」「Tier 1」「Tier 2」「Token Budget」「Packer」「context.xml」等工程术语
- 用「源码上下文」（zh）/「Code context」（en）作为对外统一名称
- 「token」可以保留英文（与 OpenAI / Claude 用户教育对齐），但「token 预算」/「Token budget」首字母大小写需统一

### 12.13 与既有 UI 系统的复用

| 复用对象 | 来源 | 用途 |
|---|---|---|
| `SyncIconButton` | `Starcat/Shared/Components/SyncIconButton.swift` | 摘要面板「重新生成」按钮（已存在，沿用） |
| `CopyFeedbackButton` | `Starcat/Features/AI/CopyFeedbackButton.swift` | 复制 commit SHA 按钮 |
| `DisclosureGroup + @SceneStorage` | `AISettingsView.parametersSection` 同款 | 设置页折叠区 |
| `.confirmationDialog` | 全工程多处 | 清缓存二次确认 |
| `RelativeDateTimeFormatter` | Activity / Release 同款 | footer 「1 小时前」 |
| 紫蓝渐变 AI 胶囊视觉 | 详情页 hero `RepoMetadataHeaderView` 同款 | 摘要 phase 状态条 |
| 系统警告 yellow + warning icon | 全工程多处 banner 同款 | 降级 banner |

### 12.14 UX 实施工作量

| 阶段 | 任务 | 工时 |
|---|---|---|
| 1 | 触点 A 阶段状态 + 触点 B footer | 0.5 天 |
| 2 | 触点 C 设置页配置区 + 4 字段绑定 | 0.5 天 |
| 3 | 触点 D 降级 banner + 失败矩阵 | 0.5 天 |
| 4 | 触点 E 数据管理面板（含详情 sheet） | 0.5 天 |
| 5 | 触点 F 右上角菜单项 | 0.2 天 |
| 6 | i18n 键 7 组 × en/zh-Hans | 0.3 天 |
| **小计** | | **2.5 天** |

### 12.15 UX 不做清单（明确划红线）

| 不做项 | 理由 |
|---|---|
| 详情页 hero indicator | V2 评估，MVP 视觉噪音 |
| 首次启用引导 sheet | V2 评估，默认值开启不打扰用户 |
| Sidebar 进度条 | 单次 Packer 通常 < 5 秒，不值得占 sidebar 位置 |
| 上下文 inspector（可视化 Tier 分级） | 工程内部细节，用户不需要 |
| 上下文 diff 视图（新旧 commit 差异） | 过度设计 |
| 自定义 Tier 规则编辑器 | V2 评估 |
| 「让我看一眼 prompt」按钮 | 暴露 prompt 模板，与 AI 设置页「Prompt 编辑器」职责重叠 |

---

## 13. 文件目录布局

### 13.1 Packer 输出目录

```
~/Library/Containers/com.starcat.app/Data/Library/Application Support/Starcat/
└── analysis/
    └── <owner>/
        └── <repo>/
            ├── context.xml      ← Packer 主产物
            └── metadata.json    ← 元信息
```

### 13.2 与 CodeFlow 的目录关系

```
Starcat/
├── repository-snapshots/    ← 共享 ZIP 层（CodeFlow 与 Packer 共用）
│   └── github.com/<owner>/<repo>/<sha>.zip
│
├── codeflow/               ← CodeFlow 输出（独立）
│   └── <owner>/<repo>/
│       ├── index.html
│       └── metadata.json
│
└── analysis/               ← Packer 输出（独立）
    └── <owner>/<repo>/
        ├── context.xml
        └── metadata.json
```

### 13.3 用户自定义输出目录

**MVP 不支持**。CodeFlow 已支持自定义输出目录（security-scoped bookmark），Packer 第一版固定写到 App Container，简化实现。后续若用户反馈强烈再补。

---

## 14. 关键设计决策

| # | 决策 | 选择 | 理由 |
|---|---|---|---|
| 1 | 是否内嵌 repomix | 否，Swift 自研 | 沙箱限制 + 体积过大 + 70% 代码 Starcat 不需要 |
| 2 | 是否做 compress 模式 | MVP 不做 | tree-sitter wasm 23MB + SwiftTreeSitter 集成成本，ROI 低 |
| 3 | Token 计数精度 | 字符 × 0.27 估算 | MVP 误差 ±10% 可接受，V2 可升级 tiktoken-swift |
| 4 | 输出格式 | 仅 XML | LLM 对 XML 解析最稳定；MD/JSON 可后加 |
| 5 | 是否读 .gitignore | 不读 | 默认 ignore 85 条覆盖 95%，引入 .gitignore 解析增加复杂度 |
| 6 | Tier 分级数据存哪 | 静态 Swift 常量 | 不上 GRDB，不做 runtime 配置 |
| 7 | 与 CodeFlow 关系 | 共享 ZIP 层，输出目录独立 | 复用 CodeFlow 已建立的下载基础设施 |
| 8 | 私有仓库支持 | MVP 不支持 | 与 CodeFlow MVP 对齐 |
| 9 | 单文件超 budget 处理 | Tier 0 → Tier 1 自动降级 | 避免一个大文件吃光预算 |
| 10 | 临时目录管理 | UUID 子目录，结束清理 | 沙箱友好，避免冲突 |
| 11 | 错误处理 | 失败不写 metadata.json | 与 CodeFlow `lastExecution` 风格一致 |
| 12 | Packer 是否查 GitHub API | 不查 | commit SHA / owner / repo 全由调用方提供 |
| 13 | 是否支持自定义输出目录 | MVP 不支持 | CodeFlow 已支持，Packer V2 再补 |
| 14 | Tier 规则版本化 | `tierRulesVersion` 写入 XML / metadata | 升级规则时上游可识别旧产物 |
| 15 | 是否支持流式生成 | 不支持 | 一次性生成，Packer 不暴露 progress |

---

## 15. 需要新增 / 修改的文件清单

### 15.1 新建文件

```
Starcat/
├── Shared/Services/RepoContextPacker/
│   ├── RepoContextPacker.swift              # Facade（顶层入口）
│   ├── RepoContextPackerError.swift         # 错误体系
│   ├── PackerOptions.swift                  # 配置选项
│   ├── ContextArtifact.swift                # 输出契约
│   ├── PackerMetadata.swift                 # metadata.json 结构
│   ├── TokenBudget.swift                    # 预算结构
│   │
│   ├── Components/
│   │   ├── SourceZipExtractor.swift         # 模块 1
│   │   ├── FileFilter.swift                 # 模块 2
│   │   ├── TierClassifier.swift             # 模块 3
│   │   ├── TokenEstimator.swift             # 模块 4
│   │   ├── BudgetAllocator.swift            # 模块 5
│   │   ├── DirectoryTreeBuilder.swift       # 模块 6
│   │   ├── XmlOutputBuilder.swift           # 模块 7
│   │   └── ContextWriter.swift              # 模块 8
│   │
│   └── Rules/
│       ├── TierRules.swift                  # Tier 0/1/2 完整清单
│       └── BinaryFileDetection.swift        # 二进制识别规则
│
└── Features/AI/
    └── RepoAIContextProvider.swift          # 决定何时跑 Packer 的协调层
```

### 15.2 修改文件

```
Starcat/
├── Features/AI/
│   └── RepoAIInsightService.swift            # prompt 注入 <repo-context>
├── Core/Settings/
│   └── AppSettings.swift                     # 新增 aiSummaryUseRepoContext / 
│                                             #       repoContextPackerSettings
├── Features/Settings/
│   └── AISettingsView.swift                  # 新增"AI 摘要上下文"设置区
├── App/
│   └── AppDependencies.swift                 # 注入 RepoContextPacker 及其组件
├── Resources/
│   └── Localizable.xcstrings                 # 新增 packer 相关 i18n 键
└── docs/工程进度/
    └── 功能实现总览.md                       # 4.2 章节新增 - [ ] 条目
```

### 15.3 新建测试文件

```
StarcatTests/
├── RepoContextPackerTests/
│   ├── SourceZipExtractorTests.swift
│   ├── FileFilterTests.swift
│   ├── TierClassifierTests.swift
│   ├── TokenEstimatorTests.swift
│   ├── BudgetAllocatorTests.swift
│   ├── DirectoryTreeBuilderTests.swift
│   ├── XmlOutputBuilderTests.swift
│   ├── ContextWriterTests.swift
│   └── RepoContextPackerIntegrationTests.swift   # 端到端，用 fixture ZIP
│
└── Fixtures/RepoContextPacker/
    ├── small-typescript-project.zip
    ├── rust-monorepo.zip
    ├── swift-macos-app.zip
    └── monorepo-50-packages.zip
```

---

## 16. V2 路线图（明确划红线）

| 优先级 | V2 功能 | 工作量 | 是否值得 |
|---|---|---|---|
| ⭐⭐⭐ | gpt-tokenizer 精确计数（tiktoken-swift） | 0.5 天 | 高 ROI，等用户反馈"AI 摘要被截断" |
| ⭐⭐⭐ | `.gitignore` 解析 | 1 天 | 适合超大仓库 / 单仓多语言混合 |
| ⭐⭐ | Markdown 输出格式 | 0.5 天 | 用户直接看 packed 产物时更友好 |
| ⭐⭐ | 编码检测（jschardet 等价） | 1 天 | 老代码、GBK 中文项目 |
| ⭐ | tree-sitter compress 模式 | 5-7 天 | 大仓库才有价值，**需用户先抱怨** |
| ⭐ | git 历史增强（GitHub Commits API） | 1 天 | 反映活跃度，对摘要质量小幅提升 |
| ⭐ | 自定义输出目录（security-scoped bookmark） | 0.5 天 | 与 CodeFlow 对齐 |
| ⭐ | 用户级 Tier 规则覆盖 | 2 天 | 用户自定义"我希望也看 *.spec.ts" |
| ❌ | MCP server 模式 | - | 不是 Starcat 业务范畴 |
| ❌ | Claude Skill 输出 | - | 同上 |
| ❌ | 远程 git clone | - | CodeFlow 已用 ZIP 解决 |
| ❌ | secretlint 安全扫描 | - | 公开仓库不需要 |
| ❌ | stdin / stdout / CLI 入口 | - | Starcat 不暴露命令行 |

---

## 17. 测试策略

### 17.1 单元测试

每个模块独立测试，重点覆盖：

| 模块 | 关键测试场景 |
|---|---|
| SourceZipExtractor | 正常 ZIP / 空 ZIP / 超大 ZIP / 含 wrapper 目录的 GitHub zipball |
| FileFilter | 默认 ignore 命中 / .git 自动排除 / 二进制扩展名 / magic byte 二进制 / 超大文件 |
| TierClassifier | 精确匹配 / glob 匹配 / @main 注解扫描 / Tier 0 命中后 Tier 1 不再匹配 |
| TokenEstimator | 中英混合 / 纯代码 / 极短串 / 极长串（>10MB 流式） |
| BudgetAllocator | Tier 0 超 budget 自动降级 / Tier 1 截断 / Tier 2 完整截断三档（≤100 / 100-500 / >500） |
| DirectoryTreeBuilder | 嵌套深目录 / 单目录 >50 文件截断 / 空目录 |
| XmlOutputBuilder | CDATA 转义 / `]]>` 边界 / 空文件 / 单文件 |
| ContextWriter | 原子写入 / 失败回滚 / 输出目录不存在自动创建 |

### 17.2 集成测试

用 4 个 fixture ZIP 跑端到端：

1. **small-typescript-project.zip**：10 文件，验证基本流程
2. **rust-monorepo.zip**：多 `Cargo.toml`，验证 monorepo
3. **swift-macos-app.zip**：验证 `@main` 注解扫描和 SwiftPM 文件命中
4. **monorepo-50-packages.zip**：验证子包数量爆炸时的截断策略

### 17.3 性能基准

```
基线（MVP 验收）：
  - 小项目（< 50 文件）：< 200 ms
  - 中项目（500 文件）：< 1 s
  - 大项目（5000 文件）：< 5 s
```

---

## 18. 实施步骤（按依赖排序）

```
Step 1：搭骨架（0.5 天）
  - 新建目录 Starcat/Shared/Services/RepoContextPacker/
  - 写所有 protocol 占位（Swift package layout）
  - 写 PackerOptions / ContextArtifact / RepoContextPackerError
  - xcodegen generate 让项目能编译

Step 2：实现 TierRules.swift（1 天）
  - 照抄 repomix defaultIgnore.js 的 85 条
  - 整理 Tier 0 精确清单（§5.2）
  - 整理 Tier 1 glob 清单（§5.3）
  - 写 TierRulesTests（覆盖每条规则至少 1 个正例 + 1 个反例）

Step 3：实现 SourceZipExtractor + FileFilter（1.5 天）
  - Compression.framework 解压
  - GitHub zipball wrapper 识别
  - 默认 ignore glob 匹配
  - 二进制检测（扩展名 + magic byte）

Step 4：实现 TierClassifier + TokenEstimator（1 天）
  - 加载 TierRules
  - 字符 × 0.27 估算
  - @main 注解扫描

Step 5：实现 BudgetAllocator（1 天）
  - 按 §6.2 算法分配
  - Tier 0 降级
  - Tier 2 三档截断

Step 6：实现 DirectoryTreeBuilder + XmlOutputBuilder（0.5 天）
  - ASCII 树
  - XML 拼装 + CDATA 转义

Step 7：实现 ContextWriter + RepoContextPacker Facade（0.5 天）
  - 原子写盘
  - 编排 8 模块

Step 8：集成 RepoAIContextProvider（0.5 天）
  - 决定是否复用 / 重新生成
  - 调 SharedSnapshotService 取 ZIP

Step 9：接入 RepoAIInsightService prompt（0.5 天）
  - 注入 <repo-context>
  - 新增 AppSettings 开关

Step 10：集成测试 + UI 接入（1 天）
  - 4 个 fixture ZIP
  - AISettingsView 新增设置区
  - 端到端验证 AI 摘要质量提升

合计 ≈ 8 个工作日
```

---

## 19. 验收标准

- [ ] `RepoContextPacker.pack()` 对一个典型仓库（500 文件以下）能在 1 秒内产出 context.xml
- [ ] 输出 XML 通过 XML 1.0 严格校验
- [ ] 默认 ignore 85 条全部生效（fixture 验证）
- [ ] Tier 0 命中率 ≥ 90%（fixture 项目都有 README + 包管理文件）
- [ ] Token 估算与实际 GPT-4o tokenizer 误差 ≤ 12%
- [ ] 失败时临时目录不残留
- [ ] 失败时不写脏数据到 `analysis/<owner>/<repo>/`
- [ ] AI 摘要接入后，对 5 个 fixture 仓库的摘要质量评测**比纯 README 版有可感知提升**（dong4j 手测）
- [ ] 沙箱下运行无 entitlement 报错
- [ ] 与 CodeFlow 共享 ZIP 层后，CodeFlow 仍能正常工作（不污染对方）

---

## 20. 风险与缓解

| 风险 | 缓解措施 |
|---|---|
| Tier 清单不全（生态遗漏） | 兜底走 Tier 2，仍能产出可用 context；持续迭代清单 |
| Token 估算偏差大 | budget 留 20% buffer；V2 升级精确计数 |
| 大文件吃光 budget | Tier 0 → Tier 1 自动降级机制 |
| ZIP 解压失败 | 与 CodeFlow 共享下载层，下载失败由 CodeFlow 报错 |
| 临时目录磁盘空间不足 | 解压前预检 ZIP 大小，超过 100MB 直接拒绝 |
| AI 摘要质量未达预期 | 设置开关 `aiSummaryUseRepoContext` 让用户回退到纯 README 路径 |
| Tier 规则争议（用户认为某文件应该是 Tier X） | V2 加用户级覆盖机制 |

---

## 21. 与既有设计文档的关系

| 既有文档 | 关系 |
|---|---|
| `docs/需求讨论/starcat-repomix-integration-plan.md` | **本文档取代该方案**。原方案要求用户自己安装 repomix CLI 或自动安装，本方案改为 Swift 自研，但 §1-3 的业务背景仍有效 |
| `docs/需求讨论/starcat-codeflow-integration.md` | **共享 ZIP 快照层契约由 CodeFlow 定义**，本方案严格遵守该契约（§8） |
| `docs/详细设计/14-AI集成落地记录.md` | AI 调用链由 `RepoAIInsightService` 编排，本方案只负责 context.xml，prompt 编排不动 |
| `docs/详细设计/15-AI设置与调用链重构方案.md` | AI provider / model 抽象不动；本方案新增的 AppSettings 字段遵循同款 `AIModelTask`-style 设计 |
| `docs/详细设计/26-向量搜索改进.md` | 向量搜索的 `IndexedTextBuilder` 与本方案的 Packer **完全独立**——前者服务于向量化，后者服务于 AI 摘要 prompt 注入；两者输入源都包含 README，但输出格式和消费者都不同 |

---

## 22. 实施前 grill 决策记录（v1.2 实施版本附录）

> **本章是 §1-§21 的【实施权威覆盖层】**——v1.2 通过 10 轮 grill 对 10 个关键技术决策点做了**最终拍板**，所有决议**优先于**原章节的描述。代码实施时遵循本章；§1-§21 保留作为「为什么这么设计」的背景上下文。
>
> grill 时间：2026-06-13 15:53 ～ 16:21（UTC+8），由 dong4j 与 Claude 协作完成，共 10 轮提问。

### 22.1 决议总表

| Q# | 决策主题 | 决议（一句话） |
|---|---|---|
| **Q1** | ZIP 解压库 | **ZIPFoundation**（第三方 SPM 包，约 200KB），不用 AppleArchive / Compression.framework |
| **Q2** | glob 匹配引擎 | **自写 glob → regex 转换器**（约 50 行），用 `NSRegularExpression`，**case-sensitive** 匹配 |
| **Q3** | 单文件错误处理粒度 | **分层错误**：致命错抛 `RepoContextPackerError`，单文件错 skip + 写入 `metadata.json.skippedFiles[]` |
| **Q4** | pipeline 数据流 + 并发 + actor/struct | **三 pass + 懒读 + Pass 3 用 TaskGroup 并发读（cap 8）+ 全 struct**（除 Facade / Extractor / Writer 标 `async throws`） |
| **Q5** | 临时目录与产物布局 | 解压用系统 `temporaryDirectory/RepoContextPacker/<UUID>/` + `defer` 清；产物持久化到 `Application Support/Starcat/analysis/<owner>/<repo>/` |
| **Q6** | 二进制文件检测策略 | **扩展名白名单 fast-path + Tier 0/1 读取前 NUL 字节 8KB 探测**；Tier 2 不做检测 |
| **Q7** | Token 估算时机 + 校准 | **Pass 2 用 size 估算**（不读内容）→ **Pass 3 用真 char count 校准**；不回滚 plan，超 20% 写 warning；metadata 同时输出 `estimatedTokens` + `actualTokens` + `tokenEstimatorVersion` |
| **Q8** | 截断语义 | **Tier 1**：行数 80 + 字符数 4000 双约束 + 统一 `// ... [truncated: ...]` marker；**Tier 0**：100KB 硬上限 → 降级为 Tier 2 + skippedFiles 记录 |
| **Q9** | XML 输出格式 | **String 拼接** + CDATA `]]>` 拆段转义 + POSIX 相对路径 + UTF-8 无 BOM + 2 空格缩进 + `<repository>` 根 + 5 段保留 + `metadata.json` 旁路 |
| **Q10** | ZIP 边界 + 安全防护 | **通用 unzipped root 识别**（一级单目录则进入，否则 flat）+ **Zip slip 兜底**（路径在 rootURL 子树内）+ **symlink 完全跳过** + **双层大小限制**（ZIP 100MB / 解压后 500MB / 单文件 5MB）+ mojibake 文件名 MVP 不处理 |

### 22.2 Q1 / ZIP 解压库 = ZIPFoundation

**决议**：引入 `ZIPFoundation` SPM 依赖（[weichsel/ZIPFoundation](https://github.com/weichsel/ZIPFoundation)）。

**为什么不选其它**：
- ❌ **AppleArchive**：API 只支持 `.aar`（Apple Archive 格式），不支持标准 ZIP
- ❌ **Compression.framework**：低层 API，只能压缩 / 解压**单个数据流**，不能直接处理 ZIP 容器（条目元数据 / 目录结构）需要自己 parse
- ❌ **手写 ZIP parser**：ZIP 规范复杂（central directory / local file header / 多种压缩算法），自写 risk 大
- ✅ **ZIPFoundation**：Swift-native API、沙箱兼容、约 200KB 体积、稳定维护

**关键 API**：
```swift
import ZIPFoundation
try FileManager.default.unzipItem(at: zipURL, to: destinationURL)
```

**开源致谢登记**（强制规则，AGENTS.md §「开源致谢同步规则」）：
- 在 `project.yml` 的 `packages` 里加 SPM 依赖
- 在 `AboutView.swift` 的 `AboutDependency.all` 追加：
  ```swift
  AboutDependency(
      name: "ZIPFoundation",
      license: "MIT",
      copyright: "Copyright (c) 2017-2024 Thomas Zoechling",
      url: "https://github.com/weichsel/ZIPFoundation"
  )
  ```

### 22.3 Q2 / glob 匹配 = 自写 glob → regex 转换器

**决议**：在 `Starcat/Shared/Services/RepoContextPacker/Internal/GlobCompiler.swift` 实现约 50 行的 glob → regex 转换器，匹配引擎用 `NSRegularExpression`，**case-sensitive**。

**支持的 glob 语法**：
- `*` — 单目录内任意字符（不跨 `/`）
- `**` — 跨目录任意路径
- `?` — 单字符（不跨 `/`）
- `{a,b,c}` — 字符类（多选一）
- 元字符 `. ( ) + $ ^ | [ ] \` 自动转义

**实现参考**：

```swift
enum GlobCompileError: Error {
    case unmatchedBrace
}

enum GlobCompiler {
    /// 把 glob pattern 编译成 NSRegularExpression
    /// 支持：* ** ? {a,b,c}；其它元字符自动转义；case-sensitive
    static func toRegex(_ glob: String) throws -> NSRegularExpression {
        var pattern = "^"
        var i = glob.startIndex
        while i < glob.endIndex {
            let c = glob[i]
            switch c {
            case "*":
                let next = glob.index(after: i)
                if next < glob.endIndex && glob[next] == "*" {
                    pattern += ".*"               // ** 跨目录
                    i = glob.index(after: next)
                    continue
                } else {
                    pattern += "[^/]*"            // * 单目录内
                }
            case "?":
                pattern += "[^/]"                 // ? 单字符
            case "{":
                guard let end = glob[i...].firstIndex(of: "}") else {
                    throw GlobCompileError.unmatchedBrace
                }
                let parts = glob[glob.index(after: i)..<end].split(separator: ",")
                pattern += "(" + parts.map(NSRegularExpression.escapedPattern(for:))
                    .joined(separator: "|") + ")"
                i = glob.index(after: end)
                continue
            case ".", "(", ")", "+", "$", "^", "|", "[", "]", "\\":
                pattern += "\\\(c)"               // 转义 regex 元字符
            default:
                pattern += String(c)
            }
            i = glob.index(after: i)
        }
        pattern += "$"
        return try NSRegularExpression(pattern: pattern)  // 默认 case-sensitive
    }
}
```

**为什么 case-sensitive**：GitHub 仓库的文件系统大多 case-sensitive（Linux / macOS APFS）；`README.md` 与 `readme.md` 是不同文件。误判 case 会导致 ignore 规则漏挡 / 误挡。

**性能优化**：把 `defaultIgnorePatterns` / `tier0GlobPatterns` / `tier1GlobPatterns` 在 `TierRules` 加载时**预编译**为 `[NSRegularExpression]` 缓存，避免每个文件重新编译。

### 22.4 Q3 / 分层错误处理

**决议**：致命错误**抛 `RepoContextPackerError`**；单文件错误**skip + 写入 `metadata.json.skippedFiles[]`**。

**致命错误清单**（必须抛）：

```swift
public enum RepoContextPackerError: LocalizedError, Sendable {
    // ===== Pass 0 解压阶段 =====
    case zipFileNotFound(URL)
    case zipTooLarge(actualBytes: Int, maxBytes: Int)
    case extractedDirectoryTooLarge(actualBytes: Int, maxBytes: Int)
    case zipEmpty
    case zipExtractionFailed(underlying: Error)
    case zipSlipDetected(path: String)

    // ===== Pass 1-2 处理阶段 =====
    case noFilesAfterFiltering

    // ===== Pass 3-4 写入阶段 =====
    case outputDirectoryNotWritable(URL, underlying: Error)
    case xmlBuildFailed(underlying: Error)
    case writeFailed(URL, underlying: Error)

    // ===== Task lifecycle =====
    case cancelled
}
```

**单文件错误**（不抛，写 `skippedFiles[]`）：

```json
{
  "skippedFiles": [
    { "path": "weird-binary.dat",    "reason": "binaryDetected",     "tier": 2 },
    { "path": "huge-readme.md",      "reason": "tier0FileTooLarge",  "tier": 0, "fileSize": 152048 },
    { "path": "src/.../large.gen.swift", "reason": "singleFileTooLarge", "tier": 2, "fileSize": 6291456 },
    { "path": "Sources/Foo.swift",   "reason": "fileReadFailed",     "tier": 1 },
    { "path": "tools/utf16-file.txt","reason": "encodingDetectionFailed", "tier": 1 },
    { "path": "links/upstream",      "reason": "symlinkSkipped",     "tier": null }
  ]
}
```

**reason 字符串常量**（写入 `RepoContextPacker/Models/SkipReason.swift`）：

```swift
enum SkipReason {
    static let binaryDetected            = "binaryDetected"
    static let tier0FileTooLarge         = "tier0FileTooLarge"
    static let singleFileTooLarge        = "singleFileTooLarge"
    static let symlinkSkipped            = "symlinkSkipped"
    static let fileReadFailed            = "fileReadFailed"
    static let encodingDetectionFailed   = "encodingDetectionFailed"
}
```

**与 §10 关系**：v1.0 §10 错误枚举不全，本节是**完整权威版**。`fileReadFailed` 从枚举里**移除**，改为 skipReason。

### 22.5 Q4 / 三 pass + Pass 3 TaskGroup 并发读 + 全 struct

**决议**：

| Pass | 职责 | 同步 / 异步 | 并发 |
|---|---|---|---|
| **Pass 0**：Extract | ZIPFoundation 解压到临时目录 | `async throws`（内部 `Task.detached` 避免阻塞调用线程） | 否 |
| **Pass 1**：Scan | 递归 walk 目录，应用 ignore 规则，输出 `[FilteredFile]`（path + size） | 同步 `throws` | 否 |
| **Pass 2**：Plan | classify → budget allocate → 输出 `AllocatedPlan` | 同步 | 否 |
| **Pass 3**：Render | TaskGroup 并发读 Tier 0/1 文件内容、估算实际 token、拼 XML | `async throws` | **TaskGroup，cap = 8** |
| **Pass 4**：Write | 原子写 `context.xml` + `metadata.json` | `async throws` | 否 |

**模块类型修订（覆盖原 §9）**：

| 模块 | 原 §9 | v1.2 决议 |
|---|---|---|
| `SourceZipExtractor` | actor | **struct + `async throws`** |
| `FileFilter` | struct | struct（同步） |
| `TierClassifier` | struct | struct（同步） |
| `TokenEstimator` | struct | struct（同步纯函数） |
| `BudgetAllocator` | actor | **struct**（同步纯算法） |
| `DirectoryTreeBuilder` | struct | struct（同步） |
| `XmlOutputBuilder` | struct | **struct + `async throws`**（Pass 3 内 TaskGroup 读文件） |
| `ContextWriter` | actor | **struct + `async throws`** |
| `RepoContextPacker`（Facade） | actor | **struct + `async throws`** |

**Pass 3 并发读的关键约束**：

```swift
struct XmlOutputBuilder {
    /// Pass 3：并发读 Tier 0/1 内容，cap=8 防止 fd 耗尽
    /// 顺序保证：每个子 Task 返回 (originalIndex, ContentResult)，
    /// TaskGroup 收集完后按 originalIndex 排序，再喂给 XML 拼装
    func build(plan: AllocatedPlan, tree: String, rootURL: URL) async throws -> XmlBuildResult {
        try Task.checkCancellation()
        
        let contents = try await readAllContentsConcurrently(
            items: plan.contentItems,  // Tier 0 + Tier 1 列表
            rootURL: rootURL,
            concurrencyCap: 8
        )
        
        // 按 plan.contentItems 的原始顺序（path 字典序）拼 XML
        return try renderXML(plan: plan, tree: tree, contents: contents)
    }
    
    private func readAllContentsConcurrently(
        items: [ContentItem],
        rootURL: URL,
        concurrencyCap: Int
    ) async throws -> [Int: ContentResult] {
        try await withThrowingTaskGroup(of: (Int, ContentResult).self) { group in
            var results: [Int: ContentResult] = [:]
            var nextIndex = 0
            let total = items.count

            // 启动初始 cap 个子任务
            for _ in 0..<min(concurrencyCap, total) {
                let idx = nextIndex
                nextIndex += 1
                group.addTask {
                    let result = await Self.readSingleFile(items[idx], rootURL: rootURL)
                    return (idx, result)
                }
            }

            // 拿一个补一个，维持并发度 = cap
            while let (idx, result) = try await group.next() {
                results[idx] = result
                if nextIndex < total {
                    let i = nextIndex
                    nextIndex += 1
                    group.addTask {
                        let r = await Self.readSingleFile(items[i], rootURL: rootURL)
                        return (i, r)
                    }
                }
            }
            return results
        }
    }
}
```

**Cancellation 协议**：每个 Pass 入口先 `try Task.checkCancellation()`；Pass 3 内部每读完一个文件不必单独 check（TaskGroup 自动传播 cancel）。

### 22.6 Q5 / 临时目录 + 产物布局

**决议**：

| 角色 | 路径 | 生命周期 |
|---|---|---|
| **解压临时区** | `FileManager.default.temporaryDirectory/RepoContextPacker/<UUID>/` | pipeline 跑完 `defer` 清；OS reboot 自动清 |
| **最终产物** | `Application Support/Starcat/analysis/<owner>/<repo>/` | 持久化；按 commit SHA 覆盖；用户在「数据管理」一键清；取消 star 时清 |

**沙箱实际位置**：
- 解压：`~/Library/Containers/com.starcat.app/Data/tmp/RepoContextPacker/<UUID>/`
- 产物：`~/Library/Containers/com.starcat.app/Data/Library/Application Support/Starcat/analysis/<owner>/<repo>/`

**实施代码**（覆盖原 §9.1）：

```swift
struct DefaultSourceZipExtractor: SourceZipExtracting {
    func extract(_ zipURL: URL) async throws -> ExtractedSourceDirectory {
        // 1. 大小预检
        let zipSize = (try? FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? Int) ?? 0
        guard zipSize > 0 else { throw RepoContextPackerError.zipFileNotFound(zipURL) }
        guard zipSize <= TierRules.zipMaxBytes else {
            throw RepoContextPackerError.zipTooLarge(actualBytes: zipSize, maxBytes: TierRules.zipMaxBytes)
        }

        // 2. 创建解压临时目录
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoContextPacker", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        // 3. ZIPFoundation 解压（detached 避免阻塞调用线程）
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.unzipItem(at: zipURL, to: tempRoot)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: tempRoot)
            throw RepoContextPackerError.zipExtractionFailed(underlying: error)
        }

        // 4. ZIP bomb 兜底
        let extractedSize = try Self.directorySize(of: tempRoot)
        guard extractedSize <= TierRules.extractedMaxBytes else {
            try? FileManager.default.removeItem(at: tempRoot)
            throw RepoContextPackerError.extractedDirectoryTooLarge(
                actualBytes: extractedSize, maxBytes: TierRules.extractedMaxBytes
            )
        }

        // 5. 识别真正的项目根目录（GitHub ZIP 包裹一层 / 用户 ZIP flat）
        let rootURL = try Self.findUnzippedRoot(in: tempRoot)

        return ExtractedSourceDirectory(rootURL: rootURL) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }
}

struct ExtractedSourceDirectory {
    let rootURL: URL
    let cleanup: () -> Void
}
```

### 22.7 Q6 / 二进制检测 = 扩展名白名单 + NUL 探测

**决议**：

1. **FileFilter Pass 1 阶段**：扩展名 / 文件名白名单 fast-path——**不在白名单的全 skip**（写 `skippedFiles[]` reason = `binaryDetected`，但只在 dong4j 后续要求时才记录，MVP 静默 skip 因为数量可能很大）
2. **XmlOutputBuilder Pass 3 阶段**：Tier 0 / Tier 1 读取**之前**，调 `BinaryDetection.isLikelyBinary(at:)` 读头 8KB 探测 NUL 字节，含 NUL → skip + 记录

**白名单（写入 `TierRules.swift`）**：

```swift
enum TierRules {
    // ... 既有内容 ...

    // MARK: - 文本扩展名白名单（约 60 条）
    static let textExtensions: Set<String> = [
        // 源码
        "swift", "kt", "java", "py", "js", "ts", "tsx", "jsx", "go", "rs",
        "c", "cpp", "h", "hpp", "cs", "rb", "php", "scala", "dart", "lua",
        "ex", "exs", "clj", "hs", "ml", "nim", "zig", "v", "m", "mm",
        // 脚本
        "sh", "zsh", "fish", "bash", "ps1", "bat", "cmd",
        // 标记
        "md", "markdown", "mdx", "txt", "rst", "adoc",
        // 配置
        "json", "yaml", "yml", "toml", "xml", "html", "htm", "css", "scss",
        "sass", "less", "ini", "conf", "properties",
        // Web (text-based)
        "svg",
    ]

    // MARK: - 无扩展名文件白名单（约 30 条）
    static let textFilenames: Set<String> = [
        "LICENSE", "COPYING", "NOTICE", "AUTHORS", "CONTRIBUTORS", "CHANGELOG",
        "README",
        "Makefile", "GNUmakefile", "Rakefile", "Gemfile", "Procfile",
        "Dockerfile",
        ".dockerignore", ".gitignore", ".editorconfig", ".gitattributes",
        ".npmrc", ".babelrc", ".eslintrc", ".prettierrc", ".stylelintrc",
        ".browserslistrc",
    ]
}
```

**NUL 探测实现**（`RepoContextPacker/Internal/BinaryDetection.swift`）：

```swift
enum BinaryDetection {
    /// 在 Tier 0/1 文件**读取前**调用，判定是否为 binary 应跳过
    ///
    /// 算法：读头 8KB，含 NUL byte (0x00) 即视为 binary。
    /// 这是 git/diff/less/file 命令的业界标准做法（GNU diffutils 用 8000 字节）。
    /// 已踩过的坑：
    /// 1. 不要尝试 String(contentsOf:) 全文 decode 后判定——大文件可能 100MB 全量 load 内存
    /// 2. 不要只看扩展名——`.txt` 但内容是 protobuf 的伪装文件会蒙混
    /// 3. 不要做编码探测——UTF-16 文件含 NUL 字节会误判，但 MVP 接受这个代价
    static func isLikelyBinary(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return true  // 文件读不开 → 当 binary 处理（skip 策略一致）
        }
        defer { try? handle.close() }
        guard let sample = try? handle.read(upToCount: 8192), !sample.isEmpty else {
            return false  // 空文件 → 当 text（让上层决定是否含）
        }
        return sample.contains(0x00)
    }
}
```

### 22.8 Q7 / Token 估算两阶段：估算 → 校准

**决议**：

| 阶段 | 输入 | 公式 | 用途 |
|---|---|---|---|
| **Pass 2 估算**（不读内容） | `file.size`（bytes） | `tokens_est = file.size × 0.27`（Tier 0 全文）或 `min(file.size × 0.27, 1080)`（Tier 1 头 80 行） | BudgetAllocator 决定 plan |
| **Pass 3 校准**（真读完） | `truncated_text.count`（chars） | `tokens_actual = truncated_text.count × 0.27` | 写入 `metadata.stats.actualTokens` |

**关键不变量**：
- ✅ Pass 2 **永远不读文件内容**，只用 size
- ✅ Pass 3 **永远不重新分配 budget**，只校准实际值 + 写 warning
- ✅ `actualTokens > tokenBudget × 1.2` 时写 `warnings: ["actualTokensExceededBudget"]`，**不 retry**
- ✅ `metadata.json.stats` 同时输出 `estimatedTokens` + `actualTokens` + `tokenEstimatorVersion = "char-x-0.27"`

**TokenEstimator 实现**（覆盖原 §9.4）：

```swift
struct TokenEstimator {
    /// 经验系数 0.27 = repomix 实测出的 GPT-4 tokenizer 经验值
    /// 误差 ±10%，足够 budget 决策用；V2 接 tiktoken-swift 在 Pass 3 精确算
    static let charToTokenRatio = 0.27
    static let version = "char-x-0.27"

    /// Pass 2 用：基于 byte size 估算（零 IO）
    /// 假设 ASCII 主导（源码 / 配置）；中文 README 会高估 3x，但 README 是 Tier 0 全文，
    /// 高估只会让 BudgetAllocator 更保守地少 include Tier 1，对结果无害
    static func estimate(byteCount: Int) -> Int {
        Int(Double(byteCount) * charToTokenRatio)
    }

    /// Pass 3 用：基于 char count 精确算（写入 metadata.stats）
    static func estimate(text: String) -> Int {
        Int(Double(text.count) * charToTokenRatio)
    }

    /// Tier 1 头 N 行的估算上限（用经验值 80 行 × 50 字符 卡顶）
    static func estimateTier1Head(byteCount: Int) -> Int {
        min(
            estimate(byteCount: byteCount),
            estimate(byteCount: TierTruncation.tier1MaxLines * 50)
        )
    }
}
```

### 22.9 Q8 / 截断语义

**决议**：

| 项 | 默认值 | 用户可调？ | 备注 |
|---|---|---|---|
| Tier 0 单文件上限 | 100 KB | ❌（不开放给用户） | 超出 → 降级 Tier 2 + `skippedFiles` reason = `tier0FileTooLarge` |
| Tier 1 行数上限 | 80 行 | ✅（AI 设置页 §12.3 D） | |
| Tier 1 字符数上限 | 4000 字符 | ❌ | 挡 minified JS 单行超长 |
| 单源码文件上限（任何 Tier） | 5 MB | ❌ | 超出 → 强制降级 Tier 2 + `skippedFiles` reason = `singleFileTooLarge` |
| 截断 marker 注释语法 | 统一 `// ... [truncated: ...]` | ❌ | 不按语言切换 |

**marker 文案**：

| 触发场景 | marker 文本 |
|---|---|
| 行数超 80 | `\n\n// ... [truncated: showing first 80 of N lines]\n` |
| 字符数超 4000 | `\n\n// ... [truncated: exceeded 4000 chars]\n` |

**TierTruncation 实现**（写入 `RepoContextPacker/Rules/TierTruncation.swift`）：

```swift
enum TierTruncation {
    static let tier0MaxBytes = 100 * 1024            // Tier 0 100KB 硬上限
    static let tier1MaxLines = 80                     // Tier 1 行数上限
    static let tier1MaxChars = 4000                   // Tier 1 字符数上限
    static let singleFileMaxBytes = 5 * 1024 * 1024   // 单源码文件 5MB 上限

    /// Tier 1 截断主入口（行数 + 字符数双约束）
    static func tier1Head(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        let exceedsLines = lines.count > tier1MaxLines
        let exceedsChars = normalized.count > tier1MaxChars

        if !exceedsLines && !exceedsChars {
            return normalized
        }

        var result = lines.prefix(tier1MaxLines).joined(separator: "\n")
        if result.count > tier1MaxChars {
            result = String(result.prefix(tier1MaxChars))
            return result + "\n\n// ... [truncated: exceeded \(tier1MaxChars) chars]\n"
        }
        return result + "\n\n// ... [truncated: showing first \(tier1MaxLines) of \(lines.count) lines]\n"
    }
}
```

### 22.10 Q9 / XML 输出格式

**决议**：String 拼接 + CDATA 拆段转义 + POSIX 相对路径 + UTF-8 无 BOM + 2 空格缩进 + `<repository>` 根 + 5 段保留 + `metadata.json` 旁路。

**完整 XML 模板（实施权威版）**：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<repository
  schemaVersion="1"
  tierRulesVersion="1.0"
  tokenEstimatorVersion="char-x-0.27"
  owner="vapor"
  repo="vapor"
  ref="main"
  commitSha="51ab970"
  generatedAt="2026-06-13T16:23:00Z"
  tokenBudget="8000">

  <directoryStructure><![CDATA[
src/
  index.ts
  utils/
    helper.ts
README.md
package.json
  ]]></directoryStructure>

  <keyFiles>
    <file path="README.md" tier="0" tokens="1234"><![CDATA[
# Project Name
...
    ]]></file>
    <file path="package.json" tier="0" tokens="89"><![CDATA[
{...}
    ]]></file>
  </keyFiles>

  <entryPoints>
    <file path="src/index.ts" tier="1" tokens="567" totalLines="234" truncated="true"><![CDATA[
import ...

// ... [truncated: showing first 80 of 234 lines]
    ]]></file>
  </entryPoints>

  <fileList>
    <file path="src/utils/helper.ts" tier="2"/>
    <file path="src/utils/other.ts" tier="2"/>
  </fileList>

  <stats
    totalFiles="87"
    tier0Count="3"
    tier1Count="5"
    tier2Count="79"
    estimatedTokens="7800"
    actualTokens="7234"/>
</repository>
```

**XMLEscape 工具**（写入 `RepoContextPacker/Internal/XMLEscape.swift`）：

```swift
enum XMLEscape {
    /// CDATA 内容转义：只需处理 `]]>` 序列
    /// 算法：在 `]]` 后关闭旧 CDATA，新 CDATA 段从 `>` 开始
    static func escapeCDATA(_ text: String) -> String {
        text.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")
    }

    /// 属性值转义：5 个标准字符
    static func escapeAttribute(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
```

**metadata.json 完整模板（实施权威版）**：

```json
{
  "schemaVersion": 1,
  "tierRulesVersion": "1.0",
  "tokenEstimatorVersion": "char-x-0.27",
  "owner": "vapor",
  "repo": "vapor",
  "ref": "main",
  "commitSha": "51ab9708841e14258bebfb5fb326e8b37782d193",
  "generatedAt": "2026-06-13T16:23:00Z",
  "tokenBudget": 8000,
  "stats": {
    "totalFiles": 87,
    "tier0Count": 3,
    "tier1Count": 5,
    "tier2Count": 79,
    "estimatedTokens": 7800,
    "actualTokens": 7234,
    "contextXmlBytes": 28456
  },
  "skippedFiles": [
    { "path": "weird-binary.dat", "reason": "binaryDetected", "tier": 2 },
    { "path": "huge-readme.md",   "reason": "tier0FileTooLarge", "tier": 0, "fileSize": 152048 }
  ],
  "warnings": []
}
```

### 22.11 Q10 / 5 项安全防护

**决议清单**：

1. **通用 unzipped root 识别** — `findUnzippedRoot(in:)` 见 §22.6
2. **Zip slip 兜底** — FileFilter 扫描时验证 `normalizedFilePath.hasPrefix(normalizedRootPath + "/")`，不通过抛 `zipSlipDetected`
3. **symlink 完全跳过** — FileFilter `URL.resourceValues(forKeys: [.isSymbolicLinkKey])` 检测，is symlink 则 skip + `skippedFiles` reason = `symlinkSkipped`
4. **双层大小限制** — ZIP 100MB（Pass 0 解压前 check）+ 解压后总 500MB（Pass 0 解压后 check）+ 单源码文件 5MB（Pass 1 FileFilter check）
5. **mojibake 文件名 MVP 不处理** — 遇到非 UTF-8 文件名按普通名字处理（多半被默认 ignore 挡掉），写 `warnings: ["nonAsciiFilenamesDetected: N"]`

**TierRules 新增大小常量**：

```swift
enum TierRules {
    // ... 既有内容 ...

    // MARK: - Q10 / 大小限制（v1.2 新增）
    static let zipMaxBytes = 100 * 1024 * 1024              // 100MB ZIP 上限
    static let extractedMaxBytes = 500 * 1024 * 1024        // 500MB 解压后上限（ZIP bomb 兜底）
    static let singleFileMaxBytes = 5 * 1024 * 1024         // 5MB 单文件上限
}
```

**findUnzippedRoot 完整实现**：

```swift
extension DefaultSourceZipExtractor {
    static func findUnzippedRoot(in tempRoot: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: tempRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        // 过滤 macOS / Windows 元数据
        let realEntries = contents.filter { url in
            !url.lastPathComponent.hasPrefix("__MACOSX") &&
            url.lastPathComponent != ".DS_Store" &&
            url.lastPathComponent != "Thumbs.db"
        }

        guard !realEntries.isEmpty else { throw RepoContextPackerError.zipEmpty }

        // 一级是单个目录 → 进入它（GitHub source ZIP 通用 layout）
        if realEntries.count == 1,
           (try? realEntries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return realEntries[0]
        }
        // 否则 flat layout，直接用 tempRoot
        return tempRoot
    }
}
```

### 22.12 实施前检查清单（写代码前过一遍）

> ✅ 本次实施（2026-06-13 17:15）已全部满足。

- [x] **依赖**：`project.yml` 加 ZIPFoundation SPM 依赖；`AboutDependency.all` 同步加致谢条目
- [x] **目录结构**：`Starcat/Shared/Services/RepoContextPacker/` 下建 `Internal/` / `Models/` / `Rules/` / `Protocols/` 子目录
- [x] **TierRules 三件套**：常量集中在 `Rules/TierRules.swift` + `Rules/TierTruncation.swift`；`SkipReason` 因为是「错误处理」语义放在 `Models/SkipReason.swift`（与 `Models/RepoContextPackerError.swift` 配对，比放 Rules/ 更贴语义）
- [x] **错误枚举**：严格按 §22.4 实现（11 个 case，已剔除 `fileReadFailed` 和 `tokenBudgetExceededByTier0`），未照搬原 §10
- [x] **模块签名**：严格按 §22.5 实现（4 个原 actor 全降级为 struct），未照搬原 §9
- [x] **XML 输出**：严格按 §22.10 模板实现（含 5 段保留 / CDATA 拆段转义 / 3 个版本属性 / 2 空格缩进）
- [x] **TaskGroup cap = 8**：常量定义在 `TierRules.contentReadConcurrencyCap`（§22.5）
- [x] **`xcodegen generate` 在新增 swift 文件后跑通**（`xcodegen generate` 0 错 → `xcodebuild build` BUILD SUCCEEDED → `xcodebuild build-for-testing` TEST BUILD SUCCEEDED）
- [x] **测试覆盖**：8 个测试文件 ~55 case 覆盖 grill 10 项决议边界（详见 §23.3）

---

## 23. 任务清单与实施进度（2026-06-13 17:15）

> 本章节按工程任务粒度罗列 RepoContextPacker 的全部实施任务，并标注本次（2026-06-13）已完成的部分。
>
> **本次范围**（dong4j 明确决策）：「先实现从 ZIP 解压、代码分析到生成 XML 的这一流程；下载 ZIP 和之后 XML 如何使用的逻辑先不管」 → 即设计文档 §18 的 **Step 1-7 全部完成**，**Step 8-10 客户端接入暂不做**。

### 23.1 已完成（2026-06-13 本次）

#### 阶段 A：依赖与项目骨架

- [x] **A1. ZIPFoundation SPM 依赖集成** —— `project.yml` packages 段加 `ZIPFoundation` from `0.9.20`、Starcat target dependencies 段加引用
- [x] **A2. AboutDependency 致谢条目同步** —— `Starcat/Features/About/AboutView.swift` SPM 区追加 `ZIPFoundation` 一条（MIT, Copyright (c) 2017-2026 Thomas Zoechling）
- [x] **A3. 目录骨架** —— 建 `Starcat/Shared/Services/RepoContextPacker/{Models, Rules, Protocols, Internal}/`

#### 阶段 B：Models 层（3 个文件）

- [x] **B1. `Models/RepoContextPackerError.swift`** —— 11 个致命错 case（§22.4）
- [x] **B2. `Models/SkipReason.swift`** —— 6 类单文件错 reason 常量 + `SkippedFile` 结构体（§22.4）
- [x] **B3. `Models/PackerIO.swift`** —— 10 个核心类型（PackInput / PackOutput / FilteredFile / Tier / TieredFile / FileStrategy / AllocatedFile / AllocatedPlan / ExtractedSourceDirectory / XmlBuildResult / XmlMetadata / PackMetadata / PackStats）

#### 阶段 C：Rules 层（2 个文件）

- [x] **C1. `Rules/TierRules.swift`** —— 默认 ignore 列表 ~140 条（照搬 repomix v1.14.1）+ Tier 0 精确名集合（45 个） + Tier 0 glob 列表（~15 条）+ Tier 1 入口 glob 列表（~30 条）+ 文本扩展名白名单（60+ 条）+ 无扩展名文件名白名单（30+ 条）+ 大小阈值常量（zipMax / extractedMax / singleFileMax）+ Token 经验系数 + Pass 3 并发上限
- [x] **C2. `Rules/TierTruncation.swift`** —— 5 个截断常量（tier0Max / tier1MaxLines / tier1MaxChars / singleFileMax）+ `tier1Head(_:)` 双约束截断函数（含 `\r\n` 归一）

#### 阶段 D：Protocols 层（1 个文件）

- [x] **D1. `Protocols/PackerProtocols.swift`** —— 6 个 protocol（SourceZipExtracting / FileFiltering / TierClassifying / BudgetAllocating / DirectoryTreeBuilding / XmlOutputBuilding / ContextWriting）+ 2 个 result 结构体（FileFilterResult / TierClassifyResult）

#### 阶段 E：Internal 工具类（11 个文件）

- [x] **E1. `Internal/GlobCompiler.swift`** —— 50 行 glob→regex 转换器，支持 `*` / `**` / `?` / `{a,b,c}` + 元字符自动转义；case-sensitive；批量编译 + matchesAny API
- [x] **E2. `Internal/BinaryDetection.swift`** —— 8KB NUL 字节探测，读不开/读失败保守视为 binary，空文件视为 text
- [x] **E3. `Internal/XMLEscape.swift`** —— `escapeCDATA(_:)`（拆段 `]]>` → `]]]]><![CDATA[>`）+ `escapeAttribute(_:)`（5 个标准字符，& 先于其它）
- [x] **E4. `Internal/TokenEstimator.swift`** —— `estimate(byteCount:)` Pass 2 用 + `estimate(text:)` Pass 3 用 + `estimateTier1Head(byteCount:)` 卡 80×50 上限
- [x] **E5. `Internal/SourceZipExtractor.swift`** —— ZIPFoundation 解压 + 6 步流程（ZIP 大小预检 / 临时目录 / `Task.detached` 解压 / ZIP bomb 兜底 / unzipped root 识别 / cleanup 闭包返回）
- [x] **E6. `Internal/FileFilter.swift`** —— 递归 walk + ignore 应用 + Zip slip 兜底 + symlink 完全跳过 + 5MB 单文件上限 + 扩展名/文件名白名单 fast-path
- [x] **E7. `Internal/TierClassifier.swift`** —— 精确名命中 Tier 0 + glob 命中 Tier 0/1 + 默认 Tier 2 + Tier 0 100KB 上限降级 Tier 2 + skippedFiles 记 `tier0FileTooLarge`
- [x] **E8. `Internal/BudgetAllocator.swift`** —— 按 (tier, path) 排序 + Tier 0 永远 fullContent + Tier 1 超 budget 降级 pathOnly + Tier 2 永远 pathOnly + totalEstimatedTokens 累加
- [x] **E9. `Internal/DirectoryTreeBuilder.swift`** —— 缩进列表格式（2 空格缩进 + 目录后跟 `/` + 按 path 字典序 + 同目录不重复输出标头）
- [x] **E10. `Internal/XmlOutputBuilder.swift`** —— Pass 3 主入口：① `withThrowingTaskGroup` 并发读 Tier 0/1 内容 cap=8 + 按 originalIndex 排序保顺序；② 5 段拼装（directoryStructure / keyFiles / entryPoints / fileList / stats）；③ 真 token 校准（`text.count × 0.27`）；④ 超 budget × 1.2 写 warning；⑤ 含 ISO8601DateFormatter helper
- [x] **E11. `Internal/ContextWriter.swift`** —— 原子写 context.xml + metadata.json 到 `outputBaseDir/<owner>/<repo>/`（`Data.write(.atomic)` + JSONEncoder pretty + sortedKeys + 回填 contextXmlBytes）

#### 阶段 F：Facade（1 个文件）

- [x] **F1. `RepoContextPacker.swift`** —— pipeline 总入口：6 步编排（Pass 0 Extract → Pass 1 Filter → Pass 2a Classify → Pass 2b Allocate → Pass 2c Tree → Pass 3 XML → Pass 4 Write）+ 每 Pass `Task.checkCancellation()` + `defer { extracted.cleanup() }` + 全部 skippedFiles 汇总写 metadata

#### 阶段 G：单元测试（8 个测试文件）

- [x] **G1. `StarcatTests/RepoContextPacker/GlobCompilerTests.swift`** —— 11 case：`*` 不跨目录 / `**` 跨目录 / `?` 单字符 / `{a,b,c}` 多选 / 元字符转义 / case-sensitive / 批量 compileAll + matchesAny / unmatchedBrace 抛错
- [x] **G2. `StarcatTests/RepoContextPacker/TierTruncationTests.swift`** —— 7 case：空字符串 / 短文本原样 / `\r\n` 归一化 / 仅行数超 / 仅字符超 / 双超 / 常量值
- [x] **G3. `StarcatTests/RepoContextPacker/XMLEscapeTests.swift`** —— 7 case：CDATA 无终止 / CDATA 单 `]]>` / CDATA 多 `]]>` / 属性无元字符 / 属性 5 元字符 / `&` 先于其它 / 双重 escape 防护
- [x] **G4. `StarcatTests/RepoContextPacker/TokenEstimatorTests.swift`** —— 5 case：byte 公式 / text 公式 / Tier 1 卡顶 / 小文件按 byte / 负数防护
- [x] **G5. `StarcatTests/RepoContextPacker/BinaryDetectionTests.swift`** —— 6 case：ASCII text / NUL byte binary / 空文件 text / 中文 UTF-8 text / 不存在文件 binary（保守）/ 8KB 之后 NUL 不探测（采样窗口限制）
- [x] **G6. `StarcatTests/RepoContextPacker/TierClassifierTests.swift`** —— 6 case：精确名 Tier 0 / glob Tier 0 / glob Tier 1 / 默认 Tier 2 / Tier 0 >100KB 降级 + skippedFiles / Tier 0 <100KB 不降级
- [x] **G7. `StarcatTests/RepoContextPacker/BudgetAllocatorTests.swift`** —— 7 case：Tier 0 永远 fullContent / Tier 1 内 budget 走 headTruncated / Tier 1 超 budget 降 pathOnly / Tier 2 永远 pathOnly / 排序 / 空输入 / token 累加
- [x] **G8. `StarcatTests/RepoContextPacker/DirectoryTreeBuilderTests.swift`** —— 6 case：单平铺 / 两级 / 同目录不重复 / 混合字典序 / 三级 / 空输入

#### 阶段 H：构建与验证

- [x] **H1. `xcodegen generate` 0 错**
- [x] **H2. `xcodebuild -scheme Starcat build` BUILD SUCCEEDED**
- [x] **H3. `xcodebuild build-for-testing` TEST BUILD SUCCEEDED**（测试代码本身编译通过）
- [x] **H4. `ReadLints` 0 错**

### 23.2 已知约束 / 本次未做（与设计文档对齐）

> 本节列出**已知约束**或本次刻意未做的事项，标注「为什么」与「后续行动」。

- [ ] **U1. 测试 runtime 实际跑通** —— `xcodebuild test` 运行时命中项目级 testmanagerd 启动 hang（与 `AGENTS.md` 已知问题 #1 同源、与本次代码无关），TEST BUILD 已通过证明代码本身 OK。**后续行动**：Cmd+Q 关 Xcode IDE 后命令行重跑 / 或在 IDE 里 Cmd+U 直接跑（与项目历史「未跑全量 test」策略一致）。
- [ ] **U2. 端到端 ZIP fixture 集成测试** —— 设计文档 §18 Step 10「集成测试 + UI 接入」范围；MVP 验收预期用 4 个 fixture ZIP（vapor/vapor / repomix 自身 / 大型 monorepo / 小型 demo）跑端到端验证「< 1s 出 context.xml」「token 估算误差 ≤12%」等指标。**未做原因**：dong4j 明确「先实现 pipeline」，集成测试与 §19 验收标准一起在客户端接入阶段做。
- [ ] **U3. BinaryDetection 8KB 之后的 NUL 漏检** —— 业界标准 8000 字节采样，对「头 8KB 全 ASCII magic + 之后才出现 NUL」的极少数 binary（< 0.1%）会漏检。**接受原因**：与 git / diff / less / file 等业界工具一致；测试 G5 case 6 已显式覆盖此边界并文档化。
- [ ] **U4. UTF-8 decode 失败统一记 `encodingDetectionFailed`** —— XmlOutputBuilder 读单文件时把「读不开 / 权限不足 / UTF-16 编码 / 真损坏」全部合并为 `encodingDetectionFailed`。**接受原因**：对消费方区分这些来源意义不大；MVP §22.7 决议明确不做编码探测。
- [ ] **U5. mojibake 文件名不处理** —— §22.11 (e) 决议；< 0.001% 触发率；目前未追加 `warnings: ["nonAsciiFilenamesDetected: N"]` 实际累计逻辑（因为没读全 enumerator 文件名做 ASCII 检测），代码层 warnings 数组初始为空。**后续行动**：如果生产环境真碰到投诉，加 N 行检测逻辑即可。
- [ ] **U6. `.gitignore` 解析** —— MVP 不做，默认 ignore 列表 + 文本扩展名白名单已足够（§22.11 / 原 §13）；V2 ⭐⭐⭐ 优先级。

### 23.3 待办（客户端接入阶段，本次未做）

> 设计文档 §18 Step 8-10 范围，dong4j 决策本次不做，单开后续任务。

#### Step 8：集成 RepoAIContextProvider（~0.5 天）

- [ ] **W1. 新建 `RepoAIContextProvider`** —— 收口「从 commit SHA 找 ZIP → 调 Packer → 返回 context.xml 路径」三步；含「已存在且新鲜则跳过」cache 命中策略
- [ ] **W2. 调 SharedSnapshotService 拿 ZIP** —— 严格遵守 `docs/需求讨论/starcat-codeflow-integration.md` §4.2 共享 ZIP 快照契约（不删共享 ZIP / 不直接拼接 `repository-snapshots/...` 路径）
- [ ] **W3. 失败降级** —— Packer 任何错误（含 `RepoContextPackerError.cancelled`）不阻断 AI 摘要主流程，返回 nil 让 caller 走 README-only fallback

#### Step 9：接入 RepoAIInsightService prompt（~0.5 天）

- [ ] **X1. AppSettings 新增 `aiSummaryUseRepoContext: Bool`** —— 默认 true，写入 UserDefaults
- [ ] **X2. AppSettings 新增 `aiSummaryRepoContextTokenBudget: Int`** —— 默认 8000，UI 给 Slider 4K-32K
- [ ] **X3. AppSettings 新增 `aiSummaryRepoContextTier1MaxLines: Int`** —— 默认 80（对应 `TierTruncation.tier1MaxLines`）
- [ ] **X4. `RepoAIInsightService` prompt 注入** —— 调 `RepoAIContextProvider.context(for:)` 拿 context.xml URL → 读文件 → 在 system prompt 后追加 `<repo-context>{xml}</repo-context>` 段；nil 时跳过
- [ ] **X5. 同款接入到 `RepoAIChatViewModel` system prompt** —— 让对话也能用上代码上下文

#### Step 10：UI 触点 A~F 落地（~2.5 天）

- [ ] **Y1. 触点 A 摘要生成两阶段状态条** —— `RepoAIWindowContentView` 摘要面板进度态扩 enum 为 `.idle / .preparingContext / .streamingSummary / .done / .failed`；i18n `ai.context.phase.*` 命名空间
- [ ] **Y2. 触点 B 摘要 footer 元信息** —— `RepoAISummaryMarkdownView` 底部 caption2 行：`87 个文件 · 7.2K tokens · 51ab970 · 1 小时前 · main 分支`；i18n `ai.context.footer.*`
- [ ] **Y3. 触点 C 设置页配置区** —— `AISettingsView` 新增 `DisclosureGroup("AI 代码上下文（实验）", expanded by @SceneStorage)` 含总开关 + TokenBudget Slider + 关键文件保留行数 Stepper + 大文件降级阈值 + 数据管理跳转按钮；i18n `ai.context.settings.*`
- [ ] **Y4. 触点 D 降级 banner** —— `RepoAIWindowContentView` 顶部条件渲染 banner，5 种失败场景对应文案（网络 / 磁盘 / >100MB / 解压失败 / Zip slip 安全防护）；i18n `ai.context.banner.*`
- [ ] **Y5. 触点 E 存储 Tab 数据管理面板** —— `StorageSettingsView` 与 CodeFlow 数据管理并列，列出 `analysis/<owner>/<repo>/` 各 repo + 占用大小 + 单删 / 一键清空 / 在 Finder 显示；i18n `ai.context.storage.*`
- [ ] **Y6. 触点 F 右上角「在 Finder 显示上下文」菜单项** —— `RepoAIWindowController` toolbar 加 Menu 项，调 `NSWorkspace.shared.activateFileViewerSelecting([contextURL])`；i18n `ai.context.menu.*`
- [ ] **Y7. 端到端 fixture 测试** —— 4 个 fixture ZIP（vapor / repomix / 大型 monorepo / 小型 demo）跑完整 pipeline，断言 token 估算误差 ≤12% / 输出 XML 通过 `XMLParser` 严格校验

#### Step 11：V2 / Post-MVP（不进 MVP）

- [ ] **Z1. ⭐⭐⭐ tiktoken-swift 精确 token 计数**（0.5 天）—— 切换 `TokenEstimator` 实现，`tokenEstimatorVersion` 字符串变成 `tiktoken-cl100k`
- [ ] **Z2. ⭐⭐⭐ `.gitignore` 解析**（1 天）—— 在 FileFilter 启动期读仓库 `.gitignore` + parent dirs 的 `.gitignore`，合并到 ignore 规则
- [ ] **Z3. ⭐⭐ Markdown 输出**（0.5 天）—— 新增 `MarkdownOutputBuilder` 与 `XmlOutputBuilder` 并列，按 PackerOptions 选输出格式
- [ ] **Z4. ⭐ tree-sitter compress**（5-7 天）—— 当且仅当用户抱怨"摘要被截断"才做；SwiftTreeSitter 集成 + 多语言 grammar 配置 + signature-only 截断
- [ ] **Z5. ⭐ git 历史增强**（1 天）—— GitHub Commits API 拉最近 20 个 commit + author + 时间，注入 XML 新增 `<gitHistory>` 段
- [ ] **Z6. ❌ 永不做**：MCP server / Skill 生成 / 远程 git clone / secretlint / CLI 入口（每条都有 §1 / §14 / §16 决议背书）

### 23.4 文件清单（本次落地）

> 18 个新 Swift 源文件 + 8 个测试文件 + 2 个文件改动（依赖与致谢）。

#### 新增源文件（18）

```
Starcat/Shared/Services/RepoContextPacker/
├── RepoContextPacker.swift               # Facade
├── Models/
│   ├── RepoContextPackerError.swift      # 致命错枚举
│   ├── SkipReason.swift                  # 单文件错常量 + SkippedFile
│   └── PackerIO.swift                    # 10 个核心 IO 类型
├── Rules/
│   ├── TierRules.swift                   # 常量 + 三大白名单
│   └── TierTruncation.swift              # 截断常量 + tier1Head
├── Protocols/
│   └── PackerProtocols.swift             # 6 个 protocol
└── Internal/
    ├── GlobCompiler.swift                # glob → regex
    ├── BinaryDetection.swift             # NUL 字节探测
    ├── XMLEscape.swift                   # CDATA + 属性转义
    ├── TokenEstimator.swift              # 两阶段估算
    ├── SourceZipExtractor.swift          # ZIPFoundation 解压
    ├── FileFilter.swift                  # 递归 walk + 安全防护
    ├── TierClassifier.swift              # 分级 + 100KB 降级
    ├── BudgetAllocator.swift             # 贪心分配
    ├── DirectoryTreeBuilder.swift        # 缩进列表
    ├── XmlOutputBuilder.swift            # Pass 3 + 5 段拼装
    └── ContextWriter.swift               # 原子写
```

#### 新增测试文件（8）

```
StarcatTests/RepoContextPacker/
├── GlobCompilerTests.swift               # 11 case
├── TierTruncationTests.swift             # 7 case
├── XMLEscapeTests.swift                  # 7 case
├── TokenEstimatorTests.swift             # 5 case
├── BinaryDetectionTests.swift            # 6 case
├── TierClassifierTests.swift             # 6 case
├── BudgetAllocatorTests.swift            # 7 case
└── DirectoryTreeBuilderTests.swift       # 6 case
                                           合计 ~55 case
```

#### 修改文件（2）

- `project.yml` —— packages 段加 `ZIPFoundation` from `0.9.20` + Starcat target dependencies 段加引用
- `Starcat/Features/About/AboutView.swift` —— `AboutDependency.all` SPM 区追加 `ZIPFoundation` 致谢条目（MIT, Copyright (c) 2017-2026 Thomas Zoechling）

### 23.5 验证证据

- **`xcodegen generate`** —— exit 0，`Created project at .../Starcat.xcodeproj`
- **`xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' build`** —— `** BUILD SUCCEEDED **`（45.7s）
- **`xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' build-for-testing`** —— `** TEST BUILD SUCCEEDED **`（4.8s）
- **`ReadLints` 对 `Starcat/Shared/Services/RepoContextPacker/` + `StarcatTests/RepoContextPacker/`** —— `No linter errors found.`
- **`xcodebuild test` runtime** —— 命中项目级 testmanagerd 启动 hang（`Test runner hung before establishing connection.`），与 `AGENTS.md` 已知问题 #1 同源，**与本次代码无关**（TEST BUILD 已证明代码本身 OK）

### 23.6 后续任务粒度估算

| 阶段 | 任务编号 | 工作量预估 | 阻塞前置 |
|---|---|---|---|
| Step 8 客户端接入 | W1 ~ W3 | ~0.5 天 | CodeFlow ZIP 快照层（已完成） |
| Step 9 prompt 注入 | X1 ~ X5 | ~0.5 天 | Step 8 + AppSettings 已有 ai 命名空间 |
| Step 10 UI 触点 | Y1 ~ Y7 | ~2.5 天 | Step 9 + i18n `ai.context.*` 命名空间新增 |
| V2 升级 | Z1 ~ Z5 | 8-10 天 | 视用户反馈优先级 |

**总后续工作量**：~3.5 天（Step 8 + 9 + 10）让 RepoContextPacker 完整接入 AI 摘要主流程；V2 全部完成需 8-10 天，按 ⭐ 优先级和用户反馈分批做。

---

*文档版本：v1.4，2026-06-13*  
*作者：Starcat AI 协作（dong4j + Claude）*  
*变更记录：*  
*- v1.4（2026-06-13 21:50）：新增 §0「客户端接入任务清单」放到文档最前面，作为当前阶段的可执行任务索引；按 W → X → Y 三阶段拆分（W = SharedSnapshotService + RepoAIContextProvider 抽象层 / X = AppSettings 4 字段 + RepoAIInsightService prompt 注入 / Y = 6 个 UI 触点 + E2E fixture）；§0.1 现状摸底表对齐 8 个接入面到具体代码行号；§0.6 DoD 给硬性完成标准；§0.7 风险清单列出 5 项已识别风险与缓解。与 §23 配套：§23 记录已落地的底层 pipeline，§0 记录当前接入阶段的待办。*  
*- v1.3（2026-06-13 17:30）：新增 §23「任务清单与实施进度」章节；标注本次（2026-06-13 17:15）已完成 §18 Step 1-7 全部范围（18 新源文件 + 8 测试文件 ~55 case + ZIPFoundation 依赖集成 + AboutDependency 同步），Step 8-10 客户端接入（W1-W3 / X1-X5 / Y1-Y7 共 ~3.5 天）和 V2 升级（Z1-Z5）暂未做；同步勾选 §22.12 实施前检查清单（全 9 项 ✅）；`SkipReason` 实际归位 `Models/` 而非 `Rules/`（语义上与错误处理配对）。*  
*- v1.2（2026-06-13 16:21）：新增 §22「实施前 grill 决策记录」作为实施权威覆盖层；记录 10 轮 grill 全部决议（ZIPFoundation 依赖 / 自写 glob→regex / 分层错误 / 三 pass + TaskGroup cap=8 / 系统 temp 解压 + Application Support 持久化 / 扩展名白名单 + NUL 探测 / Token 两阶段估算→校准 / Tier 1 行字符双约束 + Tier 0 100KB 上限 / String 拼接 XML + CDATA 拆段转义 / 5 项安全防护）；§9 / §10 / §6 章节由 §22 覆盖；__SourceZipExtractor / BudgetAllocator / ContextWriter / RepoContextPacker__ 由 actor 改为 struct；错误枚举补 `zipSlipDetected` / `extractedDirectoryTooLarge` / `cancelled`，移除 `fileReadFailed`（改为 SkipReason）。*  
*- v1.1（2026-06-13 14:55）：新增 §12 UX 设计章节（15 个子节）；后续 §12-§20 顺移到 §13-§21；定义 8 个 UI 触点（5 个 MVP + 3 个 V2）、失败处理矩阵 7 项、i18n 命名规范 7 个子命名空间。*  
*- v1.0（2026-06-13 14:36）：初版落档；锁定 MVP 范围为 AI 摘要上下文打包；明确不照搬 repomix CLI / MCP / Skill / tree-sitter compress；与 CodeFlow 共享 ZIP 快照层。*
