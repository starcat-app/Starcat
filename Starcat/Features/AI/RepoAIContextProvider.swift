//
//  RepoAIContextProvider.swift
//  Starcat
//
//  W3：把"为某个 repo 准备一份 context.xml 喂给 LLM"这件事的全部门面（2026-06-13）。
//
//  对外只暴露一个方法 `context(for repo:) async throws -> URL?`，nil 表示「未启用 /
//  静默失败」。内部三步：
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
struct RepoAIContextResult: Sendable {
    let url: URL
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
    /// - Throws: 只抛 `CancellationError`，其它错误内部静默吞并映射为 `.degraded(reason)`。
    func contextOutcome(for repo: Repo) async throws -> RepoAIContextOutcome {
        // 先把 settings 快照到本地（一次性跨 MainActor 调用，后续 pipeline 用快照）。
        let snapshot = await snapshotSettings()

        // ① 总开关 guard：关掉 = 完全跳过下游链路（语义上 ≠ 失败，UI 不显示 banner）
        guard snapshot.enabled else { return .featureDisabled }

        do {
            return .success(try await prepareContext(for: repo, snapshot: snapshot))
        } catch is CancellationError {
            // 透传 cancellation 让上层 task tree 能优雅退出
            throw CancellationError()
        } catch {
            // 把错误分类成 ContextDegradationReason 让 UI 能给用户讲清楚为什么没用上代码
            let reason = ContextDegradationReason.classify(error)
            AppLog.ai.warning(
                "[RepoAIContextProvider] context prep degraded reason=\(String(describing: reason), privacy: .public) for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return .degraded(reason)
        }
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

    private func prepareContext(for repo: Repo, snapshot: SettingsSnapshot) async throws -> RepoAIContextResult {
        // ② 解析分支 → 拿 commit SHA
        let defaultBranchName = repo.defaultBranch ?? "main"
        let branch = try await snapshotService.resolveBranch(repo: repo, name: defaultBranchName)

        // ③ 缓存命中判定四件套：用入口处快照的 settings 值
        let tokenBudget = snapshot.tokenBudget
        let tier1MaxLines = snapshot.tier1MaxLines
        let currentTierRulesVersion = TierRules.tierRulesVersion

        if let existing = try? storage.existingProject(owner: repo.owner, repo: repo.name),
           existing.metadata.commitSha == branch.commitSHA,
           existing.metadata.tokenBudget == tokenBudget,
           // tier1MaxLines 可能为 nil（W7 扩字段前的旧 metadata）；按 80 兜底
           (existing.metadata.tier1MaxLines ?? 80) == tier1MaxLines,
           existing.metadata.tierRulesVersion == currentTierRulesVersion {
            // 命中缓存 → 刷新 lastAccessedAt 让 UI 列表能按"最近使用"排序
            try? storage.touch(owner: repo.owner, repo: repo.name)
            AppLog.ai.debug(
                "[RepoAIContextProvider] cache hit for \(repo.fullName, privacy: .public) sha=\(branch.commitSHA.prefix(7), privacy: .public)"
            )
            return RepoAIContextResult(url: existing.contextURL, metadata: existing.metadata)
        }

        // ④ 不命中 → 走完整 pipeline：下载 ZIP + Packer
        let archive = try await snapshotService.archiveIfNeeded(repo: repo, commitSHA: branch.commitSHA)

        let packer = try RepoContextPacker(writer: DefaultContextWriter(storage: storage))
        // PackInput.outputBaseDir 在 storage 注入路径下被忽略，但字段是 non-optional，
        // 这里给一个语义清晰的默认（storage 的 root URL），不会被实际使用。
        let outputBaseDir = (try? storage.outputRootURL()) ?? FileManager.default.temporaryDirectory
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
        let stored = try? storage.existingProject(owner: repo.owner, repo: repo.name)
        let resolvedMetadata = stored?.metadata ?? makePlaceholderMetadata(
            input: input, output: output, tokenEstimatorVersion: TierRules.tokenEstimatorVersion
        )
        return RepoAIContextResult(url: output.contextURL, metadata: resolvedMetadata)
    }

    /// 极少触发的兜底（storage 写盘成功但 existingProject 又读不出）：用 input + output 拼一个
    /// 最小可用的 PackMetadata，让 caller 能拿到 commitSha / tokenBudget / stats 等关键字段。
    private func makePlaceholderMetadata(
        input: PackInput,
        output: PackOutput,
        tokenEstimatorVersion: String
    ) -> PackMetadata {
        let isoNow = ISO8601DateFormatter.starcatPackerFormatter.string(from: .now)
        return PackMetadata(
            schemaVersion: 1,
            tierRulesVersion: TierRules.tierRulesVersion,
            tokenEstimatorVersion: tokenEstimatorVersion,
            owner: input.owner,
            repo: input.repo,
            ref: input.ref,
            commitSha: input.commitSha,
            generatedAt: isoNow,
            tokenBudget: input.tokenBudget,
            stats: output.stats,
            skippedFiles: [],
            warnings: ["metadataReadFallback"],
            tier1MaxLines: input.tier1MaxLines,
            lastAccessedAt: isoNow,
            generationCount: 1
        )
    }
}
