//
//  RepoReleaseSection.swift
//  Starcat
//
//  Repo 详情页 - Release 订阅段（HOM-47）。
//
//  组件结构：
//  - `RepoReleaseSection` (View)：展示订阅状态 + 最新 Release 概要 + 订阅 / 通知开关
//  - `RepoReleaseSectionViewModel` (@MainActor @Observable)：状态机 + 副作用入口
//
//  设计取舍：
//  - 订阅按钮的"首次按下"会立即拉一次 Release（priming 游标），
//    避免用户后续轮询时被推送一堆历史 Release
//  - 详情页只展示最新一条；完整历史去时间线视图查
//  - 通知开关与订阅状态解耦：用户可"订阅但静默"（默认开启）
//

import SwiftUI

struct RepoReleaseSection: View {

    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies

    @State private var viewModel: RepoReleaseSectionViewModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标题行：与 Tags / Notes 段保持一致——
            // "Releases" Title 后面紧贴 Subscribe / Unsubscribe 按钮（不右对齐），
            // 通知静默开关与右端 ProgressView 用 Spacer 推到行尾，
            // 让"添加 / 修改"类的主操作（订阅）始终贴在 label 旁边。
            HStack(spacing: 8) {
                Label("releases.section.title", systemImage: "shippingbox")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let vm = viewModel {
                    subscribeButton(vm: vm)
                }

                Spacer()

                if let vm = viewModel {
                    if vm.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    if vm.subscription?.isSubscribed == true {
                        notifyToggle(vm: vm)
                    }
                }
            }

            latestReleaseRow
        }
        .task(id: repo.id) {
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

    @ViewBuilder
    private var latestReleaseRow: some View {
        if let vm = viewModel, let latest = vm.latestRelease {
            HStack(spacing: 8) {
                Image(systemName: "tag.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // tag 本身就是跳转入口：蓝色 accent 颜色暗示可点击，配 `.pressableHover()`
                // 与 Stars / Forks 等 Stat Item 一致的 opacity + scale 反馈，
                // 替代原先额外的 `arrow.up.right.square` 跳转图标按钮（dong4j 反馈交互冗余）。
                Button {
                    if let url = URL(string: latest.htmlUrl) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text(verbatim: latest.tagName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pressableHover()
                .help("releases.openOnGitHub")
                if let date = relativeDate(latest.publishedAt) {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(verbatim: date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if let vm = viewModel, vm.errorMessage != nil {
            Text(vm.errorMessage ?? "")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else if viewModel?.isLoading == false {
            Text("releases.section.noRelease")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func subscribeButton(vm: RepoReleaseSectionViewModel) -> some View {
        let subscribed = vm.subscription?.isSubscribed == true
        Button {
            Task {
                if subscribed {
                    await vm.unsubscribe(repoId: repo.id)
                } else {
                    await vm.subscribe(owner: repo.owner, repo: repo.name, repoId: repo.id)
                }
            }
        } label: {
            Label(
                subscribed ? "releases.action.unsubscribe" : "releases.action.subscribe",
                systemImage: subscribed ? "bell.slash" : "bell.badge"
            )
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .focusEffectDisabled()
        .disabled(vm.isMutating)
    }

    @ViewBuilder
    private func notifyToggle(vm: RepoReleaseSectionViewModel) -> some View {
        let notifyOn = vm.subscription?.notifyEnabled == true
        Button {
            Task { await vm.setNotifyEnabled(repoId: repo.id, enabled: !notifyOn) }
        } label: {
            Image(systemName: notifyOn ? "bell.fill" : "bell.slash.fill")
                .font(.caption)
                .foregroundStyle(notifyOn ? Color.accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .focusEffectDisabled()
        .help(notifyOn ? Text("releases.notify.disable") : Text("releases.notify.enable"))
    }

    private func relativeDate(_ iso: String?) -> String? {
        guard let iso, let date = ISO8601DateFormatter.shared.date(from: iso) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
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
            errorMessage = String(localized: "releases.error.loadFailed")
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
            let response = try await apiClient.releases(owner: owner, repo: repoName, perPage: 10)
            let dtos = response.value
            let nowISO = ISO8601DateFormatter.shared.string(from: Date())
            let records = dtos.map { dto in
                ReleaseRecord(
                    id: dto.id,
                    repoId: repoId,
                    tagName: dto.tagName,
                    name: dto.name,
                    bodyTruncated: Self.truncateBody(dto.body),
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
                errorMessage = String(localized: "releases.error.subscribeFailed")
            }
        } catch {
            errorMessage = String(localized: "releases.error.subscribeFailed")
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
            errorMessage = String(localized: "releases.error.unsubscribeFailed")
        }
    }

    func setNotifyEnabled(repoId: Int64, enabled: Bool) async {
        isMutating = true
        defer { isMutating = false }
        do {
            try await subscriptionRepository.setNotifyEnabled(repoId: repoId, enabled: enabled)
            self.subscription = try await subscriptionRepository.find(repoId: repoId)
        } catch {
            errorMessage = String(localized: "releases.error.toggleNotifyFailed")
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

    private static func truncateBody(_ body: String?) -> String? {
        guard let body, !body.isEmpty else { return nil }
        let limit = 600
        return body.count <= limit ? body : String(body.prefix(limit))
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
