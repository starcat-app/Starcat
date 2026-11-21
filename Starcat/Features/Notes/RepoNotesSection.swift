//
//  RepoNotesSection.swift
//  Starcat
//
//  详情区共享笔记入口、抽屉会话和阅读状态。正文编辑与存储不依赖详情页的滚动容器。
//

import Combine
import SwiftUI

/// 仓库和数据库作用域共同隔离编辑缓冲区；账号切换后不能向当前库写入旧内容。
struct RepoNotesScope: Hashable {
    let repoID: Int64
    let databaseRevision: UInt64
}

/// 将笔记会话保留在详情最外层，供入口、正文浮层和 Hero 的阅读状态共享。
struct RepoNotesHost<Content: View>: View {
    let repo: Repo
    @ViewBuilder let content: (RepoNotesWorkspace?) -> Content

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @State private var workspace: RepoNotesWorkspace?

    private var scope: RepoNotesScope? {
        guard authSession.state.isAuthenticated, repo.isStarred else { return nil }
        return RepoNotesScope(repoID: repo.id, databaseRevision: dependencies.databaseScopeRevision)
    }

    private var currentWorkspace: RepoNotesWorkspace? {
        workspace?.scope == scope ? workspace : nil
    }

    var body: some View {
        content(currentWorkspace)
            .environment(currentWorkspace)
            .clipped()
            .task(id: scope) {
                guard !Task.isCancelled else { return }
                if workspace?.scope != scope {
                    if scope != nil, let previous = workspace {
                        Task { await previous.flush() }
                    }
                    workspace = scope.map { scope in
                        RepoNoteWindowController.workspace(for: scope)
                            ?? RepoNotesWorkspace(repo: repo, scope: scope, dependencies: dependencies)
                    }
                }
                await currentWorkspace?.loadIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .readmeDidLoad)) { notification in
                guard let currentWorkspace, notification.userInfo?["repoId"] as? Int64 == repo.id else { return }
                Task { await currentWorkspace.noteViewModel.markAsReadIfNeeded(repoId: repo.id) }
            }
            .onDisappear {
                guard let workspace = currentWorkspace else { return }
                workspace.isDrawerOpen = false
                Task { await workspace.flush() }
            }
    }
}

/// 入口只展示已保存笔记。窄栏优先保留图标和可点击区域，摘要可截断。
struct RepoNotesEntry: View {
    @Environment(RepoNotesWorkspace.self) private var workspace: RepoNotesWorkspace?
    @Environment(\.locale) private var locale

