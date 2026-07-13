//
//  KnowledgeRAGWorkspaceViewModel.swift
//  Starcat
//
//  知识库 RAG 工作台状态协调器。
//
//  关键约束：输入框的 @repo / 模型 / 附件是确定上下文，不从自然语言反推。
//  停止生成时必须保留用户问题；若已有流式文本则落库为未完成回答，若尚无输出则
//  仅保留用户消息并提供复制 / 原地编辑。
//

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// 刷新操作可能立即完成；保留最短可见时长，才能让用户确认点击已被接收。
enum KnowledgeRAGIndexRefreshPresentation {
    static let minimumVisibleDuration: Duration = .milliseconds(600)

    static func waitForMinimumDuration(
        startedAt: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async {
        let elapsed = startedAt.duration(to: clock.now)
        guard elapsed < minimumVisibleDuration else { return }
        try? await Task.sleep(for: minimumVisibleDuration - elapsed)
    }
}

@MainActor
@Observable
final class KnowledgeRAGWorkspaceViewModel {
    private let dependencies: AppDependencies
    /// 打开独立详情窗需要共享主窗 HomeViewModel（star 状态 / registry）。
    private let homeViewModel: HomeViewModel
    private let conversationStore: any RAGConversationStoring
    private var answerTask: Task<Void, Never>?
    private var conversationTitleTask: Task<Void, Never>?
    private var remoteContextConsent: RAGRemoteContextConsent?
    private var linkDetectionTask: Task<Void, Never>?

    var conversations: [RAGConversationSummary] = []
    var conversationGroups: [RAGConversationGroup] = []
    /// 点选分组目录时设置；点选会话时清空。新会话写入此分组。
    var selectedGroupID: UUID?
    var selectedConversationID: UUID?
    var messages: [RAGStoredMessage] = []
    var draftQuestion = ""
    var streamingAnswer = ""
    var answerState: RAGAnswerState = .idle
    /// 用户气泡原地编辑：非 nil 时该消息进入图 4 编辑态。
    var editingUserMessageID: UUID?
    var editingUserDraft = ""
    var queryPlan: RAGQueryPlan?
    var retrieval: RAGRetrievalResult?
    var remoteBlocks: [RAGRemoteContextBlock] = []
    var pendingRemoteRequests: [RAGRemoteContextRequest] = []
    var approvedRemoteResources: Set<RAGRemoteContextResource> = []
    var selectedCitation: RAGCitation?
    var selectedCitationChunk: RAGChunk?
    var selectedRepoContexts: [Repo] = []
    var explicitRepoMode: RAGExplicitRepoMode = .only
    var attachments: [RAGComposerAttachment] = []
    var githubLinkContexts: [RAGGitHubLinkReference] = []
    /// 切换模型时立刻写入 AppSettings，关闭窗口后再开可恢复。
    var selectedModelID: String? {
        didSet {
            let trimmed = selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if dependencies.settings.ragWorkspaceSelectedModelID != trimmed {
                dependencies.settings.ragWorkspaceSelectedModelID = trimmed
            }
        }
    }
    var knowledgeRepos: [Repo] = []
    private var isMentionPickerDismissed = false
    private var highlightedMentionRepoID: Int64?
    private var knowledgeCandidates: [RAGRepoCandidate] = []
    var indexCoverage = RAGIndexCoverage(
        knowledgeRepoCount: 0,
        indexedRepoCount: 0,
        totalChunks: 0,
        readyChunks: 0,
        pendingChunks: 0,
        failedChunks: 0,
        staleChunks: 0
    )
    var indexIssueChunks: [RAGIndexIssueKind: [RAGChunk]] = [:]
    var indexIssueHasMore: Set<RAGIndexIssueKind> = []
    var loadingIndexIssueKinds: Set<RAGIndexIssueKind> = []
    var isIndexing = false
    /// 直接透出 builder 的状态，让工作台显示真实构建阶段与数字进度。
    var indexingStatus: RAGIndexingStatus { dependencies.knowledgeRAGIndexBuilder.status }
    /// 手动刷新结果在阶段切换后保持不变，供工作台连续展示 README 与分片进度。
    var indexRefreshSummary: RAGIndexRefreshSummary? { dependencies.knowledgeRAGIndexBuilder.refreshSummary }
    var embeddingModel: String { dependencies.settings.aiEmbeddingTask.resolvedModelName }
    var errorMessage: String?
    /// 开关本身持久化；debug 事件只服务当前窗口，关闭开关立即清空，不进会话历史。
    var isDebugModeEnabled = false {
        didSet {
            if !isDebugModeEnabled { debugTraces = [] }
            if dependencies.settings.ragWorkspaceDebugModeEnabled != isDebugModeEnabled {
                dependencies.settings.ragWorkspaceDebugModeEnabled = isDebugModeEnabled
            }
        }
    }
    var debugTraces: [RAGDebugTrace] = []

    init(dependencies: AppDependencies, homeViewModel: HomeViewModel) {
        self.dependencies = dependencies
        self.homeViewModel = homeViewModel
        self.conversationStore = dependencies.ragConversationStore
        let resolvedModelID = Self.resolveInitialModelID(
            savedModelID: dependencies.settings.ragWorkspaceSelectedModelID,
            availableModels: dependencies.knowledgeRAGChatModels,
            chatTask: dependencies.settings.aiChatTask
        )
        self.selectedModelID = resolvedModelID
        self.isDebugModeEnabled = dependencies.settings.ragWorkspaceDebugModeEnabled
        // init 内 didSet 不触发：把解析后的可用模型回写，清掉已删除/禁用的旧 ID。
        let trimmed = resolvedModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if dependencies.settings.ragWorkspaceSelectedModelID != trimmed {
            dependencies.settings.ragWorkspaceSelectedModelID = trimmed
        }
    }

