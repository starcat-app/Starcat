//
//  KnowledgeRAGWorkspaceWindowController.swift
//  Starcat
//
//  知识库 RAG 工作台的独立 macOS 窗口外壳。
//
//  设计约束:
//  - RAG 问答和证据核验是长时间工作流,需要完整 macOS 窗口语义。
//  - 不使用主窗口 overlay,避免遮住系统红黄绿按钮和继承底层内容的 cursor rect。
//  - 内容由真实 KnowledgeRAGWorkspaceViewModel 驱动，窗口 controller 持有其 SwiftUI 根视图。
//

import AppKit
import MarkdownUI
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// 从 Metadata 正文提取可点击 Wiki 链接。只接受 Builder 的固定行格式和 http(s)，
/// 避免人工 override 中的任意 scheme 被当作可执行外链。
enum RAGMetadataWikiLinkParser {
    static func links(in content: String) -> [WikiLink] {
        content.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let mappings: [(prefix: String, source: WikiSource)] = [
                ("Wiki DeepWiki: ", .deepWiki),
                ("Wiki ZRead: ", .zread),
                ("Wiki CodeWiki: ", .codeWiki)
            ]
            guard let mapping = mappings.first(where: { line.hasPrefix($0.prefix) }),
                  let url = URL(string: String(line.dropFirst(mapping.prefix.count))),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host?.isEmpty == false else { return nil }
            return WikiLink(source: mapping.source, url: url)
        }
        .sorted { $0.source.sortOrder < $1.source.sortOrder }
    }
}

/// 知识库 RAG 工作台窗口尺寸策略。
private enum KnowledgeRAGWorkspaceWindowMetrics {
    static let defaultContentSize = NSSize(width: 1440, height: 820)
    static let minimumContentSize = NSSize(width: 1180, height: 700)
    static let autosaveName = "KnowledgeRAGWorkspaceWindow"
}

/// 知识库浏览器窗口尺寸策略。
private enum KnowledgeRAGBrowserWindowMetrics {
    static let defaultContentSize = NSSize(width: 1280, height: 800)
    static let minimumContentSize = NSSize(width: 980, height: 660)
    static let autosaveName = "KnowledgeRAGBrowserWindow.v2"
}

/// 为两个 RAG 独立窗口统一换算并执行内容区下限。
@MainActor
private enum KnowledgeRAGWindowSizePolicy {
    static func enforce(minimumContentSize: NSSize, on window: NSWindow) {
        // `contentMinSize` 描述 SwiftUI 内容区，`minSize` 描述包含标题栏的外框；
        // 两者不能直接复用同一个数值，否则恢复窗口或系统重算约束时会出现语义偏差。
        let minimumFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: minimumContentSize)
        ).size
        window.contentMinSize = minimumContentSize
        window.minSize = minimumFrameSize

        let currentFrame = window.frame
        guard currentFrame.width < minimumFrameSize.width
                || currentFrame.height < minimumFrameSize.height else { return }

        // AppKit autosave、Accessibility 和 SwiftUI 布局重算都可能直接写入一个过小 frame；
        // resize 回调再次执行这里，确保最小尺寸是运行时约束，而不只是初始化提示。
        let correctedSize = NSSize(
            width: max(currentFrame.width, minimumFrameSize.width),
            height: max(currentFrame.height, minimumFrameSize.height)
        )
        window.setFrame(
            NSRect(origin: currentFrame.origin, size: correctedSize),
            display: true,
            animate: false
        )
    }
}

/// 复用单个 RAG 工作台窗口;重复点击 toolbar 入口时把已有窗口带到前台。
final class KnowledgeRAGWorkspaceWindowController: NSWindowController, NSWindowDelegate {

    private static var shared: KnowledgeRAGWorkspaceWindowController?
    private let chromeState: WorkspaceChromeState
    private let viewModel: KnowledgeRAGWorkspaceViewModel

    /// 显示知识库 RAG 工作台窗口。
    ///
    /// `homeViewModel` 用于正文引用 / 本地 GitHub 链接打开独立详情窗，必须与主窗共享
    /// 同一实例，才能同步 star 状态。
    @MainActor
    static func show(
        dependencies: AppDependencies,
        homeViewModel: HomeViewModel
    ) {
        guard AIWorkspaceEntryGate.authorizeOpening(
            dependencies: dependencies,
            workspace: .knowledgeRAG
        ) else {
            return
        }

        let controller: KnowledgeRAGWorkspaceWindowController
        let shouldCenter: Bool

        if let shared {
            controller = shared
            shouldCenter = false
        } else {
            controller = KnowledgeRAGWorkspaceWindowController(
                dependencies: dependencies,
                homeViewModel: homeViewModel
            )
            shared = controller
            shouldCenter = true
        }

        controller.showWindow(nil)
        if let window = controller.window {
            // `showWindow` 可能恢复历史 frame；前置前再校正一次，避免旧的小窗口闪现。
            KnowledgeRAGWindowSizePolicy.enforce(
                minimumContentSize: KnowledgeRAGWorkspaceWindowMetrics.minimumContentSize,
                on: window
            )
            if shouldCenter {
                window.center()
            }
        }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 用户数据库切换前销毁旧工作台，避免旧账户的内存历史继续显示，或在切库后把
    /// 未完成回答写进新账户数据库。
    @MainActor
    static func closeForUserDatabaseChange() {
        shared?.viewModel.cancelAllAnswers()
        shared?.close()
        shared = nil
    }

    private init(
        dependencies: AppDependencies,
        homeViewModel: HomeViewModel
    ) {
        let chromeState = WorkspaceChromeState()
        let viewModel = KnowledgeRAGWorkspaceViewModel(
            dependencies: dependencies,
            homeViewModel: homeViewModel
        )
        self.chromeState = chromeState
        self.viewModel = viewModel

        let settingsNavigation = RAGSettingsNavigationAction { target in
            AppDelegate.openSettingsWindow(target: target)
        }
        let content = KnowledgeRAGWorkspaceView(chromeState: chromeState, viewModel: viewModel)
            .appHostEnvironment(dependencies, homeViewModel: homeViewModel)
            .environment(\.ragSettingsNavigation, settingsNavigation)

        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)

        window.title = String.l10n("rag.workspace.window.title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(KnowledgeRAGWorkspaceWindowMetrics.defaultContentSize)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        window.setFrameAutosaveName(KnowledgeRAGWorkspaceWindowMetrics.autosaveName)
        KnowledgeRAGWindowSizePolicy.enforce(
            minimumContentSize: KnowledgeRAGWorkspaceWindowMetrics.minimumContentSize,
            on: window
        )

        let controls = NSTitlebarAccessoryViewController()
        controls.layoutAttribute = .right
        let controlsView = NSHostingView(rootView: WorkspaceTitlebarControls(
            chromeState: chromeState,
            onPinnedChange: { [weak window] isPinned in
                window?.level = isPinned ? .floating : .normal
            },
            onSettings: {
                // 配置使用 App 级 SwiftUI Window Scene；这里不再把自绘 sheet 状态
                // 塞进工作台 chrome，重复点击也只会激活同一个原生设置窗口。
                AppDelegate.openRAGWorkspaceSettingsWindow()
            }
        ))
        // 标题栏 accessory 由 AppKit 布局；显式 frame 能避免 SwiftUI hosting view 初始 intrinsic size 为 0。
        // RAG 比 Agent 多一个齿轮（约 +34pt）。
        controlsView.frame = NSRect(x: 0, y: 0, width: 146, height: 32)
        controls.view = controlsView
        window.addTitlebarAccessoryViewController(controls)

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KnowledgeRAGWorkspaceWindowController does not support storyboard initialization")
    }

    func windowDidResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow else { return }
        KnowledgeRAGWindowSizePolicy.enforce(
            minimumContentSize: KnowledgeRAGWorkspaceWindowMetrics.minimumContentSize,
            on: resizedWindow
        )
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.persistCurrentComposerDraft()
        viewModel.cancelAllAnswers()
        window?.resignKey()
        Self.shared = nil
    }

    /// 知识库浏览器的召回测试需要复用最近一轮问答计划；工作台未打开时为 nil。
    @MainActor
    static var displayedQueryPlanForRetrievalTest: RAGQueryPlan? {
        shared?.viewModel.displayedQueryPlan
    }
}

/// 复用单个知识库浏览器窗口。它只读本地知识库数据，索引操作仍交由既有 builder 执行。
final class KnowledgeRAGBrowserWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: KnowledgeRAGBrowserWindowController?
    /// 窗口关闭时必须能取消正在下载/打包的 RepoContext 任务，不能只让 SwiftUI 视图释放。
    private let viewModel: KnowledgeRAGBrowserViewModel

    @MainActor
    static func show(
        dependencies: AppDependencies,
        homeViewModel: HomeViewModel,
        settingsNavigation: RAGSettingsNavigationAction,
        centeredOver presentingWindow: NSWindow?,
        revealingChunk: RAGChunk? = nil
    ) {
        let isNewWindow = shared == nil
        let controller = shared ?? KnowledgeRAGBrowserWindowController(
            dependencies: dependencies,
            homeViewModel: homeViewModel,
            settingsNavigation: settingsNavigation
        )
        shared = controller
        if let chunk = revealingChunk, let chunkID = chunk.id {
            // 必须在 showWindow 之前记下目标：首开时 SwiftUI `.task` bootstrap 可能立刻跑起来，
            // 晚登记会让浏览器先选中列表第一项，再跳一次。
            controller.viewModel.revealChunk(repoID: chunk.repoId, chunkID: chunkID)
        }
        controller.showWindow(nil)
        if let window = controller.window {
            KnowledgeRAGWindowSizePolicy.enforce(
                minimumContentSize: KnowledgeRAGBrowserWindowMetrics.minimumContentSize,
                on: window
            )
            if isNewWindow {
                controller.center(window, over: presentingWindow)
            }
            // makeKeyAndOrderFront 不会恢复 Dock 中的最小化窗口。复用 shared controller 时
            // 必须先解除最小化，再强制前置，保证每次点击都能看到同一个知识库窗口。
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    /// 首次打开时锚定 RAG 工作台，避免浏览器落在上一次应用启动时保存的无关位置。
    /// 已存在的窗口保留用户手动调整的位置，因此不应在每次前置时重新居中。
    private func center(_ window: NSWindow, over presentingWindow: NSWindow?) {
        guard let presentingWindow else {
            window.center()
            return
        }

        let visibleFrame = presentingWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? presentingWindow.frame
        var frame = window.frame
        frame.origin = NSPoint(
            x: presentingWindow.frame.midX - frame.width / 2,
            y: presentingWindow.frame.midY - frame.height / 2
        )
        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
        window.setFrameOrigin(frame.origin)
    }

    private init(
        dependencies: AppDependencies,
        homeViewModel: HomeViewModel,
        settingsNavigation: RAGSettingsNavigationAction
    ) {
        let viewModel = KnowledgeRAGBrowserViewModel(
            dependencies: dependencies,
            homeViewModel: homeViewModel
        )
        self.viewModel = viewModel
        let content = KnowledgeRAGBrowserView(viewModel: viewModel)
            .appHostEnvironment(dependencies, homeViewModel: homeViewModel)
            // 浏览器也是独立 NSWindow，不能依赖默认 no-op EnvironmentAction。
            .environment(\.ragSettingsNavigation, settingsNavigation)
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = ""
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // 400pt 左栏约占窗口三分之一，与知识库宽屏布局截图的栏宽比例一致；
        // 右栏保留约 880pt，分片标题、状态和行内操作不再互相挤压。
        window.setContentSize(KnowledgeRAGBrowserWindowMetrics.defaultContentSize)
        window.isReleasedWhenClosed = false
        // v2 让旧版 980×660 的已保存 frame 不覆盖新默认值；用户之后的手动尺寸仍会正常记忆。
        window.setFrameAutosaveName(KnowledgeRAGBrowserWindowMetrics.autosaveName)
        KnowledgeRAGWindowSizePolicy.enforce(
            minimumContentSize: KnowledgeRAGBrowserWindowMetrics.minimumContentSize,
            on: window
        )
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("KnowledgeRAGBrowserWindowController does not support storyboard initialization") }

    func windowDidResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow else { return }
        KnowledgeRAGWindowSizePolicy.enforce(
            minimumContentSize: KnowledgeRAGBrowserWindowMetrics.minimumContentSize,
            on: resizedWindow
        )
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.cancelRepoContextGeneration()
        viewModel.cancelRepositoryInsightsGeneration()
        Self.shared = nil
    }
}

/// 知识库详情的联合展示项。两个 XML 只存在于展示模型，绝不伪造成数据库分片。
enum KnowledgeRAGBrowserManagedItem: Identifiable {
    case chunk(RAGManagedChunk)
    case repositoryInsights(RepositoryInsightsContextArtifact)
    case repoContext(RepoContextDocument)

    var id: String {
        switch self {
        case .chunk(let managed): return "chunk:\(managed.id)"
        case .repositoryInsights(let artifact):
            return "repository-insights:\(artifact.document.repositoryID):\(artifact.document.sourceHash)"
        case .repoContext(let document): return "repo-context:\(document.id)"
        }
    }

    /// 固定顺序：Metadata → Insights XML → RepoContext XML → 普通分片。
    /// 旧数据缺 Metadata 时两个特殊项置顶，仍保持 Insights 在 RepoContext 前。
    static func merge(
        chunks: [RAGManagedChunk],
        repositoryInsights: RepositoryInsightsContextArtifact?,
        repoContext: RepoContextDocument?
    ) -> [KnowledgeRAGBrowserManagedItem] {
        var items = chunks.map(Self.chunk)
        var insertionIndex = specialContextInsertionIndex(in: chunks.map(\.chunk.source))
        if let repositoryInsights {
            items.insert(.repositoryInsights(repositoryInsights), at: insertionIndex)
            insertionIndex += 1
        }
        if let repoContext {
            items.insert(.repoContext(repoContext), at: insertionIndex)
        }
        return items
    }

    static func specialContextInsertionIndex(in sources: [RAGChunkSource]) -> Int {
        guard let metadataIndex = sources.firstIndex(of: .metadata) else { return 0 }
        return min(metadataIndex + 1, sources.count)
    }

    /// 特殊 XML 是仓库级单件产物，统计只能看文件快照是否存在，不能借用普通 chunk 数量。
    static func singletonAvailability(_ isAvailable: Bool) -> String {
        isAvailable ? "1 / 1" : "0 / 1"
    }
}

/// RepoContext XML 导出的纯文件能力。NSSavePanel 留在 View，文件名与原子写入保持可单测。
enum RepoContextXMLExport {
    static func defaultFilename(owner: String, repo: String) -> String {
        "\(safeFilenameComponent(owner))-\(safeFilenameComponent(repo))-context.xml"
    }

    static func writeDraft(_ xml: String, to url: URL) throws {
        try Data(xml.utf8).write(to: url, options: .atomic)
    }