    var body: some View {
        if let workspace {
            let title: LocalizedStringKey = workspace.isLoaded && workspace.savedSummary == nil
                ? "repo.notes.write" : "repo.privateNotes"
            Button {
                if !RepoNoteWindowController.focusIfOpen(for: workspace.scope), !workspace.isDrawerOpen {
                    workspace.isDrawerMaximized = false
                    workspace.isDrawerOpen = true
                }
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Label(title, systemImage: "note.text")
                            .font(.caption.weight(.semibold))
                            .fixedSize()
                        if let summary = workspace.savedSummary {
                            Text(verbatim: summary)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(idealWidth: 128, maxWidth: .infinity, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                        if workspace.savedSummary != nil, let timestamp = workspace.noteViewModel.note?.editedAt {
                            Text(verbatim: formattedDate(timestamp))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        chevron
                    }
                    HStack(spacing: 8) {
                        Label(title, systemImage: "note.text")
                            .font(.caption.weight(.semibold))
                            .fixedSize()
                        Spacer(minLength: 0)
                        chevron
                    }
                    HStack(spacing: 6) {
                        Label(title, systemImage: "note.text")
                            .labelStyle(.iconOnly)
                        Spacer(minLength: 0)
                        chevron
                    }
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .inlineActionHover()
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(title)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private func formattedDate(_ timestamp: String) -> String {
        let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp))
            ?? (try? Date.ISO8601FormatStyle().parse(timestamp))
        return date?.formatted(.dateTime.month(.abbreviated).day().locale(locale)) ?? timestamp
    }
}

/// 详情和独立窗口共用编辑缓冲区、自动保存与 AI 会话。
@MainActor
@Observable
final class RepoNotesWorkspace {
    let repo: Repo
    let scope: RepoNotesScope
    let noteViewModel: RepoNotesSectionViewModel
    let ai: RepoNoteAIGenerationViewModel

    var isDrawerOpen = false
    var isDrawerMaximized = false
    private(set) var isClosing = false
    private(set) var isLoaded = false
    private(set) var loadErrorKey: String?
    private(set) var saveFailed = false
    private(set) var content = ""
    private var persistedContent = ""

    private let dependencies: AppDependencies
    private var writeTask: Task<Bool, Never>?
    @ObservationIgnored private var noteChanges: AnyCancellable?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var refreshIndexTask: Task<Void, Never>?

    init(repo: Repo, scope: RepoNotesScope, dependencies: AppDependencies) {
        self.repo = repo
        self.scope = scope
        self.dependencies = dependencies
        noteViewModel = RepoNotesSectionViewModel(repoNoteRepository: dependencies.repoNoteRepository)
        let store = RepoNoteAIGenerationSessionStore.shared
        store.activate(databaseRevision: scope.databaseRevision)
        ai = store.session(for: repo.id) ?? RepoNoteAIGenerationViewModel(
            readmeProvider: RepoNoteAIReadmeProvider(
                repository: dependencies.readmeRepository,
                readmeAPI: dependencies.readmeAPI
            ),
            aiService: dependencies.repoAIInsightService,
            maxReadmeLength: dependencies.settings.aiReadmeTruncateLength
        )
        // 通知跟随会话，切到别的仓库后独立窗口仍需要接收本仓库的更新。
        noteChanges = NotificationCenter.default.publisher(for: .repoNoteContentDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard notification.userInfo?["repoId"] as? Int64 == scope.repoID else { return }
                self?.acceptExternalContent(
                    notification.userInfo?["content"] as? String ?? "",
                    editedAt: notification.userInfo?["editedAt"] as? String
                )
            }
    }

    var savedSummary: String? {
        noteViewModel.note?.content?
            .split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            .map { line in
                let excerpt = line.drop(while: { $0 == "#" || $0.isWhitespace })
                return excerpt.isEmpty ? line : String(excerpt.prefix(160))
            }
    }

    var hasContent: Bool { !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasUnsavedChanges: Bool { isLoaded && normalizedContent(content) != persistedContent }
    var isSaving: Bool { writeTask != nil }

    func loadIfNeeded() async {
        guard !isLoaded else { return }
        loadErrorKey = nil
        await noteViewModel.loadFor(repoId: repo.id)
        guard !Task.isCancelled else { return }
        loadErrorKey = noteViewModel.errorMessage
        guard loadErrorKey == nil else { return }
        content = noteViewModel.note?.content ?? ""
        persistedContent = normalizedContent(content)
        isLoaded = true
    }

    func updateContent(_ text: String) {
        guard isLoaded, !isClosing, !ai.isBusy, content != text else { return }
        content = text
        saveFailed = false
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            await self.flush()
        }
    }

    func acceptExternalContent(_ text: String, editedAt: String?) {
        guard scope.databaseRevision == dependencies.databaseScopeRevision,
              isLoaded, !hasUnsavedChanges, !isSaving, ai.phase != .applying else { return }
        noteViewModel.applyExternalContent(repoId: repo.id, content: text, editedAt: editedAt)
        content = text
        persistedContent = normalizedContent(text)
        saveFailed = false
    }

    /// 只取消尚未开始的防抖等待。已提交的写入先结束，再比较最新缓冲区，避免关抽屉时漏写最后一次输入。
    @discardableResult
    func flush() async -> Bool {
        debounceTask?.cancel()
        debounceTask = nil
        guard isLoaded else { return true }
        while scope.databaseRevision == dependencies.databaseScopeRevision {
            if let writeTask {
                guard await writeTask.value else { return false }
                continue
            }
            guard hasUnsavedChanges, ai.phase != .applying else { return true }
            let snapshot = content
            writeTask = Task {
                let succeeded = await persist(snapshot)
                saveFailed = !succeeded
                writeTask = nil
                return succeeded
            }
        }
        return false
    }

    func closeDrawer() async {
        await closeAfterSaving { isDrawerOpen = false }
    }

    /// 浮层与独立窗口共用关闭门槛。写入失败时保留界面及草稿，允许重试。
    func closeAfterSaving(_ dismiss: () -> Void) async {
        guard !isClosing, ai.phase != .applying else { return }
        isClosing = true
        defer { isClosing = false }
        if await flush() {
            dismiss()
        }
    }

    func startGeneration() {
        guard isLoaded, !isClosing, !ai.isBusy,
              scope.databaseRevision == dependencies.databaseScopeRevision else { return }
        RepoNoteAIGenerationSessionStore.shared.retain(ai, for: repo.id)
        ai.start(repo: repo, existingNote: content)
    }

    func discardGeneration() {
        ai.discard()
        RepoNoteAIGenerationSessionStore.shared.removeSession(for: repo.id)
    }

    /// 生成时冻结的原文仍须与当前笔记一致，确认按钮才会写入草稿。
    func applyDraft() async {
        guard !isClosing, !isSaving,
              let draft = ai.beginApplying(currentNote: content) else { return }
        debounceTask?.cancel()
        let succeeded = await persist(draft, isAIGenerated: true)
        if succeeded {
            content = draft
            saveFailed = false
            if scope.databaseRevision == dependencies.databaseScopeRevision {
                RepoNoteAIGenerationSessionStore.shared.removeSession(for: repo.id)
            }
        }
        ai.finishApplying(success: succeeded)
    }

    private func persist(_ snapshot: String, isAIGenerated: Bool = false) async -> Bool {
        guard dependencies.authSession.state.isAuthenticated,
              scope.databaseRevision == dependencies.databaseScopeRevision,
              await noteViewModel.saveContent(repoId: repo.id, content: snapshot, isAIGenerated: isAIGenerated)
        else { return false }
        persistedContent = normalizedContent(snapshot)
        if !persistedContent.isEmpty {
            NotificationCenter.default.post(name: .gettingStartedDidOrganizeRepo, object: nil)
        }
        scheduleIndexRefresh()
        return true
    }

    private func normalizedContent(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
    }

    /// 写库及语义索引采用原有的两级防抖，避免连续打字反复触发索引刷新。
    private func scheduleIndexRefresh() {
        refreshIndexTask?.cancel()
        let repo = repo
        let revision = scope.databaseRevision
        let dependencies = dependencies
        refreshIndexTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, revision == dependencies.databaseScopeRevision else { return }
            await dependencies.semanticSearchService.refreshIndexIfChanged(for: repo)
        }
    }
}

/// 状态按钮仍位于 Hero，继续使用原有的阅读状态转换和入库反馈。
struct RepoNotesSection: View {
    @Environment(RepoNotesWorkspace.self) private var workspace: RepoNotesWorkspace?
    @State private var statusToast: String?

    var body: some View {
        if let workspace {
            StatusBadge(
                status: workspace.noteViewModel.status ?? .unread,
                onPrimaryTap: {
                    Task {
                        if await workspace.noteViewModel.setStatus(repoId: workspace.repo.id, status: .using) {
                            statusToast = "library.action.added"
                        }
                    }
                },
                onCancelUsing: {
                    Task {
                        await workspace.noteViewModel.setStatus(repoId: workspace.repo.id, status: .read)
                    }
                }
            )
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .toast(message: $statusToast, icon: "heart.fill")
        }
    }
}

/// 仓库的笔记正文及阅读状态共用 `repo_notes` 记录。
@MainActor
@Observable
final class RepoNotesSectionViewModel {
    private(set) var note: RepoNote?
    private(set) var errorMessage: String?
    private let repoNoteRepository: any RepoNoteRepositoryProtocol

    var status: RepoStatus? {
        guard let note else { return nil }
        return RepoStatus.parse(note.status)
    }

    init(repoNoteRepository: any RepoNoteRepositoryProtocol) {
        self.repoNoteRepository = repoNoteRepository
    }

    func loadFor(repoId: Int64) async {
        do {
            note = try await repoNoteRepository.find(repoId: repoId)
            errorMessage = nil
        } catch {
            note = nil
            errorMessage = "repo.notes.loadFailed"
        }
    }

    /// 即时落库并通知主列表；状态变化由仓库层维护入库等副作用。
    @discardableResult
    func setStatus(repoId: Int64, status: RepoStatus) async -> Bool {
        do {
            try await repoNoteRepository.updateStatus(repoId: repoId, status: status)
            await loadFor(repoId: repoId)
            postStatusDidChange(repoId: repoId)
            return true
        } catch {
            errorMessage = "repo.notes.saveStatusFailed"
            return false
        }
    }

    /// README 就绪后将未读升级为已读；仓库层保证重复通知无害。
    func markAsReadIfNeeded(repoId: Int64) async {
        do {
            try await repoNoteRepository.markAsReadIfNeeded(repoId: repoId)
            await loadFor(repoId: repoId)
            postStatusDidChange(repoId: repoId)
        } catch {
            errorMessage = "repo.notes.saveStatusFailed"
        }
    }

    private func postStatusDidChange(repoId: Int64) {
        NotificationCenter.default.post(
            name: .repoStatusDidChange,
            object: nil,
            userInfo: ["repoId": repoId, "status": (status ?? .unread).rawValue]
        )
    }

    /// 只写正文。`edited_at` 及清空笔记的语义由仓库层统一处理。
    @discardableResult
    func saveContent(repoId: Int64, content: String, isAIGenerated: Bool = false) async -> Bool {
        do {
            try await repoNoteRepository.updateContent(
                repoId: repoId,
                content: content.isEmpty ? nil : content,
                isAIGenerated: isAIGenerated
            )
            await loadFor(repoId: repoId)
            return true
        } catch {
            errorMessage = "repo.notes.saveContentFailed"
            return false
        }
    }

    func applyExternalContent(repoId: Int64, content: String, editedAt: String?) {
        note = RepoNote(
            repoId: repoId,
            content: content.isEmpty ? nil : content,
            status: note?.status ?? RepoStatus.unread.rawValue,
            isAIGenerated: note?.isAIGenerated ?? false,
            editedAt: editedAt
        )
        errorMessage = nil
    }
}

/// 主按钮进入使用中，取消按钮独立处理回退，避免嵌套 Button 吞掉事件。
private struct StatusBadge: View {
    let status: RepoStatus
    let onPrimaryTap: () -> Void
    let onCancelUsing: () -> Void

    private var isUsing: Bool { status == .using }

    var body: some View {
        let tint: Color = isUsing ? .accentColor : .secondary

        HStack(spacing: 4) {
            primaryButton
            if isUsing {
                cancelButton
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(isUsing ? 0.18 : 0.12), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(tint.opacity(isUsing ? 0.3 : 0.2), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }

    private var primaryButton: some View {
        Button(action: onPrimaryTap) {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.system(size: 10))
                Text(status.displayName)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(isUsing ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(isUsing ? Text("repo.status.usingHint") : Text("repo.status.markUsingHint"))
    }

    private var cancelButton: some View {
        Button(action: onCancelUsing) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor.opacity(0.7))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text("repo.status.cancelUsing"))
    }

    private var iconName: String {
        switch status {
        case .unread: "envelope.badge"
        case .read: "envelope.open"
        case .using: "checkmark.seal.fill"
        }
    }
}