    /// 优先恢复上次选用且仍可用的模型；否则对齐全局 chat task；再否则取列表首项。
    private static func resolveInitialModelID(
        savedModelID: String,
        availableModels: [AIModelDescriptor],
        chatTask: AIModelTaskConfiguration
    ) -> String? {
        let trimmed = savedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, availableModels.contains(where: { $0.id == trimmed }) {
            return trimmed
        }
        if let matched = availableModels.first(where: {
            $0.providerID == chatTask.providerID && $0.name == chatTask.resolvedModelName
        }) {
            return matched.id
        }
        return availableModels.first?.id
    }

    var isAnswering: Bool {
        switch answerState {
        case .planning, .retrieving, .awaitingRemoteContextConfirmation, .fetchingRemoteContext, .generating: return true
        default: return false
        }
    }

    /// 「停止且尚无 AI 输出」时，末条用户消息常显复制 / 编辑。
    var pendingActionUserMessageID: UUID? {
        guard !isAnswering, streamingAnswer.isEmpty else { return nil }
        guard let last = messages.last, last.role == .user else { return nil }
        return last.id
    }

    var availableModels: [AIModelDescriptor] { dependencies.knowledgeRAGChatModels }

    var historicalRemoteContextAudits: [RAGRemoteContextAudit] {
        messages.flatMap(\.remoteContextAudits)
    }

    var selectedModelDisplayName: String {
        availableModels.first(where: { $0.id == selectedModelID })?.name
            ?? dependencies.settings.aiChatTask.resolvedModelName
    }

    /// 模型记录保存的是 provider profile ID；解析为枚举后，UI 才能复用统一的服务商 logo。
    var selectedModelProvider: AIServiceProvider? {
        guard let selectedModel = availableModels.first(where: { $0.id == selectedModelID }) else { return nil }
        return provider(for: selectedModel)
    }

    var selectedModelEndpoint: String? {
        let profileID = availableModels.first(where: { $0.id == selectedModelID })?.providerID
            ?? dependencies.settings.aiChatTask.providerID
        return dependencies.settings.aiProviderProfiles
            .first(where: { $0.id == profileID })?
            .baseURL
    }

    func provider(for model: AIModelDescriptor) -> AIServiceProvider? {
        dependencies.settings.aiProviderProfiles
            .first(where: { $0.id == model.providerID })?
            .provider
    }

    /// 提前阻断确定不可发送的附件条件。vision 能力在 OpenAI-compatible `/models` 中没有
    /// 统一字段，因此图片继续交给服务端校验；服务端拒绝时保留其原始可展示错误。
    var composerBlockingReason: String? {
        if attachments.count > 5 { return RAGAttachmentError.tooManyFiles.localizedDescription }
        if let attachment = attachments.first(where: { $0.sizeInBytes > 10 * 1_024 * 1_024 }) {
            return RAGAttachmentError.fileTooLarge(attachment.filename).localizedDescription
        }
        if attachments.reduce(Int64(0), { $0 + $1.sizeInBytes }) > 20 * 1_024 * 1_024 {
            return RAGAttachmentError.totalTooLarge.localizedDescription
        }
        if let attachment = attachments.first(where: { $0.handling == .unsupported }) {
            return RAGAttachmentError.unsupported(attachment.filename).localizedDescription
        }
        return nil
    }

    var mentionQuery: String? {
        guard let at = draftQuestion.lastIndex(of: "@") else { return nil }
        let suffix = draftQuestion[draftQuestion.index(after: at)...]
        guard !suffix.contains(where: \.isWhitespace) else { return nil }
        return String(suffix)
    }

    var mentionSuggestions: [Repo] {
        guard let query = mentionQuery else { return [] }
        // 多选时保留已选项：列表用 checkmark 展示，方便再次点击取消。
        return knowledgeCandidates.filter { candidate in
            let repo = candidate.repo
            guard !query.isEmpty else { return true }
            let searchable = [
                repo.fullName,
                repo.description ?? "",
                repo.language ?? "",
                repo.topicsArray.joined(separator: " "),
                candidate.tagNames.joined(separator: " "),
                candidate.status.rawValue
            ].joined(separator: " ")
            return searchable.localizedCaseInsensitiveContains(query)
        }.prefix(12).map(\.repo)
    }

    func isMentionSelected(_ repo: Repo) -> Bool {
        selectedRepoContexts.contains { $0.id == repo.id }
    }

    var isMentionPickerPresented: Bool {
        !isMentionPickerDismissed && mentionQuery != nil && !mentionSuggestions.isEmpty
    }

    var highlightedMentionRepoIDValue: Int64? {
        let suggestions = mentionSuggestions
        guard !suggestions.isEmpty else { return nil }
        return suggestions.contains(where: { $0.id == highlightedMentionRepoID })
            ? highlightedMentionRepoID
            : suggestions.first?.id
    }

