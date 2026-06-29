//
//  RepoAIContextProvider.swift
//  Starcat
//
//  W3：把"为某个 repo 准备一份 context.xml 喂给 LLM"这件事的全部门面（2026-06-13）。
//  W4（2026-06-21）：新增 `onProgress` 回调（`RepoAIContextProgressCallback`），
//     在 resolveBranch / archiveIfNeeded / pack 三个边界发 `RepoAIContextProgress`
//     事件，让 AI 面板能在「生成摘要」按钮上方显示「解析分支 → 下载项目代码 → 解压并
//     生成上下文」进度 chip，不再被前置 IO 阻塞按钮可点状态。
//
//  对外只暴露一个方法 `contextOutcome(for:onProgress:) async throws -> RepoAIContextOutcome`
//  （+ 兼容旧 `context(for:)` / 新 `prepareContextForGeneration` 走 service 层），内部三步：
//    ① `SharedSnapshotService.resolveBranch + archiveIfNeeded` 拿 ZIP；
//    ② 查 `RepoContextStorage.existingProject(owner:repo:)` 看缓存是否命中
//       （commitSha + tokenBudget + tier1MaxLines + tierRulesVersion 四件套全等）；
//    ③ 命中 → 调 `storage.touch(...)` 刷 lastAccessedAt → 直接返回旧 contextURL；
//       不命中 → 调 `RepoContextPacker.pack(_:)`，packer 内部走 W8 改造的 storage 写盘路径。
//
//  失败降级原则（学习 `RepoAIInsightService.generateInsight:127-129` 的 AnySearchContextProvider 范本）：
//    - `CancellationError` 透传：上层取消任务时本服务必须立刻停手；
//    - 其它任意错误 → 返回 nil + AppLog.ai.warning(...)，让 AI 摘要静默降级为 README-only，
//      **绝不让 Packer 错误阻断 AI 主流程**。
//
//  关键约束（已踩过的坑级）：
//    1. 总开关 `settings.aiRepoContextEnabled = false` 时直接返回 nil（**第一道 guard**），
//       根本不走 ZIP 下载——节省 100MB 流量 + 几秒磁盘 I/O。
//    2. 缓存命中判定的四件套（commitSha + tokenBudget + tier1MaxLines + tierRulesVersion）
//       缺一不可：用户调 settings 后旧 metadata 必须自动失效；packer 升级 TierRules 后所有
//       旧 metadata 也自动失效。
//    3. 不做私有仓库判断：OAuth scope `read:user + public_repo` 永远拿不到 isPrivate=true 的
//       repo（即便有，SharedSnapshotService 会先抛 .privateRepository，本服务降级返回 nil）。
//

import Foundation

/// `RepoAIContextProvider.context(for:)` 的返回值。
///
/// Y2 决议（2026-06-13）：除了 context xml 路径外，还透传 `PackMetadata`，让 UI 层
/// （RepoAIWindowContentView footer）能显示"基于 commit abc123、消耗 4280 tokens 生成"。
///
/// 2026-06-14 silent failure 修复：新增 `xml: String` 字段。原设计只返回 `url: URL`，
/// 让 `RepoAIInsightService.makeSource` 在 security scope 外 `String(contentsOf:)` 读 xml；
/// 用户把 RepoContext 输出根目录改成自选文件夹时（需要 security scope），读 xml 必失败、
/// 被 `try?` 吞掉，contextMetadata 永远 nil → UI footer 第二行 / ⋯ 菜单第二项一并丢失。
/// 把 xml 读取移进 provider 内部（在 `withOutputRoot` 内通过 `storage.loadContextXml(...)`
/// 完成），通过本字段透传给 caller，杜绝跨 scope 边界的失败路径。
struct RepoAIContextResult: Sendable {
    /// context.xml 文件路径。**调用方不应直接 `String(contentsOf:)`**——
    /// security scope 已在 provider 返回前关闭，跨 scope 读取会失败。需要文件全文请用 `xml`；
    /// 需要 Finder 跳转请走 `RepoContextStorage.revealProject(_:)`（内部自己 withOutputRoot）。
    let url: URL

