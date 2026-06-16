//
//  RepoReleaseSection.swift
//  Starcat
//
//  Repo 详情页 hero stats 行 - Release 订阅紧凑 stat 单元（HOM-47）。
//
//  ⚠️ 文件名仍为 `RepoReleaseSection` 是历史遗留：v2.0（2026-06-12）把原本独立成段
//      的「Releases 订阅段」压缩进 hero stats 行的紧凑 stat 单元 `RepoReleaseStatItem`，
//      与 Stars / Forks / Watchers / Created / Updated 同一行,作为详情页第 6 个 stat。
//      为避免触发 xcodegen 全量 project 重生与 git history 断裂,文件名保留不动。
//
//  组件结构：
//  - `RepoReleaseStatItem` (View)：紧凑 stat 单元（VStack center, 14pt 主行 + 10pt 副行）
//  - `RepoReleaseSectionViewModel` (@MainActor @Observable)：状态机 + 副作用入口（沿用）
//
//  设计取舍：
//  - 订阅按钮的"首次按下"会立即拉一页 Release（priming 游标），
//    避免用户后续轮询时被推送一堆历史 Release
//  - 详情页只在 stat 第二行展示**最新一条 tag**；完整历史去时间线视图查
//  - 通知静默开关 v1.0 时存在,v2.0 移除：订阅 = 自动开通知,与首次订阅授权语义对齐,
//    后续若用户想静音可去时间线视图统一管理
//
//  v1.0 → v2.0 演化轨迹（2026-06-12,dong4j 反馈）：
//  - v1.0：详情页有完整 `RepoReleaseSection` 段（标题 + 订阅按钮 + 通知开关 + 最新 release 行）
//  - v2.0：dong4j 反馈该段独立成块挤压 README 阅读区,与 hero stats 重复表达"仓库基础信息",
//    遂压缩为单 stat 单元;同时删除通知静默开关与 "3 天前" 相对时间这两个紧凑形态放不下的修饰
//

import SwiftUI

/// 详情页 hero stats 行的「Releases 订阅」紧凑单元。
///
/// 视觉规格与 `RepoStatItem` / `StarStatChipButton` 对齐(VStack center,14pt 主行 + 10pt 副行)：
/// - **第一行**：🔔 / 🔔.fill 图标 + "订阅" / "已订阅" 文本 —— 整列作为 Button,
///   未订阅 → 订阅(priming 拉一页 + 写库 + 申请通知授权),已订阅 → 取消订阅
/// - **第二行**：
///   - 未订阅 / 没有 release：`Releases` 灰色 label(与其它 stat 第二行 label 风格一致)
///   - 已订阅 + 有 release：最新 tag(accent 色,可点击打开 GitHub release 页)
///
/// 状态机(沿用 `RepoReleaseSectionViewModel`)：
/// - `subscription.isSubscribed`：决定第一行图标 / 文本与点击行为
/// - `latestRelease`：决定第二行展示 tag 还是 fallback "Releases" label
/// - `isMutating`：subscribe / unsubscribe 进行中,第一行图标位渲染 ProgressView 替代,
///   按钮 disabled 防双击
/// - `errorMessage`：通过 `.help` tooltip 透传给用户,不在主视觉上高亮(stats 行已经
///   有 5 个其它 stat,出错时整列变红会过分抢眼)
///
/// **登录态门控（与 hero ⭐/☆ chip 同构）**：
/// 未登录用户点击订阅按钮不会进入 `subscribe / unsubscribe` API 路径,而是先调
/// `authSession.signIn()` 触发设备流登录,登录完成后用户需再点一次才真正订阅。
/// 这与 `StarStatChipButton` 调用方(`handleStarTapped`)的处理完全一致 ——
/// **不直接抛错、不弹错误提示**(避免把"未登录"误传成"操作失败"语义)。
struct RepoReleaseStatItem: View {

    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies

    /// 登录态门控来源。未登录时点击订阅会走 `authSession.signIn()` 触发设备流,
    /// 与 `RepoDetailScaffold.onStarTapped` / 各 ScaffoldShell.handleStarTapped
    /// 的「未登录 → signIn() 后 return」一致。
    @Environment(AuthSession.self) private var authSession