    private static func safeFilenameComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let parts = value.components(separatedBy: invalid).filter { !$0.isEmpty }
        return parts.isEmpty ? "repository" : parts.joined(separator: "-")
    }
}

/// RepoContext 主动生成只展示 provider 能确认的真实阶段，不虚构无法测量的百分比。
enum RepoContextGenerationStep: Int, CaseIterable, Sendable, Hashable {
    case resolving
    case downloading
    case packing

    static func map(_ progress: RepoAIContextProgress) -> Self {
        switch progress {
        case .resolvingBranch, .checkingCache: return .resolving
        case .downloadingArchive: return .downloading
        case .packingContext: return .packing
        }
    }
}

/// 生成状态显式保留成功、失败与取消语义；取消完成后 UI 会收回 idle，但不会误报失败。
enum RepoContextGenerationState: Equatable, Sendable {
    case idle
    case preparing(RepoContextGenerationStep)
    case succeeded(cacheHit: Bool)
    /// 保留结构化降级原因，避免 UI 通过本地化后的 message 反推是否应展示恢复操作。
    case failed(message: String, reason: ContextDegradationReason?)
    case cancelled

    var isActive: Bool {
        if case .preparing = self { return true }
        return false
    }

    var currentStep: RepoContextGenerationStep? {
        guard case .preparing(let step) = self else { return nil }
        return step
    }

    /// repo 切换后的提示必须属于新仓库；无论旧状态是成功、失败还是活动中都收回 idle。
    func resetForRepositoryLifecycle() -> Self { .idle }
}

/// 生成结果只有同时属于当前请求和当前仓库才可回写。抽成纯值对象后，无需暴露整个
/// 浏览器 ViewModel 就能锁定取消后迟到、切仓后迟到两类竞态。
struct SpecialContextGenerationIdentity: Equatable, Sendable {
    let id: UUID
    let repoID: Int64

    func accepts(currentID: UUID?, selectedRepoID: Int64?) -> Bool {
        id == currentID && repoID == selectedRepoID
    }
}

/// 浏览器的只读状态协调器。仓库列表与聚合状态必须来自同一次刷新，避免索引重建中出现
/// “仓库已显示但统计仍属于旧模型”的错配。
@MainActor
@Observable
private final class KnowledgeRAGBrowserViewModel {
    private let dependencies: AppDependencies
    /// 与证据 tab「Starcat 详情」同路：独立详情窗需要共享 HomeViewModel 才能同步 star。
    private let homeViewModel: HomeViewModel
    /// 浏览器的分片读取与工作台会话读取一样需要防止旧请求覆盖新选择。
    private let repositorySelectionGate = RAGLatestRequestGate()

    /// 浏览器只复用索引状态纯值投影，仓库选择、分页和召回测试仍保持独立状态机。
    var indexStatus = RAGIndexStatusProjection.empty
    var candidates: [RAGRepoCandidate] = []
    var indexes: [Int64: RAGKnowledgeRepositoryIndex] = [:]
    var selectedRepoID: Int64?
    var chunks: [RAGManagedChunk] = []
    /// Inspector 点问题分片后，浏览器用它高亮并滚动到对应行。
    var highlightedChunkID: Int64?
    /// 每次定位递增，驱动左右两栏 ScrollViewReader 重新 scrollTo。
    var revealScrollNonce = 0
    /// 仓库洞察 XML 与 RepoContext 一样是文件 Artifact，不进入 `rag_chunks`。
    var repositoryInsightsArtifact: RepositoryInsightsContextArtifact?
    /// RepoContext 是文件系统产物，不进入 `rag_chunks`；浏览器只在展示层把它合并为特殊项。
    var repoContextDocument: RepoContextDocument?
    var isGeneratingRepositoryInsights = false
    private var repositoryInsightsGenerationIdentity: SpecialContextGenerationIdentity?
    private var repositoryInsightsGenerationTask: Task<Void, Never>?
    /// 取消时必须保留原 repo，不能依赖此刻可能已切换的 `selectedCandidate`。
    private var repositoryInsightsGenerationRepo: Repo?
    var repoContextGenerationState: RepoContextGenerationState = .idle
    var isRepoContextSettingsPromptPresented = false
    /// UUID 同时防护 repo 切换与“取消后旧 task 迟到回写”两类竞态。
    private var repoContextGenerationIdentity: SpecialContextGenerationIdentity?
    private var repoContextGenerationTask: Task<Void, Never>?
    private var repoContextGenerationRepo: Repo?
    var hasMoreChunks = false
    var hasMoreRepositories = false
    var isLoading = false
    var isLoadingMoreChunks = false
    var isLoadingMoreRepositories = false
    var isIndexing = false
    var isLibraryOperationInFlight = false
    /// 用户主动移出仓库后保持右栏空态；索引异步刷新不得把选择跳回第一条。
    private var preservesEmptySelection = false
    /// 首轮 `bootstrap` 完成前，Inspector 定位只登记 pending，避免和列表加载抢 selectedRepoID。
    private var hasCompletedInitialLoad = false
    private var pendingReveal: (repoID: Int64, chunkID: Int64)?
    /// 浏览器独立于 Composer「+」面板；默认最近加入知识库倒序。
    var repositorySortOption: RepoSortOption = RAGComposerMentionSort.default {
        didSet {
            guard oldValue != repositorySortOption else { return }
            scheduleRepositoryReload(force: true)
        }
    }
    var repositoryFilters: RAGComposerMentionFilters = .empty {
        didSet {
            guard oldValue != repositoryFilters else { return }
            scheduleRepositoryReload(force: true)
        }
    }
    var repositorySearchQuery = "" {
        didSet {
            guard oldValue != repositorySearchQuery else { return }
            scheduleRepositoryReload(force: false)
        }
    }
    var isRepositoryFilterPresented = false
    var isRepositoryLanguageAddPresented = false
    private var repositoryQueryTask: Task<Void, Never>?
    /// 每个仓库单独保存完成时间，切换仓库时不能借用其它仓库或全局刷新的时间。
    var selectedRepositoryRefreshAt: Date? {
        guard let selectedRepoID else { return nil }
        return dependencies.knowledgeRAGIndexBuilder.repositoryRefreshDates[selectedRepoID]
    }
    var retrievalQuery = ""
    var retrievalHits: [RAGChildHit] = []
    /// 默认全库 oracle；按当前计划需要工作台已有一轮问答计划。
    var retrievalTestMode: RAGRetrievalTestMode = .indexOracle
    /// 测试面板维护独立草稿，连续调参不会在用户明确保存前污染正式问答配置。
    var retrievalTestSettings: RAGRetrievalSettings
    var retrievalTestDiagnostics: RAGRetrievalDiagnostics?
    var isTestingRetrieval = false
    /// 仅在服务端成功返回后置位，用于区分“尚未测试”和“测试完成但无命中”。
    var hasCompletedRetrievalTest = false
    var errorMessage: String? {
        didSet {
            if errorMessage == nil { workspaceError = nil }
        }
    }
    /// 保留原始 Error 类型供共享 alert 分类；字符串只用于反馈邮件中的技术细节。
    var workspaceError: RAGWorkspaceError?

    init(dependencies: AppDependencies, homeViewModel: HomeViewModel) {
        self.dependencies = dependencies
        self.homeViewModel = homeViewModel
        self.retrievalTestSettings = dependencies.settings.ragRetrievalSettings.normalized()
    }

    func dismissError() {
        errorMessage = nil
        workspaceError = nil
    }

    /// 向量化、网络与配置错误必须保留具体类型，不能先抹平成 String 再让 UI 猜测。
    private func presentError(_ error: Error) {
        errorMessage = error.localizedDescription
        workspaceError = RAGWorkspaceError(error: error)
    }

    var embeddingModel: String { dependencies.settings.aiEmbeddingTask.resolvedModelName }
    var configuredEmbeddingModelName: String? { dependencies.settings.configuredEmbeddingModelName }
    var embeddingConfigurationIssue: AIEmbeddingError? { dependencies.settings.embeddingConfigurationIssue }
    var selectedCandidate: RAGRepoCandidate? { candidates.first(where: { $0.repo.id == selectedRepoID }) }
    var selectedIndex: RAGKnowledgeRepositoryIndex? { selectedRepoID.flatMap { indexes[$0] } }
    var managedItems: [KnowledgeRAGBrowserManagedItem] {
        KnowledgeRAGBrowserManagedItem.merge(
            chunks: chunks,
            repositoryInsights: repositoryInsightsArtifact,
            repoContext: repoContextDocument
        )
    }
    var isGeneratingRepoContext: Bool { repoContextGenerationState.isActive }

    func bootstrap() async {
        await refresh(showsLoading: true)
        hasCompletedInitialLoad = true
        await fulfillPendingReveal()
    }

    /// 供概览刷新按钮直接读 builder 状态，SwiftUI 才能订阅到 embedding 进度变化。
    var indexBuilder: KnowledgeRAGIndexBuilder { dependencies.knowledgeRAGIndexBuilder }

    func observeIndexChanges() async {
        for await _ in NotificationCenter.default.notifications(named: .knowledgeRAGIndexDidChange) {
            guard !Task.isCancelled else { break }
            await refresh()
        }
    }

    /// 索引概览刷新：启动全库重建，消化 pending / failed / stale，不是只重查统计。
    func startOverviewIndexRebuild() {
        guard !indexBuilder.status.isActivelyIndexing else { return }
        indexBuilder.startRebuild()
    }

    func resetRepositoryFilters() {
        repositoryFilters = .empty
    }

    func clearRepositorySearch() {
        repositorySearchQuery = ""
    }