    /// `context.xml` 文件全文（已在 security scope 内读好）。
    /// 上层（service）直接消费此字符串，不再做任何文件 IO。
    let xml: String

    let metadata: PackMetadata
}

/// Y4：context 准备结果三态。
///
/// 与早期版本"`URL?` 单值"的差别：把"用户关了开关"和"失败"分开 —— 前者用户主动不要
/// 不需要 banner，后者要在 UI 上提示原因。
enum RepoAIContextOutcome: Sendable {
    /// 成功（命中缓存或新生成）。
    case success(RepoAIContextResult)

    /// 用户关了 `aiRepoContextEnabled`，全链路跳过。UI 不显示降级提示。
    case featureDisabled

    /// 失败 / 不可用——附带原因，UI 在摘要顶部显示 banner。
    case degraded(ContextDegradationReason)
}

/// W4（2026-06-21）：context 准备步骤事件。
///
/// 给 `contextOutcome(for:onProgress:)` 的回调参数用——把原本黑盒的"下载 ZIP + pack"
/// pipeline 拆成三个可观察的边界点，让 AI 面板能在用户等待期间显示「解析分支 →
/// 下载项目代码 → 解压并生成上下文」进度行。
///
/// - 设计动机：原 `cachedInsight` 路径在 ViewModel 入口一次性 `await makeSource`，
///   UI 只能展示静态「正在读取本地 AI 缓存…」文案。用户体感是「点开 AI 面板后好几秒
///   看到按钮」。把 pipeline 拆成可观察 step 后，UI 可以**先显示「生成摘要」按钮**、
///   在按钮上方铺进度 chip，让按钮不被前置 IO 阻塞。
/// - 不在 `RepoContextPacker.pack` 内部继续拆"解压"与"生成 XML"两步：packer 本身是
///   一个内部事务（ZIPFoundation 流式遍历 + 单文件写出），强行拆需要把 packer 改成
///   AsyncStream 风格，scope 太大。当前粒度（3 段）覆盖了 90% 的用户感知耗时
///   （resolveBranch / archiveIfNeeded / pack 三个网络+磁盘边界）。
enum RepoAIContextProgress: Sendable, Equatable {
    /// 即将调 `SharedSnapshotService.resolveBranch`（GitHub `/branches/:name` API）。
    case resolvingBranch
    /// 即将调 `SharedSnapshotService.archiveIfNeeded`（命中本地 ZIP 缓存时**不**发此事件）。
    case downloadingArchive
    /// 即将调 `RepoContextPacker.pack`（解压 + 全仓文件遍历 + 写 context.xml）。
    case packingContext
}

/// 进度回调签名。强制 `@MainActor`：consumer（ViewModel）要把 step 写入
/// `@Observable` 状态，必须主线程；provider 在任意 actor 上调用回调即可。
typealias RepoAIContextProgressCallback = @MainActor (RepoAIContextProgress) -> Void

struct RepoAIContextProvider {

    private let snapshotService: SharedSnapshotService
    private let storage: RepoContextStorage
    private let settings: AppSettings

    init(
        snapshotService: SharedSnapshotService,
        storage: RepoContextStorage,
        settings: AppSettings
    ) {
        self.snapshotService = snapshotService
        self.storage = storage
        self.settings = settings
    }

    /// `AppSettings` 字段在 MainActor 上读到的快照（避免 pipeline 内反复跨 actor 调用）。
    private struct SettingsSnapshot {
        let enabled: Bool
        let tokenBudget: Int
        let tier1MaxLines: Int
    }

    @MainActor
    private func snapshotSettings() -> SettingsSnapshot {
        SettingsSnapshot(
            enabled: settings.aiRepoContextEnabled,
            tokenBudget: settings.aiRepoContextTokenBudget,
            tier1MaxLines: settings.aiRepoContextTier1MaxLines
        )
    }