    @State private var viewModel: RepoReleaseSectionViewModel?

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            actionRow
            secondaryRow
        }
        .help(helpText)
        .task(id: repo.id) {
            // viewModel 在首次进入时按需创建;后续 repo 切换由 task(id:) 重启 → loadFor 重读。
            if viewModel == nil {
                viewModel = RepoReleaseSectionViewModel(
                    apiClient: dependencies.apiClient,
                    subscriptionRepository: dependencies.releaseSubscriptionRepository,
                    releaseRepository: dependencies.releaseRepository,
                    notificationService: dependencies.releaseNotificationService
                )
            }
            await viewModel?.loadFor(repo: repo)
        }
    }

    /// 第一行:图标 + 文字,作为订阅 / 取消订阅的主交互入口。
    ///
    /// **未登录门控**:与 hero ⭐/☆ chip 调用方同构(详见 `StarStatChipButton.swift`
    /// 文件头第 33 行说明 + 各 `ScaffoldShell.handleStarTapped`):未登录用户点击 →
    /// `authSession.signIn()` 触发设备流,return 不进入 subscribe / unsubscribe API
    /// 路径。登录成功后用户需再点一次才真正订阅(不做"先记意图后续登录自动执行"的
    /// 隐式行为,避免误订阅)。
    @ViewBuilder
    private var actionRow: some View {
        Button {
            guard let vm = viewModel else { return }
            guard authSession.state.isAuthenticated else {
                authSession.signIn()
                return
            }
            Task {
                if subscribed {
                    await vm.unsubscribe(repoId: repo.id)
                } else {
                    await vm.subscribe(owner: repo.owner, repo: repo.name, repoId: repo.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                iconOrSpinner
                Text(actionTitleKey)
                    .font(.system(size: 14, weight: .medium))
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .disabled(viewModel?.isMutating == true)
    }

    /// isMutating 时显示 spinner(防双击同时给用户视觉反馈),否则显示订阅状态对应的铃铛图标。
    /// 不监听 isLoading(初次 loadFor 的状态)是为了避免详情页打开瞬间 stat 闪一下 spinner。
    @ViewBuilder
    private var iconOrSpinner: some View {
        if viewModel?.isMutating == true {
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: subscribed ? "bell.fill" : "bell")
                .foregroundStyle(subscribed ? Color.accentColor : .secondary)
                .font(.system(size: 14))
        }
    }

    /// 第二行:未订阅 → "Releases" 灰色 label;已订阅 + 有 release → 最新 tag(accent 色,可点跳 GitHub)。
    @ViewBuilder
    private var secondaryRow: some View {
        if subscribed, let latest = viewModel?.latestRelease {
            Button {
                if let url = URL(string: latest.htmlUrl) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text(verbatim: latest.tagName)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover()
        } else {
            Text("releases.section.title")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var subscribed: Bool {
        viewModel?.subscription?.isSubscribed == true
    }

    private var actionTitleKey: LocalizedStringKey {
        subscribed ? "releases.stat.subscribed" : "releases.action.subscribe"
    }

    /// hover 时的帮助 tooltip:errorMessage 优先(动态字符串,verbatim 直传);
    /// 否则给出动作意图(订阅 / 取消订阅)。
    private var helpText: Text {
        if let err = viewModel?.errorMessage, !err.isEmpty {
            return Text(verbatim: err)
        }
        return subscribed ? Text("releases.action.unsubscribe") : Text("releases.action.subscribe")
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class RepoReleaseSectionViewModel {

    private(set) var subscription: ReleaseSubscription?
    private(set) var latestRelease: ReleaseRecord?
    private(set) var isLoading: Bool = false
    private(set) var isMutating: Bool = false
    private(set) var errorMessage: String?

    private let apiClient: any GitHubAPIClientProtocol
    private let subscriptionRepository: any ReleaseSubscriptionRepositoryProtocol
    private let releaseRepository: any ReleaseRepositoryProtocol
    private let notificationService: ReleaseNotificationService

    init(
        apiClient: any GitHubAPIClientProtocol,
        subscriptionRepository: any ReleaseSubscriptionRepositoryProtocol,
        releaseRepository: any ReleaseRepositoryProtocol,
        notificationService: ReleaseNotificationService
    ) {
        self.apiClient = apiClient
        self.subscriptionRepository = subscriptionRepository
        self.releaseRepository = releaseRepository
        self.notificationService = notificationService
    }

    func loadFor(repo: Repo) async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let subTask = subscriptionRepository.find(repoId: repo.id)
            async let latestTask = releaseRepository.latest(forRepo: repo.id)
            self.subscription = try await subTask
            self.latestRelease = try await latestTask
            errorMessage = nil
        } catch {
            errorMessage = String.l10n("releases.error.loadFailed")
        }
    }

    /// 订阅入口。
    ///
    /// 流程：
    /// 1. 立即拉一页 Releases（priming）
    /// 2. 把"当前最新"作为 lastKnownReleaseId 写库（避免下次轮询补推）
    /// 3. 把所有 priming 拿到的 Release 写库 + 标记为 isRead=true（用户主动订阅，
    ///    不需要把当前已存在的版本当成"未读"高亮）
    /// 4. 异步请求通知授权（首次订阅触发系统对话框）
    func subscribe(owner: String, repo repoName: String, repoId: Int64) async {
        isMutating = true
        defer { isMutating = false }
        do {
            // 首次订阅时取满 GitHub 单页上限，给「活动 → 发行版」聚合详情页提供
            // 尽可能完整的近期历史；不在这里做无限翻页，避免一次订阅消耗过多 rate limit。
            let response = try await apiClient.releases(owner: owner, repo: repoName, perPage: 100)
            let dtos = response.value
            let nowISO = ISO8601DateFormatter.shared.string(from: Date())
            let records = dtos.map { dto in
                ReleaseRecord(
                    id: dto.id,
                    repoId: repoId,
                    tagName: dto.tagName,
                    name: dto.name,
                    bodyMarkdown: dto.body,
                    htmlUrl: dto.htmlUrl,
                    isPrerelease: dto.prerelease,
                    isDraft: dto.draft,
                    publishedAt: dto.publishedAt,
                    createdAtRemote: dto.createdAt,
                    assetsJson: ReleaseAssetCodec.encode(dto.assets?.map(Self.dtoToAsset)),
                    isRead: true,
                    fetchedAt: nowISO
                )
            }

            // priming：取最新 release id 作为游标
            let primingId = dtos.first?.id
            let primingTag = dtos.first?.tagName

            try await subscriptionRepository.subscribe(repoId: repoId, primingReleaseId: primingId, primingTagName: primingTag)
            try await releaseRepository.upsertMany(records, isReadDefault: true)

            // 主动请求一次通知授权（首次订阅时弹系统对话框）
            await notificationService.ensureAuthorized()

            await loadFor(repo: makeRepoStub(id: repoId, owner: owner, name: repoName))
        } catch NetworkError.notFound {
            // 仓库无 Release：仍允许订阅（未来作者发布会被识别为新）
            do {
                try await subscriptionRepository.subscribe(repoId: repoId, primingReleaseId: nil, primingTagName: nil)
                await notificationService.ensureAuthorized()
                await loadFor(repo: makeRepoStub(id: repoId, owner: owner, name: repoName))
            } catch {
                errorMessage = String.l10n("releases.error.subscribeFailed")
            }
        } catch {
            errorMessage = String.l10n("releases.error.subscribeFailed")
        }
    }

    func unsubscribe(repoId: Int64) async {
        isMutating = true
        defer { isMutating = false }
        do {
            try await subscriptionRepository.unsubscribe(repoId: repoId)
            // 重新读一次 → subscription.isSubscribed = false（行保留）
            self.subscription = try await subscriptionRepository.find(repoId: repoId)
        } catch {
            errorMessage = String.l10n("releases.error.unsubscribeFailed")
        }
    }

    func setNotifyEnabled(repoId: Int64, enabled: Bool) async {
        isMutating = true
        defer { isMutating = false }
        do {
            try await subscriptionRepository.setNotifyEnabled(repoId: repoId, enabled: enabled)
            self.subscription = try await subscriptionRepository.find(repoId: repoId)
        } catch {
            errorMessage = String.l10n("releases.error.toggleNotifyFailed")
        }
    }

    // MARK: - 工具

    /// loadFor(repo:) 需要 Repo，但 unsubscribe 之后我们只持有 id。这里造一个 stub
    /// 仅用于 task 的 id 一致性，不参与展示路径。
    private func makeRepoStub(id: Int64, owner: String, name: String) -> Repo {
        Repo(
            id: id, owner: owner, name: name, fullName: "\(owner)/\(name)",
            description: nil, language: nil, starsCount: 0, forksCount: 0, watchersCount: 0,
            topics: nil, license: nil, homepage: nil, htmlUrl: "", cloneUrl: nil, sshUrl: nil,
            isPrivate: false, isFork: false, isArchived: false, isStarred: true,
            pushedAt: nil, createdAt: nil, updatedAt: nil, starredAt: nil, cachedAt: nil
        )
    }

    private static func dtoToAsset(_ dto: GitHubReleaseAssetDTO) -> ReleaseAsset {
        ReleaseAsset(
            id: dto.id,
            name: dto.name,
            contentType: dto.contentType,
            size: dto.size,
            browserDownloadUrl: dto.browserDownloadUrl,
            downloadCount: dto.downloadCount,
            createdAt: dto.createdAt
        )
    }
}
