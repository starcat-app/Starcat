//
//  RepoIssuesWorkspaceViewModel.swift
//  Starcat
//
//  Issues 工作台（左列表 + 右详情/新建 大模态）的状态层。
//
//  职责划分（2026-11-01 dong4j 确认）：
//  - 左栏列表完全复用 `RepoIssuesViewModel`（分页 / 筛选 / 搜索 / SWR 共享缓存）。
//  - 右栏详情 = **完整复用活动-issues 详情页** `GitHubNotificationDetailView`：
//    选中 Issue 时按组织 Issues 同一管道把该 Issue 物化成
//    `github_notification_threads` 记录（方案 B：与组织 Issue 同语义，不做列表排除，
//    会作为「已读会话」出现在活动-通知列表），再由记录构建 ActivityItem 喂给详情页。
//    评论时间线、AI 总结、AI 写回复、翻译、评论草稿（按 threadId）全部由详情页自带。
//  - 新建表单沿用旧 NewIssueSheet 逻辑（草稿按仓库，DiskIssueDraftCache）。
//  - AI 生成 / Issue 模板 / 剪贴板图片上传为业务阶段接线点（占位见 createIssue 等）。
//
//  交互契约（设计确认 2026-11-01）：
//  ① 取消新建 → 回到上一个选中的 Issue，窗口保留；
//  ② 创建成功 → 列表刷新并自动选中新 Issue；
//  ③ 评论成功 → 监听 inbox 变更，左栏对应行评论数同步；
//  ⑤ 提交失败保留输入，错误内联在编辑器附近。
//

import Foundation
import Observation

@MainActor
@Observable
final class RepoIssuesWorkspaceViewModel {

    enum PaneMode: Equatable {
        case detail
        case create
    }

    // MARK: - 依赖

    let repo: Repo
    /// 左栏列表数据层（分页/筛选/搜索/SWR 缓存），由 Scaffold 持有并传入。
    let listViewModel: RepoIssuesViewModel
    /// 通知 inbox 服务：时间线缓存、issue state 解析、变更通知的消费方约定。
    private let inbox: GitHubNotificationInboxService?
    /// 统一 thread 记录仓库：工作台 Issue 物化的写入方（与组织 Issues 同一张表）。
    private let threadRepository: (any GitHubNotificationThreadRepositoryProtocol)?
    /// 新建描述的剪贴板图片上传（与通知评论框同一 `uploadUserAttachment` 通道）。
    private let apiClient: (any GitHubAPIClientProtocol)?
    /// AI 生成（与通知评论框同一 Chat 任务与门禁）。
    private let aiService: RepoAIInsightService?
    /// 测试注入独立缓存，不能读取或删除用户 Application Support 下的真实草稿。
    private let draftCache: DiskIssueDraftCache

    /// Preview 专用：不接 inbox / thread 仓库 / apiClient / aiService，详情项直接由种子状态注入。
    init(
        repo: Repo,
        listViewModel: RepoIssuesViewModel,
        inbox: GitHubNotificationInboxService? = nil,
        threadRepository: (any GitHubNotificationThreadRepositoryProtocol)? = nil,
        apiClient: (any GitHubAPIClientProtocol)? = nil,
        aiService: RepoAIInsightService? = nil,
        draftCache: DiskIssueDraftCache = .shared
    ) {
        self.repo = repo
        self.listViewModel = listViewModel
        self.inbox = inbox
        self.threadRepository = threadRepository
        self.apiClient = apiClient
        self.aiService = aiService
        self.draftCache = draftCache
    }

    // MARK: - 右栏模式 / 选中

    private(set) var paneMode: PaneMode = .detail
    private(set) var selectedIssue: GitHubRepoIssue?
    /// 「取消新建」的回跳目标；每次用户主动选中 Issue 时更新。
    private var lastSelectedIssue: GitHubRepoIssue?
    /// 选中与新建共用一个版本：数据库读取可以晚到，不能让旧会话重新接管评论目标。
    @ObservationIgnored private var detailGeneration: UInt64 = 0

    var isCreating: Bool { paneMode == .create }

