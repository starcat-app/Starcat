//
//  SearchCenterViewModel.swift
//  Starcat
//
//  全局搜索中心的界面状态与提交边界。
//
//  关键约束：输入草稿不会逐字符访问数据库或网络；只有用户提交、切换 scope 后补跑
//  缺失来源、或显式加载更多时才调用 Coordinator，避免远端搜索消耗失控。
//
//  历史记录：从 W4 (UserDefaults) 升级到 W5-ready GRDB SQLite + CloudKit-friendly
//  字段（id UUID / modifiedAt LWW / useCount + 半衰期衰减排序）。详见
//  `SearchHistoryRepositoryProtocol` 与 `docs/2-产品/需求讨论/正式方案/CloudKit数据同步设计.md` §2.x。
//

import CryptoKit
import Foundation
import Observation

/// 智能发现缓存身份只保存配置与密钥指纹。密钥原文绝不能进入内存缓存键或诊断导出。
struct SearchDiscoveryCacheIdentity: Equatable, Hashable, Sendable {
    let chatConfiguration: String
    let rerankConfiguration: String
    let externalSearchConfiguration: String
    let credentialFingerprint: String

    static let constant = SearchDiscoveryCacheIdentity(
        chatConfiguration: "constant-chat",
        rerankConfiguration: "constant-rerank",
        externalSearchConfiguration: "constant-external",
        credentialFingerprint: "constant-credentials"
    )

    @MainActor static func live(
        settings: AppSettings,
        keychain: any KeychainManaging
    ) -> SearchDiscoveryCacheIdentity {
        let chatTask = settings.resolvedAITask(settings.aiChatTask)
        let chatProfile = settings.aiProviderProfiles.first { $0.id == chatTask.providerID }
        let chatModel = chatProfile?.models.first { $0.name == chatTask.resolvedModelName }
        let rerank = settings.ragRerankConfiguration.normalized
        let externalProviders = ExternalSearchProviderID.allCases.sorted { $0.rawValue < $1.rawValue }
        let externalSettings = externalProviders.map { provider in
            let value = settings.externalSearchSettings(for: provider)
            return "\(provider.rawValue):\(value.isEnabled),\(value.anonymousMode),\(value.defaultMaxResults),\(value.fetchFullText),\(String(describing: value.credentialVerifiedAt))"
        }
        let chatKey = (try? keychain.loadAIKey(forProvider: chatTask.providerID)) ?? ""
        let rerankKey = (try? keychain.loadAIKey(
            forProvider: RAGRerankConfiguration.keychainID
        )) ?? ""
        let decisionAccess = JevDecisionEngine.resolveAccess(settings: settings, keychain: keychain)
        let githubKey = (try? keychain.loadGithubToken()) ?? ""
        let externalKeys = externalProviders.map { provider in
            (try? keychain.loadServiceAPIKey(forService: provider.keychainServiceID)) ?? ""
        }
        return SearchDiscoveryCacheIdentity(
            chatConfiguration: fingerprint([
                chatTask.providerID,
                chatTask.resolvedModelName,
                chatTask.useCustomModel ? "custom" : "catalog",
                String(describing: chatTask.parameters),
                chatProfile?.provider.rawValue ?? "",
                chatProfile?.baseURL ?? "",
                String(describing: chatProfile?.isVerifiedConfiguration),
                String(describing: chatModel?.isEnabled),
                String(describing: chatModel?.capability),
                String(settings.decisionEngineEnabled),
                String(settings.decisionSearchRoutingEnabled),
                settings.decisionEngineID.rawValue,
                settings.typesafeModelID,
                String(describing: decisionAccess?.source),
                decisionAccess?.modelID ?? "",
                String(describing: settings.selectedLocalAIModel(for: .llm))
            ]),
            rerankConfiguration: fingerprint([
                String(rerank.isEnabled),
                rerank.provider.rawValue,
                rerank.endpoint,
                rerank.model,
                String(rerank.candidateLimit),
                String(describing: settings.selectedLocalAIModel(for: .reranker))
            ]),
            externalSearchConfiguration: fingerprint([
                String(settings.externalContextEnabled),
                settings.externalContextProviderSelection.rawValue,
                settings.externalSearchDefaultProvider.rawValue,
                String(settings.externalSearchIncludeInAll)
            ] + externalSettings),
            credentialFingerprint: fingerprint([
                chatKey, rerankKey, githubKey, decisionAccess?.apiKey ?? ""
            ] + externalKeys)
        )
    }