    /// 给 `RepoAIInsightService.makeSource(for:)` 用的入口（Y4 引入 3 态 outcome）。
    ///
    /// - Parameter onProgress: 进度回调，consumer 在 step 切换时显示 UI 进度。
    ///   默认 `nil`，保持现有调用方（`makeSource`）零改动。**调用方**必须是 MainActor
    ///   才能把 step 写进 @Observable 状态，所以回调本身也强制 `@MainActor`。
    /// - Throws: 只抛 `CancellationError`，其它错误内部静默吞并映射为 `.degraded(reason)`。
    func contextOutcome(
        for repo: Repo,
        onProgress: RepoAIContextProgressCallback? = nil
    ) async throws -> RepoAIContextOutcome {
        // 先把 settings 快照到本地（一次性跨 MainActor 调用，后续 pipeline 用快照）。
        let snapshot = await snapshotSettings()

        // ① 总开关 guard：关掉 = 完全跳过下游链路（语义上 ≠ 失败，UI 不显示 banner）
        guard snapshot.enabled else { return .featureDisabled }

        do {
            return .success(try await prepareContext(for: repo, snapshot: snapshot, onProgress: onProgress))
        } catch is CancellationError {
            // 透传 cancellation 让上层 task tree 能优雅退出
            throw CancellationError()
        } catch {
            // 把错误分类成 ContextDegradationReason 让 UI 能给用户讲清楚为什么没用上代码
            let reason = ContextDegradationReason.classify(error)

            // 2026-06-14（dong4j 反馈"zip 已下载但 xml/metadata 没生成"）：
            //
            // `error.localizedDescription` 把 `RepoContextPackerError` 的 enum case 名 +
            // underlying NSError 全挤进一行字符串里，根因丢失。Console.app 上看到
            // "代码上下文打包失败" 这类泛化文案对排查没帮助。
            //
            // 这里改用 `String(reflecting:)` 把 enum case + 关联值结构完整导出（如
            // `RepoContextPackerError.zipExtractionFailed(underlying: ...)`），同时单独
            // dump NSError 的 domain / code / userInfo 让 Console 一眼定位是哪一步挂的。
            //
            // 关键约束：privacy 全部 .public —— 这些是错误诊断信息（无 PII），打码反而
            // 让 dong4j 在 Console.app 上看到一堆 `<private>` 没法用。
            let debugDump = Self.formatErrorForDiagnostics(error)
            AppLog.ai.error(
                """
                [RepoAIContextProvider] context prep failed for \(repo.fullName, privacy: .public)
                  reason=\(String(describing: reason), privacy: .public)
                  \(debugDump, privacy: .public)
                """
            )
            return .degraded(reason)
        }
    }

    /// 把任意 `Error` 拆解为对人类可读的多行诊断文本。
    ///
    /// 输出格式（每段独占一行）：
    /// ```
    /// type=<dynamicType>
    /// localized=<localizedDescription>
    /// reflecting=<String(reflecting: error)>      # enum case + 关联值（packer 错误用）
    /// nserror.domain=<NSError.domain>
    /// nserror.code=<NSError.code>
    /// nserror.userInfo=<NSError.userInfo>
    /// underlying=<formatErrorForDiagnostics(underlying)>   # 递归展开 underlying
    /// ```
    ///
    /// 对 `RepoContextPackerError` 的 6 个含 `underlying:` 关联值的 case 会递归展开，
    /// 让 Console.app 能看到"ZIPFoundation 抛 fileWriteUnknown / writer 抛 cocoa
    /// .fileNoSuchFileError"这类底层根因。
    private static func formatErrorForDiagnostics(_ error: Error) -> String {
        var lines: [String] = []
        lines.append("type=\(type(of: error))")
        lines.append("localized=\(error.localizedDescription)")
        lines.append("reflecting=\(String(reflecting: error))")

        let nsError = error as NSError
        lines.append("nserror.domain=\(nsError.domain) code=\(nsError.code)")
        if !nsError.userInfo.isEmpty {
            // userInfo 可能含巨大对象（NSURL / NSData），用 String(describing:) 控制大小。
            lines.append("nserror.userInfo=\(nsError.userInfo)")
        }

        // 递归展开 RepoContextPackerError 的 underlying 关联值——单独 case
        // 才有 underlying，用 if case let 模式匹配避免漏 case 时编译失败。
        if let packerError = error as? RepoContextPackerError {
            if let underlying = packerError.underlyingError {
                let nested = formatErrorForDiagnostics(underlying)
                    .split(separator: "\n")
                    .map { "  " + $0 }
                    .joined(separator: "\n")
                lines.append("underlying:\n\(nested)")
            }
        }
        return lines.joined(separator: "\n  ")
    }

