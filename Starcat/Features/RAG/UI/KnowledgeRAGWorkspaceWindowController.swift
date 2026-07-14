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

/// 知识库 RAG 工作台窗口尺寸策略。
private enum KnowledgeRAGWorkspaceWindowMetrics {
    static let defaultContentSize = NSSize(width: 1440, height: 820)
    static let minimumContentSize = NSSize(width: 1180, height: 700)
    static let autosaveName = "KnowledgeRAGWorkspaceWindow"
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
    static func show(dependencies: AppDependencies, homeViewModel: HomeViewModel) {
        guard AIWorkspaceEntryGate.authorizeOpening(
            dependencies: dependencies,
            proFeature: .knowledgeRAG
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
        if shouldCenter {
            controller.window?.center()
        }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 用户数据库切换前销毁旧工作台，避免旧账户的内存历史继续显示，或在切库后把
    /// 未完成回答写进新账户数据库。
    @MainActor
    static func closeForUserDatabaseChange() {
        shared?.viewModel.cancelAnswer()
        shared?.close()
        shared = nil
    }

    private init(dependencies: AppDependencies, homeViewModel: HomeViewModel) {
        let chromeState = WorkspaceChromeState()
        let viewModel = KnowledgeRAGWorkspaceViewModel(
            dependencies: dependencies,
            homeViewModel: homeViewModel
        )
        self.chromeState = chromeState
        self.viewModel = viewModel

        let content = KnowledgeRAGWorkspaceView(chromeState: chromeState, viewModel: viewModel)
            .appHostEnvironment(dependencies, homeViewModel: homeViewModel)

        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)

        window.title = String.l10n("rag.workspace.window.title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(KnowledgeRAGWorkspaceWindowMetrics.defaultContentSize)
        window.contentMinSize = KnowledgeRAGWorkspaceWindowMetrics.minimumContentSize
        window.minSize = KnowledgeRAGWorkspaceWindowMetrics.minimumContentSize
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        window.setFrameAutosaveName(KnowledgeRAGWorkspaceWindowMetrics.autosaveName)

        let controls = NSTitlebarAccessoryViewController()
        controls.layoutAttribute = .right
        let controlsView = NSHostingView(rootView: WorkspaceTitlebarControls(
            chromeState: chromeState,
            onPinnedChange: { [weak window] isPinned in
                window?.level = isPinned ? .floating : .normal
            },
            onSettings: { [chromeState] in
                chromeState.isSettingsPresented = true
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

    func windowWillClose(_ notification: Notification) {
        viewModel.cancelAnswer()
        window?.resignKey()
        Self.shared = nil
    }
}

/// 复用单个知识库浏览器窗口。它只读本地知识库数据，索引操作仍交由既有 builder 执行。
final class KnowledgeRAGBrowserWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: KnowledgeRAGBrowserWindowController?

    @MainActor
    static func show(
        dependencies: AppDependencies,
        homeViewModel: HomeViewModel,
        centeredOver presentingWindow: NSWindow?
    ) {
        let isNewWindow = shared == nil
        let controller = shared ?? KnowledgeRAGBrowserWindowController(
            dependencies: dependencies,
            homeViewModel: homeViewModel
        )
        shared = controller
        controller.showWindow(nil)
        if isNewWindow, let window = controller.window {
            controller.center(window, over: presentingWindow)
        }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    private init(dependencies: AppDependencies, homeViewModel: HomeViewModel) {
        let content = KnowledgeRAGBrowserView(
            viewModel: KnowledgeRAGBrowserViewModel(
                dependencies: dependencies,
                homeViewModel: homeViewModel
            )
        )
        .appHostEnvironment(dependencies, homeViewModel: homeViewModel)
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = ""
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 980, height: 660))
        window.contentMinSize = NSSize(width: 760, height: 500)
        window.minSize = window.contentMinSize
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("KnowledgeRAGBrowserWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("KnowledgeRAGBrowserWindowController does not support storyboard initialization") }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }
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

    var coverage = RAGIndexCoverage(knowledgeRepoCount: 0, indexedRepoCount: 0, totalChunks: 0, readyChunks: 0, pendingChunks: 0, failedChunks: 0, staleChunks: 0)
    var candidates: [RAGRepoCandidate] = []
    var indexes: [Int64: RAGKnowledgeRepositoryIndex] = [:]
    var selectedRepoID: Int64?
    var chunks: [RAGManagedChunk] = []
    var hasMoreChunks = false
    var hasMoreRepositories = false
    var isLoading = false
    var isLoadingMoreChunks = false
    var isLoadingMoreRepositories = false
    var isIndexing = false
    /// 每个仓库单独保存完成时间，切换仓库时不能借用其它仓库或全局刷新的时间。
    var selectedRepositoryRefreshAt: Date? {
        guard let selectedRepoID else { return nil }
        return dependencies.knowledgeRAGIndexBuilder.repositoryRefreshDates[selectedRepoID]
    }
    var retrievalQuery = ""
    var retrievalHits: [RAGChildHit] = []
    /// 测试面板维护独立草稿，连续调参不会在用户明确保存前污染正式问答配置。
    var retrievalTestSettings: RAGRetrievalSettings
    var retrievalTestDiagnostics: RAGRetrievalDiagnostics?
    var isTestingRetrieval = false
    /// 仅在服务端成功返回后置位，用于区分“尚未测试”和“测试完成但无命中”。
    var hasCompletedRetrievalTest = false
    var errorMessage: String?

    init(dependencies: AppDependencies, homeViewModel: HomeViewModel) {
        self.dependencies = dependencies
        self.homeViewModel = homeViewModel
        self.retrievalTestSettings = dependencies.settings.ragRetrievalSettings.normalized()
    }

    var embeddingModel: String { dependencies.settings.aiEmbeddingTask.resolvedModelName }
    var selectedCandidate: RAGRepoCandidate? { candidates.first(where: { $0.repo.id == selectedRepoID }) }
    var selectedIndex: RAGKnowledgeRepositoryIndex? { selectedRepoID.flatMap { indexes[$0] } }

    func bootstrap() async { await refresh(showsLoading: true) }

    func observeIndexChanges() async {
        for await _ in NotificationCenter.default.notifications(named: .knowledgeRAGIndexDidChange) {
            guard !Task.isCancelled else { break }
            await refresh()
        }
    }

    func selectRepository(_ id: Int64) async {
        guard selectedRepoID != id else { return }
        let requestGeneration = repositorySelectionGate.begin()
        selectedRepoID = id
        await loadChunks(selectionGeneration: requestGeneration)
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
              rowIndex >= max(candidates.count - Self.repositoryPrefetchLeadCount, 0) else { return }
        isLoadingMoreRepositories = true
        defer { isLoadingMoreRepositories = false }
        await loadRepositories(limit: Self.repositoryPageSize, append: true)
    }

    func rebuildIndex() {
        guard !isIndexing, let repo = selectedCandidate?.repo else { return }
        isIndexing = true
        Task { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let startedAt = clock.now
            do {
                try await dependencies.knowledgeRAGIndexBuilder.rebuildRepository(repo)
                await refresh()
            } catch { errorMessage = error.localizedDescription }
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
                let result = try await service.testRetrieval(query: query)
                retrievalHits = result.childHits.sorted { $0.score > $1.score }
                retrievalTestDiagnostics = result.diagnostics
                hasCompletedRetrievalTest = true
            } catch { errorMessage = error.localizedDescription }
        }
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

    func saveChunk(_ managed: RAGManagedChunk, title: String, sectionPath: String, content: String) async {
        guard let id = managed.chunk.id else { return }
        do {
            try await dependencies.ragChunkRepository.saveKnowledgeChunkOverride(id: id, title: title, sectionPath: sectionPath, content: content)
            await refresh()
            // 保存先恢复“可用”管理状态，再后台补 embedding；完成事件会让浏览器自动从 pending 更新到 ready。
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await dependencies.knowledgeRAGIndexBuilder.embedEditedChunks()
                    await refresh()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// 首次删除仅下架：仍显示在管理列表且可编辑，但 SQL 召回会立即排除它。
    func disableChunk(_ managed: RAGManagedChunk) async {
        guard let id = managed.chunk.id else { return }
        do {
            try await dependencies.ragChunkRepository.setKnowledgeChunkExcluded(id: id, isExcluded: true)
            // 下架只更新当前项；整页 refresh 会丢掉“加载更多”已有的数据并回到第一页。
            if let index = chunks.firstIndex(where: { $0.id == id }) {
                chunks[index].isExcluded = true
            }
            try await refreshIndexStatistics()
        } catch { errorMessage = error.localizedDescription }
    }

    /// 对已下架项的第二次删除才是永久删除：写 tombstone 并移除索引行，后续 source 重建也不会复活。
    func permanentlyDeleteChunk(_ managed: RAGManagedChunk) async {
        guard let id = managed.chunk.id else { return }
        do {
            try await dependencies.ragChunkRepository.permanentlyDeleteKnowledgeChunk(id: id)
            chunks.removeAll { $0.id == id }
            try await refreshIndexStatistics()
        } catch { errorMessage = error.localizedDescription }
    }

    func restoreChunk(_ managed: RAGManagedChunk) async {
        guard let id = managed.chunk.id else { return }
        do {
            try await dependencies.ragChunkRepository.restoreKnowledgeChunk(id: id)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
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
            await loadChunks()
        } catch { errorMessage = error.localizedDescription }
    }

    /// 分片删除后仅同步统计，保留用户已分页加载到内存中的其他分片。
    private func refreshIndexStatistics() async throws {
        async let loadedCoverage = dependencies.ragChunkRepository.coverage(model: embeddingModel)
        async let loadedIndexes = dependencies.ragChunkRepository.knowledgeRepositoryIndexes(model: embeddingModel)
        coverage = try await loadedCoverage
        indexes = Dictionary(uniqueKeysWithValues: try await loadedIndexes.map { ($0.repoID, $0) })
    }

    private static let repositoryPageSize = 20
    /// 距列表尾部还有这么多行时开始续页，保证滚到底前数据已接上。
    private static let repositoryPrefetchLeadCount = 8
    private static let initialChunkPageSize = 10
    private static let additionalChunkPageSize = 10

    private func loadRepositories(limit: Int, append: Bool) async {
        let offset = append ? candidates.count : 0
        do {
            let page = try await dependencies.ragCandidateRepository.fetchKnowledgeBrowserPage(
                limit: limit,
                offset: offset
            )
            if append {
                let existingIDs = Set(candidates.map(\.repo.id))
                candidates.append(contentsOf: page.candidates.filter { !existingIDs.contains($0.repo.id) })
            } else {
                candidates = page.candidates
                if selectedRepoID == nil || !candidates.contains(where: { $0.repo.id == selectedRepoID }) {
                    selectedRepoID = candidates.first?.repo.id
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
            hasMoreChunks = false
            return
        }
        let requestedRepoID = selectedRepoID
        let requestedOffset = append ? chunks.count : 0
        do {
            let page = try await dependencies.ragChunkRepository.fetchManagedKnowledgeChunks(
                repoId: requestedRepoID,
                limit: limit,
                offset: requestedOffset
            )
            // refresh / load more 与用户点选可以并发；只允许仍属于当前仓库且仍是最新选择的
            // 结果改写列表，避免 A 的分页数据出现在 B 的详情中。
            guard self.selectedRepoID == requestedRepoID,
                  selectionGeneration.map(repositorySelectionGate.isCurrent) ?? true else { return }
            if append {
                chunks.append(contentsOf: page.chunks)
            } else {
                chunks = page.chunks
            }
            hasMoreChunks = page.hasMore
        }
        catch { errorMessage = error.localizedDescription }
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
    @State private var editingChunk: RAGManagedChunk?
    @State private var inspectingHit: RAGRetrievalHitInspection?
    @State private var hoveredRetrievalHitID: Int64?
    @State private var hoveredRepositoryID: Int64?
    @State private var hoveredChunkID: Int64?
    @State private var isKnowledgeOverviewExpanded = false
    @State private var isRetrievalTestExpanded = false
    @State private var isRetrievalTestSettingsExpanded = false
    @State private var knowledgeHeroCollapseProgress: CGFloat = 0
    @State private var permanentlyDeletingChunk: RAGManagedChunk?
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

    /// 与主工作台 Composer 保持同一 13pt 高密度基准，并随全局界面字号档位缩放。
    private var retrievalQueryFont: NSFont {
        NSFont.systemFont(ofSize: interfaceScale.scaled(13))
    }

    private var retrievalQueryMinHeight: CGFloat {
        ceil(retrievalQueryLineHeight * 2 + RAGComposerTextEditor.verticalInset * 2)
    }

    private var retrievalQueryMaxHeight: CGFloat {
        ceil(retrievalQueryLineHeight * 4 + RAGComposerTextEditor.verticalInset * 2)
    }

    private var retrievalQueryFrameHeight: CGFloat {
        let measured = retrievalQueryEditorHeight > 0 ? retrievalQueryEditorHeight : retrievalQueryMinHeight
        return min(max(measured, retrievalQueryMinHeight), retrievalQueryMaxHeight)
    }

    var body: some View {
        HSplitView {
            repositoryList.frame(minWidth: 240, idealWidth: 300, maxWidth: 360)
            detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await viewModel.bootstrap() }
        .task { await viewModel.observeIndexChanges() }
        .sheet(isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            RAGWorkspaceErrorSheet(
                error: .init(technicalDetail: viewModel.errorMessage ?? ""),
                onAction: { action in
                    if action == .openAISettings {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                    viewModel.errorMessage = nil
                },
                onDismiss: { viewModel.errorMessage = nil }
            )
            .appLocaleEnvironment()
        }
        .sheet(item: $editingChunk) { chunk in
            KnowledgeRAGChunkEditor(chunk: chunk) { title, sectionPath, content in
                await viewModel.saveChunk(chunk, title: title, sectionPath: sectionPath, content: content)
            }
            .appLocaleEnvironment()
        }
        .sheet(item: $inspectingHit) { hit in
            KnowledgeRAGChunkEditor(hit: hit) {
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
    }

    private var repositoryList: some View {
        ZStack(alignment: .top) {
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
                        .padding(.vertical, 8)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(viewModel.candidates.enumerated()), id: \.element.repo.id) { rowIndex, candidate in
                            repositoryRow(candidate, rowIndex: rowIndex)
                                .onAppear {
                                    // 距尾部 8 行即续载，避免贴底才请求造成停顿。
                                    Task { await viewModel.loadMoreRepositoriesIfNeeded(rowIndex: rowIndex) }
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
                    .padding(.bottom, 12)
                }
            }
            .coordinateSpace(name: "knowledgeBrowserSidebarScroll")
            .onPreferenceChange(KnowledgeRAGBrowserScrollOffsetKey.self) { offsetY in
                knowledgeHeroCollapseProgress = knowledgeHeroCollapseProgress(for: offsetY)
            }

            collapsedKnowledgeHeader
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
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
            Text("\(viewModel.coverage.indexedRepoCount)/\(viewModel.coverage.knowledgeRepoCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("\(viewModel.coverage.readyChunks)")
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let candidate = viewModel.selectedCandidate { repositoryDetail(candidate) }
                else { ContentUnavailableView("rag.browser.empty", systemImage: "books.vertical").frame(maxWidth: .infinity, minHeight: 280) }
            }
            .padding(20)
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
                    Image(systemName: isKnowledgeOverviewExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("rag.browser.overview").font(.headline)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(12)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerStyle(.link)

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
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.embeddingModel)
                .font(.caption2.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                // primary 低透明在明暗主题都会反转，比 controlBackground 叠在卡片上更明显。
                .background(Color.primary.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.16)))
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                overviewStat("rag.workspace.status.repos", value: "\(viewModel.coverage.indexedRepoCount)/\(viewModel.coverage.knowledgeRepoCount)", color: .blue)
                overviewStat("rag.workspace.status.readyChunks", value: "\(viewModel.coverage.readyChunks)", color: .green)
                overviewStat("rag.workspace.status.pendingChunks", value: "\(viewModel.coverage.pendingChunks)", color: .orange)
                overviewStat("rag.workspace.status.failedChunks", value: "\(viewModel.coverage.failedChunks)", color: .red)
                overviewStat("rag.workspace.status.staleChunks", value: "\(viewModel.coverage.staleChunks)", color: .purple)
            }
        }
    }

    /// 圆点与标签同行；数字与整块一起靠左。
    private func overviewStat(_ key: LocalizedStringKey, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(key).font(.caption).lineLimit(1)
            }
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var retrievalTestCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isRetrievalTestExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isRetrievalTestExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("rag.browser.retrieval.title").font(.headline)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(12)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerStyle(.link)

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
            ZStack(alignment: .bottomTrailing) {
                // AppKit 输入：默认 2 行 / 最高 4 行；超长时 NSScrollView 出滚动条。
                RAGComposerTextEditor(
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
                        // 18pt 圆钮贴合 2～4 行输入框角位；24pt 会压过输入区观感。
                        Button { viewModel.runRetrievalTest() } label: {
                            Image(systemName: "testtube.2")
                                .font(interfaceScale.font(size: 9, weight: .semibold))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .foregroundStyle(.white)
                        .background(
                            Circle().fill(
                                viewModel.retrievalQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Color.accentColor.opacity(0.4)
                                    : Color.accentColor
                            )
                        )
                        .disabled(viewModel.retrievalQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                    Image(systemName: isRetrievalTestSettingsExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("rag.browser.retrieval.settings.title")
                        .font(.caption.weight(.semibold))
                    if viewModel.hasUnsavedRetrievalTestSettings {
                        Text("rag.browser.retrieval.settings.unsaved")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    Text("rag.browser.retrieval.settings.draftHint")
                        .font(.caption2)
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

                    HStack(alignment: .top, spacing: 10) {
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
                        HStack(spacing: 10) {
                            ForEach(RAGChunkSource.allCases, id: \.self) { source in
                                Toggle(source.titleKey, isOn: retrievalTestSourceBinding(source))
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
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(didRestoreRetrievalTestSettings ? Color.green : Color.primary)
                                .frame(width: 14, height: 14)
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
                                .font(.caption.weight(.semibold))
                                .frame(width: 14, height: 14)
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
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
                .frame(maxWidth: .infinity)
        }
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
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(String(format: "%.3f", value))
                .font(.caption2.monospaced())
                .foregroundStyle(.primary)
        }
    }

    private func repositoryRow(_ candidate: RAGRepoCandidate, rowIndex: Int) -> some View {
        let selected = candidate.repo.id == viewModel.selectedRepoID
        let isHovered = hoveredRepositoryID == candidate.repo.id
        let index = viewModel.indexes[candidate.repo.id]
        return Button { Task { await viewModel.selectRepository(candidate.repo.id) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                RepoIdentityLabel(
                    fullName: candidate.repo.fullName,
                    ownerAvatarURL: candidate.repo.ownerAvatar,
                    avatarSize: 18,
                    font: .callout.weight(selected ? .semibold : .regular),
                    spacing: 6,
                    showAvatarBorder: false
                )
                Text(candidate.repo.description ?? String.l10n("rag.browser.noDescription")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    if let language = candidate.repo.language, !language.isEmpty { Text(language) }
                    if let index { Text("\(index.readyChunks)/\(index.totalChunks)") }
                }
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(repositoryRowBackground(rowIndex: rowIndex, selected: selected, isHovered: isHovered))
            .overlay {
                if selected || isHovered {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(repositoryRowBorderColor(selected: selected, isHovered: isHovered))
                }
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointerStyle(.link)
        .padding(.horizontal, 8)
        .onHover { isHovering in
            hoveredRepositoryID = isHovering ? candidate.repo.id : nil
        }
    }

    /// 选中和悬停优先于底纹，确保当前操作对象仍是列表里的最强视觉信号。
    private func repositoryRowBackground(rowIndex: Int, selected: Bool, isHovered: Bool) -> Color {
        if selected { return Color.accentColor.opacity(0.12) }
        if isHovered { return Color.accentColor.opacity(0.07) }
        return zebraStripeBackground(rowIndex: rowIndex)
    }

    private func repositoryRowBorderColor(selected: Bool, isHovered: Bool) -> Color {
        if selected { return Color.accentColor.opacity(0.35) }
        if isHovered { return Color.accentColor.opacity(0.55) }
        return .clear
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
                }
                Spacer()
                // logo-only：打开 Starcat 独立详情窗；文案留给 help / accessibility。
                Button {
                    viewModel.openSelectedRepository()
                } label: {
                    // App Icon 带玻璃外框，小尺寸下主体看不清；裁掉外围放大黑猫/金星。
                    StarcatCompactMark(size: 16)
                        .squareLogoActionChrome()
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
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
                // icon-only：统一走 SyncIconButton，与上下文-索引刷新一致。
                SyncIconButton(
                    isRefreshing: viewModel.isIndexing,
                    disabled: viewModel.isIndexing,
                    font: .caption,
                    frameSize: 18,
                    tooltip: String.l10n("rag.workspace.index.rebuild")
                ) {
                    viewModel.rebuildIndex()
                }
            }
            if viewModel.chunks.isEmpty {
                ContentUnavailableView("rag.browser.noChunks", systemImage: "doc.text").frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.chunks.enumerated()), id: \.element.id) { index, chunk in
                        if index > 0 { Divider() }
                        chunkRow(chunk, rowIndex: index)
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
        return HStack(alignment: .top, spacing: 8) {
            Button { editingChunk = managed } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        // 与证据卡 / 引用列表同源：来源 SF Symbol + tint。
                        Image(systemName: chunk.source.systemImageName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(chunk.source.tintColor)
                            .accessibilityHidden(true)
                        Text(sourceKey(chunk.source)).font(.caption.weight(.semibold))
                        Text(verbatim: String(format: String.l10n("rag.browser.chunks.tokenCountFormat"), chunk.tokenCount))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(chunk.sectionPath.isEmpty ? chunk.title : chunk.sectionPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                    }
                    Text(chunk.content).font(.caption).lineLimit(3)
                    if let error = chunk.embeddingError, !error.isEmpty { Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerStyle(.link)

            // 编辑 / 状态 / 删除三图标统一 caption2，与「可用」绿勾同视觉字号；点击热区仍略放大。
            HStack(alignment: .center, spacing: 8) {
                if managed.hasOverride {
                    Image(systemName: "pencil.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
                Label {
                    Text(managedStatusKey(managed, embeddingStatus: status))
                } icon: {
                    Image(systemName: managedStatusIcon(managed, embeddingStatus: status))
                }
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(managedStatusColor(managed, embeddingStatus: status))
                .symbolRenderingMode(.hierarchical)
                Button(role: .destructive) {
                    if managed.isExcluded {
                        permanentlyDeletingChunk = managed
                    } else {
                        Task { await viewModel.disableChunk(managed) }
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .frame(width: 28, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerStyle(.link)
                .foregroundStyle(.red)
                .help(managed.isExcluded ? "rag.browser.chunk.permanentDelete" : "rag.browser.chunk.disable")
            }
            .frame(height: 16)
        }
        .padding(12)
        .background(chunkRowBackground(managed, isHovered: isHovered, rowIndex: rowIndex))
        .contentShape(Rectangle())
        .onHover { hoveredChunkID = $0 ? managed.id : nil }
    }

    private func chunkRowBackground(_ managed: RAGManagedChunk, isHovered: Bool, rowIndex: Int) -> Color {
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
        switch status {
        case .ready: return "rag.browser.status.ready"
        case .pending: return "rag.browser.status.pending"
        case .failed: return "rag.browser.status.failed"
        case .stale: return "rag.browser.status.stale"
        case .keywordOnly: return "rag.browser.status.keywordOnly"
        }
    }

    private func statusColor(_ status: RAGEmbeddingStatus) -> Color {
        switch status {
        case .ready: return .green
        case .pending: return .orange
        case .failed: return .red
        case .stale: return .purple
        case .keywordOnly: return .blue
        }
    }

    private func managedStatusKey(_ managed: RAGManagedChunk, embeddingStatus: RAGEmbeddingStatus) -> LocalizedStringKey {
        managed.isExcluded ? "rag.browser.status.unavailable" : statusKey(embeddingStatus)
    }

    private func managedStatusColor(_ managed: RAGManagedChunk, embeddingStatus: RAGEmbeddingStatus) -> Color {
        // 下架态固定红色，与编辑窗「不可用」一致；其余仍跟 embedding 状态色。
        managed.isExcluded ? .red : statusColor(embeddingStatus)
    }

    private func managedStatusIcon(_ managed: RAGManagedChunk, embeddingStatus: RAGEmbeddingStatus) -> String {
        if managed.isExcluded { return RAGChunkAvailabilityBadge.unavailableSymbol }
        switch embeddingStatus {
        case .ready: return RAGChunkAvailabilityBadge.availableSymbol
        case .pending: return "clock.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stale: return "clock.arrow.circlepath"
        case .keywordOnly: return "text.magnifyingglass"
        }
    }

    /// 与仓库级统计保持同一语义：旧 embedding 模型即使数据库残留 ready，也不能被标为当前可用。
    private func effectiveStatus(for chunk: RAGChunk) -> RAGEmbeddingStatus {
        if chunk.embeddingStatus == .ready, chunk.embeddingModel != viewModel.embeddingModel { return .stale }
        return chunk.embeddingStatus
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
    let chunk: RAGChunk
    let isExcluded: Bool?
    let retrievalMetadata: (repositoryName: String, ownerAvatarURL: String?, kind: String, score: Double, vectorSimilarity: Double?)?
    let onSave: ((String, String, String) async -> Void)?
    /// 只读命中详情右上角：切到同款编辑 sheet（左侧列表点进的那个）。
    let onEdit: (() -> Void)?
    @State private var title: String
    @State private var sectionPath: String
    @State private var content: String

    init(chunk: RAGManagedChunk, onSave: @escaping (String, String, String) async -> Void) {
        self.chunk = chunk.chunk
        isExcluded = chunk.isExcluded
        retrievalMetadata = nil
        self.onSave = onSave
        onEdit = nil
        _title = State(initialValue: chunk.chunk.title)
        _sectionPath = State(initialValue: chunk.chunk.sectionPath)
        _content = State(initialValue: chunk.chunk.content)
    }

    init(hit: RAGRetrievalHitInspection, onEdit: @escaping () -> Void) {
        chunk = hit.hit.chunk
        isExcluded = nil
        retrievalMetadata = (
            hit.repositoryName,
            hit.ownerAvatarURL,
            hit.hit.kind.rawValue,
            hit.hit.score,
            hit.hit.vectorSimilarity
        )
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
                Image(systemName: chunk.source.systemImageName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(chunk.source.tintColor)
                    .accessibilityHidden(true)
                if isReadOnly {
                    Text("rag.browser.retrieval.detail").font(.title3.weight(.semibold))
                } else {
                    Text("rag.browser.chunk.edit").font(.title3.weight(.semibold))
                }
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
                    Text(chunk.source.rawValue).font(.caption).foregroundStyle(.secondary)
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
                    .disabled(isReadOnly)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("rag.browser.chunk.sectionLabel").font(.caption).foregroundStyle(.secondary)
                TextField("rag.browser.chunk.section", text: $sectionPath)
                    .disabled(isReadOnly)
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
                        .font(.body)
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
            if let onSave, let isExcluded {
                HStack(alignment: .center, spacing: 12) {
                    // 与列表共用可用/不可用图标色；不可用时附保存后恢复提示。
                    RAGChunkAvailabilityBadge(isExcluded: isExcluded, showsRestoreHint: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("common.cancel") { dismiss() }
                    Button("rag.browser.chunk.save") {
                        Task {
                            await onSave(title, sectionPath, content)
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    }
}

/// 分片管理态徽章：列表与编辑窗共用，可用绿勾、不可用红叉。
private struct RAGChunkAvailabilityBadge: View {
    static let availableSymbol = "checkmark.circle.fill"
    static let unavailableSymbol = "xmark.circle.fill"

    let isExcluded: Bool
    var showsRestoreHint: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label {
                Text(isExcluded ? "rag.browser.status.unavailable" : "rag.browser.status.available")
            } icon: {
                Image(systemName: isExcluded ? Self.unavailableSymbol : Self.availableSymbol)
            }
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isExcluded ? Color.red : Color.green)
            .symbolRenderingMode(.hierarchical)

            if isExcluded, showsRestoreHint {
                Text("rag.browser.chunk.edit.restoreHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