    private static func fingerprint(_ values: [String]) -> String {
        let bytes = values.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(bytes.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct SearchDiscoveryCacheKey: Hashable {
    let request: SearchRequest
    let identity: SearchDiscoveryCacheIdentity
    let policyVersion: String
}

private struct SearchDiscoveryCacheEntry {
    let result: RepositoryDiscoveryResult
    let createdAt: Date
}

@MainActor
@Observable
final class SearchCenterViewModel {
    var query: String = ""
    var scope: SearchScope = .all
    /// 键盘选中态。`nil` 表示"用户尚未通过方向键显式选中任何一项"，
    /// 视图层据此跳过"深色 accent 高亮"，让 hover 成为唯一的高亮来源——
    /// 避免搜索结果一出来第一项就被强制选中，干扰鼠标用户的视觉焦点。
    var selectedIndex: Int?
    var isPresented: Bool = false
    /// 搜索浮层会在关闭时从 SwiftUI 视图树移除，因此可恢复的 UI 状态必须由
    /// 长生命周期 ViewModel 持有，不能放在 SearchCenterView 的临时 @State 中。
    var isGitHubFiltersExpanded: Bool = false
    var githubFilters: GitHubSearchFilters = .empty
    /// AnySearch 筛选条折叠状态。与 GitHub 筛选条对称（dong4j 2026-06-14 拍板：
    /// 持久化策略对齐 githubFilters —— 仅会话级，App 重启清零，不写 AppSettings）。
    var isAnySearchFiltersExpanded: Bool = false
    /// AnySearch 专属筛选条件（domain / contentTypes / zone）。
    /// 默认 `.empty` 表示「自动」，与未做本次改造前的行为完全一致。
    var anySearchFilters: AnySearchFilters = .empty
    /// External Search 公共筛选条件。会话级保存，不写 AppSettings。
    var externalSearchFilters: ExternalSearchFilters = .empty
    /// Web tab 当前 External Search Provider。会话级保存，App 重启回到设置页默认值。
    var webSearchProvider: ExternalSearchProviderID
    /// 当前搜索入口触发的 Pro 付费墙。只在用户明确进入网页搜索时弹出，避免 `.all`
    /// 搜索里本地/GitHub 结果也被一起挡住。
    var paywallContext: ProPaywallContext?

    private(set) var lastSubmittedQuery: String = ""
    /// 结果 List 的重建令牌。切 scope 复用候选后 SwiftUI List 会保留旧 contentOffset，
    /// 首卡会被截在可见区域上方；递增此值让 List 以新身份从顶部开始。
    private(set) var resultListEpoch: Int = 0
    /// 与范围正交的会话展示状态；切来源只改内存视图，不重新访问数据库或网络。
    private(set) var resultFilter: SearchResultFilter?
    /// 历史记录（按 `decayedScore` 降序排列；UI 直接遍历即可）。
    /// 持久化由 `historyRepository` 负责；本字段是异步加载后的最新内存快照。
    private(set) var history: [SearchHistory] = []
    /// 页码由累计成功快照维护，不能因范围切换或失败请求提前推进
    var currentGitHubPage: Int { coordinator.currentGitHubPage }

    let coordinator: SearchCoordinator
    private let historyRepository: any SearchHistoryRepositoryProtocol
    private let includeWebInAll: () -> Bool
    private let entitlementGate: EntitlementGate?
    private let telemetryManager: TelemetryManager?
    private let intentRouter: (any SearchIntentRoutingProviding)?
    private let discoveryService: (any RepositoryDiscoveryProviding)?
    private let discoveryCacheIdentity: () -> SearchDiscoveryCacheIdentity
    private let discoveryNow: () -> Date
    /// 搜索提交、Router 与 Discovery 共用的请求身份；新提交会先取消旧链路。
    private var searchGeneration = UUID()
    private var searchTask: Task<Void, Never>?
    private var discoveryGeneration = UUID()
    private var discoveryTask: Task<Void, Never>?
    private var discoveryCache: [SearchDiscoveryCacheKey: SearchDiscoveryCacheEntry] = [:]
    private var requestCacheIdentity = SearchDiscoveryCacheIdentity.constant

    /// 智能发现独立于 Coordinator：基础搜索先展示，发现完成后再合并。
    private(set) var discoverySession: SearchDiscoverySession?
    private var latestDiscoveryResult: RepositoryDiscoveryResult?
    private(set) var discoveryDiagnostics: [SearchDiscoveryDiagnostic] = []
    private(set) var isDiscoveryRunning = false

    init(
        coordinator: SearchCoordinator,
        historyRepository: any SearchHistoryRepositoryProtocol,
        includeWebInAll: @escaping () -> Bool = { false },
        entitlementGate: EntitlementGate? = nil,
        telemetryManager: TelemetryManager? = nil,
        intentRouter: (any SearchIntentRoutingProviding)? = nil,
        discoveryService: (any RepositoryDiscoveryProviding)? = nil,
        discoveryCacheIdentity: @escaping () -> SearchDiscoveryCacheIdentity = {
            .constant
        },
        discoveryNow: @escaping () -> Date = { Date() }
    ) {
        self.coordinator = coordinator
        self.historyRepository = historyRepository
        self.includeWebInAll = includeWebInAll
        self.entitlementGate = entitlementGate
        self.telemetryManager = telemetryManager
        self.intentRouter = intentRouter
        self.discoveryService = discoveryService
        self.discoveryCacheIdentity = discoveryCacheIdentity
        self.discoveryNow = discoveryNow
        self.webSearchProvider = AppSettings.shared.externalSearchDefaultProvider

        // 历史加载放在 `present()` 触发，不在 init 做。
        //
        // HOM-199 修复（dong4j 2026-06-14）：原实现在 init 里 `Task { await reloadHistory() }`,
        // 但 HomeView.init 与 AppDependencies.init 同步发生在 `_anonymous` 占位 DB 阶段
        // （D-30 多账号 DB 隔离），此时 `historyRepository.fetchAll()` 命中的是空的占位库；
        // 之后 `AuthSession.restoreSessionIfAvailable` → `database.reopen(userId:)` 把 DB
        // pool 切到该 user 的真实 SQLite，但本 VM 没有任何路径再拉一次 → `history` 永远停留
        // 在空快照，用户必须先 submit 一次才能间接触发 `reloadHistory()`（见 `submit()`）
        // 把真实历史搬上来。
        //
        // 修法选型（dong4j 选择方案 2，与 AuthSession 解耦）：每次 `present()` 时按需 reload。
        // 代价：首次打开会多一次 SQLite 读（50 行表，<1ms）；收益：彻底回避 DB 切换时序窗口，
        // ViewModel 不需要订阅 AuthSession.state，分层依然干净。
    }

    var candidates: [SearchCandidate] {
        let candidates = unfilteredCandidates
        guard let resultFilter else { return candidates }
        return matchingCandidates(resultFilter, in: candidates)
    }

    /// 内容策略与多来源合并先完成，再应用底栏筛选；计数始终基于这一完整快照。
    private var unfilteredCandidates: [SearchCandidate] {
        var repositories = coordinator.repositories
        var repositoryIndices = Dictionary(uniqueKeysWithValues: repositories.enumerated().map {
            ($0.element.id, $0.offset)
        })
        var references = coordinator.references
        var seenReferenceIDs = Set(references.map(\.id))

        // 同一个仓库只显示一行，但保留发现来源和理由；否则本地命中会吞掉发现标记，
        // 导致列表已有候选而“智能发现”计数为零。库内状态继续以基础结果为准。
        if scope == .all, let latestDiscoveryResult {
            for candidate in latestDiscoveryResult.repositories {
                if let index = repositoryIndices[candidate.id] {
                    repositories[index].discovery = candidate.discovery
                    repositories[index].sources.formUnion(candidate.sources)
                    repositories[index].remoteRepo = repositories[index].remoteRepo ?? candidate.remoteRepo
                } else {
                    repositoryIndices[candidate.id] = repositories.count
                    repositories.append(candidate)
                }
            }
            // AI 取证许可与资料卡展示是两个开关；隐藏网页卡片仍保留仓库的证据链接。
            if includeWebInAll() {
                for reference in latestDiscoveryResult.references
                where seenReferenceIDs.insert(reference.id).inserted {
                    references.append(reference)
                }
            }
            // 只认同一轮模型给出的相对顺序；基础来源的分数没有共同量纲。
            var ranks: [String: Int] = [:]
            for (index, candidate) in latestDiscoveryResult.repositories.enumerated()
            where candidate.discovery?.kind == .modelMatch {
                ranks[candidate.identity.normalizedFullName] = candidate.discovery?.rank ?? index
            }
            repositories = repositories.enumerated().sorted { left, right in
                let leftRank = ranks[left.element.identity.normalizedFullName]
                let rightRank = ranks[right.element.identity.normalizedFullName]
                if leftRank != rightRank {
                    return (leftRank ?? Int.max) < (rightRank ?? Int.max)
                }
                return left.offset < right.offset
            }.map(\.element)
        }

        let blockedIDs = contentSummary.blockedIDs
        return repositories.filter { !blockedIDs.contains($0.contentKey) }.map(SearchCandidate.repository)
            + references.filter { !blockedIDs.contains($0.contentKey) }.map(SearchCandidate.reference)
    }

    /// 普通来源只认基础搜索的贡献，避免发现链路内部的 GitHub 请求膨胀普通来源计数。
    /// 对同仓库保留多来源身份，因此关键词与语义同时命中时，两种筛选都能看到它。
    private func matchingCandidates(
        _ filter: SearchResultFilter,
        in candidates: [SearchCandidate]
    ) -> [SearchCandidate] {
        switch filter {
        case .source(let source):
            let repositoryIDs = Set(coordinator.repositories.filter { $0.sources.contains(source) }.map(\.id))
            let referenceIDs = Set(coordinator.references.filter { $0.source == source }.map(\.id))
            return candidates.filter { candidate in
                switch candidate {
                case .repository(let repository): return repositoryIDs.contains(repository.id)
                case .reference(let reference): return referenceIDs.contains(reference.id)
                }
            }
        case .discovery:
            return candidates.filter { candidate in
                if case .repository(let repository) = candidate { return repository.discovery != nil }
                return false
            }
        }
    }

    /// 与对应筛选列表一致的去重数，不受当前选择了哪个来源影响。
    func resultCount(for source: SearchSource) -> Int {
        matchingCandidates(.source(source), in: unfilteredCandidates).count
    }

    /// 空结果等待态只关心当前所选来源，不能被其他来源的在途请求遮成空白。
    var isResultFilterSearching: Bool {
        switch resultFilter {
        case .source(let source):
            if case .loading = coordinator.status(for: source) { return true }
            return false
        case .discovery: return isDiscoveryRunning
        case nil: return false
        }
    }

    /// 再次点击同一胶囊恢复全部；列表和键盘位置一起重置，不触碰 Provider 快照。
    func toggleResultFilter(_ filter: SearchResultFilter) {
        resultFilter = resultFilter == filter ? nil : filter
        selectedIndex = nil
        resultListEpoch += 1
    }

    /// 合并已接入的统计，不在 SwiftUI 派生状态中重新归一化或扫描候选文字。
    var contentSummary: SearchContentSummary {
        var summary = coordinator.contentSummary
        if let latestDiscoveryResult { summary.formUnion(latestDiscoveryResult.contentSummary) }
        return summary
    }

    /// 与实际展示列表同口径：只计去重后的发现仓库，不包含网页资料或 API 命中总数。
    var discoveryResultCount: Int {
        matchingCandidates(.discovery, in: unfilteredCandidates).count
    }

    var hasDiscoveryFailures: Bool {
        discoveryDiagnostics.contains(where: \.isFailure)
    }

    /// 详情面板的展示条件：有诊断（失败或上限）或有真实执行步骤可看。
    var hasDiscoveryDetails: Bool {
        !discoveryDiagnostics.isEmpty || !discoverySteps.isEmpty || contentSummary.checkedCount > 0
    }

    var contentSummaryText: String {
        let summary = contentSummary
        return String(
            format: String.l10n("search.content.summaryFormat"),
            summary.checkedCount, summary.hiddenCount, summary.retainedCount
        )
    }

    /// 详情面板展示的真实执行步骤。成功结果优先用发现服务返回的完整快照，
    /// 路由/规划失败时回落到会话里 ViewModel 记录的局部步骤。
    var discoverySteps: [SearchDiscoveryStep] {
        guard discoverySession != nil else { return [] }
        return latestDiscoveryResult?.steps ?? discoverySession?.steps ?? []
    }

    var selectedCandidate: SearchCandidate? {
        guard let selectedIndex, candidates.indices.contains(selectedIndex) else { return nil }
        return candidates[selectedIndex]
    }

    var isSearching: Bool {
        activeSources.contains { source in
            if case .loading = coordinator.status(for: source) { return true }
            return false
        }
            || isDiscoveryRunning
    }

    /// 结果区不再叠浮层错误；完整句留给 footer chip 的 tooltip，
    /// 短标签走 `footerErrors`，避免底栏被长文案挤爆。
    var errorMessages: [String] {
        footerErrors.map(\.fullMessage)
    }

    /// 底部状态栏右侧错误 chip 的数据源（短标签 + 完整原因）。
    ///
    /// 排序与历史 `errorMessages` 一致，保证多来源同时失败时顺序稳定、不抖动。
    var footerErrors: [SearchFooterError] {
        coordinator.statuses.compactMap { source, status -> SearchFooterError? in
            guard activeSources.contains(source) else { return nil }
            guard case .failed(let message) = status else { return nil }
            // `localSemantic` / 各 provider rawValue 对用户不友好；短标签与完整句
            // 都走产品向本地化名，避免底栏出现调试标识。
            let sourceName: String
            switch source {
            case .localSemantic:
                sourceName = String.l10n("search.mode.semantic")
            case .localKeyword:
                sourceName = String.l10n("search.footer.source.local")
            case .github:
                sourceName = String.l10n("search.footer.source.github")
            case .web:
                sourceName = String.l10n("search.footer.source.web")
            }
            return SearchFooterError(
                source: source,
                shortLabel: String.l10n(Self.footerErrorShortKey(for: source)),
                fullMessage: "\(sourceName): \(message)"
            )
        }
        .sorted { $0.fullMessage < $1.fullMessage }
    }

    private static func footerErrorShortKey(for source: SearchSource) -> String {
        switch source {
        case .localSemantic:
            return "search.footer.error.semantic"
        case .localKeyword:
            return "search.footer.error.localKeyword"
        case .github:
            return "search.footer.error.github"
        case .web:
            return "search.footer.error.web"
        }
    }

    var canLoadMoreGitHub: Bool {
        !isLoadingGitHub && coordinator.loadedPage(for: .github)?.hasNextPage == true
    }

    var isLoadingGitHub: Bool {
        guard case .loading = coordinator.status(for: .github) else { return false }
        return true
    }

    var canLoadMoreWeb: Bool {
        externalSearchFilters.maxResults < 100
            && !isLoadingWeb
            && coordinator.loadedPage(for: .web)?.hasNextPage == true
    }

    var isLoadingWeb: Bool {
        guard case .loading = coordinator.status(for: .web) else { return false }
        return true
    }

    var githubResultSummary: String? {
        guard case .loaded(let page) = coordinator.status(for: .github), let total = page.totalCount else { return nil }
        if total > 1_000 {
            return String(format: String.l10n("search.github.summary.cappedFormat"), total)
        }
        return String(format: String.l10n("search.github.summary.format"), total)
    }

    /// 网页搜索（AnySearch）成功响应后的页级元信息。
    ///
    /// 只在 web provider 处于 `.loaded` 状态时非 nil；用于驱动浮层底部 footer
    /// 的"X 条结果 · 用时 Y.Ys"摘要 chip 和"剩余 N/M"限流 chip。
    ///
    /// 关键约束：
    /// - 调用方（SearchCenterView）拿到非 nil 后应**进一步判空**`rateLimit` 字段，
    ///   因为 header 三字段缺一不全时 `rateLimit == nil` 但 metadata 仍可能有效。
    /// - status 在 `.idle` / `.loading` / `.failed` 时返回 nil，footer 不渲染。
    var webMetadata: WebSearchMetadata? {
        guard case .loaded(let page) = coordinator.status(for: .web) else { return nil }
        return page.webMetadata
    }

    /// 当前 scope 下、各 provider 已加载的命中数。
    ///
    /// `.web` footer 仍走这里（含用时的汇总 chip）。`.all` / `.local` 的底栏
    /// 已改用 `processChips`，把关键词与语义拆开，并在搜索过程中显示「搜索中」。
    /// 本属性保留给 `.web` 与尚未切到过程 chip 的调用方，避免再发明一套计数。
    ///
    /// - `.all`：返回三段（本地关键词 / GitHub / 网页），只包含已加载的来源。
    ///   语义仍不计列，避免与过程 chip 双计。
    /// - `.web`：返回单段（网页）。
    /// - `.local` / `.github`：返回空数组。
    ///   - `.local` 走 `processChips`。
    ///   - `.github` 命中数已通过 `githubResultSummary` 在 githubFilterBar 显示。
    var resultCounts: [ResultSourceCount] {
        let sources: [SearchSource]
        switch scope {
        case .all:
            sources = [.localKeyword, .github, .web]
        case .web:
            sources = [.web]
        case .local, .github:
            return []
        }
        return sources.compactMap { source in
            guard case .loaded = coordinator.status(for: source) else { return nil }
            return ResultSourceCount(source: source, count: resultCount(for: source))
        }
    }

    /// `.all` / `.local` 底栏过程 chip：谁还在搜、谁已经返回了几条。
    ///
    /// 关键词与语义并行，不能合成「本地 N」——否则语义还在跑时用户会以为本地已结束。
    /// 失败来源只在被选中时保留可取消胶囊；其余失败交给右侧 `footerErrors`。
    var processChips: [SearchProcessChip] {
        processChipSources.compactMap { source -> SearchProcessChip? in
            switch coordinator.status(for: source) {
            case .loading:
                return SearchProcessChip(source: source, phase: .loading)
            case .loaded:
                return SearchProcessChip(source: source, phase: .loaded(resultCount(for: source)))
            case .failed:
                guard resultFilter == .source(source) else { return nil }
                return SearchProcessChip(
                    source: source,
                    phase: .failed(String.l10n(Self.footerErrorShortKey(for: source)))
                )
            case .idle:
                return nil
            }
        }
    }

    /// 至少有一个当前范围内的来源已经 loaded / failed
    /// 关键词先返回 0 时必须为 true，这样结果区不再继续画 8 行假骨架。
    var hasSettledSearchProvider: Bool {
        activeSources.contains { source in
            switch coordinator.status(for: source) {
            case .loaded, .failed:
                return true
            case .idle, .loading:
                return false
            }
        }
    }

    /// 继续查找的入口条件。上限 3 轮可防止用户误触造成无限远端消耗。
    var canContinueDiscovery: Bool {
        let currentRound = discoverySession?.round ?? 0
        guard scope == .all,
              !isDiscoveryRunning,
              coordinator.blockedQuery == nil,
              intentRouter != nil,
              discoveryService != nil,
              discoverySession?.phase.canContinue == true,
              currentRound < 3
        else { return false }
        return true
    }

    /// 显式智能查找只在没有智能分支或上一轮失败时展示；成功结果继续走“继续查找”。
    var canStartSmartDiscovery: Bool {
        guard scope == .all,
              !isDiscoveryRunning,
              coordinator.blockedQuery == nil,
              !lastSubmittedQuery.isEmpty
        else { return false }
        return discoverySession == nil || discoverySession?.phase.isFailed == true
    }

    func evidence(for candidate: RepositoryCandidate) -> [SearchEvidence] {
        let ids = Set(candidate.discovery?.evidenceIDs ?? [])
        return (discoverySession?.evidence ?? []).filter { ids.contains($0.id) && $0.isValid }
    }

    /// 骨架只在「这次提交后谁都还没落地」时出现。
    /// 任一 provider 已返回（含 0 条）且列表仍空：交给空白等待区 + 底栏过程文案。
    var shouldShowSearchSkeleton: Bool {
        candidates.isEmpty && isSearching && !hasSettledSearchProvider
    }

    /// 加载态必须覆盖当前范围的全部来源，不能复用为了底栏排版而裁剪过的 chip 集合
    private var activeSources: [SearchSource] {
        switch scope {
        case .all:
            var sources: [SearchSource] = [.localKeyword, .localSemantic, .github]
            if includeWebInAll() {
                sources.append(.web)
            }
            return sources
        case .local:
            return [.localKeyword, .localSemantic]
        case .github:
            return [.github]
        case .web:
            return [.web]
        }
    }

    /// 远端独立范围保留原有摘要排版，但仍参与加载态判断
    private var processChipSources: [SearchSource] {
        scope == .all || scope == .local ? activeSources : []
    }

    func present(scope requestedScope: SearchScope? = nil) {
        // 重新打开只恢复面板，不重置选中项或重新搜索。用户误点遮罩关闭后应回到
        // 原来的 query、scope、filters、结果和键盘位置。
        let shouldRefreshScope = requestedScope.map { $0 != scope } ?? false
        if let requestedScope {
            if shouldRefreshScope { resultFilter = nil }
            scope = requestedScope
        }
        isPresented = true
        // HOM-199 修复：每次打开都 fire-and-forget 拉一次最新历史。
        // - 首次打开（init 后从未加载）→ 把历史从真实 user DB 填进来；
        // - 后续打开 → 顺便吸收上一次提交可能并发产生的写入（成本：单次 50 行表 SQLite read）。
        // 用 detached-on-MainActor 模式：本 VM 是 @MainActor，`Task { ... }` 继承 actor，
        // SwiftUI Button 调用 present() 时不需要 await，UI 已经显示后历史会异步填充。
        Task {
            await self.reloadHistory()
            if shouldRefreshScope, let requestedScope {
                // “列表搜索”快捷键与 toolbar 入口复用同一 Search Center，只把初始
                // scope 切到 Local；已有 query 时按来源复用，不能展示旧 scope 的 GitHub 结果。
                await self.changeScope(requestedScope)
            }
        }
    }

    func dismiss() {
        // dismiss 仅控制可见性。真正清空会话只允许走 clear() 或提交空 query，
        // 否则点击浮层外部 / Esc 会让用户被迫重复远端搜索。
        isPresented = false
    }

    func submit() async {
        resultFilter = nil
        let request = makeRequest(query: query)
        guard !request.query.isEmpty else {
            cancelActiveSearch()
            coordinator.reset()
            lastSubmittedQuery = ""
            selectedIndex = nil
            return
        }
        guard canRunExplicitWebSearch(request) else { return }
        guard coordinator.allowsQuery(request.query) else {
            cancelActiveSearch()
            lastSubmittedQuery = request.query
            selectedIndex = nil
            return
        }

        lastSubmittedQuery = request.query
        let task = startExclusiveSearchOperation(.submit(request))
        await awaitSearchTasks([task])
    }

    private func performSubmit(_ request: SearchRequest, generation: UUID) async {
        lastSubmittedQuery = request.query
        // 历史记录持久化 + 重新加载：try? 静默吞错避免 SQLite 异常炸 UI；
        // 真实失败留到 W5 接 CloudKit 时一起观测。
        try? await historyRepository.record(request.query)
        guard isActiveSearch(generation) else {
            resetIfSearchCancelled(generation)
            return
        }
        await reloadHistory()
        guard isActiveSearch(generation) else {
            resetIfSearchCancelled(generation)
            return
        }
        selectedIndex = nil
        telemetryManager?.track(
            .searchPerformed,
            properties: [.source: .string(request.scope.rawValue)]
        )
        // Getting Started 清单的“试用一次搜索”对应真实提交行为，而不是只打开搜索面板。
        NotificationCenter.default.post(name: .gettingStartedDidUseSearch, object: nil)

        let cacheKey = SearchDiscoveryCacheKey(
            request: request,
            identity: requestCacheIdentity,
            policyVersion: coordinator.contentPolicy.version
        )
        let now = discoveryNow()
        discoveryCache = discoveryCache.filter {
            $0.key.identity == cacheKey.identity
                && $0.key.policyVersion == cacheKey.policyVersion
                && now.timeIntervalSince($0.value.createdAt) < Self.discoveryCacheTTL
        }
        if let cached = discoveryCache[cacheKey] {
            let baseSearchTask = Task {
                guard !Task.isCancelled else { return }
                await coordinator.search(request)
            }
            applyDiscovery(cached.result, cacheRequest: nil)
            await awaitSearchTasks([baseSearchTask])
            guard isActiveSearch(generation) else {
                resetIfSearchCancelled(generation)
                return
            }
            clampSelection()
            return
        }

        // 先启动基础搜索，再让 Router 做 LLM 分类/规划；两者都挂在 MainActor
        // 的服务上，但网络等待会让出 actor，因此本地和远端结果可以并行落地。
        let baseSearchTask = Task {
            guard !Task.isCancelled else { return }
            await coordinator.search(request)
        }
        let deadline = Date().addingTimeInterval(SearchDiscoveryBudget.firstRound.timeoutSeconds)
        let routingOutcome: SearchIntentRoutingOutcome?
        if let intentRouter, request.scope == .all {
            discoverySession = SearchDiscoverySession(
                generation: discoveryGeneration,
                round: 1,
                phase: .routing
            )
            routingOutcome = await intentRouter.route(
                query: request.query, explicitSmartDiscovery: false, deadline: deadline
            )
        } else {
            routingOutcome = nil
        }
        guard isActiveSearch(generation) else {
            baseSearchTask.cancel()
            resetIfSearchCancelled(generation)
            return
        }

        if routingOutcome?.route == .smartDiscovery {
            // 基础召回与规划已并行执行；重排前等待同次基础快照，避免只给新增候选排序。
            await awaitSearchTasks([baseSearchTask])
            guard isActiveSearch(generation) else {
                resetIfSearchCancelled(generation)
                return
            }
            let discoveryTask = startDiscovery(
                query: request.query,
                request: request,
                plan: routingOutcome?.plan,
                round: 1,
                initialSteps: routingOutcome?.steps ?? [],
                deadline: deadline,
                generation: generation
            )
            await awaitSearchTasks([baseSearchTask, discoveryTask])
        } else if case .failed(let message) = routingOutcome?.plannerStatus {
            // Planner 在 Router 内失败时不会进入 Discovery Service；这里必须留下
            // failed 会话，否则用户只能看到基础搜索，无法知道智能分支为何没有启动。
            discoverySession = SearchDiscoverySession(
                generation: discoveryGeneration,
                round: 1,
                phase: .failed(message),
                usedLLMCalls: 1,
                steps: routingOutcome?.steps ?? []
            )
            discoveryDiagnostics = [routingOutcome?.diagnostic ?? SearchDiscoveryDiagnostic(
                stage: .planning,
                kind: .failure,
                message: message
            )]
            await awaitSearchTasks([baseSearchTask])
        } else {
            discoverySession = nil
            discoveryDiagnostics = []
            await awaitSearchTasks([baseSearchTask])
        }
        guard isActiveSearch(generation) else {
            resetIfSearchCancelled(generation)
            return
        }
        clampSelection()
    }

    func changeScope(_ newScope: SearchScope) async {
        resultFilter = nil
        scope = newScope
        resultListEpoch += 1
        guard canRunExplicitWebSearch(makeRequest(query: query)) else { return }
        guard !lastSubmittedQuery.isEmpty else { return }
        query = lastSubmittedQuery
        selectedIndex = nil
        await coordinator.updateScope(makeRequest(query: lastSubmittedQuery))
        clampSelection()
    }

    func useHistory(_ entry: SearchHistory) async {
        query = entry.query
        await submit()
    }

    func clear() {
        cancelActiveSearch()
        resultFilter = nil
        query = ""
        lastSubmittedQuery = ""
        selectedIndex = nil
        coordinator.reset()
        resetDiscoveryState()
    }

    /// 用户显式触发下一轮发现。Router 跳过分类并重新规划，基础结果保持不变。
    func continueDiscovery() async {
        guard canContinueDiscovery, let previousSession = discoverySession else { return }
        let request = makeRequest(query: lastSubmittedQuery)
        guard coordinator.allowsQuery(request.query) else {
            resetDiscoveryState()
            return
        }
        let task = startExclusiveSearchOperation(.continueDiscovery(request, previousSession.round + 1))
        await awaitSearchTasks([task])
    }

    private func performContinueDiscovery(_ request: SearchRequest, round: Int, generation: UUID) async {
        let previousResult = latestDiscoveryResult
        discoverySession = SearchDiscoverySession(
            generation: generation,
            round: round,
            phase: .routing
        )
        let discoveryTask = startDiscovery(
            query: request.query,
            request: request,
            plan: previousResult?.session.plan,
            round: round,
            generation: generation,
            previousResult: previousResult
        )
        await awaitSearchTasks([discoveryTask])
    }

    /// 显式按钮触发；不重跑基础搜索，只让 Planner 重新规划并执行一轮发现。
    func startSmartDiscovery() async {
        guard canStartSmartDiscovery else { return }
        let request = makeRequest(query: lastSubmittedQuery)
        guard coordinator.allowsQuery(request.query) else {
            resetDiscoveryState()
            return
        }
        let task = startExclusiveSearchOperation(.smartDiscovery(request))
        await awaitSearchTasks([task])
    }

    private func performSmartDiscovery(_ request: SearchRequest, generation: UUID) async {
        discoverySession = SearchDiscoverySession(
            generation: generation,
            round: 1,
            phase: .routing
        )
        guard let intentRouter else {
            discoverySession = SearchDiscoverySession(
                generation: generation,
                round: 1,
                phase: .failed("Discovery router is unavailable")
            )
            discoveryDiagnostics = [.unavailable(stage: .planning)]
            return
        }
        let deadline = Date().addingTimeInterval(SearchDiscoveryBudget.firstRound.timeoutSeconds)
        let outcome = await intentRouter.route(
            query: request.query, explicitSmartDiscovery: true, deadline: deadline
        )
        guard isActiveSearch(generation) else {
            resetIfSearchCancelled(generation)
            return
        }
        guard outcome.route == .smartDiscovery else {
            if case .failed(let message) = outcome.plannerStatus {
                discoverySession = SearchDiscoverySession(
                    generation: generation,
                    round: 1,
                    phase: .failed(message),
                    usedLLMCalls: 1,
                    steps: outcome.steps
                )
                discoveryDiagnostics = [outcome.diagnostic ?? SearchDiscoveryDiagnostic(
                    stage: .planning,
                    kind: .failure,
                    message: message
                )]
            } else {
                discoverySession = nil
                discoveryDiagnostics = []
            }
            return
        }
        let discoveryTask = startDiscovery(
            query: request.query,
            request: request,
            plan: outcome.plan,
            round: 1,
            initialSteps: outcome.steps,
            deadline: deadline,
            generation: generation
        )
        await awaitSearchTasks([discoveryTask])
    }

    private enum SearchCenterOperation {
        case submit(SearchRequest)
        case continueDiscovery(SearchRequest, Int)
        case smartDiscovery(SearchRequest)
    }

    /// 所有会触发远端智能链路的入口都必须先取消上一条链路，再固定同一请求身份。
    private func startExclusiveSearchOperation(_ operation: SearchCenterOperation) -> Task<Void, Never> {
        searchTask?.cancel()
        let generation = UUID()
        searchGeneration = generation
        requestCacheIdentity = discoveryCacheIdentity()
        if case .continueDiscovery = operation {
            // 续查是一轮追加；取消任务但保留列表和证据，避免等待或失败时卡片消失。
            discoveryTask?.cancel()
            discoveryTask = nil
            discoveryDiagnostics = []
        } else {
            resetDiscoveryState(keepCache: true)
        }
        discoveryGeneration = generation

        let task = Task { [weak self] in
            guard let self else { return }
            switch operation {
            case .submit(let request):
                await self.performSubmit(request, generation: generation)
            case .continueDiscovery(let request, let round):
                await self.performContinueDiscovery(request, round: round, generation: generation)
            case .smartDiscovery(let request):
                await self.performSmartDiscovery(request, generation: generation)
            }
        }
        searchTask = task
        return task
    }

    private func isActiveSearch(_ generation: UUID) -> Bool {
        searchGeneration == generation && !Task.isCancelled
    }

    private func resetIfSearchCancelled(_ generation: UUID) {
        guard searchGeneration == generation else { return }
        resetDiscoveryState(keepCache: true)
    }

    private func cancelActiveSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration = UUID()
        resetDiscoveryState()
    }

    /// 子任务是非结构化 Task，不会继承外层取消；等待点必须显式向下传导。
    private func awaitSearchTasks(_ tasks: [Task<Void, Never>]) async {
        await withTaskCancellationHandler {
            for task in tasks {
                await task.value
            }
        } onCancel: {
            tasks.forEach { $0.cancel() }
        }
    }

    private func startDiscovery(
        query: String,
        request: SearchRequest,
        plan: SearchDiscoveryPlan?,
        round: Int,
        initialSteps: [SearchDiscoveryStep] = [],
        deadline: Date? = nil,
        generation: UUID? = nil,
        previousResult: RepositoryDiscoveryResult? = nil
    ) -> Task<Void, Never> {
        guard let discoveryService else {
            discoverySession = SearchDiscoverySession(
                generation: generation ?? UUID(),
                round: round,
                phase: .failed("Discovery service is unavailable")
            )
            discoveryDiagnostics = [.unavailable(stage: .planning)]
            return Task {}
        }
        let generation = generation ?? UUID()
        let service = discoveryService
        let seedRepositories = coordinator.repositories + (previousResult?.repositories ?? [])
        let cacheKey = SearchDiscoveryCacheKey(
            request: request,
            identity: requestCacheIdentity,
            policyVersion: coordinator.contentPolicy.version
        )
        discoveryGeneration = generation
        isDiscoveryRunning = true
        discoveryDiagnostics = []
        discoverySession = SearchDiscoverySession(
            generation: generation,
            round: round,
            phase: .planning,
            plan: plan,
            evidence: previousResult?.session.evidence ?? [],
            usedLLMCalls: previousResult == nil ? 1 : 0,
            steps: initialSteps
        )
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await service.discover(
                query: query,
                request: request,
                initialPlan: plan,
                generation: generation,
                round: round,
                budget: .firstRound,
                initialLLMCalls: previousResult == nil ? 1 : 0,
                deadline: deadline,
                previousResult: previousResult,
                seedRepositories: seedRepositories
            )
            // 旧轮响应一律丢弃；即使 Provider 未响应取消，也不会覆盖新查询。
            guard self.discoveryGeneration == generation,
                  self.searchTask?.isCancelled != true else { return }
            self.applyDiscovery(
                result, cacheRequest: cacheKey, initialSteps: initialSteps, previousResult: previousResult
            )
        }
        discoveryTask = task
        return task
    }

    private func applyDiscovery(
        _ unfilteredResult: RepositoryDiscoveryResult,
        cacheRequest: SearchDiscoveryCacheKey?,
        initialSteps: [SearchDiscoveryStep] = [],
        previousResult: RepositoryDiscoveryResult? = nil
    ) {
        guard unfilteredResult.session.phase != .cancelled else {
            resetDiscoveryState(keepCache: true)
            return
        }
        let result = applyingDiscoveryLibraryUpdates(coordinator.contentPolicy.filtering(
            previousResult.map { Self.mergingDiscovery($0, with: unfilteredResult) } ?? unfilteredResult
        ))
        discoverySession = result.session
        latestDiscoveryResult = result
        discoveryDiagnostics = result.diagnostics
        isDiscoveryRunning = false
        discoveryTask = nil
        // Router 已执行的规划必须进入最终快照；服务收到现成计划时不会再次执行，
        // 不能在服务结果覆盖会话时把前置步骤丢掉，也不能将缓存中的合并步骤重复追加。
        let initialIDs = Set(initialSteps.map(\.id))
        var steps = initialSteps + result.steps.filter { !initialIDs.contains($0.id) }
        if result.session.phase.canContinue, !steps.contains(where: { $0.stage == .merging }) {
            let mergeStart = Date()
            let mergedCount = candidates.count
            steps.append(SearchDiscoveryStep(
                id: "merging",
                stage: .merging,
                state: .completed,
                detail: String(format: String.l10n("search.discovery.step.countFormat"), mergedCount),
                durationSeconds: max(0, Date().timeIntervalSince(mergeStart))
            ))
        }
        let session = SearchDiscoverySession(
            generation: result.session.generation,
            round: result.session.round,
            phase: result.session.phase,
            plan: result.session.plan,
            evidence: result.session.evidence,
            usedLLMCalls: result.session.usedLLMCalls,
            usedWebQueries: result.session.usedWebQueries,
            usedGitHubQueries: result.session.usedGitHubQueries,
            steps: steps
        )
        let snapshot = RepositoryDiscoveryResult(
            session: session,
            repositories: result.repositories,
            references: result.references,
            diagnostics: result.diagnostics,
            contentSummary: result.contentSummary
        )
        discoverySession = session
        latestDiscoveryResult = snapshot
        if let cacheRequest,
           result.session.phase.isCacheable,
           !result.diagnostics.contains(where: \.isFailure),
           cacheRequest.identity == discoveryCacheIdentity() {
            discoveryCache[cacheRequest] = SearchDiscoveryCacheEntry(
                result: snapshot,
                createdAt: discoveryNow()
            )
        }
    }

    /// 续查只替换同仓库的新事实；空结果或局部失败仍保留前轮成功候选及其可追溯证据。
    private static func mergingDiscovery(
        _ previous: RepositoryDiscoveryResult,
        with current: RepositoryDiscoveryResult
    ) -> RepositoryDiscoveryResult {
        var repositories = current.repositories
        for candidate in previous.repositories {
            if let index = repositories.firstIndex(where: { $0.id == candidate.id }) {
                repositories[index].sources.formUnion(candidate.sources)
            } else {
                repositories.append(candidate)
            }
        }
        repositories = repositories.enumerated().map { index, candidate in
            var candidate = candidate
            if let annotation = candidate.discovery {
                candidate.discovery = SearchDiscoveryAnnotation(
                    reason: annotation.reason, evidenceIDs: annotation.evidenceIDs, rank: index, kind: annotation.kind
                )
            }
            return candidate
        }
        var referenceIDs = Set(previous.references.map(\.id))
        let references = previous.references + current.references.filter { referenceIDs.insert($0.id).inserted }
        var evidenceIDs = Set(previous.session.evidence.map(\.id))
        let evidence = previous.session.evidence + current.session.evidence.filter { evidenceIDs.insert($0.id).inserted }
        let steps = previous.steps + current.steps.map {
            SearchDiscoveryStep(
                id: "round-\(current.session.round)-\($0.id)",
                stage: $0.stage, state: $0.state, detail: $0.detail,
                durationSeconds: $0.durationSeconds, model: $0.model, technicalDetail: $0.technicalDetail
            )
        }
        var phase = current.session.phase
        if !repositories.isEmpty {
            if phase == .noResults { phase = .completed }
            if phase.isFailed { phase = .partialFailure }
        }
        var summary = previous.contentSummary
        summary.formUnion(current.contentSummary)
        return RepositoryDiscoveryResult(
            session: SearchDiscoverySession(
                generation: current.session.generation, round: current.session.round, phase: phase,
                plan: current.session.plan ?? previous.session.plan, evidence: evidence,
                usedLLMCalls: current.session.usedLLMCalls, usedWebQueries: current.session.usedWebQueries,
                usedGitHubQueries: current.session.usedGitHubQueries, steps: steps
            ),
            repositories: repositories, references: references,
            diagnostics: current.diagnostics, contentSummary: summary
        )
    }

    /// 智能发现引用外部长时效信息。15 分钟能在重复搜索与时效性之间取得折中；
    /// 失败、部分失败和取消都不写入缓存，配置变化也通过身份键自然失效。
    private static let discoveryCacheTTL: TimeInterval = 15 * 60

    private func resetDiscoveryState(keepCache: Bool = false) {
        discoveryGeneration = UUID()
        discoveryTask?.cancel()
        discoveryTask = nil
        isDiscoveryRunning = false
        discoverySession = nil
        latestDiscoveryResult = nil
        discoveryDiagnostics = []
        if !keepCache {
            discoveryCache = [:]
        }
    }

    /// 删除单条历史。仅在用户主动点击 chip 上的 "x" 时调用，
    /// 不会重置当前的查询 / 结果 / 选中位置，保持手术式删除。
    func removeHistory(_ entry: SearchHistory) async {
        try? await historyRepository.remove(query: entry.queryLower)
        await reloadHistory()
    }

    /// 清空全部历史。视图层负责二次确认（confirmationDialog），
    /// 此处只是执行删除并刷新本地 `history` 快照。
    func clearHistory() async {
        guard !history.isEmpty else { return }
        try? await historyRepository.clearAll()
        await reloadHistory()
    }

    func applyGitHubFilters() async {
        guard !lastSubmittedQuery.isEmpty else { return }
        selectedIndex = nil
        await coordinator.updateScope(makeRequest(query: lastSubmittedQuery), refreshing: .github)
        clampSelection()
    }

    /// 应用 AnySearch 筛选条件。与 `applyGitHubFilters` 对称：触发 coordinator
    /// 重跑当前 query 的网页来源，ExternalSearchWebProvider 的 cache key 已把 filters fingerprint
    /// 纳入，新筛选不会复用旧结果。
    func applyAnySearchFilters() async {
        guard !lastSubmittedQuery.isEmpty else { return }
        guard canRunExplicitWebSearch(makeRequest(query: lastSubmittedQuery)) else { return }
        selectedIndex = nil
        await coordinator.updateScope(makeRequest(query: lastSubmittedQuery), refreshing: .web)
        clampSelection()
    }

    func changeWebSearchProvider(_ provider: ExternalSearchProviderID) async {
        webSearchProvider = provider
        guard scope == .web, !lastSubmittedQuery.isEmpty else { return }
        selectedIndex = nil
        await coordinator.updateScope(makeRequest(query: lastSubmittedQuery))
        clampSelection()
    }

    func loadMoreGitHub() async {
        guard canLoadMoreGitHub, !lastSubmittedQuery.isEmpty else { return }
        let request = makeRequest(query: lastSubmittedQuery, page: currentGitHubPage + 1)
        await coordinator.loadMore(request, source: .github)
        clampSelection()
    }

    /// Web provider 普遍没有统一 cursor/page 协议；“加载更多”通过增大 maxResults
    /// 后重跑 web source 实现，Coordinator 会按 URL 去重合并，避免重复卡片。
    func loadMoreWeb() async {
        guard canLoadMoreWeb, scope == .web, !lastSubmittedQuery.isEmpty else { return }
        externalSearchFilters.maxResults = min(externalSearchFilters.maxResults + 10, 100)
        await coordinator.loadMore(makeRequest(query: lastSubmittedQuery), source: .web)
        clampSelection()
    }

    func updateRepositoryLibraryState(
        identity: RepoIdentity,
        state: LibraryState,
        persistedRepo: Repo?
    ) {
        coordinator.updateRepositoryLibraryState(
            identity: identity,
            state: state,
            persistedRepo: persistedRepo
        )
        latestDiscoveryResult = latestDiscoveryResult.map(applyingDiscoveryLibraryUpdates)
        discoveryCache = discoveryCache.mapValues { entry in
            SearchDiscoveryCacheEntry(
                result: applyingDiscoveryLibraryUpdates(entry.result),
                createdAt: entry.createdAt
            )
        }
    }

    /// 缓存保留原过期时间，只刷新知识库事实；同一操作也覆盖后续落地的发现结果。
    private func applyingDiscoveryLibraryUpdates(_ result: RepositoryDiscoveryResult) -> RepositoryDiscoveryResult {
        RepositoryDiscoveryResult(
            session: result.session,
            repositories: coordinator.applyingLibraryUpdates(to: result.repositories),
            references: result.references, diagnostics: result.diagnostics,
            steps: result.steps, contentSummary: result.contentSummary
        )
    }

    func moveSelection(by offset: Int) {
        guard !candidates.isEmpty else { return }
        // 首次按方向键时（selectedIndex == nil）一律跳到第 0 项，让用户的注意力
        // 从"完全没选"过渡到"键盘聚焦在第一项"。后续移动维持 clamp,不环绕。
        guard let current = selectedIndex else {
            selectedIndex = 0
            return
        }
        selectedIndex = min(max(0, current + offset), candidates.count - 1)
    }

    /// 远端结果回来后修正选中索引：若 candidates 为空则回到"未选中"，
    /// 否则把可能越界的旧 index clamp 到合法范围；nil 状态保持不动。
    private func clampSelection() {
        guard !candidates.isEmpty else {
            selectedIndex = nil
            return
        }
        if let current = selectedIndex {
            selectedIndex = min(current, candidates.count - 1)
        }
    }

    /// 新查询、筛选与范围切换始终描述首页；只有显式翻页才传入下一页
    private func makeRequest(query: String, page: Int = 1) -> SearchRequest {
        SearchRequest(
            query: query,
            scope: scope,
            githubFilters: githubFilters,
            anySearchFilters: anySearchFilters,
            externalSearchFilters: externalSearchFilters,
            externalSearchProvider: scope == .web ? webSearchProvider : AppSettings.shared.externalSearchDefaultProvider,
            page: page,
            includeWebInAll: includeWebInAll(),
            minimumSemanticScore: AppSettings.shared.aiSemanticSearchScoreThreshold
        )
    }

    private func canRunExplicitWebSearch(_ request: SearchRequest) -> Bool {
        // 2026-06-21 dong4j 拍板放开 Pro 后的 stub 钩子。
        //
        // 历史行为：曾调用 `entitlementGate?.requirePro(.anySearchWeb)` 拦截非 Pro
        // 用户的 `.web` scope 搜索，失败时设 `paywallContext` 弹付费墙。
        //
        // 现在：网页搜索对所有用户开放 → body 退化为「.web scope 直接放行」。
        // 函数本身**保留**而非删除，理由：
        //  1. 调用点已经分布在 submit() / changeScope() 两条主路径，删函数要动
        //     两处调用 + 改 return 语义，diff 噪音大于收益
        //  2. 这是 free 用户「软限速」最自然的入口（每日 N 次 / 配额耗尽 → 付费墙
        //     或提示升级），未来加 AnySearch 免费配额时直接在这里补 return false 分支
        //     即可，无需重新引入函数
        //  3. 删除再复活会让 git blame 丢失"曾经放开过"的历史信号
        //
        // 未来接入示例（占位写法，**不要现在就实现**）：
        //   do {
        //       try entitlementGate?.requireFreeQuota(.anySearch, used: dailyCounter)
        //       return true
        //   } catch {
        //       paywallContext = ProPaywallContext(...)
        //       return false
        //   }
        guard request.scope == .web else { return true }
        return true
    }

    /// 从 repository 拉最新历史，按 `decayedScore` 降序写入 `history`。
    ///
    /// **为何在 ViewModel 里排序而不是 SQL**：SQLite 不内置 `pow()`，注册自定义函数
    /// 仅为这一个表的排序得不偿失；表上限 50 条，内存排序的 O(n log n) ≪ 1ms。
    private func reloadHistory() async {
        guard let entries = try? await historyRepository.fetchAll() else {
            history = []
            return
        }
        let now = Date()
        history = entries.sorted { lhs, rhs in
            lhs.decayedScore(now: now) > rhs.decayedScore(now: now)
        }
    }
}

/// 搜索过程 chip 的阶段：加载中显示「语义搜索中…」，落地后显示「语义 1」。
enum SearchProcessPhase: Equatable, Sendable {
    case loading
    case loaded(Int)
    case failed(String)
}

struct SearchProcessChip: Identifiable, Equatable, Sendable {
    let source: SearchSource
    let phase: SearchProcessPhase

