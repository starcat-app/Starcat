//
//  KnowledgeRAGWorkspaceViewModel.swift
//  Starcat
//
//  知识库 RAG 工作台状态协调器。
//
//  关键约束：输入框的 @repo / 模型 / 附件是确定上下文，不从自然语言反推；会话只有在
//  得到完整回答或明确早停答复后才原子写入一轮，取消中的半截流不会污染历史。
//

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class KnowledgeRAGWorkspaceViewModel {
    private let dependencies: AppDependencies
    private let conversationStore: any RAGConversationStoring
    private var answerTask: Task<Void, Never>?
    private var remoteContextConsent: RAGRemoteContextConsent?
    private var linkDetectionTask: Task<Void, Never>?

    var conversations: [RAGConversationSummary] = []
    var selectedConversationID: UUID?
    var messages: [RAGStoredMessage] = []
    var draftQuestion = ""
    var streamingAnswer = ""
    var answerState: RAGAnswerState = .idle
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
    var selectedModelID: String?
    var knowledgeRepos: [Repo] = []
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
    var isIndexing = false
    var errorMessage: String?

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        self.conversationStore = dependencies.ragConversationStore
        self.selectedModelID = dependencies.knowledgeRAGChatModels.first {
            $0.providerID == dependencies.settings.aiChatTask.providerID
                && $0.name == dependencies.settings.aiChatTask.resolvedModelName
        }?.id
    }

    var isAnswering: Bool {
        switch answerState {
        case .planning, .retrieving, .awaitingRemoteContextConfirmation, .fetchingRemoteContext, .generating: return true
        default: return false
        }
    }

    var availableModels: [AIModelDescriptor] { dependencies.knowledgeRAGChatModels }

    var selectedModelDisplayName: String {
        availableModels.first(where: { $0.id == selectedModelID })?.name
            ?? dependencies.settings.aiChatTask.resolvedModelName
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
        let selectedIDs = Set(selectedRepoContexts.map(\.id))
        return knowledgeCandidates.filter { candidate in
            let repo = candidate.repo
            guard !selectedIDs.contains(repo.id) else { return false }
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

    func bootstrap() async {
        do {
            async let loadedConversations = conversationStore.listConversations()
            async let loadedCandidates = dependencies.ragCandidateRepository.fetchCandidates(
                plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "knowledge"),
                explicitRepoIDs: [],
                explicitMode: .only
            )
            conversations = try await loadedConversations
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
        do {
            let conversation = try await conversationStore.createConversation(title: nil)
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
        do {
            guard let detail = try await conversationStore.loadConversation(id: id) else { return }
            selectedConversationID = id
            messages = detail.messages
            let initialCitation = messages.reversed().lazy.flatMap(\.citations).first
            resetTurnState()
            if let initialCitation { selectCitation(initialCitation) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteConversation(_ id: UUID) async {
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

    func send() {
        let question = draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering, composerBlockingReason == nil else { return }
        answerTask?.cancel()
        answerTask = Task { [weak self] in
            await self?.runQuestion(question)
        }
    }

    func cancelAnswer() {
        answerTask?.cancel()
        answerTask = nil
        if isAnswering { answerState = .cancelled }
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

    func selectMention(_ repo: Repo) {
        if let at = draftQuestion.lastIndex(of: "@") {
            draftQuestion.removeSubrange(at..<draftQuestion.endIndex)
        }
        selectedRepoContexts.append(repo)
        draftQuestion = draftQuestion.trimmingCharacters(in: .whitespaces) + (draftQuestion.isEmpty ? "" : " ")
    }

    func removeMention(repoID: Int64) {
        selectedRepoContexts.removeAll { $0.id == repoID }
    }

    func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = String.l10n("rag.workspace.composer.attach")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !attachments.contains(where: { $0.localURL == url }) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
            let handling: RAGAttachmentHandling
            if type?.conforms(to: .image) == true {
                handling = .vision
            } else if type?.conforms(to: .text) == true || type?.conforms(to: .pdf) == true
                        || type?.conforms(to: .json) == true || type?.conforms(to: .sourceCode) == true {
                handling = .textContext
            } else {
                handling = .unsupported
            }
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

    func copyAnswer(_ content: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    func exportAnswer(_ content: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Starcat-RAG.md"
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
            do {
                try await dependencies.knowledgeRAGIndexBuilder.rebuildKnowledgeBase()
                try await refreshIndexCoverage()
            } catch {
                errorMessage = error.localizedDescription
            }
            isIndexing = false
        }
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

    func openCitation(_ citation: RAGCitation) {
        selectCitation(citation)
        Task {
            if let repo = try? await dependencies.repoRepository.findById(citation.repoID) {
                dependencies.companionActionDispatcher.requestOpenRepo(repo)
            } else if let url = citation.sourceURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func openGitHub(_ citation: RAGCitation) {
        if let url = citation.sourceURL { NSWorkspace.shared.open(url) }
    }

    func handleLink(_ url: URL) {
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
                dependencies.companionActionDispatcher.requestOpenRepo(repo)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func runQuestion(_ question: String) async {
        guard let conversationID = selectedConversationID else { return }
        let history = messages.map { message in
            AIChatMessage(
                role: message.role == .user ? .user : .assistant,
                content: message.content
            )
        }
        let userMessage = RAGStoredMessage(
            id: UUID(),
            conversationID: conversationID,
            role: .user,
            content: question,
            model: nil,
            citations: [],
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
                conversationID: conversationID
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
                    citations: completedPayload.2
                )
            } else if let terminalReply, answerState != .cancelled {
                try await persistAnswer(
                    conversationID: conversationID,
                    question: question,
                    answer: terminalReply,
                    model: selectedModelDisplayName,
                    citations: []
                )
            } else if answerState == .cancelled {
                messages.removeAll { $0.id == userMessage.id }
            }
        } catch is CancellationError {
            answerState = .cancelled
            messages.removeAll { $0.id == userMessage.id }
        } catch {
            answerState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            messages.removeAll { $0.id == userMessage.id }
        }
        remoteContextConsent = nil
        answerTask = nil
    }

    private func persistAnswer(
        conversationID: UUID,
        question: String,
        answer: String,
        model: String,
        citations: [RAGCitation]
    ) async throws {
        try await conversationStore.appendTurn(
            conversationID: conversationID,
            question: question,
            answer: answer,
            model: model,
            citations: citations
        )
        if let detail = try await conversationStore.loadConversation(id: conversationID) {
            messages = detail.messages
            if let citation = citations.first { selectCitation(citation) }
        }
        conversations = try await conversationStore.listConversations()
        streamingAnswer = ""
        attachments = []
        githubLinkContexts = []
    }

    private func refreshIndexCoverage() async throws {
        indexCoverage = try await dependencies.knowledgeRAGIndexBuilder.coverage()
    }

    private func resetTurnState() {
        draftQuestion = ""
        streamingAnswer = ""
        answerState = .idle
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