    func bootstrap() async {
        do {
            async let loadedConversations = conversationStore.listConversations()
            async let loadedGroups = conversationStore.listGroups()
            async let loadedCandidates = dependencies.ragCandidateRepository.fetchCandidates(
                plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "knowledge"),
                explicitRepoIDs: [],
                explicitMode: .only
            )
            conversations = try await loadedConversations
            conversationGroups = try await loadedGroups
            knowledgeCandidates = try await loadedCandidates
            knowledgeRepos = knowledgeCandidates.map(\.repo)
            try await refreshIndexCoverage()
            if let first = conversations.first {
                await selectConversation(first.id)
            } else {
                await newConversation()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 独立工作台打开期间，主窗口仍可能增删知识库 repo。每次边界变化都重新读取 SQL
    /// candidates，并移除已经不在知识库中的显式上下文，避免 @ picker 展示陈旧项目。
    func observeKnowledgeBoundaryChanges() async {
        let stream = NotificationCenter.default.notifications(named: .repoLibraryStateDidChange)
        for await _ in stream {
            guard !Task.isCancelled else { break }
            do {
                let candidates = try await dependencies.ragCandidateRepository.fetchCandidates(
                    plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "knowledge"),
                    explicitRepoIDs: [],
                    explicitMode: .only
                )
                knowledgeCandidates = candidates
                knowledgeRepos = candidates.map(\.repo)
                let currentRepoIDs = Set(knowledgeRepos.map(\.id))
                selectedRepoContexts.removeAll { !currentRepoIDs.contains($0.id) }
                try await refreshIndexCoverage()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// README/notes/summary/metadata 的后台 source refresh 不由当前窗口发起，完成后仍要
    /// 立即反映 ready/pending/failed/stale 数量。
    func observeIndexChanges() async {
        let stream = NotificationCenter.default.notifications(named: .knowledgeRAGIndexDidChange)
        for await _ in stream {
            guard !Task.isCancelled else { break }
            try? await refreshIndexCoverage()
        }
    }

    func newConversation() async {
        cancelAnswer()
        conversationTitleTask?.cancel()
        do {
            // 当前选中目录时，新会话直接归入该一级分组。
            let conversation = try await conversationStore.createConversation(
                title: nil,
                groupID: selectedGroupID
            )
            conversations.insert(conversation, at: 0)
            selectedConversationID = conversation.id
            messages = []
            resetTurnState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectConversation(_ id: UUID) async {
        guard selectedConversationID != id || messages.isEmpty else { return }
        cancelAnswer()
        conversationTitleTask?.cancel()
        do {
            guard let detail = try await conversationStore.loadConversation(id: id) else { return }
            selectedConversationID = id
            // 点选会话时目录选中态让位，避免误以为「新会话仍进目录」。
            selectedGroupID = nil
            messages = detail.messages
            let initialCitation = messages.reversed().lazy.flatMap(\.citations).first
            resetTurnState()
            if let initialCitation { selectCitation(initialCitation) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteConversation(_ id: UUID) async {
        if selectedConversationID == id { conversationTitleTask?.cancel() }
        do {
            try await conversationStore.deleteConversation(id: id)
            conversations.removeAll { $0.id == id }
            if selectedConversationID == id {
                if let next = conversations.first {
                    selectedConversationID = nil
                    await selectConversation(next.id)
                } else {
                    await newConversation()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 用户手动重命名：立刻写库并刷新列表；若正在打字机生成标题则取消，避免覆盖。
    func renameConversation(id: UUID, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if selectedConversationID == id { conversationTitleTask?.cancel() }
        do {
            try await conversationStore.renameConversation(id: id, title: trimmed)
            updateConversationTitle(title: trimmed, for: id)
            // 列表按 updated_at 排序；重命名后刷新顺序，避免停留在旧位置。
            conversations = try await conversationStore.listConversations()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 置顶 / 取消置顶后刷新列表（置顶项排在最前）。
    func setConversationPinned(id: UUID, isPinned: Bool) async {
        do {
            try await conversationStore.setConversationPinned(id: id, isPinned: isPinned)
            conversations = try await conversationStore.listConversations()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveConversation(id: UUID, toGroupID groupID: UUID?) async {
        do {
            try await conversationStore.setConversationGroup(id: id, groupID: groupID)
            if let index = conversations.firstIndex(where: { $0.id == id }) {
                conversations[index].groupID = groupID
            } else {
                conversations = try await conversationStore.listConversations()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createGroup(title: String?) async {
        do {
            let group = try await conversationStore.createGroup(title: title)
            conversationGroups.append(group)
            conversationGroups.sort { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.createdAt < rhs.createdAt
            }
            selectedGroupID = group.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameGroup(id: UUID, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await conversationStore.renameGroup(id: id, title: trimmed)
            if let index = conversationGroups.firstIndex(where: { $0.id == id }) {
                conversationGroups[index].title = trimmed
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteGroup(id: UUID) async {
        do {
            try await conversationStore.deleteGroup(id: id)
            conversationGroups.removeAll { $0.id == id }
            for index in conversations.indices where conversations[index].groupID == id {
                conversations[index].groupID = nil
            }
            if selectedGroupID == id {
                selectedGroupID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func conversations(inGroupID groupID: UUID?) -> [RAGConversationSummary] {
        conversations.filter { $0.groupID == groupID }
    }

    func send() {
        let question = draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering, composerBlockingReason == nil else { return }
        do {
            try dependencies.entitlementGate.requirePro(.knowledgeRAG)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        editingUserMessageID = nil
        editingUserDraft = ""
        answerTask?.cancel()
        answerTask = Task { [weak self] in
            await self?.runQuestion(question)
        }
    }

    func cancelAnswer() {
        answerTask?.cancel()
        answerTask = nil
        // 主动停止不是失败，清掉可能残留的错误弹窗。
        if isAnswering {
            answerState = .cancelled
            errorMessage = nil
        }
    }

    /// 复制停止态问题：写入剪贴板并回填底部输入框。
    @discardableResult
    func copyQuestionToComposerAndPasteboard(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        draftQuestion = trimmed
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(trimmed, forType: .string)
    }

    func beginEditUserMessage(_ messageID: UUID) {
        guard messages.contains(where: { $0.id == messageID && $0.role == .user }) else { return }
        guard let message = messages.first(where: { $0.id == messageID }) else { return }
        editingUserMessageID = messageID
        editingUserDraft = message.content
    }

    func cancelEditUserMessage() {
        editingUserMessageID = nil
        editingUserDraft = ""
    }

    /// 编辑态「发送」：删掉旧的无回答用户消息，用改后文案重新提问。
    func submitEditedUserMessage() {
        guard let messageID = editingUserMessageID else { return }
        let question = editingUserDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }
        do {
            try dependencies.entitlementGate.requirePro(.knowledgeRAG)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        editingUserMessageID = nil
        editingUserDraft = ""
        messages.removeAll { $0.id == messageID }
        answerTask?.cancel()
        answerTask = Task { [weak self] in
            guard let self else { return }
            try? await conversationStore.deleteMessage(id: messageID)
            conversations = (try? await conversationStore.listConversations()) ?? conversations
            await runQuestion(question)
        }
    }

    func toggleRemoteResource(_ resource: RAGRemoteContextResource) {
        if approvedRemoteResources.contains(resource) {
            approvedRemoteResources.remove(resource)
        } else {
            approvedRemoteResources.insert(resource)
        }
    }

    func confirmRemoteContext() {
        let consent = remoteContextConsent
        pendingRemoteRequests = []
        Task { await consent?.resolve(approvedRemoteResources) }
    }

    func skipRemoteContext() {
        let consent = remoteContextConsent
        pendingRemoteRequests = []
        approvedRemoteResources = []
        Task { await consent?.resolve([]) }
    }

    /// 切换 `@` 多选：写入 / 移除 chip，但不清掉输入框里的 `@token`，便于连续勾选。
    func toggleMention(_ repo: Repo) {
        if let index = selectedRepoContexts.firstIndex(where: { $0.id == repo.id }) {
            selectedRepoContexts.remove(at: index)
        } else {
            selectedRepoContexts.append(repo)
        }
        highlightedMentionRepoID = repo.id
    }

    /// `@repo` 候选由输入框持有键盘焦点。这里仅移动高亮，不改变输入内容，Enter 才会
    /// 切换明确的 repo context，避免方向键意外修改问题文本。
    func moveMentionSelection(by offset: Int) {
        let suggestions = mentionSuggestions
        guard !suggestions.isEmpty else { return }
        let currentIndex = highlightedMentionRepoIDValue.flatMap { id in
            suggestions.firstIndex(where: { $0.id == id })
        } ?? (offset > 0 ? -1 : suggestions.count)
        let nextIndex = min(max(currentIndex + offset, 0), suggestions.count - 1)
        highlightedMentionRepoID = suggestions[nextIndex].id
    }

    func selectHighlightedMention() {
        guard let id = highlightedMentionRepoIDValue,
              let repo = mentionSuggestions.first(where: { $0.id == id }) else { return }
        toggleMention(repo)
    }

    /// Esc / 点空白关闭：清掉未完成的 `@token`，已勾选的 chip 保留。
    func dismissMentionPicker() {
        if let at = draftQuestion.lastIndex(of: "@") {
            let suffix = draftQuestion[draftQuestion.index(after: at)...]
            if !suffix.contains(where: \.isWhitespace) {
                draftQuestion.removeSubrange(at..<draftQuestion.endIndex)
            }
        }
        isMentionPickerDismissed = true
        highlightedMentionRepoID = nil
    }

    func handleDraftQuestionChanged() {
        // Esc 只关闭当前这次候选；继续编辑时重新打开，并让高亮回到当前候选集合的首项。
        isMentionPickerDismissed = false
        highlightedMentionRepoID = nil
        scheduleGitHubLinkDetection()
    }

    func removeMention(repoID: Int64) {
        selectedRepoContexts.removeAll { $0.id == repoID }
    }

    /// 清空输入框上方全部上下文 chip：已选仓库、附件、GitHub 链接。
    func clearComposerContext() {
        selectedRepoContexts = []
        attachments = []
        githubLinkContexts = []
    }

    func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = String.l10n("rag.workspace.composer.attach")
        // 在选文件面板层过滤：不支持的类型直接置灰不可选，而不是选完再报错。
        panel.allowedContentTypes = Self.composerAttachmentContentTypes
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !attachments.contains(where: { $0.localURL == url }) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
            // 面板已过滤；仍用 conforms 兜底，避免扩展名欺骗。
            let handling: RAGAttachmentHandling =
                Self.isAllowedComposerAttachment(type) ? .textContext : .unsupported
            attachments.append(RAGComposerAttachment(
                id: UUID(),
                filename: url.lastPathComponent,
                contentType: type?.preferredMIMEType ?? "application/octet-stream",
                sizeInBytes: Int64(values?.fileSize ?? 0),
                localURL: url,
                handling: handling
            ))
        }
    }

    /// 仅允许纯文本 / Markdown / JSON / 源码；图片、PDF、二进制等不可选。
    private static let composerAttachmentContentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .utf8PlainText, .json, .sourceCode]
        if let markdown = UTType("net.daringfireball.markdown") {
            types.append(markdown)
        }
        if let md = UTType(filenameExtension: "md") {
            types.append(md)
        }
        if let markdown = UTType(filenameExtension: "markdown") {
            types.append(markdown)
        }
        return types
    }()

    private static func isAllowedComposerAttachment(_ type: UTType?) -> Bool {
        guard let type else { return false }
        return composerAttachmentContentTypes.contains { type.conforms(to: $0) }
            || type.conforms(to: .text)
            || type.conforms(to: .json)
            || type.conforms(to: .sourceCode)
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    func scheduleGitHubLinkDetection() {
        linkDetectionTask?.cancel()
        linkDetectionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                await self?.detectGitHubLink()
            } catch {
                // 新输入取消旧检测，不需要展示错误。
            }
        }
    }

    func removeGitHubLink(_ url: URL) {
        githubLinkContexts.removeAll { $0.url == url }
    }

    func openGitHubLink(_ reference: RAGGitHubLinkReference) {
        guard reference.relation == .knownButNotInKnowledge,
              let repoID = reference.matchedRepoID else {
            NSWorkspace.shared.open(reference.url)
            return
        }
        Task {
            if let repo = try? await dependencies.repoRepository.findById(repoID) {
                openLocalRepoDetail(repo)
            } else {
                NSWorkspace.shared.open(reference.url)
            }
        }
    }

    /// 当前会话全文（用户 / Starcat 分段），供顶部「复制全部 / 导出全部」使用。
    var conversationTranscriptMarkdown: String {
        messages.map { message in
            let roleLabel = message.role == .user
                ? String.l10n("rag.workspace.message.user")
                : String.l10n("rag.workspace.message.assistant")
            return "## \(roleLabel)\n\n\(message.content)"
        }.joined(separator: "\n\n")
    }

    func clearDebugTraces() {
        debugTraces = []
    }

    /// 左侧标题与索引摘要都指向同一真实数据浏览器，避免用户误以为“知识库”只是装饰标签。
    func showKnowledgeBrowser(presentingWindow: NSWindow?) {
        KnowledgeRAGBrowserWindowController.show(
            dependencies: dependencies,
            centeredOver: presentingWindow
        )
    }

    var debugTraceText: String {
        debugTraces.sorted { $0.startedAt < $1.startedAt }.map { trace in
            let events = trace.events.map { event in
                """
                [\(event.stage.rawValue)] +\(String(format: "%.3f", event.elapsedSeconds))s
                \(event.payload)
                """
            }.joined(separator: "\n\n")
            return """
            [\(trace.category.rawValue)] \(trace.startedAt.ISO8601Format())
            \(events)
            """
        }.joined(separator: "\n\n==========\n\n")
    }

    func exportAnswer(_ content: String) {
        exportMarkdown(content, suggestedName: "Starcat-RAG.md")
    }

    /// 导出当前会话全部对话。
    func exportConversation() {
        exportMarkdown(conversationTranscriptMarkdown, suggestedName: "Starcat-RAG-Conversation.md")
    }

    private func exportMarkdown(_ content: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(content.utf8).write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rebuildIndex() {
        guard !isIndexing else { return }
        isIndexing = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let startedAt = clock.now
            do {
                try await dependencies.knowledgeRAGIndexBuilder.rebuildKnowledgeBase()
                try await refreshIndexCoverage()
            } catch {
                errorMessage = error.localizedDescription
            }
            await KnowledgeRAGIndexRefreshPresentation.waitForMinimumDuration(startedAt: startedAt, clock: clock)
            isIndexing = false
        }
    }

    func loadIndexIssueChunks(_ kind: RAGIndexIssueKind, append: Bool = false) async {
        guard !loadingIndexIssueKinds.contains(kind) else { return }
        loadingIndexIssueKinds.insert(kind)
        defer { loadingIndexIssueKinds.remove(kind) }
        do {
            let existing = indexIssueChunks[kind, default: []]
            let page = try await dependencies.ragChunkRepository.fetchIndexIssueChunks(
                kind: kind,
                model: dependencies.settings.aiEmbeddingTask.resolvedModelName,
                limit: append ? 10 : 5,
                offset: append ? existing.count : 0
            )
            indexIssueChunks[kind] = append ? existing + page.chunks : page.chunks
            if page.hasMore {
                indexIssueHasMore.insert(kind)
            } else {
                indexIssueHasMore.remove(kind)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func indexIssueChunks(for kind: RAGIndexIssueKind) -> [RAGChunk] {
        indexIssueChunks[kind, default: []]
    }

    func isLoadingIndexIssue(_ kind: RAGIndexIssueKind) -> Bool {
        loadingIndexIssueKinds.contains(kind)
    }

    func hasMoreIndexIssueChunks(_ kind: RAGIndexIssueKind) -> Bool {
        indexIssueHasMore.contains(kind)
    }

    func knowledgeRepositoryName(for id: Int64) -> String {
        knowledgeRepos.first(where: { $0.id == id })?.fullName ?? "#\(id)"
    }

    func selectCitation(_ citation: RAGCitation) {
        selectedCitation = citation
        selectedCitationChunk = nil
        guard let chunkID = citation.chunkID else { return }
        Task { [weak self] in
            guard let self else { return }
            let chunk = try? await dependencies.ragChunkRepository.fetchChunks(ids: [chunkID]).first
            guard selectedCitation?.id == citation.id else { return }
            selectedCitationChunk = chunk
        }
    }

    /// 证据列表手风琴：再点同一条则收起。
    func toggleCitation(_ citation: RAGCitation) {
        if selectedCitation?.id == citation.id {
            selectedCitation = nil
            selectedCitationChunk = nil
            return
        }
        selectCitation(citation)
    }

    func openCitation(_ citation: RAGCitation) {
        selectCitation(citation)
        Task {
            await openLocalRepoDetail(for: citation)
        }
    }

    /// 回答正文里的 `starcat-rag://citation/<uuid>`：只开独立详情窗，不抢右侧证据选中。
    /// - Returns: 是否已处理（调用方不应再走通用 `handleLink`）。
    @discardableResult
    func openCitationLink(_ url: URL) -> Bool {
        guard url.scheme == "starcat-rag", url.host == "citation" else { return false }
        let idString = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let id = UUID(uuidString: idString),
              let citation = messages.flatMap(\.citations).first(where: { $0.id == id }) else {
            return false
        }
        Task {
            await openLocalRepoDetail(for: citation)
        }
        return true
    }

    func openGitHub(_ citation: RAGCitation) {
        if let url = citation.sourceURL { NSWorkspace.shared.open(url) }
    }

    func handleLink(_ url: URL) {
        if openCitationLink(url) { return }
        let host = url.host?.lowercased()
        guard host == "github.com" || host == "www.github.com" else {
            NSWorkspace.shared.open(url)
            return
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else {
            NSWorkspace.shared.open(url)
            return
        }
        Task {
            if let repo = try? await dependencies.repoRepository.findByOwnerName(owner: parts[0], name: parts[1]) {
                openLocalRepoDetail(repo)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// 本地已收录仓库走独立详情窗；与推荐卡片 / 主窗「新窗打开」一致，不激活主窗口 selection。
    private func openLocalRepoDetail(_ repo: Repo) {
        RepoDetailWindowController.show(
            repo: repo,
            dependencies: dependencies,
            homeViewModel: homeViewModel
        )
    }

    private func openLocalRepoDetail(for citation: RAGCitation) async {
        if let repo = try? await dependencies.repoRepository.findById(citation.repoID) {
            openLocalRepoDetail(repo)
        } else if let url = citation.sourceURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func runQuestion(_ question: String) async {
        guard let conversationID = selectedConversationID else { return }
        let debugTraceID = isDebugModeEnabled ? beginDebugTrace(category: .questionAnswer) : nil
        let history = RAGConversationHistoryBuilder.build(from: messages)
        let isFirstTurn = history.isEmpty
        let userMessage = RAGStoredMessage(
            id: UUID(),
            conversationID: conversationID,
            role: .user,
            content: question,
            model: nil,
            citations: [],
            remoteContextAudits: [],
            createdAt: ISO8601DateFormatter.shared.string(from: Date())
        )
        messages.append(userMessage)
        draftQuestion = ""
        streamingAnswer = ""
        queryPlan = nil
        retrieval = nil
        remoteBlocks = []
        pendingRemoteRequests = []
        approvedRemoteResources = []
        selectedCitation = nil
        selectedCitationChunk = nil
        errorMessage = nil
        var completedPayload: (String, String, [RAGCitation])?
        var terminalReply: String?

        do {
            let service = try dependencies.makeKnowledgeRAGService(selectedModelID: selectedModelID)
            let consent = RAGRemoteContextConsent()
            remoteContextConsent = consent
            let request = RAGServiceRequest(
                rawQuestion: question,
                composerContext: RAGComposerContext(
                    explicitRepoIDs: selectedRepoContexts.map(\.id),
                    explicitRepoMode: explicitRepoMode,
                    selectedModelID: selectedModelID,
                    attachments: attachments,
                    pastedGitHubLinks: githubLinkContexts,
                    disabledRemoteResources: []
                ),
                conversationID: conversationID,
                isDebugEnabled: isDebugModeEnabled,
                debugEndpoint: selectedModelEndpoint
            )
            for try await event in service.ask(request: request, history: history, remoteContextConsent: consent) {
                switch event {
                case .state(let state):
                    answerState = state
                    terminalReply = reply(for: state) ?? terminalReply
                case .plan(let plan): queryPlan = plan
                case .retrieval(let result): retrieval = result
                case .remoteContextConfirmation(let requests):
                    pendingRemoteRequests = requests
                    approvedRemoteResources = Set(requests.map(\.resource))
                case .remoteContext(let blocks): remoteBlocks = blocks
                case .debug(let event):
                    appendDebugEvent(event, to: debugTraceID)
                case .delta(let text): streamingAnswer += text
                case .completed(let answer, let model, let citations, _):
                    completedPayload = (answer, model, citations)
                }
            }
            if let completedPayload {
                try await persistAnswer(
                    conversationID: conversationID,
                    question: question,
                    answer: completedPayload.0,
                    model: completedPayload.1,
                    citations: completedPayload.2,
                    remoteContexts: remoteBlocks
                )
                if isFirstTurn {
                    generateConversationTitle(
                        using: service,
                        conversationID: conversationID,
                        firstQuestion: question
                    )
                }
            } else if let terminalReply, answerState != .cancelled {
                try await persistAnswer(
                    conversationID: conversationID,
                    question: question,
                    answer: terminalReply,
                    model: selectedModelDisplayName,
                    citations: [],
                    remoteContexts: remoteBlocks
                )
            } else if answerState == .cancelled {
                scheduleFinalizeCancelledTurn(
                    conversationID: conversationID,
                    userMessage: userMessage,
                    question: question,
                    isFirstTurn: isFirstTurn,
                    service: service
                )
            }
        } catch is CancellationError {
            answerState = .cancelled
            scheduleFinalizeCancelledTurn(
                conversationID: conversationID,
                userMessage: userMessage,
                question: question,
                isFirstTurn: isFirstTurn,
                service: nil
            )
        } catch {
            // 停止按钮会 cancel Task；部分底层 API 不抛 CancellationError 而是带上
            // Task.isCancelled，不能当成「RAG 请求失败」弹窗。
            if Task.isCancelled {
                answerState = .cancelled
                scheduleFinalizeCancelledTurn(
                    conversationID: conversationID,
                    userMessage: userMessage,
                    question: question,
                    isFirstTurn: isFirstTurn,
                    service: nil
                )
            } else {
                answerState = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription
                messages.removeAll { $0.id == userMessage.id }
            }
        }
        finishDebugTrace(debugTraceID, state: debugTraceState(for: answerState))
        remoteContextConsent = nil
        answerTask = nil
    }

    /// 在已取消的回答 Task 之外落库：否则 `appendUserMessage` 等 await 会再抛
    /// `CancellationError`，被误写成 errorMessage 弹出「RAG 请求失败」。
    private func scheduleFinalizeCancelledTurn(
        conversationID: UUID,
        userMessage: RAGStoredMessage,
        question: String,
        isFirstTurn: Bool,
        service: KnowledgeRAGService?
    ) {
        let partial = streamingAnswer
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 若调度时流式文本已被清空，用快照补回，避免竞态丢半截回答。
            if streamingAnswer.isEmpty, !partial.isEmpty {
                streamingAnswer = partial
            }
            await finalizeCancelledTurn(
                conversationID: conversationID,
                userMessage: userMessage,
                question: question,
                isFirstTurn: isFirstTurn,
                service: service
            )
        }
    }

    /// 停止生成：保留用户问题；已有流式文本则落库半截回答，否则只落库用户消息。
    private func finalizeCancelledTurn(
        conversationID: UUID,
        userMessage: RAGStoredMessage,
        question: String,
        isFirstTurn: Bool,
        service: KnowledgeRAGService?
    ) async {
        let partial = streamingAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        if partial.isEmpty {
            // 尚无 AI 输出：保留气泡，落库用户消息，供复制 / 编辑。
            do {
                try await conversationStore.appendUserMessage(
                    conversationID: conversationID,
                    messageID: userMessage.id,
                    question: question,
                    createdAt: userMessage.createdAt
                )
                if let detail = try await conversationStore.loadConversation(id: conversationID) {
                    messages = detail.messages
                }
                conversations = try await conversationStore.listConversations()
                if isFirstTurn, let service {
                    generateConversationTitle(
                        using: service,
                        conversationID: conversationID,
                        firstQuestion: question
                    )
                }
            } catch is CancellationError {
                // 忽略：停止路径不应弹失败窗。
            } catch {
                // 落库失败仍保留内存中的用户气泡，避免「停止后问题消失」。
                errorMessage = error.localizedDescription
            }
            streamingAnswer = ""
        } else {
            do {
                try await persistAnswer(
                    conversationID: conversationID,
                    question: question,
                    answer: partial,
                    model: selectedModelDisplayName,
                    citations: [],
                    remoteContexts: remoteBlocks
                )
                if isFirstTurn, let service {
                    generateConversationTitle(
                        using: service,
                        conversationID: conversationID,
                        firstQuestion: question
                    )
                }
            } catch is CancellationError {
                // 忽略：停止路径不应弹失败窗；半截文本仍挂到时间线。
                let assistant = RAGStoredMessage(
                    id: UUID(),
                    conversationID: conversationID,
                    role: .assistant,
                    content: partial,
                    model: selectedModelDisplayName,
                    citations: [],
                    remoteContextAudits: [],
                    createdAt: ISO8601DateFormatter.shared.string(from: Date())
                )
                if !messages.contains(where: { $0.id == userMessage.id }) {
                    messages.append(userMessage)
                }
                if !messages.contains(where: { $0.role == .assistant && $0.content == partial }) {
                    messages.append(assistant)
                }
                streamingAnswer = ""
            } catch {
                // 落库失败时至少把半截流式文本挂成助手气泡，避免只剩用户问题。
                let assistant = RAGStoredMessage(
                    id: UUID(),
                    conversationID: conversationID,
                    role: .assistant,
                    content: partial,
                    model: selectedModelDisplayName,
                    citations: [],
                    remoteContextAudits: [],
                    createdAt: ISO8601DateFormatter.shared.string(from: Date())
                )
                if !messages.contains(where: { $0.id == userMessage.id }) {
                    messages.append(userMessage)
                }
                messages.append(assistant)
                streamingAnswer = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 标题请求从回答任务中拆开：回答一旦落库即可立即交互，标题网络慢或失败都不能阻塞它。
    private func generateConversationTitle(
        using service: KnowledgeRAGService,
        conversationID: UUID,
        firstQuestion: String
    ) {
        conversationTitleTask?.cancel()
        let debugEnabled = isDebugModeEnabled
        let debugEndpoint = selectedModelEndpoint
        let debugTraceID = debugEnabled ? beginDebugTrace(category: .conversationTitle) : nil
        conversationTitleTask = Task { [weak self] in
            guard let self else { return }
            let result = await service.generateConversationTitle(
                firstQuestion: firstQuestion,
                isDebugEnabled: debugEnabled,
                debugEndpoint: debugEndpoint
            )
            guard !Task.isCancelled, selectedConversationID == conversationID else {
                finishDebugTrace(debugTraceID, state: .cancelled)
                return
            }

            switch result {
            case .completed(let title, let debugEvents):
                appendDebugEvents(debugEvents, to: debugTraceID)
                finishDebugTrace(debugTraceID, state: .completed)
                await typewriteConversationTitle(title, for: conversationID)
            case .failed(let debugEvents):
                appendDebugEvents(debugEvents, to: debugTraceID)
                finishDebugTrace(debugTraceID, state: .failed)
            case .cancelled:
                finishDebugTrace(debugTraceID, state: .cancelled)
                break
            }
        }
    }

    private func beginDebugTrace(category: RAGDebugTraceCategory) -> UUID {
        let trace = RAGDebugTrace(
            id: UUID(),
            category: category,
            startedAt: Date(),
            state: .running,
            events: []
        )
        debugTraces.append(trace)
        return trace.id
    }

    private func appendDebugEvent(_ event: RAGDebugEvent, to traceID: UUID?) {
        guard isDebugModeEnabled, let traceID,
              let index = debugTraces.firstIndex(where: { $0.id == traceID }) else { return }
        debugTraces[index].events.append(event)
    }

    private func appendDebugEvents(_ events: [RAGDebugEvent], to traceID: UUID?) {
        for event in events { appendDebugEvent(event, to: traceID) }
    }

    private func finishDebugTrace(_ traceID: UUID?, state: RAGDebugTrace.State) {
        guard let traceID, let index = debugTraces.firstIndex(where: { $0.id == traceID }) else { return }
        debugTraces[index].state = state
    }

    private func debugTraceState(for answerState: RAGAnswerState) -> RAGDebugTrace.State {
        switch answerState {
        case .cancelled: return .cancelled
        case .failed: return .failed
        default: return .completed
        }
    }

    /// 动画期间只改内存中的列表标题，完成后才写数据库，避免历史记录被半截文本污染。
    private func typewriteConversationTitle(_ title: String, for conversationID: UUID) async {
        updateConversationTitle(title: "", for: conversationID)
        var displayedTitle = ""
        for character in title {
            do {
                try await Task.sleep(for: .milliseconds(32))
            } catch {
                return
            }
            guard !Task.isCancelled, selectedConversationID == conversationID else { return }
            displayedTitle.append(character)
            updateConversationTitle(title: displayedTitle, for: conversationID)
        }
        guard !Task.isCancelled, selectedConversationID == conversationID else { return }
        do {
            try await conversationStore.renameConversation(id: conversationID, title: title)
        } catch {
            // 标题失败不应影响已完成的问答；内存标题仍保留，下一次加载会使用数据库旧标题。
        }
    }

    private func updateConversationTitle(title: String, for conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].title = title
    }

    private func persistAnswer(
        conversationID: UUID,
        question: String,
        answer: String,
        model: String,
        citations: [RAGCitation],
        remoteContexts: [RAGRemoteContextBlock]
    ) async throws {
        try await conversationStore.appendTurn(
            conversationID: conversationID,
            question: question,
            answer: answer,
            model: model,
            citations: citations,
            remoteContexts: remoteContexts
        )
        if let detail = try await conversationStore.loadConversation(id: conversationID) {
            messages = detail.messages
            if let citation = citations.first { selectCitation(citation) }
        }
        conversations = try await conversationStore.listConversations()
        streamingAnswer = ""
        remoteBlocks = []
        attachments = []
        githubLinkContexts = []
    }

    private func refreshIndexCoverage() async throws {
        indexCoverage = try await dependencies.knowledgeRAGIndexBuilder.coverage()
        indexIssueChunks = [:]
        indexIssueHasMore = []
    }

    private func resetTurnState() {
        draftQuestion = ""
        streamingAnswer = ""
        answerState = .idle
        editingUserMessageID = nil
        editingUserDraft = ""
        queryPlan = nil
        retrieval = nil
        remoteBlocks = []
        pendingRemoteRequests = []
        approvedRemoteResources = []
        selectedRepoContexts = []
        attachments = []
        githubLinkContexts = []
        errorMessage = nil
        selectedCitation = nil
        selectedCitationChunk = nil
    }

    private func reply(for state: RAGAnswerState) -> String? {
        switch state {
        case .needsClarification(let question): return question
        case .noKnowledgeRepos: return String.l10n("rag.workspace.state.noKnowledgeRepos")
        case .noCandidates: return String.l10n("rag.workspace.state.noCandidates")
        case .noIndex: return String.l10n("rag.workspace.state.noIndex")
        case .noRelevantChunks: return String.l10n("rag.workspace.state.noRelevantChunks")
        default: return nil
        }
    }

    private func detectGitHubLink() async {
        let pattern = #"https?://github\.com/([^/\s]+)/([^/\s?#]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: draftQuestion,
                range: NSRange(draftQuestion.startIndex..., in: draftQuestion)
              ),
              let urlRange = Range(match.range(at: 0), in: draftQuestion),
              let ownerRange = Range(match.range(at: 1), in: draftQuestion),
              let repoRange = Range(match.range(at: 2), in: draftQuestion) else { return }
        let rawURL = String(draftQuestion[urlRange])
        guard let url = URL(string: rawURL), !githubLinkContexts.contains(where: { $0.url == url }) else { return }
        let owner = String(draftQuestion[ownerRange])
        let name = String(draftQuestion[repoRange]).replacingOccurrences(of: ".git", with: "")

        if let candidate = knowledgeCandidates.first(where: {
            $0.repo.owner.caseInsensitiveCompare(owner) == .orderedSame
                && $0.repo.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            if !selectedRepoContexts.contains(where: { $0.id == candidate.repo.id }) {
                selectedRepoContexts.append(candidate.repo)
            }
            draftQuestion.removeSubrange(urlRange)
            draftQuestion = draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }

        let known = try? await dependencies.repoRepository.findByOwnerName(owner: owner, name: name)
        githubLinkContexts.append(RAGGitHubLinkReference(
            url: url,
            owner: owner,
            repo: name,
            matchedRepoID: known?.id,
            relation: known == nil ? .external : .knownButNotInKnowledge
        ))
        draftQuestion.removeSubrange(urlRange)
        draftQuestion = draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
