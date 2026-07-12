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
    static func show(dependencies: AppDependencies) {
        let controller = shared ?? KnowledgeRAGBrowserWindowController(dependencies: dependencies)
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
    var isLoading = false
    var isIndexing = false
    var errorMessage: String?

    init(dependencies: AppDependencies) { self.dependencies = dependencies }

    var embeddingModel: String { dependencies.settings.aiEmbeddingTask.resolvedModelName }
    var selectedCandidate: RAGRepoCandidate? { candidates.first(where: { $0.repo.id == selectedRepoID }) }
    var selectedIndex: RAGKnowledgeRepositoryIndex? { selectedRepoID.flatMap { indexes[$0] } }

    func bootstrap() async { await refresh() }

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

    func rebuildIndex() {
        guard !isIndexing else { return }
        isIndexing = true
        Task { [weak self] in
            guard let self else { return }
            defer { isIndexing = false }
            do {
                try await dependencies.knowledgeRAGIndexBuilder.rebuildKnowledgeBase()
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func openSelectedRepository() {
        guard let repo = selectedCandidate?.repo else { return }
        dependencies.companionActionDispatcher.requestOpenRepo(repo)
    }

    func saveChunk(_ managed: RAGManagedChunk, title: String, sectionPath: String, content: String) async {
        guard let id = managed.chunk.id else { return }
        do {
            try await dependencies.ragChunkRepository.saveKnowledgeChunkOverride(id: id, title: title, sectionPath: sectionPath, content: content)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func excludeChunk(_ managed: RAGManagedChunk) async {
        guard let id = managed.chunk.id else { return }
        do {
            try await dependencies.ragChunkRepository.setKnowledgeChunkExcluded(id: id, isExcluded: true)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func restoreChunk(_ managed: RAGManagedChunk) async {
        guard let id = managed.chunk.id else { return }
        do {
            try await dependencies.ragChunkRepository.restoreKnowledgeChunk(id: id)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let plan = RAGQueryPlan(mode: .semanticOnly, semanticQuery: "knowledge")
            async let loadedCoverage = dependencies.ragChunkRepository.coverage(model: embeddingModel)
            async let loadedCandidates = dependencies.ragCandidateRepository.fetchCandidates(plan: plan, explicitRepoIDs: [], explicitMode: .only)
            async let loadedIndexes = dependencies.ragChunkRepository.knowledgeRepositoryIndexes(model: embeddingModel)
            coverage = try await loadedCoverage
            candidates = try await loadedCandidates
            indexes = Dictionary(uniqueKeysWithValues: try await loadedIndexes.map { ($0.repoID, $0) })
            if selectedRepoID == nil || !candidates.contains(where: { $0.repo.id == selectedRepoID }) {
                selectedRepoID = candidates.first?.repo.id
            }
            await loadChunks()
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadChunks() async {
        guard let selectedRepoID else { chunks = []; return }
        do { chunks = try await dependencies.ragChunkRepository.fetchManagedKnowledgeChunks(repoId: selectedRepoID) }
        catch { errorMessage = error.localizedDescription }
    }
}

/// 左侧选择仓库，右侧只显示持久化的分片与当前 embedding 模型下的索引状态。
private struct KnowledgeRAGBrowserView: View {
    @Bindable var viewModel: KnowledgeRAGBrowserViewModel
    @State private var editingChunk: RAGManagedChunk?

    var body: some View {
        HSplitView {
            repositoryList.frame(minWidth: 270, idealWidth: 310, maxWidth: 350)
            detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await viewModel.bootstrap() }
        .task { await viewModel.observeIndexChanges() }
        .alert("rag.workspace.error.title", isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button("common.ok") { viewModel.errorMessage = nil }
        } message: { Text(viewModel.errorMessage ?? "") }
        .sheet(item: $editingChunk) { chunk in
            KnowledgeRAGChunkEditor(chunk: chunk) { title, sectionPath, content in
                await viewModel.saveChunk(chunk, title: title, sectionPath: sectionPath, content: content)
            }
            .appLocaleEnvironment()
        }
    }

    private var repositoryList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("rag.browser.title").font(.title3.weight(.semibold))
                Text("rag.browser.subtitle").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    Text("rag.browser.repositories")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                    ForEach(viewModel.candidates, id: \.repo.id) { candidate in repositoryRow(candidate) }
                }
                .padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                overview
                Divider()
                if let candidate = viewModel.selectedCandidate { repositoryDetail(candidate) }
                else { ContentUnavailableView("rag.browser.empty", systemImage: "books.vertical").frame(maxWidth: .infinity, minHeight: 280) }
            }
            .padding(20)
        }
        .overlay { if viewModel.isLoading { ProgressView().controlSize(.small) } }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("rag.browser.overview").font(.headline)
                Spacer()
                Text(viewModel.embeddingModel).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                stat("rag.workspace.status.repos", value: "\(viewModel.coverage.indexedRepoCount)/\(viewModel.coverage.knowledgeRepoCount)", color: .blue)
                stat("rag.workspace.status.readyChunks", value: "\(viewModel.coverage.readyChunks)", color: .green)
                stat("rag.workspace.status.pendingChunks", value: "\(viewModel.coverage.pendingChunks)", color: .orange)
                stat("rag.workspace.status.failedChunks", value: "\(viewModel.coverage.failedChunks)", color: .red)
                stat("rag.workspace.status.staleChunks", value: "\(viewModel.coverage.staleChunks)", color: .purple)
            }
        }
    }

    private func repositoryRow(_ candidate: RAGRepoCandidate) -> some View {
        let selected = candidate.repo.id == viewModel.selectedRepoID
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
            .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).focusEffectDisabled().padding(.horizontal, 8)
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
                Button { viewModel.rebuildIndex() } label: {
                    Label(viewModel.isIndexing ? "rag.workspace.index.rebuilding" : "rag.workspace.index.rebuild", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered).disabled(viewModel.isIndexing)
            }
            if viewModel.chunks.isEmpty {
                ContentUnavailableView("rag.browser.noChunks", systemImage: "doc.text").frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ForEach(viewModel.chunks) { chunk in chunkRow(chunk) }
            }
        }
    }

    private func chunkRow(_ managed: RAGManagedChunk) -> some View {
        let chunk = managed.chunk
        let status = effectiveStatus(for: chunk)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(sourceKey(chunk.source)).font(.caption.weight(.semibold))
                Text(chunk.sectionPath.isEmpty ? chunk.title : chunk.sectionPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if managed.hasOverride { Image(systemName: "pencil.circle.fill").foregroundStyle(Color.accentColor) }
                if managed.isExcluded { Image(systemName: "eye.slash.fill").foregroundStyle(.secondary) }
                Text(statusKey(status)).font(.caption2.weight(.semibold)).foregroundStyle(statusColor(status))
                Menu {
                    Button("rag.browser.chunk.edit") { editingChunk = managed }
                    if managed.isExcluded {
                        Button("rag.browser.chunk.restore") { Task { await viewModel.restoreChunk(managed) } }
                    } else {
                        Button("rag.browser.chunk.delete", role: .destructive) { Task { await viewModel.excludeChunk(managed) } }
                    }
                    if managed.hasOverride {
                        Button("rag.browser.chunk.revert") { Task { await viewModel.restoreChunk(managed) } }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
            Text(chunk.content).font(.caption).lineLimit(3).textSelection(.enabled)
            if let error = chunk.embeddingError, !error.isEmpty { Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2) }
        }
        .padding(12).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func stat(_ key: LocalizedStringKey, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) { Circle().fill(color).frame(width: 7, height: 7); Text(key).font(.caption) }
            Text(value).font(.callout.weight(.semibold).monospaced())
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

    /// 与仓库级统计保持同一语义：旧 embedding 模型即使数据库残留 ready，也不能被标为当前可用。
    private func effectiveStatus(for chunk: RAGChunk) -> RAGEmbeddingStatus {
        if chunk.embeddingStatus == .ready, chunk.embeddingModel != viewModel.embeddingModel { return .stale }
        return chunk.embeddingStatus
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
            TextField("rag.browser.chunk.title", text: $title)
            TextField("rag.browser.chunk.section", text: $sectionPath)
            TextEditor(text: $content).font(.body).frame(minHeight: 260)
            HStack { Spacer(); Button("common.cancel") { dismiss() }; Button("common.save") { Task { await onSave(title, sectionPath, content); dismiss() } }.buttonStyle(.borderedProminent).disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        .padding(18)
        .frame(width: 620, height: 420)
    }
}
