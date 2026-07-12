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
    @MainActor
    static func show(dependencies: AppDependencies) {
        let controller: KnowledgeRAGWorkspaceWindowController
        let shouldCenter: Bool

        if let shared {
            controller = shared
            shouldCenter = false
        } else {
            controller = KnowledgeRAGWorkspaceWindowController(dependencies: dependencies)
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

    private init(dependencies: AppDependencies) {
        let chromeState = WorkspaceChromeState()
        let viewModel = KnowledgeRAGWorkspaceViewModel(dependencies: dependencies)
        self.chromeState = chromeState
        self.viewModel = viewModel

        let content = KnowledgeRAGWorkspaceView(chromeState: chromeState, viewModel: viewModel)
        .appHostEnvironment(dependencies)

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
        let controlsView = NSHostingView(rootView: WorkspaceTitlebarControls(chromeState: chromeState) { [weak window] isPinned in
            window?.level = isPinned ? .floating : .normal
        })
        // 标题栏 accessory 由 AppKit 布局；显式 frame 能避免 SwiftUI hosting view 初始 intrinsic size 为 0。
        controlsView.frame = NSRect(x: 0, y: 0, width: 112, height: 32)
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
    static func show(dependencies: AppDependencies, centeredOver presentingWindow: NSWindow?) {
        let isNewWindow = shared == nil
        let controller = shared ?? KnowledgeRAGBrowserWindowController(dependencies: dependencies)
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

    private init(dependencies: AppDependencies) {
        let content = KnowledgeRAGBrowserView(viewModel: KnowledgeRAGBrowserViewModel(dependencies: dependencies))
            .appHostEnvironment(dependencies)
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = String.l10n("rag.browser.window.title")
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

    var coverage = RAGIndexCoverage(knowledgeRepoCount: 0, indexedRepoCount: 0, totalChunks: 0, readyChunks: 0, pendingChunks: 0, failedChunks: 0, staleChunks: 0)
    var candidates: [RAGRepoCandidate] = []
    var indexes: [Int64: RAGKnowledgeRepositoryIndex] = [:]
    var selectedRepoID: Int64?
    var chunks: [RAGManagedChunk] = []
    var hasMoreChunks = false
    var isLoading = false
    var isLoadingMoreChunks = false
    var isIndexing = false
    /// 每个仓库单独保存完成时间，切换仓库时不能借用其它仓库或全局刷新的时间。
    var selectedRepositoryRefreshAt: Date? {
        guard let selectedRepoID else { return nil }
        return dependencies.knowledgeRAGIndexBuilder.repositoryRefreshDates[selectedRepoID]
    }
    var retrievalQuery = ""
    var retrievalHits: [RAGChildHit] = []
    var isTestingRetrieval = false
    var errorMessage: String?

    init(dependencies: AppDependencies) { self.dependencies = dependencies }

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
        selectedRepoID = id
        await loadChunks()
    }

    func loadMoreChunks() async {
        guard !isLoadingMoreChunks, hasMoreChunks, selectedRepoID != nil else { return }
        isLoadingMoreChunks = true
        defer { isLoadingMoreChunks = false }
        await loadChunks(limit: Self.additionalChunkPageSize, append: true)
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

    func openSelectedRepository() {
        guard let repo = selectedCandidate?.repo else { return }
        dependencies.companionActionDispatcher.requestOpenRepo(repo)
    }

    func runRetrievalTest() {
        let query = retrievalQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isTestingRetrieval else { return }
        isTestingRetrieval = true
        Task { [weak self] in
            guard let self else { return }
            defer { isTestingRetrieval = false }
            do {
                let service = try dependencies.makeKnowledgeRAGService(selectedModelID: nil)
                retrievalHits = try await service.testRetrieval(query: query).childHits.sorted { $0.score > $1.score }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func repositoryName(for id: Int64) -> String {
        candidates.first(where: { $0.repo.id == id })?.repo.fullName ?? "#\(id)"
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
            let plan = RAGQueryPlan(mode: .semanticOnly, semanticQuery: "knowledge")
            async let loadedCandidates = dependencies.ragCandidateRepository.fetchCandidates(plan: plan, explicitRepoIDs: [], explicitMode: .only)
            try await refreshIndexStatistics()
            candidates = try await loadedCandidates
            if selectedRepoID == nil || !candidates.contains(where: { $0.repo.id == selectedRepoID }) {
                selectedRepoID = candidates.first?.repo.id
            }
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

    private static let initialChunkPageSize = 5
    private static let additionalChunkPageSize = 10

    private func loadChunks() async {
        await loadChunks(limit: Self.initialChunkPageSize, append: false)
    }

    private func loadChunks(limit: Int, append: Bool) async {
        guard let selectedRepoID else {
            chunks = []
            hasMoreChunks = false
            return
        }
        do {
            let page = try await dependencies.ragChunkRepository.fetchManagedKnowledgeChunks(
                repoId: selectedRepoID,
                limit: limit,
                offset: append ? chunks.count : 0
            )
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
private struct KnowledgeRAGBrowserView: View {
    @Bindable var viewModel: KnowledgeRAGBrowserViewModel
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @State private var editingChunk: RAGManagedChunk?
    @State private var inspectingHit: RAGRetrievalHitInspection?
    @State private var hoveredRetrievalHitID: Int64?
    @State private var hoveredRepositoryID: Int64?
    @State private var hoveredChunkID: Int64?
    @State private var isRetrievalTestExpanded = false
    @State private var permanentlyDeletingChunk: RAGManagedChunk?

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
                technicalDetail: viewModel.errorMessage ?? "",
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
            KnowledgeRAGRetrievalHitDetail(hit: hit)
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("rag.browser.title").font(.title3.weight(.semibold))
                Text("rag.browser.subtitle").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            VStack(spacing: 8) {
                knowledgeOverviewCard
                retrievalTestCard
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            Divider()
            Text("rag.browser.repositories")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(viewModel.candidates, id: \.repo.id) { candidate in repositoryRow(candidate) }
                }
                .padding(.bottom, 12)
            }
            .frame(minHeight: 140, maxHeight: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
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
    private var knowledgeOverviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("rag.browser.overview").font(.headline)
            Text(viewModel.embeddingModel)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
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
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.35)))
    }

    private func overviewStat(_ key: LocalizedStringKey, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(key).font(.caption).lineLimit(1)
                Text(value).font(.callout.weight(.semibold).monospacedDigit())
            }
            Spacer(minLength: 0)
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
                    Image(systemName: isRetrievalTestExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("rag.browser.retrieval.title").font(.headline)
                    Spacer()
                    Text("rag.browser.retrieval.hint").font(.caption2).foregroundStyle(.secondary)
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
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $viewModel.retrievalQuery)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        // 为右下角操作预留输入空间，避免第二行文本被按钮覆盖。
                        .padding(.trailing, 104)
                        .padding(.bottom, 28)
                    if viewModel.retrievalQuery.isEmpty {
                        Text("rag.browser.retrieval.placeholder")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            // 与 TextEditor 的原生首行基线匹配，避免占位文本与光标错行。
                            .padding(.leading, 5)
                            .padding(.top, 2)
                            .allowsHitTesting(false)
                    }
                }
                Button("rag.browser.retrieval.run") { viewModel.runRetrievalTest() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.retrievalQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isTestingRetrieval)
                    .padding(8)
            }
            .frame(height: 72)
            .padding(.horizontal, 7)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.24)))
            if viewModel.isTestingRetrieval { ProgressView().controlSize(.small) }
            if !viewModel.retrievalHits.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.retrievalHits, id: \.chunk.id) { hit in
                            retrievalHitRow(hit)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
    }

    private func retrievalHitRow(_ hit: RAGChildHit) -> some View {
        Button {
            inspectingHit = RAGRetrievalHitInspection(hit: hit, repositoryName: viewModel.repositoryName(for: hit.chunk.repoId))
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(viewModel.repositoryName(for: hit.chunk.repoId)).font(.caption.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(String(format: "%.3f", hit.score)).font(.caption.monospaced()).foregroundStyle(.primary)
                }
                Text(hit.chunk.sectionPath.isEmpty ? hit.chunk.title : hit.chunk.sectionPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(sourceKey(hit.chunk.source))
                    Text("·")
                    Text(hit.kind.rawValue)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(8)
            .background(
                hoveredRetrievalHitID == hit.chunk.id ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointerStyle(.link)
        .onHover { isHovering in
            hoveredRetrievalHitID = isHovering ? hit.chunk.id : nil
        }
    }

    private func repositoryRow(_ candidate: RAGRepoCandidate) -> some View {
        let selected = candidate.repo.id == viewModel.selectedRepoID
        let isHovered = hoveredRepositoryID == candidate.repo.id
        let index = viewModel.indexes[candidate.repo.id]
        return Button { Task { await viewModel.selectRepository(candidate.repo.id) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.repo.fullName).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                Text(candidate.repo.description ?? String.l10n("rag.browser.noDescription")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    if let language = candidate.repo.language, !language.isEmpty { Text(language) }
                    if let index { Text("\(index.readyChunks)/\(index.totalChunks)") }
                }
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(repositoryCardBackground(selected: selected, isHovered: isHovered), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(repositoryCardBorderColor(selected: selected, isHovered: isHovered))
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointerStyle(.link)
        .padding(.horizontal, 8)
        .onHover { isHovering in
            hoveredRepositoryID = isHovering ? candidate.repo.id : nil
        }
    }

    /// 仓库列表始终保留卡片边界，避免未选中项在浅色背景中融成一片。
    private func repositoryCardBackground(selected: Bool, isHovered: Bool) -> Color {
        if selected { return Color.accentColor.opacity(0.12) }
        if isHovered { return Color.accentColor.opacity(0.07) }
        return Color(nsColor: .textBackgroundColor)
    }

    private func repositoryCardBorderColor(selected: Bool, isHovered: Bool) -> Color {
        if selected { return Color.accentColor.opacity(0.35) }
        if isHovered { return Color.accentColor.opacity(0.55) }
        return Color(nsColor: .separatorColor).opacity(0.35)
    }

    private func repositoryDetail(_ candidate: RAGRepoCandidate) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.repo.fullName).font(.title3.weight(.semibold))
                    Text(candidate.repo.description ?? String.l10n("rag.browser.noDescription")).font(.body).foregroundStyle(.secondary)
                }
                Spacer()
                Button("rag.browser.open") { viewModel.openSelectedRepository() }.buttonStyle(.bordered)
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
            HStack {
                Text("rag.browser.chunks").font(.headline)
                Spacer()
                if let index = viewModel.selectedIndex {
                    repositoryIndexStatisticsLabel(index)
                }
                repositoryRefreshTime
                Button { viewModel.rebuildIndex() } label: {
                    HStack(spacing: 6) {
                        refreshIndexIcon
                        Text("rag.workspace.index.rebuild")
                    }
                }
                .buttonStyle(.bordered).disabled(viewModel.isIndexing)
            }
            if viewModel.chunks.isEmpty {
                ContentUnavailableView("rag.browser.noChunks", systemImage: "doc.text").frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ForEach(viewModel.chunks) { chunk in chunkRow(chunk) }
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

    private func chunkRow(_ managed: RAGManagedChunk) -> some View {
        let chunk = managed.chunk
        let status = effectiveStatus(for: chunk)
        let isHovered = hoveredChunkID == managed.id
        return HStack(alignment: .top, spacing: 8) {
            Button { editingChunk = managed } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
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

            // 状态与删除入口共用标题行高度，避免图标因 28pt 点击框而向下错位。
            HStack(alignment: .center, spacing: 8) {
                if managed.hasOverride { Image(systemName: "pencil.circle.fill").foregroundStyle(Color.accentColor) }
                Text(managedStatusKey(managed, embeddingStatus: status))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(managedStatusColor(managed, embeddingStatus: status))
                Button(role: .destructive) {
                    if managed.isExcluded {
                        permanentlyDeletingChunk = managed
                    } else {
                        Task { await viewModel.disableChunk(managed) }
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.callout)
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
        .background(chunkCardBackground(managed, isHovered: isHovered), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(isHovered ? 0.7 : 0.35))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hoveredChunkID = $0 ? managed.id : nil }
    }

    private func chunkCardBackground(_ managed: RAGManagedChunk, isHovered: Bool) -> Color {
        if isHovered { return Color.accentColor.opacity(0.10) }
        if managed.isExcluded { return Color.secondary.opacity(0.10) }
        // 使用 control surface 作为常态，确保每个分片在详情页中保持独立卡片层级。
        return Color(nsColor: .controlBackgroundColor)
    }

    private func stat(_ key: LocalizedStringKey, value: String, color: Color) -> some View {
        VStack(alignment: .center, spacing: 4) {
            HStack(spacing: 5) { Circle().fill(color).frame(width: 7, height: 7); Text(key).font(.caption) }
                .frame(maxWidth: .infinity, alignment: .center)
            Text(value).font(.callout.weight(.semibold).monospaced())
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var refreshIndexIcon: some View {
        if reduceMotion {
            Image(systemName: "arrow.triangle.2.circlepath")
        } else {
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.rotate, options: .repeating, isActive: viewModel.isIndexing)
        }
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
        switch source {
        case .readme: return "rag.browser.source.readme"
        case .notes: return "rag.browser.source.notes"
        case .summary: return "rag.browser.source.summary"
        case .metadata: return "rag.browser.source.metadata"
        }
    }

    private func statusKey(_ status: RAGEmbeddingStatus) -> LocalizedStringKey {
        switch status {
        case .ready: return "rag.browser.status.ready"
        case .pending: return "rag.browser.status.pending"
        case .failed: return "rag.browser.status.failed"
        case .stale: return "rag.browser.status.stale"
        }
    }

    private func statusColor(_ status: RAGEmbeddingStatus) -> Color {
        switch status {
        case .ready: return .green
        case .pending: return .orange
        case .failed: return .red
        case .stale: return .purple
        }
    }

    private func managedStatusKey(_ managed: RAGManagedChunk, embeddingStatus: RAGEmbeddingStatus) -> LocalizedStringKey {
        managed.isExcluded ? "rag.browser.status.unavailable" : statusKey(embeddingStatus)
    }

    private func managedStatusColor(_ managed: RAGManagedChunk, embeddingStatus: RAGEmbeddingStatus) -> Color {
        managed.isExcluded ? .secondary : statusColor(embeddingStatus)
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
}

/// 召回命中详情只读展示完整分片与评分，避免测试列表为了预览而截断关键信息。
private struct KnowledgeRAGRetrievalHitDetail: View {
    @Environment(\.dismiss) private var dismiss
    let hit: RAGRetrievalHitInspection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("rag.browser.retrieval.detail").font(.headline)
                Spacer()
                SheetCloseButton(action: { dismiss() })
            }
            HStack(spacing: 8) {
                Text(hit.repositoryName).font(.callout.weight(.semibold))
                Text(hit.hit.chunk.source.rawValue).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(hit.hit.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%.3f", hit.hit.score)).font(.caption.monospaced())
            }
            Text(hit.hit.chunk.sectionPath.isEmpty ? hit.hit.chunk.title : hit.hit.chunk.sectionPath)
                .font(.subheadline.weight(.semibold))
            ScrollView { Text(hit.hit.chunk.content).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(18)
        .frame(width: 680, height: 500)
    }
}

/// 分片编辑器只提交人工覆盖层；关闭或重建都不会直接覆盖 README 等源数据。
private struct KnowledgeRAGChunkEditor: View {
    @Environment(\.dismiss) private var dismiss
    let chunk: RAGManagedChunk
    let onSave: (String, String, String) async -> Void
    @State private var title: String
    @State private var sectionPath: String
    @State private var content: String

    init(chunk: RAGManagedChunk, onSave: @escaping (String, String, String) async -> Void) {
        self.chunk = chunk
        self.onSave = onSave
        _title = State(initialValue: chunk.chunk.title)
        _sectionPath = State(initialValue: chunk.chunk.sectionPath)
        _content = State(initialValue: chunk.chunk.content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("rag.browser.chunk.edit").font(.headline); Spacer(); SheetCloseButton(action: { dismiss() }) }
            VStack(alignment: .leading, spacing: 4) {
                Text("rag.browser.chunk.titleLabel").font(.caption).foregroundStyle(.secondary)
                TextField("rag.browser.chunk.title", text: $title)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("rag.browser.chunk.sectionLabel").font(.caption).foregroundStyle(.secondary)
                TextField("rag.browser.chunk.section", text: $sectionPath)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("rag.browser.chunk.contentLabel").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $content)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 250)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.55))
                    )
            }
            HStack(alignment: .center, spacing: 12) {
                // 左侧展示管理态（可用/不可用）；不可用时提示保存会重置，与 saveChunk 清 is_excluded 一致。
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(chunk.isExcluded ? "rag.browser.status.unavailable" : "rag.browser.status.available")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if chunk.isExcluded {
                        Text("rag.browser.chunk.edit.restoreHint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
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
        .padding(18)
        .frame(width: 680, height: 540)
    }
}