    /// 关键词 120ms 合并；排序 / 筛选变更可 `force` 立即重查。
    private func scheduleRepositoryReload(force: Bool) {
        repositoryQueryTask?.cancel()
        repositoryQueryTask = Task { [weak self] in
            do {
                if !force {
                    try await Task.sleep(for: .milliseconds(120))
                }
                guard let self else { return }
                try Task.checkCancellation()
                await self.reloadRepositoriesFromStart()
            } catch is CancellationError {
                // 连续输入会取消旧查询；不是用户可见错误。
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func reloadRepositoriesFromStart() async {
        await loadRepositories(limit: Self.repositoryPageSize, append: false)
        await loadChunks()
    }

    func selectRepository(_ id: Int64, loadsChunks: Bool = true) async {
        if highlightedChunkID != nil, selectedRepoID != id {
            highlightedChunkID = nil
        }
        guard selectedRepoID != id else { return }
        cancelRepoContextGeneration()
        cancelRepositoryInsightsGeneration()
        let requestGeneration = repositorySelectionGate.begin()
        preservesEmptySelection = false
        selectedRepoID = id
        // 先清掉旧仓库 XML，避免磁盘读取完成前短暂展示上一项目的特殊行。
        repositoryInsightsArtifact = nil
        repoContextDocument = nil
        if loadsChunks {
            await loadChunks(selectionGeneration: requestGeneration)
        }
    }

    /// Inspector 问题分片卡片：打开已有窗口或等首开 bootstrap 完成后，选中仓库并滚到该分片。
    func revealChunk(repoID: Int64, chunkID: Int64) {
        pendingReveal = (repoID: repoID, chunkID: chunkID)
        highlightedChunkID = chunkID
        if hasCompletedInitialLoad {
            Task { await fulfillPendingReveal() }
        }
    }

    /// 洞察 XML 的主动生成不显示全页 loading；旧 Artifact 保持可见，成功后一次替换。
    func generateRepositoryInsights() {
        guard !isGeneratingRepositoryInsights, let repo = selectedCandidate?.repo else { return }
        let identity = SpecialContextGenerationIdentity(id: UUID(), repoID: repo.id)
        repositoryInsightsGenerationIdentity = identity
        repositoryInsightsGenerationRepo = repo
        isGeneratingRepositoryInsights = true
        let coordinator = dependencies.repositoryInsightsContextCoordinator
        repositoryInsightsGenerationTask = Task { [weak self] in
            guard let self else { return }
            let artifact = await coordinator.prepareArtifact(for: repo, mode: .forceRegenerate)
            guard !Task.isCancelled,
                  identity.accepts(
                      currentID: repositoryInsightsGenerationIdentity?.id,
                      selectedRepoID: selectedRepoID
                  ) else { return }
            if let artifact {
                repositoryInsightsArtifact = artifact
            } else {
                errorMessage = String.l10n("rag.browser.repositoryInsights.generation.failed")
            }
            repositoryInsightsGenerationIdentity = nil
            repositoryInsightsGenerationTask = nil
            repositoryInsightsGenerationRepo = nil
            isGeneratingRepositoryInsights = false
        }
    }

    func cancelRepositoryInsightsGeneration() {
        let repo = repositoryInsightsGenerationRepo
        repositoryInsightsGenerationTask?.cancel()
        repositoryInsightsGenerationTask = nil
        repositoryInsightsGenerationIdentity = nil
        repositoryInsightsGenerationRepo = nil
        isGeneratingRepositoryInsights = false
        if let repo {
            let coordinator = dependencies.repositoryInsightsContextCoordinator
            Task {
                await coordinator.cancelPreparation(for: repo, mode: .forceRegenerate)
            }
        }
    }

    /// 用户主动生成或重新生成 RepoContext。下载、缓存和打包都复用统一 provider，
    /// 知识库 UI 只负责生命周期与展示，不复制第二套文件流水线。
    func generateRepoContext() {
        guard !isGeneratingRepoContext, let repo = selectedCandidate?.repo else { return }
        guard dependencies.settings.aiRepoContextEnabled else {
            isRepoContextSettingsPromptPresented = true
            return
        }

        let generationIdentity = SpecialContextGenerationIdentity(id: UUID(), repoID: repo.id)
        repoContextGenerationIdentity = generationIdentity
        repoContextGenerationRepo = repo
        repoContextGenerationState = .preparing(.resolving)
        let provider = dependencies.repoAIContextProvider

        repoContextGenerationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await provider.contextOutcome(for: repo) { [weak self] progress in
                    guard let self,
                          generationIdentity.accepts(
                              currentID: self.repoContextGenerationIdentity?.id,
                              selectedRepoID: self.selectedRepoID
                          ) else { return }
                    self.repoContextGenerationState = .preparing(RepoContextGenerationStep.map(progress))
                }
                try Task.checkCancellation()
                guard generationIdentity.accepts(
                    currentID: repoContextGenerationIdentity?.id,
                    selectedRepoID: selectedRepoID
                ) else { return }
                switch outcome {
                case .success(let result):
                    repoContextDocument = RepoContextDocument(xml: result.xml, metadata: result.metadata)
                    repoContextGenerationState = .succeeded(cacheHit: result.cacheHit)
                case .featureDisabled:
                    // 设置可能在任务执行期间被关闭；不擅自改回开关，仍提示用户处理。
                    repoContextGenerationState = .idle
                    isRepoContextSettingsPromptPresented = true
                case .degraded(let reason):
                    // 知识库主动生成与单仓 AI 共用项目上下文 ZIP 阈值；超限时必须把
                    // 当前配置值直接告诉用户，不能回退到历史固定 100MB 文案。
                    repoContextGenerationState = .failed(
                        message: reason.bannerMessage(
                            maximumArchiveMB: dependencies.settings.aiRepoContextMaximumArchiveMB
                        ),
                        reason: reason
                    )
                }
                repoContextGenerationIdentity = nil
                repoContextGenerationTask = nil
                repoContextGenerationRepo = nil
            } catch is CancellationError {
                guard generationIdentity.accepts(
                    currentID: repoContextGenerationIdentity?.id,
                    selectedRepoID: selectedRepoID
                ) else { return }
                repoContextGenerationState = .cancelled
                repoContextGenerationState = .idle
                repoContextGenerationTask = nil
                repoContextGenerationRepo = nil
            } catch {
                guard generationIdentity.accepts(
                    currentID: repoContextGenerationIdentity?.id,
                    selectedRepoID: selectedRepoID
                ) else { return }
                repoContextGenerationState = .failed(
                    message: error.localizedDescription,
                    reason: nil
                )
                repoContextGenerationTask = nil
                repoContextGenerationRepo = nil
            }
        }
    }

    /// 停止只清理由本轮下载留下的 `.tmp`；provider 明确保留正式 ZIP 和旧有效 XML，
    /// 所以下次生成仍可命中缓存，也不会因取消丢失现有第二项。
    func cancelRepoContextGeneration() {
        let repo = repoContextGenerationRepo
        repoContextGenerationIdentity = nil
        repoContextGenerationTask?.cancel()
        repoContextGenerationTask = nil
        repoContextGenerationRepo = nil
        if isGeneratingRepoContext {
            repoContextGenerationState = .cancelled
        }
        repoContextGenerationState = repoContextGenerationState.resetForRepositoryLifecycle()
        if let repo {
            dependencies.repoAIContextProvider.cleanupTemporaryContextPreparation(for: repo)
        }
    }

    /// 移出知识库只更新知识库归属；阅读状态由用户在状态入口单独管理。
    func requestSelectedRepositoryRemoval() async {
        guard dependencies.authSession.state.isAuthenticated else {
            dependencies.authSession.requestLoginSheet()
            return
        }
        guard !isLibraryOperationInFlight, let repoID = selectedRepoID else { return }

        isLibraryOperationInFlight = true
        defer { isLibraryOperationInFlight = false }

        do {
            let state = try await dependencies.repoNoteRepository.fetchLibraryState(repoId: repoID)
            guard selectedRepoID == repoID else { return }
            guard state == .inLibrary else {
                clearRemovedRepository(repoID: repoID)
                return
            }
            await removeRepositoryFromLibrary(repoID: repoID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreChunks() async {
        guard !isLoadingMoreChunks, hasMoreChunks, selectedRepoID != nil else { return }
        isLoadingMoreChunks = true
        defer { isLoadingMoreChunks = false }
        await loadChunks(limit: Self.additionalChunkPageSize, append: true)
    }

    /// 阈值取 8 行：比贴底更早发起，滚动时下一页通常已到位。
    func loadMoreRepositoriesIfNeeded(rowIndex: Int) async {
        guard hasMoreRepositories,
              !isLoadingMoreRepositories,
              ListPaginationPolicy.shouldPrefetch(
                  appearingIndex: rowIndex,
                  itemCount: candidates.count,
                  hasMore: hasMoreRepositories
              ) else { return }
        isLoadingMoreRepositories = true
        defer { isLoadingMoreRepositories = false }
        await loadRepositories(limit: Self.repositoryPageSize, append: true)
    }

    func rebuildIndex() {
        guard !isIndexing, let repo = selectedCandidate?.repo else { return }
        guard !indexBuilder.status.isActivelyIndexing else { return }
        isIndexing = true
        Task { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let startedAt = clock.now
            do {
                try await dependencies.knowledgeRAGIndexBuilder.rebuildRepository(repo)
                await refresh()
            } catch is CancellationError {
                // 暂停或被用户全量重建替换时，单仓刷新按钮只恢复可点，不弹错误。
            } catch { presentError(error) }
            await KnowledgeRAGIndexRefreshPresentation.waitForMinimumDuration(startedAt: startedAt, clock: clock)
            isIndexing = false
        }
    }

    /// 与证据 tab「Starcat 详情」一致：只开独立详情渲染窗，不激活主窗口选中态。
    func openSelectedRepository() {
        guard let repo = selectedCandidate?.repo else { return }
        RepoDetailWindowController.show(
            repo: repo,
            dependencies: dependencies,
            homeViewModel: homeViewModel
        )
    }

    /// 浏览器打开 GitHub 仓库主页；htmlUrl 缺失时用 owner/name 兜底拼接。
    func openRepositoryOnGitHub(_ repo: Repo) {
        let url = RepoExternalLinks.repo(repo) ?? GitHubURLs.repo(owner: repo.owner, repo: repo.name)
        NSWorkspace.shared.open(url)
    }

    func runRetrievalTest() {
        let query = retrievalQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isTestingRetrieval else { return }
        let scope: RAGRetrievalTestScope
        switch retrievalTestMode {
        case .indexOracle:
            scope = .indexOracle
        case .followPlan:
            guard let plan = KnowledgeRAGWorkspaceWindowController.displayedQueryPlanForRetrievalTest else { return }
            scope = .followPlan(plan)
        }
        let testSettings = retrievalTestSettings.normalized()
        isTestingRetrieval = true
        hasCompletedRetrievalTest = false
        retrievalHits = []
        retrievalTestDiagnostics = nil
        Task { [weak self] in
            guard let self else { return }
            defer { isTestingRetrieval = false }
            do {
                let service = try dependencies.makeKnowledgeRAGService(
                    selectedModelID: nil,
                    retrievalSettingsOverride: testSettings
                )
                let result = try await service.testRetrieval(query: query, scope: scope)
                retrievalHits = result.childHits.sorted { $0.score > $1.score }
                retrievalTestDiagnostics = result.diagnostics
                hasCompletedRetrievalTest = true
            } catch { presentError(error) }
        }
    }

    var canFollowPlanForRetrievalTest: Bool {
        KnowledgeRAGWorkspaceWindowController.displayedQueryPlanForRetrievalTest != nil
    }

    var hasUnsavedRetrievalTestSettings: Bool {
        retrievalTestSettings.normalized() != dependencies.settings.ragRetrievalSettings.normalized()
    }

    func restoreSavedRetrievalTestSettings() {
        // 整结构赋值，驱动 @Observable 与下方 `.id(retrievalTestSettings)` 强制重建输入控件。
        retrievalTestSettings = dependencies.settings.ragRetrievalSettings.normalized()
    }

    func saveRetrievalTestSettings() {
        retrievalTestSettings = retrievalTestSettings.normalized()
        dependencies.settings.ragRetrievalSettings = retrievalTestSettings
    }

    func updateRetrievalTestSettings(_ update: (inout RAGRetrievalSettings) -> Void) {
        var settings = retrievalTestSettings
        update(&settings)
        retrievalTestSettings = settings.normalized()
    }

    func repositoryName(for id: Int64) -> String {
        candidates.first(where: { $0.repo.id == id })?.repo.fullName ?? "#\(id)"
    }

    /// 召回列表 / 详情用同一套 owner 头像；候选未命中时由 `RepoIdentityLabel` 按 owner 段拼接。
    func repositoryOwnerAvatar(for id: Int64) -> String? {
        candidates.first(where: { $0.repo.id == id })?.repo.ownerAvatar
    }

    func saveChunk(_ managed: RAGManagedChunk, title: String, sectionPath: String, content: String) async -> String? {
        guard let id = managed.chunk.id else { return nil }
        do {
            try await dependencies.ragChunkRepository.saveKnowledgeChunkOverride(id: id, title: title, sectionPath: sectionPath, content: content)
            await refresh()
            // 保存先恢复“可用”管理状态，再后台补 embedding；完成事件会让浏览器自动从 pending 更新到 ready。
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await dependencies.knowledgeRAGIndexBuilder.embedEditedChunks([
                        .init(id: id, source: managed.chunk.source)
                    ])
                    await refresh()
                } catch {
                    presentError(error)
                }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 编辑的是 RepoContext 文件真源；成功后直接替换当前展示快照，不触发普通 RAG 重建。
    func saveRepoContextXML(_ xml: String) -> String? {
        guard !isGeneratingRepoContext else { return String.l10n("rag.browser.repoContext.generation.inProgress") }
        guard let repo = selectedCandidate?.repo else { return String.l10n("rag.browser.repoContext.error.noRepository") }
        do {
            repoContextDocument = try dependencies.repoContextStorage.saveEditedContextXML(
                xml,
                owner: repo.owner,
                repo: repo.name
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// RepoContext 删除不写 tombstone；它不是索引分片，用户以后可以重新生成。
    func deleteRepoContext() {
        guard !isGeneratingRepoContext else { return }
        guard let repo = selectedCandidate?.repo else { return }
        do {
            try dependencies.repoContextStorage.deleteProject(owner: repo.owner, repo: repo.name)
            repoContextDocument = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 只删除洞察 XML Artifact；Coordinator 的 Storage 不持有数据库依赖，因此不会碰
    /// 页面洞察缓存、Star History 或 AI 已有摘要。
    func deleteRepositoryInsights() {
        guard !isGeneratingRepositoryInsights else { return }
        guard let repo = selectedCandidate?.repo else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await dependencies.repositoryInsightsContextCoordinator.deleteArtifact(for: repo)
                guard selectedRepoID == repo.id else { return }
                repositoryInsightsArtifact = nil
            } catch {
                // 删除失败时继续展示旧 Artifact，避免文件仍会被 RAG 使用而 UI 却假装已删除。
                guard selectedRepoID == repo.id else { return }
                errorMessage = String.l10n("rag.browser.repositoryInsights.delete.failed")
            }
        }
    }

    /// 首次删除仅下架：仍显示在管理列表且可编辑，但 SQL 召回会立即排除它。
    func disableChunk(_ managed: RAGManagedChunk) async {
        guard managed.allowsRemoval, let id = managed.chunk.id else { return }
        do {
            try await dependencies.ragChunkRepository.setKnowledgeChunkExcluded(id: id, isExcluded: true)
            // 下架只更新当前项；整页 refresh 会丢掉“加载更多”已有的数据并回到第一页。
            if let index = chunks.firstIndex(where: { $0.id == id }) {
                chunks[index].isExcluded = true
            }
            try await refreshIndexStatistics()
            synchronizeRemovedChunk(id: id, source: managed.chunk.source)
        } catch { errorMessage = error.localizedDescription }
    }

    /// 对已下架项的第二次删除才是永久删除：写 tombstone 并移除索引行，后续 source 重建也不会复活。
    func permanentlyDeleteChunk(_ managed: RAGManagedChunk) async {
        guard managed.allowsRemoval, let id = managed.chunk.id else { return }
        do {
            try await dependencies.ragChunkRepository.permanentlyDeleteKnowledgeChunk(id: id)
            chunks.removeAll { $0.id == id }
            try await refreshIndexStatistics()
            synchronizeRemovedChunk(id: id, source: managed.chunk.source)
        } catch { errorMessage = error.localizedDescription }
    }

    func restoreChunk(_ managed: RAGManagedChunk) async {
        guard let id = managed.chunk.id else { return }
        do {
            try await dependencies.ragChunkRepository.restoreKnowledgeChunk(id: id)
            await refresh()
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await dependencies.knowledgeRAGIndexBuilder.embedEditedChunks([
                        .init(id: id, source: managed.chunk.source)
                    ])
                    await refresh()
                } catch {
                    presentError(error)
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// 本地 SQL 边界会立即排除下架项；外部派生索引在后台精确删除，避免网络等待阻塞管理操作。
    private func synchronizeRemovedChunk(id: Int64, source: RAGChunkSource) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await dependencies.knowledgeRAGIndexBuilder.removeManagedChunksFromExternalIndexes([
                    .init(id: id, source: source)
                ])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 仅首次打开显示中央加载态；后续刷新保留当前内容，避免按钮操作造成视觉跳动。
    private func refresh(showsLoading: Bool = false) async {
        if showsLoading { isLoading = true }
        defer { if showsLoading { isLoading = false } }
        do {
            try await refreshIndexStatistics()
            // 索引变更刷新时保留已滚过的页数，避免 embedding 过程中把列表打回首页。
            let reloadCount = max(candidates.count, Self.repositoryPageSize)
            await loadRepositories(limit: reloadCount, append: false)
            if pendingReveal != nil {
                // bootstrap 末尾会 fulfill；这里再 loadChunks 会先闪第一仓。
                return
            }
            // 定位高亮还在时必须保住已加载到目标分片的页数，否则索引通知会把列表打回前 10 条。
            let chunkLimit = highlightedChunkID == nil
                ? Self.initialChunkPageSize
                : max(chunks.count, Self.initialChunkPageSize)
            await loadChunks(limit: chunkLimit, append: false)
        } catch { errorMessage = error.localizedDescription }
    }

    /// 分片删除后仅同步统计，保留用户已分页加载到内存中的其他分片。
    private func refreshIndexStatistics() async throws {
        async let loadedCoverage = dependencies.ragChunkRepository.coverage(model: embeddingModel)
        async let loadedIndexes = dependencies.ragChunkRepository.knowledgeRepositoryIndexes(model: embeddingModel)
        indexStatus = try await loadedCoverage
        indexes = Dictionary(uniqueKeysWithValues: try await loadedIndexes.map { ($0.repoID, $0) })
    }

    private static let repositoryPageSize = 20
    private static let initialChunkPageSize = 10
    private static let additionalChunkPageSize = 10

    private func fulfillPendingReveal() async {
        guard let target = pendingReveal else { return }
        pendingReveal = nil
        highlightedChunkID = target.chunkID
        await ensureCandidateVisible(repoID: target.repoID)
        guard candidates.contains(where: { $0.repo.id == target.repoID }) else {
            highlightedChunkID = nil
            return
        }
        if selectedRepoID != target.repoID {
            await selectRepository(target.repoID, loadsChunks: false)
        }
        // `selectRepository` 在切仓时会清高亮；定位路径必须在滚之前写回目标分片。
        highlightedChunkID = target.chunkID
        await loadChunksThrough(chunkID: target.chunkID)
        revealScrollNonce += 1
    }

    /// 目标仓可能在当前搜索/筛选/分页之外；插入列表开头，保证右栏 `selectedCandidate` 有值。
    private func ensureCandidateVisible(repoID: Int64) async {
        if candidates.contains(where: { $0.repo.id == repoID }) { return }
        do {
            guard let candidate = try await dependencies.ragCandidateRepository
                .fetchKnowledgeBrowserCandidate(repoId: repoID) else { return }
            candidates.insert(candidate, at: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 一次加载到目标分片所在页，避免 10 条一页地连翻到第 N 条。
    private func loadChunksThrough(chunkID: Int64) async {
        let generation = repositorySelectionGate.begin()
        let offset: Int
        if let selectedRepoID {
            offset = (try? await dependencies.ragChunkRepository.fetchManagedKnowledgeChunkOffset(
                repoId: selectedRepoID,
                chunkId: chunkID
            )) ?? 0
        } else {
            offset = 0
        }
        let limit = max(Self.initialChunkPageSize, offset + 1)
        await loadChunks(limit: limit, append: false, selectionGeneration: generation)
    }

    private func loadRepositories(limit: Int, append: Bool) async {
        let offset = append ? candidates.count : 0
        let query = repositorySearchQuery
        let sort = repositorySortOption
        let filtersSnapshot = repositoryFilters
        // 浏览器只下推 SQL 条件；信号可用性在 UI 层已隐藏，这里再兜底清掉。
        var sqlFilters = filtersSnapshot
        sqlFilters.wikiAvailability = .unknown
        sqlFilters.healthAvailability = .unknown
        sqlFilters.openSSFAvailability = .unknown
        do {
            let page = try await dependencies.ragCandidateRepository.fetchKnowledgeBrowserPage(
                query: query,
                limit: limit,
                offset: offset,
                sort: sort,
                filters: sqlFilters
            )
            // 查询期间用户可能又改了条件；过期页丢弃，避免闪回旧结果。
            guard repositorySearchQuery == query,
                  repositorySortOption == sort,
                  repositoryFilters == filtersSnapshot else { return }
            if append {
                let existingIDs = Set(candidates.map(\.repo.id))
                candidates.append(contentsOf: page.candidates.filter { !existingIDs.contains($0.repo.id) })
            } else {
                candidates = page.candidates
                if selectedRepoID == nil {
                    if pendingReveal == nil, !preservesEmptySelection {
                        selectedRepoID = candidates.first?.repo.id
                    }
                } else if let selectedRepoID, !candidates.contains(where: { $0.repo.id == selectedRepoID }) {
                    let shouldKeepLocatedRepository = pendingReveal?.repoID == selectedRepoID
                        || highlightedChunkID != nil
                    if shouldKeepLocatedRepository {
                        // 定位插入的仓可能不在当前搜索/分页里；刷新时不能改选第一项把用户踢走。
                        await ensureCandidateVisible(repoID: selectedRepoID)
                    } else {
                        // 搜索/筛选可让当前仓库从候选集中消失。这也是一次真实切仓，必须
                        // 走与用户点击相同的取消边界，不能让旧下载/打包在后台继续。
                        cancelRepositoryInsightsGeneration()
                        cancelRepoContextGeneration()
                        self.selectedRepoID = candidates.first?.repo.id
                        repositoryInsightsArtifact = nil
                        repoContextDocument = nil
                    }
                }
            }
            hasMoreRepositories = page.hasMore
        } catch {
            errorMessage = error.localizedDescription
            if !append {
                candidates = []
                hasMoreRepositories = false
            }
        }
    }

    private func removeRepositoryFromLibrary(repoID: Int64) async {
        do {
            try await dependencies.repoNoteRepository.updateLibraryState(repoId: repoID, state: .outsideLibrary)

            // 数据库写入成功后再清空 UI，失败时保留当前详情供用户重试。
            homeViewModel.applyLibraryStateChange(repoId: repoID, state: .outsideLibrary)
            clearRemovedRepository(repoID: repoID)
            await homeViewModel.refreshSidebar()
            await homeViewModel.reloadItems(forceRefresh: true)
            try? await refreshIndexStatistics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearRemovedRepository(repoID: Int64) {
        guard selectedRepoID == repoID else {
            candidates.removeAll { $0.repo.id == repoID }
            indexes.removeValue(forKey: repoID)
            return
        }
        cancelRepositoryInsightsGeneration()
        cancelRepoContextGeneration()
        // 让仍在执行的分片读取失效，避免移出后旧请求把右栏内容重新写回来。
        _ = repositorySelectionGate.begin()
        preservesEmptySelection = true
        selectedRepoID = nil
        chunks = []
        repositoryInsightsArtifact = nil
        repoContextDocument = nil
        hasMoreChunks = false
        candidates.removeAll { $0.repo.id == repoID }
        indexes.removeValue(forKey: repoID)
    }

    private func loadChunks(selectionGeneration: Int? = nil) async {
        await loadChunks(
            limit: Self.initialChunkPageSize,
            append: false,
            selectionGeneration: selectionGeneration
        )
    }

    private func loadChunks(limit: Int, append: Bool, selectionGeneration: Int? = nil) async {
        guard let selectedRepoID else {
            chunks = []
            repositoryInsightsArtifact = nil
            repoContextDocument = nil
            hasMoreChunks = false
            return
        }
        let requestedRepoID = selectedRepoID
        let requestedOffset = append ? chunks.count : 0
        do {
            let repo = candidates.first(where: { $0.repo.id == requestedRepoID })?.repo
            let loadedRepoContext: RepoContextDocument? = if append {
                repoContextDocument
            } else if let repo {
                try dependencies.repoContextStorage.loadDocument(owner: repo.owner, repo: repo.name)
            } else {
                nil
            }
            // 两个文件 Artifact 与 SQLite 分片彼此独立；并行读取可避免详情首开被串行 IO 拉长，
            // 同时仍由 selection gate 统一拒绝切仓后的迟到结果。
            async let loadedRepositoryInsights = loadRepositoryInsightsArtifact(
                repo: repo,
                append: append
            )
            async let loadedPage = dependencies.ragChunkRepository.fetchManagedKnowledgeChunks(
                repoId: requestedRepoID,
                limit: limit,
                offset: requestedOffset
            )
            let (repositoryInsights, page) = try await (loadedRepositoryInsights, loadedPage)
            // refresh / load more 与用户点选可以并发；只允许仍属于当前仓库且仍是最新选择的
            // 结果改写列表，避免 A 的分页数据出现在 B 的详情中。
            guard self.selectedRepoID == requestedRepoID,
                  selectionGeneration.map(repositorySelectionGate.isCurrent) ?? true else { return }
            if append {
                chunks.append(contentsOf: page.chunks)
            } else {
                chunks = page.chunks
                repositoryInsightsArtifact = repositoryInsights
                repoContextDocument = loadedRepoContext
            }
            hasMoreChunks = page.hasMore
        }
        catch { errorMessage = error.localizedDescription }
    }

    private func loadRepositoryInsightsArtifact(
        repo: Repo?,
        append: Bool
    ) async -> RepositoryInsightsContextArtifact? {
        if append { return repositoryInsightsArtifact }
        guard let repo else { return nil }
        return await dependencies.repositoryInsightsContextCoordinator.loadArtifact(for: repo)
    }
}

/// 左侧选择仓库，右侧只显示持久化的分片与当前 embedding 模型下的索引状态。
/// 左侧知识库面板用该偏好值监听滚动位置，以驱动全局概览 Hero 的折叠状态。
private struct KnowledgeRAGBrowserScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct KnowledgeRAGBrowserView: View {
    @Bindable var viewModel: KnowledgeRAGBrowserViewModel
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(\.ragSettingsNavigation) private var settingsNavigation
    @State private var editingChunk: RAGManagedChunk?
    @State private var editingRepoContext: RepoContextDocument?
    @State private var inspectingRepositoryInsights: RepositoryInsightsContextArtifact?
    @State private var inspectingHit: RAGRetrievalHitInspection?
    @State private var hoveredRetrievalHitID: Int64?
    @State private var hoveredChunkID: Int64?
    @State private var hoveredRepositoryInsightsID: String?
    @State private var hoveredRepoContextID: String?
    @State private var hoveredRepoContextGenerationStep: RepoContextGenerationStep?
    @FocusState private var focusedRepoContextGenerationStep: RepoContextGenerationStep?
    @State private var isKnowledgeOverviewExpanded = false
    @State private var isRetrievalTestExpanded = false
    @State private var isKnowledgeOverviewHovered = false
    @State private var hoveredKnowledgeOverviewMetricID: String?
    @State private var isRetrievalTestHovered = false
    @State private var isRetrievalTestSettingsExpanded = false
    @State private var knowledgeHeroCollapseProgress: CGFloat = 0
    @State private var permanentlyDeletingChunk: RAGManagedChunk?
    @State private var isConfirmingRepositoryInsightsDeletion = false
    @State private var isConfirmingRepoContextDeletion = false
    /// 召回测试「恢复已保存」短暂成功态；1.5s 后回到箭头，避免绿勾卡住。
    @State private var didRestoreRetrievalTestSettings = false
    @State private var restoreRetrievalTestFeedbackTask: Task<Void, Never>?
    /// 召回测试输入框内容高度（AppKit 回传）；首帧落到 2 行下限。
    @State private var retrievalQueryEditorHeight: CGFloat = 0

    /// body 字号下行高，用于 2…4 行高度钳制。
    private var retrievalQueryLineHeight: CGFloat {
        let font = retrievalQueryFont
        return font.ascender - font.descender + font.leading
    }

    /// 召回测试是侧栏辅助工具，沿用正文输入层级，避免与主问答 composer 争夺视觉焦点。
    private var retrievalQueryFont: NSFont {
        NSFont.systemFont(ofSize: interfaceScale.scaled(13))
    }

    private var retrievalQueryMinHeight: CGFloat {
        ceil(retrievalQueryLineHeight * 2 + AICommandTextEditor.verticalInset * 2)
    }

    private var retrievalQueryMaxHeight: CGFloat {
        ceil(retrievalQueryLineHeight * 4 + AICommandTextEditor.verticalInset * 2)
    }

    private var retrievalQueryFrameHeight: CGFloat {
        let measured = retrievalQueryEditorHeight > 0 ? retrievalQueryEditorHeight : retrievalQueryMinHeight
        return min(max(measured, retrievalQueryMinHeight), retrievalQueryMaxHeight)
    }

    var body: some View {
        HSplitView {
            // 召回测试展开后：双列数字框 + 来源勾选至少要 ~280pt 内容区；
            // UnifiedRepoRow 底排 chip（含索引 pill）+ 排序菜单固有宽度约需 320+；
            // 再加 list/surface padding，300 仍会在极限窄栏被 `.clipped()` 右裁。
            // 340 作安全垫；更窄时依赖 chip ViewThatFits 与搜索栏压缩兜底。
            repositoryList.frame(minWidth: 340, idealWidth: 400, maxWidth: 400)
            detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await viewModel.bootstrap() }
        .task { await viewModel.observeIndexChanges() }
        .ragWorkspaceErrorAlert(
            error: Binding(
                get: {
                    viewModel.workspaceError
                        ?? viewModel.errorMessage.map(RAGWorkspaceError.init(technicalDetail:))
                },
                set: { if $0 == nil { viewModel.dismissError() } }
            ),
            onAction: { presentedError in
                if presentedError.action == .openAISettings {
                    if presentedError.kind == .embeddingConfiguration
                        || presentedError.kind == .embeddingRequest {
                        settingsNavigation("ai.embedding")
                    } else {
                        AppDelegate.openSettingsWindow(target: "ai")
                    }
                }
                viewModel.dismissError()
            }
        )
        .sheet(item: $editingChunk) { chunk in
            KnowledgeRAGChunkEditor(
                chunk: chunk,
                embeddingStatus: effectiveStatus(for: chunk.chunk)
            ) { title, sectionPath, content in
                await viewModel.saveChunk(chunk, title: title, sectionPath: sectionPath, content: content)
            }
            .appLocaleEnvironment()
        }
        .sheet(item: $editingRepoContext) { document in
            KnowledgeRAGChunkEditor(repoContext: document) { content in
                viewModel.saveRepoContextXML(content)
            }
            .appLocaleEnvironment()
        }
        .sheet(item: $inspectingRepositoryInsights) { artifact in
            RepositoryInsightsXMLViewer(artifact: artifact)
                .appLocaleEnvironment()
        }
        .sheet(item: $inspectingHit) { hit in
            KnowledgeRAGChunkEditor(
                hit: hit,
                embeddingStatus: effectiveStatus(for: hit.hit.chunk)
            ) {
                let managed = viewModel.chunks.first(where: { $0.chunk.id == hit.hit.chunk.id })
                    ?? RAGManagedChunk(chunk: hit.hit.chunk, isExcluded: false, hasOverride: false)
                inspectingHit = nil
                // 先关详情再开编辑，避免两个 sheet 抢同一 present 周期。
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    editingChunk = managed
                }
            }
            .appLocaleEnvironment()
        }
        .alert(
            "rag.browser.chunk.permanentDelete.title",
            isPresented: Binding(
                get: { permanentlyDeletingChunk != nil },
                set: { if !$0 { permanentlyDeletingChunk = nil } }
            )
        ) {
            Button("common.cancel", role: .cancel) { permanentlyDeletingChunk = nil }
            Button("rag.browser.chunk.permanentDelete.action", role: .destructive) {
                guard let chunk = permanentlyDeletingChunk else { return }
                permanentlyDeletingChunk = nil
                Task { await viewModel.permanentlyDeleteChunk(chunk) }
            }
        } message: {
            Text("rag.browser.chunk.permanentDelete.message")
        }
        .alert("rag.browser.repoContext.delete.title", isPresented: $isConfirmingRepoContextDeletion) {
            Button("common.cancel", role: .cancel) {}
            Button("rag.browser.repoContext.delete.action", role: .destructive) {
                viewModel.deleteRepoContext()
            }
        } message: {
            Text("rag.browser.repoContext.delete.message")
        }
        .alert(
            "rag.browser.repositoryInsights.delete.title",
            isPresented: $isConfirmingRepositoryInsightsDeletion
        ) {
            Button("common.cancel", role: .cancel) {}
            Button("rag.browser.repositoryInsights.delete.action", role: .destructive) {
                viewModel.deleteRepositoryInsights()
            }
        } message: {
            Text("rag.browser.repositoryInsights.delete.message")
        }
        .alert(
            "rag.browser.repoContext.settings.title",
            isPresented: $viewModel.isRepoContextSettingsPromptPresented
        ) {
            Button("common.cancel", role: .cancel) {}
            Button("rag.browser.repoContext.settings.action") {
                AppDelegate.openSettingsWindow(target: "ai.repoContext")
            }
        } message: {
            Text("rag.browser.repoContext.settings.message")
        }
    }

    private var repositoryList: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: KnowledgeRAGBrowserScrollOffsetKey.self,
                            value: proxy.frame(in: .named("knowledgeBrowserSidebarScroll")).minY
                        )
                    }
                    .frame(height: 0)

                    knowledgeHero

                    Divider()
                    Text("rag.browser.repositories")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    // 与 Composer「+」面板同构：排序 / 筛选 + 搜索；状态独立，不串会话草稿。
                    repositoryListControls
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(viewModel.candidates.enumerated()), id: \.element.repo.id) { rowIndex, candidate in
                            repositoryRow(candidate)
                                .id(candidate.repo.id)
                                .automaticListPagination(
                                    appearingIndex: rowIndex,
                                    visibleItemCount: viewModel.candidates.count,
                                    loadedItemCount: viewModel.candidates.count,
                                    hasMore: viewModel.hasMoreRepositories,
                                    isLoading: viewModel.isLoading || viewModel.isLoadingMoreRepositories,
                                    identity: "knowledge-repositories"
                                ) {
                                    await viewModel.loadMoreRepositoriesIfNeeded(rowIndex: rowIndex)
                                }
                        }
                        if viewModel.isLoadingMoreRepositories {
                            HStack {
                                Spacer()
                                ProgressView().controlSize(.small)
                                Spacer()
                            }
                            .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                // 约束内容宽度等于侧栏，避免固有宽度撑破后被 HSplitView 从左侧裁切。
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: "knowledgeBrowserSidebarScroll")
            .onPreferenceChange(KnowledgeRAGBrowserScrollOffsetKey.self) { offsetY in
                knowledgeHeroCollapseProgress = knowledgeHeroCollapseProgress(for: offsetY)
            }
            .onChange(of: viewModel.revealScrollNonce) { _, nonce in
                guard nonce > 0, let repoID = viewModel.selectedRepoID else { return }
                // 列表与 Hero 刚提交后立刻 scrollTo 会打到旧 contentSize。
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    proxy.scrollTo(repoID, anchor: .center)
                }
            }
            }

            collapsedKnowledgeHeader
        }
        // 把侧栏钉在可用宽度内：子视图固有宽度再大也不往左溢出裁切。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    /// 复用 Composer 筛选控件；`includeSignalFilters: false` 只保留 SQL 可下推项。
    ///
    /// 窄侧栏约束：`UnifiedSortMenu` 自带 `.fixedSize()`，排序/筛选优先占位；
    /// 搜索框 `minWidth: 0` 吸收剩余宽度，避免整行固有宽度撑破后被外层 `.clipped()` 右裁。
    private var repositoryListControls: some View {
        HStack(spacing: 8) {
            RAGContextPickerFilterControls(
                sortOption: $viewModel.repositorySortOption,
                filters: $viewModel.repositoryFilters,
                isFilterPresented: $viewModel.isRepositoryFilterPresented,
                isLanguageAddPresented: $viewModel.isRepositoryLanguageAddPresented,
                includeSignalFilters: false,
                onReset: { viewModel.resetRepositoryFilters() }
            )
            .layoutPriority(1)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("rag.workspace.mention.searchPlaceholder", text: $viewModel.repositorySearchQuery)
                    .textFieldStyle(.plain)
                    .font(interfaceScale.font(size: 13))
                    // 允许低于 placeholder 固有宽度收缩，否则窄栏会把整行撑破。
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if !viewModel.repositorySearchQuery.isEmpty {
                    Button {
                        viewModel.clearRepositorySearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("rag.workspace.mention.clearFilter")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minWidth: 56, maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var knowledgeHero: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "books.vertical")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("rag.browser.title").font(.title3.weight(.semibold))
                }
                Text("rag.browser.subtitle").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
            knowledgeOverviewCard
            retrievalTestCard
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 0...8pt 保持完整上下文，随后在 64pt 内收敛为紧凑摘要，减少列表滚动时的突变感。
    private func knowledgeHeroCollapseProgress(for offsetY: CGFloat) -> CGFloat {
        let normalizedOffset = max(-offsetY, 0)
        return min(max((normalizedOffset - 8) / 64, 0), 1)
    }

    private var collapsedKnowledgeHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("rag.browser.title")
                .font(.headline)
            Spacer(minLength: 8)
            Text("\(viewModel.indexStatus.indexedRepoCount)/\(viewModel.indexStatus.knowledgeRepoCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("\(viewModel.indexStatus.readyChunks)")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .opacity(knowledgeHeroCollapseProgress)
        .offset(y: -8 * (1 - knowledgeHeroCollapseProgress))
        .allowsHitTesting(false)
    }

    private var detail: some View {
        ZStack {
            if let candidate = viewModel.selectedCandidate {
                ScrollViewReader { proxy in
                    ScrollView {
                        repositoryDetail(candidate)
                            .padding(20)
                    }
                    .onChange(of: viewModel.revealScrollNonce) { _, nonce in
                        guard nonce > 0, let chunkID = viewModel.highlightedChunkID else { return }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(80))
                            proxy.scrollTo("chunk:\(chunkID)", anchor: .center)
                        }
                    }
                }
            } else {
                // 与主窗口详情列共享同一套响应式示意图，窗口缩放时不引入独立图片资产。
                RepoDetailNoSelectionPlaceholder()
            }
        }
        .overlay { if viewModel.isLoading { ProgressView().controlSize(.small) } }
    }

    /// 索引状态属于整个知识库，放在左侧控制台，切换仓库时不重复呈现。
    /// 默认折叠，交互对齐召回测试：整行可点击切换。
    private var knowledgeOverviewCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isKnowledgeOverviewExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("rag.browser.overview").font(.headline)
                    Spacer(minLength: 28)
                    Image(systemName: isKnowledgeOverviewExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .padding(12)
                .background(
                    isKnowledgeOverviewHovered ? Color.accentColor.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerStyle(.link)
            .onHover { isKnowledgeOverviewHovered = $0 }
            .onDisappear { isKnowledgeOverviewHovered = false }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.15),
                value: isKnowledgeOverviewHovered
            )
            // 独立操作叠在标题行上，避免点刷新时误折叠；chevron 仍留在整行 Button 里。
            .overlay(alignment: .trailing) {
                SyncIconButton(
                    isRefreshing: viewModel.indexBuilder.status.isActivelyIndexing,
                    disabled: viewModel.indexBuilder.status.isActivelyIndexing,
                    font: .caption,
                    frameSize: 18,
                    tooltip: String.l10n("rag.browser.overview.refresh")
                ) {
                    viewModel.startOverviewIndexRebuild()
                }
                .padding(.trailing, 34)
            }

            if isKnowledgeOverviewExpanded {
                Divider()
                knowledgeOverviewContent
                    .padding(12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.35)))
    }

    private var knowledgeOverviewContent: some View {
        let indexedRepos = viewModel.indexStatus.indexedRepoCount
        let knowledgeRepos = viewModel.indexStatus.knowledgeRepoCount
        let isCoverageComplete = knowledgeRepos > 0 && indexedRepos >= knowledgeRepos

        return VStack(alignment: .leading, spacing: 12) {
            knowledgeOverviewEmbeddingModelRow

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("rag.browser.overview.repositoryCoverage")
                        .font(interfaceScale.font(.body, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text("\(indexedRepos)/\(knowledgeRepos)")
                        .font(interfaceScale.font(.caption, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isCoverageComplete ? Color.green : Color.primary)
                }
                ProgressView(
                    value: Double(indexedRepos),
                    total: Double(max(knowledgeRepos, 1))
                )
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(isCoverageComplete ? Color.green : Color.accentColor)
                // 原生线性条偏厚；只压缩视觉高度，不改变可用宽度和覆盖比例。
                .scaleEffect(x: 1, y: 0.65, anchor: .center)
                .frame(height: 7)
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                overviewMetricRow(
                    id: "ready",
                    "rag.workspace.status.readyChunks",
                    value: "\(viewModel.indexStatus.readyChunks)",
                    rowIndex: 0
                )
                overviewMetricRow(
                    id: "pending",
                    "rag.workspace.status.pendingChunks",
                    value: "\(viewModel.indexStatus.pendingChunks)",
                    rowIndex: 1,
                    issueColor: viewModel.indexStatus.pendingChunks > 0 ? .orange : nil
                )
                overviewMetricRow(
                    id: "failed",
                    "rag.workspace.status.failedChunks",
                    value: "\(viewModel.indexStatus.failedChunks)",
                    rowIndex: 2,
                    issueColor: viewModel.indexStatus.failedChunks > 0 ? .red : nil
                )
                overviewMetricRow(
                    id: "stale",
                    "rag.workspace.status.staleChunks",
                    value: "\(viewModel.indexStatus.staleChunks)",
                    rowIndex: 3,
                    issueColor: viewModel.indexStatus.staleChunks > 0 ? .purple : nil
                )
            }
        }
    }

    /// 索引概览不能用空字符串表示配置异常，否则用户既不知道原因，也找不到恢复入口。
    /// 这里与 Inspector 共用同一套配置预检结果，并直达向量化任务模型设置。
    @ViewBuilder
    private var knowledgeOverviewEmbeddingModelRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("rag.browser.overview.model")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let modelName = viewModel.configuredEmbeddingModelName {
                Text(modelName)
                    .font(interfaceScale.font(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(modelName)
            } else {
                Button("rag.workspace.index.embeddingModel.configure") {
                    settingsNavigation("ai.embedding")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }

        if let issue = viewModel.embeddingConfigurationIssue {
            Text(issue.localizedDescription)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 与知识库其他数据列表保持一致：连续斑马纹负责可扫描性，hover 只用于当前行聚焦。
    /// 数值默认中性；待处理 / 失败 / 过期只有非零时才使用状态色，避免健康状态五颜六色。
    private func overviewMetricRow(
        id: String,
        _ key: LocalizedStringKey,
        value: String,
        rowIndex: Int,
        issueColor: Color? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(interfaceScale.font(.body, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(interfaceScale.font(.caption, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(issueColor ?? .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            hoveredKnowledgeOverviewMetricID == id
                ? Color.accentColor.opacity(0.08)
                : (rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.045)),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .onHover { isHovered in
            if reduceMotion {
                hoveredKnowledgeOverviewMetricID = isHovered
                    ? id
                    : (hoveredKnowledgeOverviewMetricID == id ? nil : hoveredKnowledgeOverviewMetricID)
            } else {
                withAnimation(.easeInOut(duration: 0.12)) {
                    hoveredKnowledgeOverviewMetricID = isHovered
                        ? id
                        : (hoveredKnowledgeOverviewMetricID == id ? nil : hoveredKnowledgeOverviewMetricID)
                }
            }
        }
        .onDisappear {
            if hoveredKnowledgeOverviewMetricID == id {
                hoveredKnowledgeOverviewMetricID = nil
            }
        }
    }

    private var retrievalTestCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isRetrievalTestExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("rag.browser.retrieval.title").font(.headline)
                    Spacer(minLength: 0)
                    Image(systemName: isRetrievalTestExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .padding(12)
                .background(
                    isRetrievalTestHovered ? Color.accentColor.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerStyle(.link)
            .onHover { isRetrievalTestHovered = $0 }
            .onDisappear { isRetrievalTestHovered = false }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.15),
                value: isRetrievalTestHovered
            )

            if isRetrievalTestExpanded {
                Divider()
                retrievalTestContent
                    .padding(10)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.35)))
    }

    private var retrievalTestContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker(selection: $viewModel.retrievalTestMode) {
                Text("rag.browser.retrieval.scope.indexOracle")
                    .tag(RAGRetrievalTestMode.indexOracle)
                Text("rag.browser.retrieval.scope.followPlan")
                    .tag(RAGRetrievalTestMode.followPlan)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(
                viewModel.retrievalTestMode == .followPlan
                    ? (viewModel.canFollowPlanForRetrievalTest
                        ? "rag.browser.retrieval.scope.hint.followPlan"
                        : "rag.browser.retrieval.scope.followPlanDisabled")
                    : "rag.browser.retrieval.scope.hint.indexOracle"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ZStack(alignment: .bottomTrailing) {
                // AppKit 输入：默认 2 行 / 最高 4 行；超长时 NSScrollView 出滚动条。
                AICommandTextEditor(
                    text: $viewModel.retrievalQuery,
                    placeholder: String.l10n("rag.browser.retrieval.placeholder"),
                    font: retrievalQueryFont,
                    maximumHeight: retrievalQueryMaxHeight,
                    onHeightChange: { retrievalQueryEditorHeight = $0 },
                    onMentionAnchorChange: { _ in },
                    onCommand: { _ in false }
                )
                .frame(height: retrievalQueryFrameHeight)
                .padding(8)
                // 按钮叠在右下角，不再整行 padding.bottom，避免「空一行」占满宽度。

                Group {
                    if viewModel.isTestingRetrieval {
                        // 加载中：系统默认 ProgressView，随明暗主题自动变色，不加彩色底。
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 18, height: 18)
                            .accessibilityLabel(Text("rag.browser.retrieval.run"))
                    } else {
                        // 与主 RAG composer 共用上箭头发送语义和圆形符号比例；不要在小圆钮
                        // 中再塞试管图标，否则图形会显得拥挤且被误读为设置入口。
                        let canRun = !viewModel.retrievalQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && (viewModel.retrievalTestMode == .indexOracle || viewModel.canFollowPlanForRetrievalTest)
                        Button { viewModel.runRetrievalTest() } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                // 输入框内只承担发送语义，尺寸收敛到与 loading 占位一致。
                                .font(interfaceScale.font(size: 18, weight: .semibold))
                                .foregroundStyle(canRun ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .disabled(!canRun)
                        .accessibilityLabel(Text("rag.browser.retrieval.run"))
                        .help(Text("rag.browser.retrieval.run"))
                        .pointerStyle(.link)
                    }
                }
                // 相对输入框描边：右/下同为 5，贴角对称。
                .padding(.trailing, 5)
                .padding(.bottom, 5)
            }
            // 只给正文左侧留白；右/下由按钮自身边距控制，避免叠加后不对称。
            .padding(.leading, 7)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.24)))
            retrievalTestSettingsPanel
            if let diagnostics = viewModel.retrievalTestDiagnostics {
                retrievalTestSummary(diagnostics)
            }
            if !viewModel.retrievalHits.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(viewModel.retrievalHits.enumerated()), id: \.element.chunk.id) { rowIndex, hit in
                            retrievalHitRow(hit, rowIndex: rowIndex)
                        }
                    }
                }
                .frame(maxHeight: 160)
            } else if viewModel.hasCompletedRetrievalTest {
                // 未命中只是一次测试结果，不应使用页面级空状态占据大块垂直空间。
                VStack(alignment: .leading, spacing: 2) {
                    Text("rag.browser.retrieval.noHitsTitle")
                        .font(.caption.weight(.semibold))
                    Text("rag.browser.retrieval.noHitsMessage")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }

    /// 草稿参数直接传入本次检索 Service；只有点保存才写入工作台正式设置。
    private var retrievalTestSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isRetrievalTestSettingsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("rag.browser.retrieval.settings.title")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if viewModel.hasUnsavedRetrievalTestSettings {
                        Text("rag.browser.retrieval.settings.unsaved")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text("rag.browser.retrieval.settings.draftHint")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                    Image(systemName: isRetrievalTestSettingsExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if isRetrievalTestSettingsExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("rag.workspace.retrieval.minimumSimilarity")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text(String(format: "%.2f", locale: locale, viewModel.retrievalTestSettings.minimumVectorSimilarity))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: retrievalTestSimilarityBinding, in: 0...1, step: 0.01)

                    // 窄侧栏里并排两列会被英文长标签撑破固有宽度；改纵向堆叠。
                    VStack(alignment: .leading, spacing: 10) {
                        retrievalTestNumberField(
                            titleKey: "rag.workspace.retrieval.finalChunkLimit",
                            text: retrievalTestFinalLimitBinding
                        )
                        retrievalTestNumberField(
                            titleKey: "rag.workspace.retrieval.perRepositoryLimit",
                            text: retrievalTestPerRepositoryLimitBinding
                        )
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("rag.workspace.retrieval.sources.title")
                            .font(.caption.weight(.medium))
                        // 侧栏默认宽度已提升至 400pt，四个来源可在同一行完整呈现。
                        // 保留文字缩放兜底，用户手动拖到 340pt 时仍尽量避免裁切。
                        HStack(spacing: 12) {
                            ForEach(RAGChunkSource.allCases, id: \.self) { source in
                                Toggle(isOn: retrievalTestSourceBinding(source)) {
                                    Text(source.titleKey)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                                .font(.caption)
                                .toggleStyle(.checkbox)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Spacer()
                        Button {
                            viewModel.restoreSavedRetrievalTestSettings()
                            restoreRetrievalTestFeedbackTask?.cancel()
                            restoreRetrievalTestFeedbackTask = Task { @MainActor in
                                // 先让草稿回写撑开一轮刷新，再切绿勾；1.5s 后回到箭头。
                                await Task.yield()
                                guard !Task.isCancelled else { return }
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                                    didRestoreRetrievalTestSettings = true
                                }
                                try? await Task.sleep(for: .seconds(1.5))
                                guard !Task.isCancelled else { return }
                                withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) {
                                    didRestoreRetrievalTestSettings = false
                                }
                            }
                        } label: {
                            Image(systemName: didRestoreRetrievalTestSettings ? "checkmark.circle.fill" : "arrow.counterclockwise.circle")
                                .font(interfaceScale.font(size: 15, weight: .semibold))
                                .foregroundStyle(didRestoreRetrievalTestSettings ? Color.green : Color.primary)
                                .frame(width: 18, height: 18)
                                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("rag.browser.retrieval.settings.restore")
                        .accessibilityLabel(Text("rag.browser.retrieval.settings.restore"))
                        .disabled(didRestoreRetrievalTestSettings)

                        Button {
                            viewModel.saveRetrievalTestSettings()
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(interfaceScale.font(size: 15, weight: .semibold))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("rag.browser.retrieval.settings.save")
                        .accessibilityLabel(Text("rag.browser.retrieval.settings.save"))
                        .disabled(!viewModel.hasUnsavedRetrievalTestSettings)
                    }
                }
                // 恢复后数值相同也可能有 TextField 脏中间态；用关键字段拼 id 强制整块重建。
                .id(retrievalTestSettingsIdentity)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                .onDisappear {
                    restoreRetrievalTestFeedbackTask?.cancel()
                    restoreRetrievalTestFeedbackTask = nil
                    didRestoreRetrievalTestSettings = false
                }
            }
        }
    }

    /// `RAGRetrievalSettings` 仅 Equatable；`.id` 需要 Hashable，用字段拼键即可。
    private var retrievalTestSettingsIdentity: String {
        let s = viewModel.retrievalTestSettings
        let sources = s.enabledSources.map(\.rawValue).sorted().joined(separator: ",")
        return "\(s.minimumVectorSimilarity)|\(s.finalEvidenceChunkLimit)|\(s.perRepositoryEvidenceLimit)|\(s.evidenceTokenBudget)|\(sources)"
    }

    private func retrievalTestSummary(_ diagnostics: RAGRetrievalDiagnostics) -> some View {
        Text(String(
            format: String.l10n("rag.browser.retrieval.summary.format"),
            locale: locale,
            diagnostics.settings.minimumVectorSimilarity,
            diagnostics.vectorRawCount,
            diagnostics.vectorSimilarityFilteredCount,
            diagnostics.finalChildHitCount
        ))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }

    private func retrievalTestNumberField(titleKey: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleKey)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var retrievalTestSimilarityBinding: Binding<Double> {
        Binding(
            get: { viewModel.retrievalTestSettings.minimumVectorSimilarity },
            set: { value in viewModel.updateRetrievalTestSettings { $0.minimumVectorSimilarity = value } }
        )
    }

    private var retrievalTestFinalLimitBinding: Binding<String> {
        retrievalTestIntegerBinding(\.finalEvidenceChunkLimit)
    }

    private var retrievalTestPerRepositoryLimitBinding: Binding<String> {
        retrievalTestIntegerBinding(\.perRepositoryEvidenceLimit)
    }

    private func retrievalTestIntegerBinding(_ keyPath: WritableKeyPath<RAGRetrievalSettings, Int>) -> Binding<String> {
        Binding(
            get: { String(viewModel.retrievalTestSettings[keyPath: keyPath]) },
            set: { rawValue in
                // 仅数字；空输入不写入，避免编辑时被立刻钳成 1。
                let digits = rawValue.filter(\.isNumber)
                guard !digits.isEmpty, let value = Int(digits) else { return }
                viewModel.updateRetrievalTestSettings {
                    $0[keyPath: keyPath] = min(max(value, 1), 50)
                }
            }
        )
    }

    private func retrievalTestSourceBinding(_ source: RAGChunkSource) -> Binding<Bool> {
        Binding(
            get: { viewModel.retrievalTestSettings.enabledSources.contains(source) },
            set: { isEnabled in
                viewModel.updateRetrievalTestSettings { settings in
                    if isEnabled {
                        settings.enabledSources.insert(source)
                    } else {
                        settings.enabledSources.remove(source)
                    }
                }
            }
        )
    }

    private func retrievalHitRow(_ hit: RAGChildHit, rowIndex: Int) -> some View {
        Button {
            inspectingHit = RAGRetrievalHitInspection(
                hit: hit,
                repositoryName: viewModel.repositoryName(for: hit.chunk.repoId),
                ownerAvatarURL: viewModel.repositoryOwnerAvatar(for: hit.chunk.repoId)
            )
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    RepoIdentityLabel(
                        fullName: viewModel.repositoryName(for: hit.chunk.repoId),
                        ownerAvatarURL: viewModel.repositoryOwnerAvatar(for: hit.chunk.repoId),
                        avatarSize: 16,
                        font: .caption.weight(.semibold),
                        spacing: 6,
                        showAvatarBorder: false
                    )
                    Spacer(minLength: 4)
                    retrievalScoreLabel("rag.browser.retrieval.rankScore", value: hit.score)
                }
                Text(hit.chunk.sectionPath.isEmpty ? hit.chunk.title : hit.chunk.sectionPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: hit.chunk.source.systemImageName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(hit.chunk.source.tintColor)
                        .accessibilityHidden(true)
                    Text(sourceKey(hit.chunk.source))
                    Text("·")
                    Text(hit.kind.rawValue)
                    Spacer(minLength: 6)
                    if let vectorSimilarity = hit.vectorSimilarity {
                        retrievalScoreLabel("rag.browser.retrieval.vectorSimilarity", value: vectorSimilarity)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(8)
            .background(retrievalRowBackground(rowIndex: rowIndex, isHovered: hoveredRetrievalHitID == hit.chunk.id))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointerStyle(.link)
        .onHover { isHovering in
            hoveredRetrievalHitID = isHovering ? hit.chunk.id : nil
        }
    }

    private func retrievalScoreLabel(_ titleKey: LocalizedStringKey, value: Double) -> some View {
        HStack(spacing: 3) {
            Text(titleKey)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "%.3f", value))
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
        }
    }

    private func repositoryRow(_ candidate: RAGRepoCandidate) -> some View {
        let selected = candidate.repo.id == viewModel.selectedRepoID
        let index = viewModel.indexes[candidate.repo.id]
        let indexMetadata = index.map {
            RepoCardInlineMetadata(
                systemImage: "square.stack.3d.up",
                text: "\($0.readyChunks)/\($0.totalChunks)",
                tint: $0.totalChunks > 0 && $0.readyChunks == $0.totalChunks ? .green : .secondary
            )
        }
        return Button { Task { await viewModel.selectRepository(candidate.repo.id) } } label: {
            // 浏览器只负责注入 RAG 索引进度；头像、描述、语言、Stars、Forks 和
            // 选中 / hover 视觉全部复用主窗口完整 Repo Row。当前列表本身即知识库，
            // 因此隐藏每行重复的知识库角标，但保留真实的 isInLibrary 数据语义。
            UnifiedRepoRow(
                card: candidate.repo.asCardData(
                    footerMetadata: indexMetadata,
                    readStatus: candidate.status,
                    isInLibrary: true
                ),
                isSelected: selected,
                showLibraryBadge: false,
                showReadStatusBadge: false
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointerStyle(.link)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func repositoryDetail(_ candidate: RAGRepoCandidate) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                // logo / 仓库名 → 浏览器打开 GitHub；右侧按钮仍走 Starcat 详情窗。
                Button {
                    viewModel.openRepositoryOnGitHub(candidate.repo)
                } label: {
                    RemoteAvatar(
                        urlString: candidate.repo.ownerAvatar ?? RepoAvatarURL.from(owner: candidate.repo.owner),
                        size: 28,
                        showBorder: true
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerStyle(.link)
                .help("repo.openOnGithub")

                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        viewModel.openRepositoryOnGitHub(candidate.repo)
                    } label: {
                        Text(candidate.repo.fullName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .pointerStyle(.link)
                    .help("repo.openOnGithub")

                    Text(candidate.repo.description ?? String.l10n("rag.browser.noDescription"))
                        .font(.body)
                        .foregroundStyle(.secondary)

                    // 与左侧列表同源：Devicon 语言图标 + 短名 + 金色星标。
                    HStack(spacing: 8) {
                        if let language = candidate.repo.language?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !language.isEmpty {
                            HStack(spacing: 4) {
                                LanguageIconView(language: language, size: 14)
                                Text(LanguageDisplayName.shortened(for: language))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        StarsBadge(count: candidate.repo.starsCount, style: .compact)
                    }
                }
                Spacer()
                // 知识库详情只呈现“移出”态；操作成功后当前候选会从左栏立即消失。
                LibraryToggleButton(
                    isSaved: true,
                    isWorking: viewModel.isLibraryOperationInFlight
                ) {
                    Task { await viewModel.requestSelectedRepositoryRemoval() }
                }
                // logo-only：打开 Starcat 独立详情窗；文案留给 help / accessibility。
                Button {
                    viewModel.openSelectedRepository()
                } label: {
                    // App Icon 带玻璃外框，小尺寸下主体看不清；裁掉外围放大黑猫/金星。
                    StarcatCompactMark(size: 16)
                        .squareLogoActionChrome(
                            backgroundColor: Color.fromHex6(0xF59E0B).opacity(0.26)
                        )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                // 与左侧知识库删除按钮复用同一套 hover 反馈，并自动尊重“减少动态效果”。
                .pressableHover()
                .help("rag.browser.open")
                .accessibilityLabel(Text("rag.browser.open"))
            }
            if let index = viewModel.selectedIndex {
                HStack(spacing: 14) {
                    stat("rag.browser.totalChunks", value: "\(index.totalChunks)", color: .blue)
                    stat("rag.workspace.status.readyChunks", value: "\(index.readyChunks)", color: .green)
                    stat("rag.workspace.status.pendingChunks", value: "\(index.pendingChunks)", color: .orange)
                    stat("rag.workspace.status.failedChunks", value: "\(index.failedChunks)", color: .red)
                    stat("rag.workspace.status.staleChunks", value: "\(index.staleChunks)", color: .purple)
                    stat(
                        "rag.browser.repositoryInsights.stat",
                        value: KnowledgeRAGBrowserManagedItem.singletonAvailability(
                            viewModel.repositoryInsightsArtifact != nil
                        ),
                        color: .orange
                    )
                    stat(
                        "rag.browser.repoContext.stat",
                        value: KnowledgeRAGBrowserManagedItem.singletonAvailability(
                            viewModel.repoContextDocument != nil
                        ),
                        color: .purple
                    )
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("rag.browser.chunks").font(.headline)
                Spacer()
                if let index = viewModel.selectedIndex {
                    repositoryIndexStatisticsLabel(index)
                }
                repositoryRefreshTime
                Button {
                    viewModel.generateRepositoryInsights()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "gauge.with.dots.needle.bottom.0percent")
                            .foregroundStyle(
                                viewModel.isGeneratingRepositoryInsights
                                    ? Color.accentColor
                                    : Color.secondary
                            )
                            .symbolEffect(
                                .pulse,
                                isActive: viewModel.isGeneratingRepositoryInsights && !reduceMotion
                            )
                        Text(
                            viewModel.repositoryInsightsArtifact == nil
                                ? "rag.browser.repositoryInsights.generate"
                                : "rag.browser.repositoryInsights.regenerate"
                        )
                    }
                }
                .controlSize(.small)
                .disabled(viewModel.isGeneratingRepositoryInsights)
                Button {
                    viewModel.generateRepoContext()
                } label: {
                    Label(
                        viewModel.repoContextDocument == nil
                            ? "rag.browser.repoContext.generate"
                            : "rag.browser.repoContext.regenerate",
                        systemImage: "chevron.left.forwardslash.chevron.right"
                    )
                }
                .controlSize(.small)
                .disabled(viewModel.isGeneratingRepoContext)
                // icon-only：统一走 SyncIconButton，与上下文-索引刷新一致。
                SyncIconButton(
                    isRefreshing: viewModel.isIndexing || viewModel.indexBuilder.status.isActivelyIndexing,
                    disabled: viewModel.isIndexing || viewModel.indexBuilder.status.isActivelyIndexing,
                    font: .caption,
                    frameSize: 18,
                    tooltip: String.l10n("rag.workspace.index.rebuild")
                ) {
                    viewModel.rebuildIndex()
                }
            }
            repoContextGenerationProgress
            if viewModel.managedItems.isEmpty {
                ContentUnavailableView("rag.browser.noChunks", systemImage: "doc.text").frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.managedItems.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        Group {
                            switch item {
                            case .chunk(let chunk):
                                chunkRow(chunk, rowIndex: index)
                            case .repositoryInsights(let artifact):
                                repositoryInsightsRow(artifact, rowIndex: index)
                            case .repoContext(let document):
                                repoContextRow(document, rowIndex: index)
                            }
                        }
                        .id(item.id)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.45)))
                if viewModel.hasMoreChunks || viewModel.isLoadingMoreChunks {
                    chunkLoadMore
                }
            }
        }
    }

    /// 三段 chip 只表达 provider 已到达的离散边界。当前 spinner 可 hover / focus 为停止，
    /// 与主窗口 AI 摘要的取消交互保持一致，也照顾键盘用户。
    @ViewBuilder
    private var repoContextGenerationProgress: some View {
        switch viewModel.repoContextGenerationState {
        case .idle, .cancelled:
            EmptyView()
        case .preparing(let currentStep):
            HStack(spacing: 8) {
                ForEach(RepoContextGenerationStep.allCases, id: \.self) { step in
                    repoContextGenerationChip(step, currentStep: currentStep)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        case .succeeded(let cacheHit):
            Label(
                cacheHit
                    ? "rag.browser.repoContext.generation.cacheHit"
                    : "rag.browser.repoContext.generation.succeeded",
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
        case .failed(let message, let reason):
            HStack(spacing: 8) {
                Label {
                    Text(verbatim: message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .textSelection(.enabled)
                .foregroundStyle(.red)
                Spacer(minLength: 8)
                if reason == .archiveTooLarge {
                    Button("codeGraph.archiveLimit.adjust") {
                        settingsNavigation("ai.repoContext")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .font(.caption)
        }
    }

    private func repoContextGenerationChip(
        _ step: RepoContextGenerationStep,
        currentStep: RepoContextGenerationStep
    ) -> some View {
        let isCurrent = step == currentStep
        let isCompleted = step.rawValue < currentStep.rawValue
        let offersStop = isCurrent && (
            hoveredRepoContextGenerationStep == step || focusedRepoContextGenerationStep == step
        )
        return Button {
            guard isCurrent else { return }
            viewModel.cancelRepoContextGeneration()
        } label: {
            HStack(spacing: 5) {
                Group {
                    if isCompleted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if offersStop {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(.red)
                    } else if isCurrent {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 13, height: 13)
                Text(LocalizedStringKey(repoContextGenerationStepLocalizationKey(step)))
                    .foregroundStyle(isCurrent || isCompleted ? .primary : .secondary)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(isCurrent ? 0.09 : 0.05), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focusedRepoContextGenerationStep, equals: step)
        .onHover { hoveredRepoContextGenerationStep = $0 ? step : nil }
        .disabled(!isCurrent)
        .help(String.l10n(
            isCurrent
                ? "rag.browser.repoContext.generation.stop"
                : repoContextGenerationStepLocalizationKey(step)
        ))
        .accessibilityLabel(Text(
            LocalizedStringKey(
                isCurrent
                    ? "rag.browser.repoContext.generation.stop"
                    : repoContextGenerationStepLocalizationKey(step)
            )
        ))
    }

    private func repoContextGenerationStepLocalizationKey(_ step: RepoContextGenerationStep) -> String {
        switch step {
        case .resolving: return "rag.browser.repoContext.generation.resolving"
        case .downloading: return "rag.browser.repoContext.generation.downloading"
        case .packing: return "rag.browser.repoContext.generation.packing"
        }
    }

    private var chunkLoadMore: some View {
        HStack {
            Spacer()
            if viewModel.isLoadingMoreChunks {
                ProgressView().controlSize(.small)
            } else {
                Text("rag.browser.chunks.loadMore")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await viewModel.loadMoreChunks() } }
                    .pointerStyle(.link)
                    .accessibilityAddTraits(.isButton)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func chunkRow(_ managed: RAGManagedChunk, rowIndex: Int) -> some View {
        let chunk = managed.chunk
        let status = effectiveStatus(for: chunk)
        let isHovered = hoveredChunkID == managed.id
        let wikiLinks = chunk.source == .metadata
            ? RAGMetadataWikiLinkParser.links(in: chunk.content)
            : []
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Button { editingChunk = managed } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            // 与证据卡 / 引用列表同源：来源 SF Symbol + tint。
                            Image(systemName: chunk.source.systemImageName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(chunk.source.tintColor)
                                .accessibilityHidden(true)
                            Text(sourceKey(chunk.source))
                                .font(interfaceScale.font(.body, weight: .semibold))
                            Text(verbatim: String(format: String.l10n("rag.browser.chunks.tokenCountFormat"), chunk.tokenCount))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(chunk.sectionPath.isEmpty ? chunk.title : chunk.sectionPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                        }
                        Text(chunk.content).font(.body).lineLimit(3)
                        if let error = chunk.embeddingError, !error.isEmpty { Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerStyle(.link)

                if !wikiLinks.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(wikiLinks) { link in
                            Button {
                                NSWorkspace.shared.open(link.url)
                            } label: {
                                Label(link.title, systemImage: "link")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .pointerStyle(.link)
                            .help(Text(verbatim: link.url.absoluteString))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 状态使用可读的 caption-strong；编辑和删除是行内操作，跟随 row-title 图标尺寸。
            HStack(alignment: .center, spacing: 8) {
                if managed.hasOverride {
                    Image(systemName: "pencil.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                }
                Label {
                    Text(managedStatusKey(managed, embeddingStatus: status))
                } icon: {
                    Image(systemName: managedStatusIcon(managed, embeddingStatus: status))
                }
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(managedStatusColor(managed, embeddingStatus: status))
                .symbolRenderingMode(.hierarchical)
                if managed.allowsRemoval {
                    Button(role: .destructive) {
                        if managed.isExcluded {
                            permanentlyDeletingChunk = managed
                        } else {
                            Task { await viewModel.disableChunk(managed) }
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.subheadline)
                            .frame(width: 28, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .pointerStyle(.link)
                    .foregroundStyle(.red)
                    .help(managed.isExcluded ? "rag.browser.chunk.permanentDelete" : "rag.browser.chunk.disable")
                } else {
                    // Metadata 系统分片不可删；同尺寸置灰 trash 仅占位，与下方可删行右对齐。
                    Image(systemName: "trash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 16)
                        .help("rag.browser.chunk.metadataManaged")
                        .accessibilityLabel(Text("rag.browser.chunk.metadataManaged"))
                }
            }
            .frame(minHeight: 18)
        }
        .padding(12)
        .background(chunkRowBackground(managed, isHovered: isHovered, rowIndex: rowIndex))
        .contentShape(Rectangle())
        .onHover { hoveredChunkID = $0 ? managed.id : nil }
    }

    /// 仓库级 XML 复用普通分片的密度和操作位置，但状态、token 与删除语义保持独立。
    private func repoContextRow(_ document: RepoContextDocument, rowIndex: Int) -> some View {
        let isHovered = hoveredRepoContextID == document.id
        return HStack(alignment: .top, spacing: 8) {
            Button { editingRepoContext = document } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.purple)
                            .accessibilityHidden(true)
                        Text("rag.browser.repoContext.title")
                            .font(interfaceScale.font(.body, weight: .semibold))
                        Text(verbatim: String(
                            format: String.l10n("rag.browser.chunks.tokenCountFormat"),
                            document.metadata.stats.actualTokens
                        ))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        Text(verbatim: "context.xml")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text(document.xml)
                        .font(.body.monospaced())
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerStyle(.link)
            .disabled(viewModel.isGeneratingRepoContext)

            HStack(alignment: .center, spacing: 8) {
                Label("rag.browser.repoContext.available", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .symbolRenderingMode(.hierarchical)
                Button(role: .destructive) {
                    isConfirmingRepoContextDeletion = true
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline)
                        .frame(width: 28, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerStyle(.link)
                .foregroundStyle(.red)
                .disabled(viewModel.isGeneratingRepoContext)
                .help("rag.browser.repoContext.delete.action")
            }
            .frame(minHeight: 18)
        }
        .padding(12)
        .background(isHovered ? Color.accentColor.opacity(0.10) : zebraStripeBackground(rowIndex: rowIndex))
        .contentShape(Rectangle())
        .onHover { hoveredRepoContextID = $0 ? document.id : nil }
    }

    /// 洞察 XML 保持与普通分片、RepoContext 相同的行密度，但只允许查看、删除和重建，
    /// 不提供编辑入口，避免用户改出一份与页面、AI 不一致的“第四份事实”。
    private func repositoryInsightsRow(
        _ artifact: RepositoryInsightsContextArtifact,
        rowIndex: Int
    ) -> some View {
        let isHovered = hoveredRepositoryInsightsID == artifact.id
        return HStack(alignment: .top, spacing: 8) {
            Button { inspectingRepositoryInsights = artifact } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Image(systemName: "gauge.with.dots.needle.bottom.0percent")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text("rag.browser.repositoryInsights.title")
                            .font(interfaceScale.font(.body, weight: .semibold))
                        Text(
                            verbatim: String(
                                format: String.l10n("rag.browser.chunks.tokenCountFormat"),
                                TokenEstimator.estimate(text: artifact.document.xml)
                            )
                        )
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        Text(verbatim: RepositoryInsightsDocument.fileName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text(artifact.document.xml)
                        .font(.body.monospaced())
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerStyle(.link)
            .disabled(viewModel.isGeneratingRepositoryInsights)

            HStack(alignment: .center, spacing: 8) {
                Label(
                    "rag.browser.repositoryInsights.available",
                    systemImage: "checkmark.circle.fill"
                )
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)
                Button(role: .destructive) {
                    isConfirmingRepositoryInsightsDeletion = true
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline)
                        .frame(width: 28, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerStyle(.link)
                .foregroundStyle(.red)
                .disabled(viewModel.isGeneratingRepositoryInsights)
                .help("rag.browser.repositoryInsights.delete.action")
            }
            .frame(minHeight: 18)
        }
        .padding(12)
        .background(isHovered ? Color.accentColor.opacity(0.10) : zebraStripeBackground(rowIndex: rowIndex))
        .contentShape(Rectangle())
        .onHover { hoveredRepositoryInsightsID = $0 ? artifact.id : nil }
    }

    private func chunkRowBackground(_ managed: RAGManagedChunk, isHovered: Bool, rowIndex: Int) -> Color {
        if managed.chunk.id == viewModel.highlightedChunkID {
            return Color.accentColor.opacity(0.16)
        }
        if isHovered { return Color.accentColor.opacity(0.10) }
        // 下架行保持弱化底色，不参与斑马纹。
        if managed.isExcluded { return Color.secondary.opacity(0.10) }
        return zebraStripeBackground(rowIndex: rowIndex)
    }

    /// 不能再用 text/control background 做交替色：浅色窗口中二者接近白色，圆角卡片会完全掩盖差异。
    /// primary 的极低透明度会随明暗主题反转，既形成可扫描的行带，又不抢占选中和状态颜色。
    private func zebraStripeBackground(rowIndex: Int) -> Color {
        rowIndex.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.045)
    }

    private func retrievalRowBackground(rowIndex: Int, isHovered: Bool) -> Color {
        isHovered ? Color.accentColor.opacity(0.08) : zebraStripeBackground(rowIndex: rowIndex)
    }

    private func stat(_ key: LocalizedStringKey, value: String, color: Color) -> some View {
        VStack(alignment: .center, spacing: 4) {
            HStack(spacing: 5) { Circle().fill(color).frame(width: 7, height: 7); Text(key).font(.caption) }
                .frame(maxWidth: .infinity, alignment: .center)
            Text(value).font(.callout.weight(.semibold).monospaced())
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func repositoryIndexStatisticsLabel(_ index: RAGKnowledgeRepositoryIndex) -> some View {
        HStack(spacing: 8) {
            statisticValue("\(index.totalChunks)", label: "rag.browser.totalChunks")
            statisticValue("\(index.readyChunks)", label: "rag.workspace.status.readyChunks")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func statisticValue(_ value: String, label: LocalizedStringKey) -> some View {
        HStack(spacing: 3) {
            Text(value).monospacedDigit()
            Text(label)
        }
    }

    /// 刷新中保留旧时间；仅在本仓库刷新完成后用数字过渡替换，避免状态图标切换推挤文字。
    @ViewBuilder
    private var repositoryRefreshTime: some View {
        if let refreshedAt = viewModel.selectedRepositoryRefreshAt {
            Text(refreshedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.green)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.18), value: refreshedAt)
        }
    }

    private func sourceKey(_ source: RAGChunkSource) -> LocalizedStringKey {
        source.titleKey
    }

    private func statusKey(_ status: RAGEmbeddingStatus) -> LocalizedStringKey {
        RAGChunkEmbeddingStatusStyle.titleKey(status)
    }

    private func statusColor(_ status: RAGEmbeddingStatus) -> Color {
        RAGChunkEmbeddingStatusStyle.color(status)
    }

    private func managedStatusKey(_ managed: RAGManagedChunk, embeddingStatus: RAGEmbeddingStatus) -> LocalizedStringKey {
        managed.isExcluded ? "rag.browser.status.unavailable" : statusKey(embeddingStatus)
    }

    private func managedStatusColor(_ managed: RAGManagedChunk, embeddingStatus: RAGEmbeddingStatus) -> Color {
        // 下架态固定红色，与编辑窗「不可用」一致；其余仍跟 embedding 状态色。
        managed.isExcluded ? .red : statusColor(embeddingStatus)
    }

    private func managedStatusIcon(_ managed: RAGManagedChunk, embeddingStatus: RAGEmbeddingStatus) -> String {
        if managed.isExcluded { return RAGChunkAvailabilitySymbols.unavailable }
        return RAGChunkEmbeddingStatusStyle.symbolName(embeddingStatus)
    }

    /// 与仓库级统计保持同一语义：旧 embedding 模型即使数据库残留 ready，也不能被标为当前可用。
    private func effectiveStatus(for chunk: RAGChunk) -> RAGEmbeddingStatus {
        RAGChunkEmbeddingStatusStyle.effective(for: chunk, currentModel: viewModel.embeddingModel)
    }
}

private struct RAGRetrievalHitInspection: Identifiable {
    let id = UUID()
    let hit: RAGChildHit
    let repositoryName: String
    let ownerAvatarURL: String?
}

/// 召回命中详情只读展示完整分片与评分，避免测试列表为了预览而截断关键信息。
/// 分片窗口共用编辑与召回详情布局；编辑只提交人工覆盖层，只读模式绝不写回 README 等源数据。
private struct KnowledgeRAGChunkEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    let source: RAGChunkSource?
    let sourceSystemImageName: String
    let sourceTintColor: Color
    let editorTitleKey: LocalizedStringKey
    let locksMetadataFields: Bool
    let usesMonospacedEditor: Bool
    let repoContextExportIdentity: (owner: String, repo: String)?
    let isExcluded: Bool?
    /// 分片才有向量化状态；仓库 XML 上下文不走 embedding 队列。
    let embeddingStatus: RAGEmbeddingStatus?
    let retrievalMetadata: (repositoryName: String, ownerAvatarURL: String?, kind: String, score: Double, vectorSimilarity: Double?)?
    /// 与列表同源：落库的大概 token 数，编辑中不随正文草稿重算。
    let tokenCount: Int
    /// 分片 `updated_at` / RepoContext `lastAccessedAt ?? generatedAt`；解析失败则不展示。
    let updatedAt: Date?
    let onSave: ((String, String, String) async -> String?)?
    /// 只读命中详情右上角：切到同款编辑 sheet（左侧列表点进的那个）。
    let onEdit: (() -> Void)?
    @State private var title: String
    @State private var sectionPath: String
    @State private var content: String
    @State private var saveErrorMessage: String?
    @State private var isSaving = false

    init(chunk: RAGManagedChunk, embeddingStatus: RAGEmbeddingStatus, onSave: @escaping (String, String, String) async -> String?) {
        source = chunk.chunk.source
        sourceSystemImageName = chunk.chunk.source.systemImageName
        sourceTintColor = chunk.chunk.source.tintColor
        editorTitleKey = "rag.browser.chunk.edit"
        locksMetadataFields = false
        usesMonospacedEditor = false
        repoContextExportIdentity = nil
        isExcluded = chunk.isExcluded
        self.embeddingStatus = embeddingStatus
        retrievalMetadata = nil
        tokenCount = chunk.chunk.tokenCount
        updatedAt = ISO8601DateFormatter.shared.date(from: chunk.chunk.updatedAt)
        self.onSave = onSave
        onEdit = nil
        _title = State(initialValue: chunk.chunk.title)
        _sectionPath = State(initialValue: chunk.chunk.sectionPath)
        _content = State(initialValue: chunk.chunk.content)
    }

    init(repoContext: RepoContextDocument, onSave: @escaping (String) async -> String?) {
        source = nil
        sourceSystemImageName = "chevron.left.forwardslash.chevron.right"
        sourceTintColor = .purple
        editorTitleKey = "rag.browser.repoContext.title"
        locksMetadataFields = true
        usesMonospacedEditor = true
        repoContextExportIdentity = (repoContext.metadata.owner, repoContext.metadata.repo)
        isExcluded = nil
        embeddingStatus = nil
        retrievalMetadata = nil
        // 与列表行同源：用 PackStats.actualTokens；时间取最近访问（手工编辑会刷新），否则生成时间。
        tokenCount = repoContext.metadata.stats.actualTokens
        updatedAt = repoContext.metadata.lastAccessedAt ?? repoContext.metadata.generatedAt
        self.onSave = { _, _, content in await onSave(content) }
        onEdit = nil
        _title = State(initialValue: String.l10n("rag.browser.repoContext.title"))
        _sectionPath = State(initialValue: "context.xml")
        _content = State(initialValue: repoContext.xml)
    }

    init(hit: RAGRetrievalHitInspection, embeddingStatus: RAGEmbeddingStatus, onEdit: @escaping () -> Void) {
        source = hit.hit.chunk.source
        sourceSystemImageName = hit.hit.chunk.source.systemImageName
        sourceTintColor = hit.hit.chunk.source.tintColor
        editorTitleKey = "rag.browser.retrieval.detail"
        locksMetadataFields = false
        usesMonospacedEditor = false
        repoContextExportIdentity = nil
        isExcluded = nil
        self.embeddingStatus = embeddingStatus
        retrievalMetadata = (
            hit.repositoryName,
            hit.ownerAvatarURL,
            hit.hit.kind.rawValue,
            hit.hit.score,
            hit.hit.vectorSimilarity
        )
        tokenCount = hit.hit.chunk.tokenCount
        updatedAt = ISO8601DateFormatter.shared.date(from: hit.hit.chunk.updatedAt)
        onSave = nil
        self.onEdit = onEdit
        _title = State(initialValue: hit.hit.chunk.title)
        _sectionPath = State(initialValue: hit.hit.chunk.sectionPath)
        _content = State(initialValue: hit.hit.chunk.content)
    }

    private var isReadOnly: Bool { onSave == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                // 窗口标题要比下方仓库身份行更大一档（title3 vs callout）。
                Image(systemName: sourceSystemImageName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(sourceTintColor)
                    .accessibilityHidden(true)
                Text(editorTitleKey).font(.title3.weight(.semibold))
                Spacer()
                if let onEdit {
                    Button {
                        onEdit()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("rag.browser.chunk.edit")
                    .accessibilityLabel(Text("rag.browser.chunk.edit"))
                }
                if repoContextExportIdentity != nil {
                    Button {
                        exportRepoContextDraft()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("rag.browser.repoContext.download")
                    .accessibilityLabel(Text("rag.browser.repoContext.download"))
                }
                SheetCloseButton(action: { dismiss() })
            }
            if let retrievalMetadata {
                HStack(spacing: 8) {
                    // callout semibold 视觉高度约 16–18；头像略放大到与文字齐平。
                    RepoIdentityLabel(
                        fullName: retrievalMetadata.repositoryName,
                        ownerAvatarURL: retrievalMetadata.ownerAvatarURL,
                        avatarSize: 20,
                        font: .callout.weight(.semibold),
                        spacing: 6,
                        showAvatarBorder: false
                    )
                    if let source {
                        Text(source.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(retrievalMetadata.kind).font(.caption).foregroundStyle(.secondary)
                    Text("rag.browser.retrieval.rankScore").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.3f", retrievalMetadata.score)).font(.caption.monospaced())
                    if let vectorSimilarity = retrievalMetadata.vectorSimilarity {
                        Text("rag.browser.retrieval.vectorSimilarity").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.3f", vectorSimilarity)).font(.caption.monospaced())
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("rag.browser.chunk.titleLabel").font(.caption).foregroundStyle(.secondary)
                TextField("rag.browser.chunk.title", text: $title)
                    .disabled(isReadOnly || locksMetadataFields)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("rag.browser.chunk.sectionLabel").font(.caption).foregroundStyle(.secondary)
                TextField("rag.browser.chunk.section", text: $sectionPath)
                    .disabled(isReadOnly || locksMetadataFields)
            }
            // 正文区吃掉标题/路径字段之外的剩余高度；否则 ScrollView 会按内容理想高度撑开，
            // 再被外层 540 固定窗裁切，长分片就滚不动。
            VStack(alignment: .leading, spacing: 4) {
                Text("rag.browser.chunk.contentLabel").font(.caption).foregroundStyle(.secondary)
                if isReadOnly {
                    // 只读详情走 Markdown；编辑态仍用 TextEditor 改原文。
                    ScrollView {
                        Markdown(content)
                            .markdownTheme(readOnlyChunkMarkdownTheme(scale: interfaceScale))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    // 可见指示器：系统默认 overlay 条在触控板滚动结束即消失，长文不好发现能滚。
                    .scrollIndicators(.visible)
                    .frame(maxWidth: .infinity, minHeight: 250, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.55))
                    )
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "http" || url.scheme == "https" else { return .discarded }
                        NSWorkspace.shared.open(url)
                        return .handled
                    })
                } else {
                    TextEditor(text: $content)
                        .font(usesMonospacedEditor ? .body.monospaced() : .body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(maxWidth: .infinity, minHeight: 250, maxHeight: .infinity)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.55))
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let saveErrorMessage {
                Text(saveErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            // 左下角一行排开：分片是否下架、当前模型索引状态、更新时间与 token。
            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let isExcluded {
                        RAGChunkAvailabilityBadge(
                            isExcluded: isExcluded,
                            helpKey: isExcluded && onSave != nil
                                ? "rag.browser.chunk.edit.restoreHint"
                                : "rag.browser.chunk.libraryHelp"
                        )
                    }
                    if let embeddingStatus {
                        RAGChunkIndexStatusBadge(status: embeddingStatus)
                    }
                    if isExcluded != nil || embeddingStatus != nil {
                        Text(verbatim: "·")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    chunkEditorFooterMeta
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

                if let onSave {
                    Button("common.cancel") { dismiss() }
                    Button("rag.browser.chunk.save") {
                        Task {
                            isSaving = true
                            defer { isSaving = false }
                            if let error = await onSave(title, sectionPath, content) {
                                saveErrorMessage = error
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(18)
        .frame(
            width: interfaceScale.scaled(680),
            height: interfaceScale.scaled(540),
            alignment: .topLeading
        )
    }

    /// 左下角元信息：最后更新时间 + 列表同款「约 N tokens」。
    /// token 用落库值，不随编辑草稿重算，避免未保存时数字抖动。
    private var chunkEditorFooterMeta: some View {
        HStack(spacing: 6) {
            if let updatedAt {
                Text(
                    String(
                        format: String.l10n("search.detail.time.updated.format"),
                        RelativeTimeText.pastEvent(updatedAt, locale: locale)
                    )
                )
                .help(Text(updatedAt, format: .dateTime.year().month().day().hour().minute()))
                Text(verbatim: "·")
                    .accessibilityHidden(true)
            }
            Text(
                verbatim: String(
                    format: String.l10n("rag.browser.chunks.tokenCountFormat"),
                    tokenCount
                )
            )
            .font(.caption.monospaced())
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// 导出当前 `@State content`，因此用户尚未点击保存的修改也会进入下载文件；此操作
    /// 不调用 storage，不会改变缓存、metadata 或编辑器脏状态。
    private func exportRepoContextDraft() {
        guard let identity = repoContextExportIdentity else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = RepoContextXMLExport.defaultFilename(
            owner: identity.owner,
            repo: identity.repo
        )
        panel.title = String.l10n("rag.browser.repoContext.download.panelTitle")
        panel.prompt = String.l10n("rag.browser.repoContext.download.action")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RepoContextXMLExport.writeDraft(content, to: url)
            saveErrorMessage = nil
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    /// 与证据 popover 同分片 Markdown 气质，略放大以适配 680 详情窗。
    private func readOnlyChunkMarkdownTheme(scale: InterfaceScale) -> Theme {
        Theme()
            .text {
                ForegroundColor(.primary)
                FontSize(scale.scaled(13))
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.92))
                BackgroundColor(.secondary.opacity(0.12))
            }
            .link {
                ForegroundColor(.accentColor)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.4), bottom: .em(0.25))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(scale.scaled(16))
                    }
            }
            .heading2 { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.35), bottom: .em(0.2))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(scale.scaled(15))
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.3), bottom: .em(0.15))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(scale.scaled(14))
                    }
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.18))
                    .markdownMargin(top: .zero, bottom: .em(0.55))
            }
            .codeBlock { configuration in
                // 只读详情用于核对原始分片，配置片段必须保留代码块边界和长行滚动；
                // 否则用户会误以为 Markdown fence 没被识别。
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.14))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.92))
                            BackgroundColor(nil)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
                )
                .markdownMargin(top: .em(0.25), bottom: .em(0.55))
            }
            // 与证据 popover / 回答正文主题对齐：横线分隔 + 斑马纹 + 表头加重；
            // 680 详情窗比 400pt popover 宽，单元格内边距用正文档 12/8。
            .table { configuration in
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .fixedSize(horizontal: true, vertical: true)
                        .markdownTableBorderStyle(
                            TableBorderStyle(
                                .horizontalBorders,
                                color: Color.secondary.opacity(0.35),
                                width: 0.5
                            )
                        )
                        .markdownTableBackgroundStyle(
                            .alternatingRows(
                                Color.clear,
                                Color.primary.opacity(0.04),
                                header: Color.primary.opacity(0.08)
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
                        )
                }
                .markdownMargin(top: .em(0.25), bottom: .em(0.55))
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 {
                            FontWeight(.semibold)
                        }
                        BackgroundColor(nil)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .relativeLineSpacing(.em(0.18))
            }
    }
}

/// 列表与编辑窗共用的向量化状态样式。旧模型残留 ready 不能当当前索引可用。
private enum RAGChunkEmbeddingStatusStyle {
    static func effective(for chunk: RAGChunk, currentModel: String) -> RAGEmbeddingStatus {
        if chunk.embeddingStatus == .ready, chunk.embeddingModel != currentModel {
            return .stale
        }
        return chunk.embeddingStatus
    }

    static func titleKey(_ status: RAGEmbeddingStatus) -> LocalizedStringKey {
        switch status {
        case .ready: return "rag.browser.status.ready"
        case .pending: return "rag.browser.status.pending"
        case .failed: return "rag.browser.status.failed"
        case .stale: return "rag.browser.status.stale"
        case .keywordOnly: return "rag.browser.status.keywordOnly"
        }
    }

    static func color(_ status: RAGEmbeddingStatus) -> Color {
        switch status {
        case .ready: return .green
        case .pending: return .orange
        case .failed: return .red
        case .stale: return .purple
        case .keywordOnly: return .blue
        }
    }

    static func symbolName(_ status: RAGEmbeddingStatus) -> String {
        switch status {
        case .ready: return RAGChunkAvailabilitySymbols.available
        case .pending: return "clock.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stale: return "clock.arrow.circlepath"
        case .keywordOnly: return "text.magnifyingglass"
        }
    }
}

/// 分片管理态徽章：分片是否下架。绿勾「可用」不等于向量已就绪。
private enum RAGChunkAvailabilitySymbols {
    static let available = "checkmark.circle.fill"
    static let unavailable = "xmark.circle.fill"
}

private struct RAGChunkAvailabilityBadge: View {
    let isExcluded: Bool
    var helpKey: LocalizedStringKey = "rag.browser.chunk.libraryHelp"

    var body: some View {
        RAGChunkLabeledStatusBadge(
            categoryKey: "rag.browser.chunk.libraryLabel",
            titleKey: isExcluded ? "rag.browser.status.unavailable" : "rag.browser.status.available",
            symbolName: isExcluded ? RAGChunkAvailabilitySymbols.unavailable : RAGChunkAvailabilitySymbols.available,
            tint: isExcluded ? .red : .green,
            helpKey: helpKey
        )
    }
}

/// 编辑窗索引状态：与列表同一套 pending / stale / ready 文案和颜色。
private struct RAGChunkIndexStatusBadge: View {
    let status: RAGEmbeddingStatus

    var body: some View {
        RAGChunkLabeledStatusBadge(
            categoryKey: "rag.browser.chunk.indexLabel",
            titleKey: RAGChunkEmbeddingStatusStyle.titleKey(status),
            symbolName: RAGChunkEmbeddingStatusStyle.symbolName(status),
            tint: RAGChunkEmbeddingStatusStyle.color(status),
            helpKey: "rag.browser.chunk.indexHelp"
        )
    }
}

/// 短类别名 + 状态徽章，避免「可用」同时表示入库和向量就绪。
private struct RAGChunkLabeledStatusBadge: View {
    let categoryKey: LocalizedStringKey
    let titleKey: LocalizedStringKey
    let symbolName: String
    let tint: Color
    let helpKey: LocalizedStringKey

    var body: some View {
        // 冒号跟语言走文案，禁止在视图里写死全角「：」。
        HStack(spacing: 0) {
            Text(categoryKey)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("rag.browser.chunk.labelSeparator")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label {
                Text(titleKey)
            } icon: {
                Image(systemName: symbolName)
            }
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .symbolRenderingMode(.hierarchical)
            .padding(.leading, 2)
        }
        .help(helpKey)
    }
}