    /// 右栏详情页的选中项（绑定给 `GitHubNotificationDetailView.selectedItem`）。
    /// 可写：绑定 set 需要赋值（工作台场景不使用详情页的清空路径，canMarkDone=false）。
    var detailItem: ActivityItem?

    func select(_ issue: GitHubRepoIssue) {
        detailGeneration &+= 1
        let generation = detailGeneration
        if selectedIssue?.id != issue.id { detailItem = nil }
        selectedIssue = issue
        lastSelectedIssue = issue
        paneMode = .detail
        Task { await materializeDetail(for: issue, generation: generation) }
    }

    /// 列表落地后自动选中第一条（交互契约：打开工作台即有内容可看）。
    func autoSelectFirstIssueIfNeeded() {
        guard !isCreating, selectedIssue == nil else { return }
        if let first = listViewModel.displayedIssues.first {
            select(first)
        }
    }

    func startCreating() {
        // 成功标记只保护刚提交完的清空操作；再次新建必须恢复本轮草稿的保存能力。
        hasCreatedIssue = false
        loadCreateDraftIfNeeded()
        detailGeneration &+= 1
        paneMode = .create
        // 左侧取消选中高亮：渲染层以 `isCreating` 为准，selectedIssue 保留供回跳。
    }

    func cancelCreating() {
        paneMode = .detail
        if let lastSelectedIssue { select(lastSelectedIssue) }
        createErrorMessage = nil
    }

    // MARK: - 详情物化（复用组织 Issues 管道）

    /// 把工作台选中的 Issue 物化成 thread 记录并构建详情项。
    /// 幂等：upsert 按 subject_api_url 复用既有记录（含组织同步已建过的行）。
    private func materializeDetail(for issue: GitHubRepoIssue, generation: UInt64) async {
        guard let threadRepository, detailGeneration == generation else { return }
        try? await threadRepository.upsertOrganizationIssues(
            [makeOrganizationIssue(from: issue)],
            credentialSource: .primaryOAuth,
            fetchedAt: ISO8601DateFormatter.shared.string(from: Date())
        )
        await reloadDetailItem(for: issue, generation: generation)
    }

    /// 重建详情项：hydrate / 发表评论后 inbox 会发 `.githubNotificationInboxDidChange`，
    /// 由工作台监听后调用，保证右栏拿到最新 comments / state。
    func reloadDetailAfterInboxChange() async {
        guard !isCreating, let issue = selectedIssue else { return }
        let generation = detailGeneration
        await reloadDetailItem(for: issue, generation: generation)
        guard detailGeneration == generation, selectedIssue?.id == issue.id else { return }
        await syncRowCommentsCount(for: issue)
    }

    private func reloadDetailItem(for issue: GitHubRepoIssue, generation: UInt64) async {
        guard let threadRepository, detailGeneration == generation,
              selectedIssue?.id == issue.id, !isCreating else { return }
        let record = await fetchThreadRecord(for: issue, using: threadRepository)
        // MainActor 不保证 await 前后的选中身份不变；同一 Issue 再次选中也属于新一轮请求。
        guard !Task.isCancelled, detailGeneration == generation,
              selectedIssue?.id == issue.id, !isCreating else { return }
        detailItem = record.map { makeDetailItem(from: $0) }
    }

    private func fetchThreadRecord(
        for issue: GitHubRepoIssue,
        using threadRepository: any GitHubNotificationThreadRepositoryProtocol
    ) async -> GitHubNotificationThreadRecord? {
        // upsert 的 id 规则与组织同步一致：organization-issue:{GitHub 全局 issue id}。
        if let record = try? await threadRepository.fetch(id: threadID(for: issue)) {
            return record
        }
        // 兜底：老数据可能走了别的 id 规则，按 subject_api_url 找一次。
        let all = (try? await threadRepository.fetchAll(limit: 500)) ?? []
        return all.first { $0.subjectApiUrl == subjectAPIURL(for: issue) }
    }