    var id: String { source.rawValue }

    var labelKey: String {
        switch source {
        case .localKeyword:
            return "search.footer.source.keyword"
        case .localSemantic:
            return "search.footer.source.semantic"
        case .github:
            return "search.footer.source.github"
        case .web:
            return "search.footer.source.web"
        }
    }

    var displayText: String {
        let label = String.l10n(labelKey)
        switch phase {
        case .loading:
            return String(format: String.l10n("search.footer.loadingFormat"), label)
        case .loaded(let count):
            return String(
                format: String.l10n("search.footer.summaryFormat"),
                label,
                count
            )
        case .failed(let failureLabel):
            return failureLabel
        }
    }

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }
}

/// 单个搜索来源的命中数据（命中数 + 来源标识）。
///
/// 用于驱动浮层底部 footer 的多段 chip 展示。`id` 直接取 source.rawValue，
/// SwiftUI ForEach 复用时不会出现"两个本地段"冲突（理论上不可能，但保险）。
struct ResultSourceCount: Identifiable, Equatable, Sendable {
    let source: SearchSource
    let count: Int

    var id: String { source.rawValue }

    /// chip 上显示的来源标签 i18n key。
    /// 与 `SearchScope.titleKey` 故意分离：scope 是"我想搜什么"，
    /// source 是"结果来自哪儿"，未来可独立翻译微调。
    var labelKey: String {
        switch source {
        case .localKeyword, .localSemantic:
            return "search.footer.source.local"
        case .github:
            return "search.footer.source.github"
        case .web:
            return "search.footer.source.web"
        }
    }
}

/// 底部状态栏右侧错误 chip：短标签进栏，完整原因只放 tooltip。
///
/// 为什么拆开：完整失败句（含 Base URL / 网络说明）太长，直接塞进 footer
/// 会挤压左侧「本地 N / GitHub M」计数；短标签保留可扫读性，详情用系统 help。
struct SearchFooterError: Identifiable, Equatable, Sendable {
    let source: SearchSource
    let shortLabel: String
    let fullMessage: String

    var id: String { source.rawValue }
}