    /// 兼容旧 API：Y2 之前的调用方期望 `URL?`，保留这个简化入口（内部走 outcome 路径）。
    /// 仅供过渡使用，新代码应该直接消费 `contextOutcome(for:)`。
    func context(for repo: Repo) async throws -> RepoAIContextResult? {
        switch try await contextOutcome(for: repo) {
        case .success(let result): return result
        case .featureDisabled, .degraded: return nil
        }
    }

    // MARK: - 内部 pipeline

    private func prepareContext(
        for repo: Repo,
        snapshot: SettingsSnapshot,
        onProgress: RepoAIContextProgressCallback?
    ) async throws -> RepoAIContextResult {
        // ② 解析分支 → 拿 commit SHA
        let defaultBranchName = repo.defaultBranch ?? "main"
        // W4：先发 progress 事件，再 await 网络。UI 在 `resolveBranch` 期间就能切换 chip
        // 到「解析分支」态，不至于让用户在 commit SHA 拿到前看到空白 chip。
        await onProgress?(.resolvingBranch)
        let branch = try await snapshotService.resolveBranch(repo: repo, name: defaultBranchName)

        // ③ 缓存命中判定四件套：用入口处快照的 settings 值
        let tokenBudget = snapshot.tokenBudget
        let tier1MaxLines = snapshot.tier1MaxLines
        let currentTierRulesVersion = TierRules.tierRulesVersion

        let cachedProject = try? await MainActor.run(resultType: RepoContextStoredProject?.self) {
            try storage.existingProject(owner: repo.owner, repo: repo.name)
        }
        if let existing = cachedProject,
           existing.metadata.commitSha == branch.commitSHA,
           existing.metadata.tokenBudget == tokenBudget,
           // tier1MaxLines 可能为 nil（W7 扩字段前的旧 metadata）；按 80 兜底
           (existing.metadata.tier1MaxLines ?? 80) == tier1MaxLines,
           existing.metadata.tierRulesVersion == currentTierRulesVersion {
            // 命中缓存 → 刷新 lastAccessedAt 让 UI 列表能按"最近使用"排序
            try? await MainActor.run {
                try storage.touch(owner: repo.owner, repo: repo.name)
            }
            // 2026-06-14 silent failure 修复：在 security scope 内读好 xml 再透传给 caller。
            // 读不到（外部删了 xml 文件 / 自选目录权限掉了）当作"缓存损坏"抛错，让外层
            // catch 把它分类成 .degraded，UI 显示 banner 而不是静默丢失。
            let cachedXML = try await MainActor.run(resultType: String?.self) {
                try storage.loadContextXml(owner: repo.owner, repo: repo.name)
            }
            guard let xml = cachedXML else {
                AppLog.ai.warning(
                    "[RepoAIContextProvider] cache hit but context.xml unreadable for \(repo.fullName, privacy: .public)"
                )
                throw RepoContextStorageError.outputDirectoryUnavailable
            }
            AppLog.ai.debug(
                "[RepoAIContextProvider] cache hit for \(repo.fullName, privacy: .public) sha=\(branch.commitSHA.prefix(7), privacy: .public)"
            )
            // W4：缓存命中时**不**发 `.downloadingArchive` 事件——chip 行要直接切到
            // 「全部完成」或保持 idle（具体由 consumer 决定），避免误导用户「明明秒开
            // 却看到下载步骤」。这里不调用 onProgress，让 consumer 自己判断 ready。
            return RepoAIContextResult(url: existing.contextURL, xml: xml, metadata: existing.metadata)
        }

        // ④ 不命中 → 走完整 pipeline：下载 ZIP + Packer
        // W4：发 `.downloadingArchive` 让 UI 把 chip 切到「下载项目代码」。
        await onProgress?(.downloadingArchive)
        let archive = try await snapshotService.archiveIfNeeded(repo: repo, commitSHA: branch.commitSHA)

        // W4：发 `.packingContext` 让 UI 把 chip 切到「解压并生成上下文」。
        await onProgress?(.packingContext)
        let packer = try RepoContextPacker(writer: DefaultContextWriter(storage: storage))
        // PackInput.outputBaseDir 在 storage 注入路径下被忽略，但字段是 non-optional，
        // 这里给一个语义清晰的默认（storage 的 root URL），不会被实际使用。
        let outputBaseDir = (try? await MainActor.run { try storage.outputRootURL() }) ?? FileManager.default.temporaryDirectory
        let input = PackInput(
            zipURL: archive.url,
            owner: repo.owner,
            repo: repo.name,
            ref: branch.name,
            commitSha: branch.commitSHA,
            outputBaseDir: outputBaseDir,
            tokenBudget: tokenBudget,
            tier1MaxLines: tier1MaxLines
        )
        let output = try await packer.pack(input)
        AppLog.ai.debug(
            "[RepoAIContextProvider] packed \(repo.fullName, privacy: .public) sha=\(branch.commitSHA.prefix(7), privacy: .public) tokens=\(output.stats.actualTokens, privacy: .public)"
        )
        // 写盘完成后让 UI（StorageSettingsTab）能看到新项目
        await MainActor.run { storage.reload() }

        // 读回新写的 metadata.json 给 caller（Y2 footer 元信息透传）。
        // storage.write 内部已经回填了 contextXmlBytes + lastAccessedAt + generationCount，
        // 直接读 storage.existingProject(...) 拿最新版本最准确。
        let stored = try? await MainActor.run {
            try storage.existingProject(owner: repo.owner, repo: repo.name)
        }
        let resolvedMetadata = stored?.metadata ?? makePlaceholderMetadata(
            input: input, output: output, tokenEstimatorVersion: TierRules.tokenEstimatorVersion
        )
        // 2026-06-14 silent failure 修复：与缓存命中路径同款 —— 在 security scope 内读好 xml
        // 再透传给 caller。packer 刚写完 xml 又立刻读，正常情况下必定成功；读不到说明
        // 存储层异常（极少触发），按"已降级"抛错让 UI 给出反馈而不是 silent failure。
        let generatedXML = try await MainActor.run(resultType: String?.self) {
            try storage.loadContextXml(owner: repo.owner, repo: repo.name)
        }
        guard let xml = generatedXML else {
            AppLog.ai.error(
                "[RepoAIContextProvider] packed but context.xml unreadable for \(repo.fullName, privacy: .public)"
            )
            throw RepoContextStorageError.outputDirectoryUnavailable
        }
        return RepoAIContextResult(url: output.contextURL, xml: xml, metadata: resolvedMetadata)
    }

    /// 极少触发的兜底（storage 写盘成功但 existingProject 又读不出）：用 input + output 拼一个
    /// 最小可用的 PackMetadata，让 caller 能拿到 commitSha / tokenBudget / stats 等关键字段。
    private func makePlaceholderMetadata(
        input: PackInput,
        output: PackOutput,
        tokenEstimatorVersion: String
    ) -> PackMetadata {
        // HOM-203：metadata 字段已是 Date 类型，直接传 .now 即可。
        let now = Date()
        return PackMetadata(
            schemaVersion: 1,
            tierRulesVersion: TierRules.tierRulesVersion,
            tokenEstimatorVersion: tokenEstimatorVersion,
            owner: input.owner,
            repo: input.repo,
            ref: input.ref,
            commitSha: input.commitSha,
            generatedAt: now,
            tokenBudget: input.tokenBudget,
            stats: output.stats,
            skippedFiles: [],
            warnings: ["metadataReadFallback"],
            tier1MaxLines: input.tier1MaxLines,
            lastAccessedAt: now,
            generationCount: 1
        )
    }
}