    /// 方案 B（2026-11-01 dong4j 确认）：工作台行不做任何列表排除，
    /// 与组织 Issue 完全同语义出现在活动-通知列表（unread=0 → 已读会话样式）。
    private func makeOrganizationIssue(from issue: GitHubRepoIssue) -> GitHubOrganizationIssue {
        GitHubOrganizationIssue(
            id: issue.id,
            subjectAPIURL: subjectAPIURL(for: issue),
            organization: repo.owner,
            repositoryFullName: repo.fullName,
            number: issue.number,
            title: issue.title,
            state: issue.state == .open ? .open : .closed,
            body: issue.body,
            htmlURL: issue.htmlURL,
            authorLogin: issue.authorLogin,
            assigneeLogins: [],
            labels: issue.labels.map { GitHubOrganizationIssueLabel(name: $0.name, colorHex: $0.colorHex) },
            commentsCount: issue.commentsCount,
            createdAt: issue.createdAt,
            updatedAt: issue.updatedAt,
            closedAt: issue.closedAt
        )
    }

    private func subjectAPIURL(for issue: GitHubRepoIssue) -> String {
        "https://api.github.com/repos/\(repo.fullName)/issues/\(issue.number)"
    }

    private func threadID(for issue: GitHubRepoIssue) -> String {
        "organization-issue:\(issue.id)"
    }

    /// 记录 → 详情项。镜像 InboxView 的 `makeNotificationItem`，差异只有两处：
    /// localRepo 直接用工作台当前 repo（免二次查库），其余字段全部走同一套 mapper。
    private func makeDetailItem(from record: GitHubNotificationThreadRecord) -> ActivityItem {
        ActivityItem(
            id: "notification:\(record.id)",
            kind: .notification,
            category: .notification,
            title: record.subjectTitle,
            subtitle: GitHubNotificationMapper.subtitle(
                fullName: record.repositoryFullName,
                subjectType: record.subjectType,
                number: record.subjectNumber
            ),
            body: record.excerpt,
            createdAt: GitHubNotificationMapper.parseDate(record.updatedAt),
            htmlURL: record.htmlUrl.flatMap(URL.init(string:)),
            repo: repo,
            release: nil,
            releases: [],
            isRead: !record.unread,
            notification: ActivityNotificationPayload(
                threadId: record.id,
                reason: record.reason,
                chip: GitHubNotificationMapper.subjectChip(for: record),
                subjectType: record.subjectType,
                subjectNumber: record.subjectNumber,
                repositoryFullName: record.repositoryFullName,
                actorLogin: GitHubNotificationMapper.eventActor(for: record) ?? record.actorLogin,
                authorLogin: GitHubNotificationMapper.openingPostAuthor(for: record),
                authorCreatedAt: GitHubNotificationMapper.parseDate(record.subjectCreatedAt),
                excerpt: record.excerpt,
                comments: GitHubNotificationMapper.decodeComments(record.commentsJson),
                people: GitHubNotificationMapper.relatedPeople(for: record),
                repositoryId: record.repositoryId,
                canMarkDone: record.remoteNotificationThreadID != nil,
                issueState: inbox?.resolvedIssueState(
                    threadId: record.id,
                    persisted: record.issueState
                ),
                labels: GitHubNotificationMapper.decodeLabels(record.labelsJson)
            )
        )
    }

    /// 交互契约 ③：评论成功（inbox 变更）后同步左栏对应行的评论数。
    /// 计数取「comments_json / 时间线评论」的较大者，只增不减（初值来自 REST 列表）。
    private func syncRowCommentsCount(for issue: GitHubRepoIssue) async {
        guard let threadRepository else { return }
        var candidate = 0
        if let record = await fetchThreadRecord(for: issue, using: threadRepository) {
            candidate = GitHubNotificationMapper.decodeComments(record.commentsJson).count
        }
        let timelineCount = inbox?.cachedIssueTimelineComments(threadId: threadID(for: issue)).count ?? 0
        candidate = max(candidate, timelineCount)
        if candidate > issue.commentsCount {
            listViewModel.updateCommentsCount(issueID: issue.id, count: candidate)
        }
    }

    // MARK: - 新建表单（草稿按仓库，沿用 DiskIssueDraftCache）

    var createTitle = ""
    var createBody = ""
    var isCreatePreview = false
    private(set) var isCreatingIssue = false
    private(set) var createErrorMessage: String?
    private(set) var uploadErrorMessage: String?
    /// 上传中的粘贴图片数：>0 时禁用「创建 Issue」，避免 `starcat-upload:` 占位符发出。
    private(set) var uploadingImageCount = 0
    private var hasCreatedIssue = false
    /// 关闭可能早于 .task 执行，尚未恢复的空表单不能反向删除磁盘草稿。
    private var hasLoadedCreateDraft = false
    private var createDraftDebounceTask: Task<Void, Never>?

    var isUploadingImage: Bool { uploadingImageCount > 0 }

    var trimmedCreateTitle: String {
        createTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedCreateBody: String {
        createBody.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func loadCreateDraftIfNeeded() {
        guard !hasLoadedCreateDraft, !hasCreatedIssue else { return }
        hasLoadedCreateDraft = true
        if let snapshot = draftCache.load(repoFullName: repo.fullName) {
            createTitle = snapshot.title
            createBody = snapshot.body
        }
    }

    func scheduleCreateDraftPersist() {
        createDraftDebounceTask?.cancel()
        guard !hasCreatedIssue else { return }
        createDraftDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            persistCreateDraftNow()
        }
    }

    private func persistCreateDraftNow() {
        guard hasLoadedCreateDraft, !hasCreatedIssue else { return }
        draftCache.upsert(repoFullName: repo.fullName, title: createTitle, body: createBody)
    }

    /// 面板消失 / 关闭前 flush（对齐旧 NewIssueSheet 的 onDisappear 行为）。
    func flushCreateDraft() {
        createDraftDebounceTask?.cancel()
        persistCreateDraftNow()
    }

    /// 创建 Issue（POST /repos/{o}/{r}/issues）。
    /// 成功：清表单 + 删草稿 + 列表重载并高亮新行 + 自动选中新 Issue 切回详情态；
    /// 失败：保留输入，错误内联（403/404 私仓提示、422 校验提示）。
    func createIssue() async {
        guard !trimmedCreateTitle.isEmpty, !isCreatingIssue, !isUploadingImage, !isGeneratingIssue,
              let apiClient
        else { return }
        isCreatingIssue = true
        createErrorMessage = nil
        defer { isCreatingIssue = false }
        do {
            let issue = try await apiClient.createRepoIssue(
                owner: repo.owner,
                repo: repo.name,
                title: trimmedCreateTitle,
                body: trimmedCreateBody.isEmpty ? nil : createBody
            )
            hasCreatedIssue = true
            createTitle = ""
            createBody = ""
            isCreatePreview = false
            draftCache.remove(repoFullName: repo.fullName)
            // 交互契约 ②：列表重载 + 高亮新行（sort=updated 时新 issue 排第一），
            // 再物化详情并切回详情态。
            listViewModel.issueDidCreate(issue)
            select(issue)
        } catch {
            createErrorMessage = Self.createIssueErrorMessage(error)
        }
    }

    /// 创建失败文案映射（对齐旧 NewIssueSheet 的惯例）。
    nonisolated private static func createIssueErrorMessage(_ error: Error) -> String {
        if let networkError = error as? NetworkError {
            switch networkError {
            case .notFound:
                return String.l10n("repo.issues.create.error.notFound", defaultValue: "无法在该仓库创建 Issue（可能是私有仓库或已关闭 Issues）")
            case .clientError(let code, _) where code == 403 || code == 404:
                return String.l10n("repo.issues.create.error.forbidden", defaultValue: "无法在该仓库创建 Issue（可能是私有仓库或权限不足）")
            case .clientError(let code, _) where code == 422:
                return String.l10n("repo.issues.create.error.validation", defaultValue: "GitHub 拒绝了这次提交，请检查标题与描述后重试")
            case .unauthorized:
                return String.l10n("repo.issues.create.error.unauthorized", defaultValue: "登录状态已失效，请重新登录 GitHub")
            case .rateLimited:
                return String.l10n("repo.issues.create.error.rateLimited", defaultValue: "GitHub 请求频率受限，请稍后再试")
            default:
                break
            }
        }
        return String.l10n("repo.issues.create.error.generic", defaultValue: "Issue 创建失败，请稍后再试")
    }

    // MARK: - AI 生成描述（对齐通知评论框：门禁 / 流式 / 取消还原 / 光晕）

    private(set) var isGeneratingIssue = false
    private(set) var aiErrorMessage: String?
    /// Pro 付费墙上下文（视图 `.sheet(item:)` 绑定，需要可写）。
    var aiPaywallContext: ProPaywallContext?
    private var generateTask: Task<Void, Never>?
    /// 生成前快照：取消 / 失败时还原，AI 不偷偷改写用户已有内容（AI 保守策略）。
    private var previousCreateBody: String?
    /// 仓库模板缓存：nil = 未拉取；[] = 已确认无模板。每次会话拉一次。
    private var cachedTemplates: [GitHubIssueTemplate]?

    var canGenerateIssue: Bool {
        !trimmedCreateBody.isEmpty && !isGeneratingIssue
    }

    /// ✨ 点击：已生成中 → 取消并还原快照；否则启动生成。
    func sparklesTapped() {
        if isGeneratingIssue {
            cancelGenerateIssue()
        } else {
            startGenerateIssue()
        }
    }

    func startGenerateIssue() {
        guard canGenerateIssue, let aiService else { return }
        aiErrorMessage = nil
        do {
            try aiService.ensureGitHubCommentReady()
        } catch let error as EntitlementGateError {
            aiPaywallContext = ProPaywallContext(feature: error.feature, message: error.localizedDescription)
            return
        } catch {
            presentAIFailure(error)
            return
        }
        previousCreateBody = createBody
        isGeneratingIssue = true
        generateTask = Task { await generateIssueBody() }
    }

    func cancelGenerateIssue() {
        generateTask?.cancel()
        generateTask = nil
        isGeneratingIssue = false
        if let previousCreateBody {
            createBody = previousCreateBody
        }
    }

    private func generateIssueBody() async {
        guard let aiService else { return }
        // 生成期间的局部快照：流式写 createBody 时用户输入被锁（编辑器 isEditable=false）。
        let pack = GitHubIssueComposerPack(
            outputLanguage: GitHubIssueComposerAI.outputLanguage(forDescription: trimmedCreateBody),
            repositoryFullName: repo.fullName,
            primaryLanguage: repo.language,
            titleDraft: trimmedCreateTitle,
            userDescription: trimmedCreateBody,
            templates: await loadTemplatesIfNeeded()
        )
        do {
            let result = try await aiService.generateIssueDraft(pack: pack) { [weak self] partial in
                self?.createBody = partial
            }
            createBody = result
            isGeneratingIssue = false
        } catch is CancellationError {
            isGeneratingIssue = false
            restorePreviousDraftIfAny()
        } catch let error as EntitlementGateError {
            isGeneratingIssue = false
            restorePreviousDraftIfAny()
            aiPaywallContext = ProPaywallContext(feature: error.feature, message: error.localizedDescription)
        } catch {
            isGeneratingIssue = false
            restorePreviousDraftIfAny()
            presentAIFailure(error)
        }
    }

    func cancelGenerateIfNeededOnDisappear() {
        generateTask?.cancel()
        generateTask = nil
    }

    private func restorePreviousDraftIfAny() {
        if let previousCreateBody {
            createBody = previousCreateBody
        }
    }

    /// 模板拉取失败静默退化为「无模板」：AI 主流程不被模板网络问题阻塞。
    private func loadTemplatesIfNeeded() async -> [GitHubIssueTemplate] {
        if let cachedTemplates { return cachedTemplates }
        var fetched: [GitHubIssueTemplate] = []
        if let apiClient {
            fetched = (try? await apiClient.issueTemplates(owner: repo.owner, repo: repo.name)) ?? []
        }
        cachedTemplates = fetched
        return fetched
    }

    /// 生成前配置检查与请求失败共用：友好文案 + 诊断记录（对齐通知评论框）。
    private func presentAIFailure(_ error: Error) {
        let friendly = UserFacingError.map(
            error,
            operation: String.l10n("diagnostics.operation.aiChat"),
            service: "AI",
            impact: .blocked, summary: .aiUnavailable
        )
        friendly.record(
            category: "ai",
            operation: "repoIssue.compose",
            service: "ai-provider"
        )
        aiErrorMessage = friendly.message
    }

    // MARK: - 剪贴板图片上传（与通知评论框同管道）

    /// 编辑器拦截到 Cmd+V 图片：先占位，上传成功换 `![name](user-attachments url)`，
    /// 失败清占位并内联报错。与 `GitHubNotificationDetailView.uploadPastedImage` 同构。
    func uploadPastedImage(_ payload: GitHubClipboardImage.Payload, placeholder: String) async {
        guard let apiClient, repo.id > 0 else {
            uploadErrorMessage = String.l10n(
                "repo.issues.create.uploadFailed",
                defaultValue: "图片上传失败，请稍后再试"
            )
            return
        }
        uploadingImageCount += 1
        defer { uploadingImageCount = max(0, uploadingImageCount - 1) }
        do {
            let url = try await apiClient.uploadUserAttachment(
                fileName: payload.fileName,
                contentType: payload.contentType,
                repositoryID: repo.id,
                data: payload.data
            )
            let markdown = GitHubUserAttachment.markdownImage(alt: payload.fileName, url: url)
            createBody = GitHubUserAttachment.replacePlaceholder(placeholder, with: markdown, in: createBody)
        } catch {
            createBody = GitHubUserAttachment.replacePlaceholder(placeholder, with: "", in: createBody)
            uploadErrorMessage = Self.uploadErrorMessage(for: error)
        }
    }

    func setUploadError(_ error: GitHubUserAttachmentError) {
        uploadErrorMessage = Self.uploadErrorMessage(for: error)
    }

    nonisolated private static func uploadErrorMessage(for error: Error) -> String {
        if let attachment = error as? GitHubUserAttachmentError,
           attachment == .imageTooLarge {
            return String.l10n(
                "repo.issues.create.imageTooLarge",
                defaultValue: "图片太大，不能超过 10 MB"
            )
        }
        return String.l10n(
            "repo.issues.create.uploadFailed",
            defaultValue: "图片上传失败，请稍后再试"
        )
    }

    // MARK: - 刷新

    /// 顶栏刷新：强制重载当前筛选首屏，并重建右栏详情项。
    func refreshAll() {
        Task {
            await listViewModel.loadFirstPage()
            autoSelectFirstIssueIfNeeded()
            if let issue = selectedIssue {
                await reloadDetailItem(for: issue, generation: detailGeneration)
            }
        }
    }

    // MARK: - DEBUG 预览种子（SwiftUI Preview / 无 Issue 仓库的 UI 走查，不参与生产路径）

#if DEBUG
    /// 仅 Xcode Preview 使用：静态注入选中项与详情（不写 thread 表、不发网络）。
    func seedPreviewState(selected: GitHubRepoIssue?) {
        guard let selected else { return }
        self.selectedIssue = selected
        self.lastSelectedIssue = selected
        detailItem = Self.makeMockDetailItem(for: selected, repo: repo)
    }

    /// Mock 详情项：直接从列表 Issue 数据构建（不经 thread 记录，评论为空态）。
    static func makeMockDetailItem(for issue: GitHubRepoIssue, repo: Repo) -> ActivityItem {
        ActivityItem(
            id: "notification:mock-issue-\(issue.id)",
            kind: .notification,
            category: .notification,
            title: issue.title,
            subtitle: GitHubNotificationMapper.subtitle(
                fullName: repo.fullName,
                subjectType: "Issue",
                number: issue.number
            ),
            body: issue.body,
            createdAt: issue.updatedAt,
            htmlURL: issue.htmlURL,
            repo: repo,
            release: nil,
            releases: [],
            isRead: true,
            notification: ActivityNotificationPayload(
                threadId: "organization-issue:\(issue.id)",
                reason: "organization",
                chip: .issue,
                subjectType: "Issue",
                subjectNumber: issue.number,
                repositoryFullName: repo.fullName,
                actorLogin: issue.authorLogin,
                authorLogin: issue.authorLogin,
                authorCreatedAt: issue.createdAt,
                excerpt: issue.body,
                comments: [],
                people: [],
                repositoryId: repo.id,
                canMarkDone: false,
                issueState: issue.state.rawValue,
                labels: issue.labels.map {
                    GitHubNotificationIssueLabel(name: $0.name, colorHex: $0.colorHex)
                }
            )
        )
    }
#endif
}
