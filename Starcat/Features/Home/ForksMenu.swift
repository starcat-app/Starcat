//
//  ForksMenu.swift
//  Starcat
//
//  详情页 Forks 数字的点击分流，以及第二行 license 后的「Forked from」。
//
//  为什么跟 WatchersMenu 分文件：
//  - Watchers 只有订阅三态；Forks 要按所有权分成三种点击，自己的 fork 还要
//    拉 parent + ahead/behind，并可能 POST merge-upstream。
//  - 会话缓存必须让菜单和 “Forked from” 行共用同一次请求，避免点进详情打两遍。
//
//  关键约束：
//  - 私仓走 `projectGitHubAPIClient`（GitHub App token）；公开仓走 OAuth。
//  - Sync 409/422 打开 GitHub 网页，不在 App 里丢弃用户提交。
//  - ahead/behind 不入库，只放进程内缓存。
//

import SwiftUI
import AppKit

/// 详情页 Forks 统计列。别人的仓直接打开 fork 页；自己的原创仓打开网络页；自己的 fork 出菜单。
struct ForksMenu: View {
    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(\.colorScheme) private var colorScheme

    @State private var store = ForkRelationSessionStore.shared
    @State private var loadFailed = false
    @State private var isSyncing = false

    private var relation: GitHubForkRelation? {
        store.relation(for: repo.id)
    }

    private var kind: RepoForkStatKind {
        RepoForkStatKindResolver.kind(
            isFork: repo.isFork,
            repoOwner: repo.owner,
            currentLogin: authSession.state.user?.login
        )
    }

    private var forkTint: Color {
        if relation?.needsSync == true {
            return .orange
        }
        return StatSemanticColor.fork.resolved(colorScheme: colorScheme)
    }

    var body: some View {
        Group {
            switch kind {
            case .forkOthersRepo:
                forkPageButton(helpKey: "repo.forkAction")
            case .viewOwnForks:
                networkButton
            case .manageOwnFork:
                ownForkMenu
            }
        }
        .task(id: repo.id) {
            await loadRelationIfNeeded()
        }
    }

    private var networkButton: some View {
        Button {
            NSWorkspace.shared.open(GitHubURLs.repoNetworkMembers(owner: repo.owner, repo: repo.name))
        } label: {
            statLabel
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help("repo.fork.ownRepoHelp")
    }

    private func forkPageButton(helpKey: LocalizedStringKey) -> some View {
        Button {
            NSWorkspace.shared.open(GitHubURLs.repoFork(owner: repo.owner, repo: repo.name))
        } label: {
            statLabel
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help(helpKey)
    }

    private var ownForkMenu: some View {
        Menu {
            if let relation {
                // hero 第二行已经写了 Fork 自哪个仓，菜单不再重复来源。
                if let statusLine = Self.statusLine(for: relation) {
                    Text(statusLine)
                    Divider()
                }

                Button {
                    NSWorkspace.shared.open(Self.contributeURL(repo: repo, relation: relation))
                } label: {
                    Label("repo.fork.contribute", systemImage: "plus.bubble")
                }
                .disabled(!relation.canContribute)

                Button {
                    Task { await syncFork(relation) }
                } label: {
                    Label("repo.fork.sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!relation.needsSync || isSyncing)

                Divider()

                Button {
                    NSWorkspace.shared.open(GitHubURLs.repo(fullName: repo.fullName))
                } label: {
                    Label("repo.fork.viewOnGitHub", systemImage: "safari")
                }
            } else if loadFailed {
                Button("action.retry") {
                    Task { await loadRelationIfNeeded(force: true) }
                }
            } else {
                Text("repo.fork.loading")
            }
        } label: {
            statLabel
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help("repo.fork.ownForkHelp")
    }

    private var statLabel: some View {
        RepoStatItem(
            label: "repo.stats.forks",
            value: repo.forksCount,
            businessIcon: .forkCount,
            tint: forkTint
        )
    }

    private func githubClient() -> any GitHubAPIClientProtocol {
        repo.isPrivate ? dependencies.projectGitHubAPIClient : dependencies.apiClient
    }

    private func loadRelationIfNeeded(force: Bool = false) async {
        guard repo.isFork else { return }
        if !force, store.relation(for: repo.id) != nil {
            loadFailed = false
            return
        }

        let requestedId = repo.id
        if !force {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }

        let loaded = await store.load(repoId: requestedId, force: force) {
            do {
                return try await self.githubClient().forkRelation(
                    owner: self.repo.owner,
                    repo: self.repo.name,
                    restFallback: !force
                )
            } catch {
                AppLog.network.error(
                    "Fork relation load failed for \(self.repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
        guard repo.id == requestedId else { return }
        loadFailed = loaded == nil && store.relation(for: requestedId) == nil
    }

    private func syncFork(_ current: GitHubForkRelation) async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            // merge-upstream 是同步 HTTP：200 时 Git 已经快进/合并完，没有后台 job 可轮询。
            _ = try await githubClient().mergeUpstream(
                owner: repo.owner,
                repo: repo.name,
                branch: current.forkDefaultBranch
            )
            // 先保留 parent + behind=0，再后台刷新 compare。绝不能 clear()，
            // 否则 ForkedFromCaption 会在空窗里显示「上游不可用」。
            store.replace(current.markingUpstreamSynced(), for: repo.id)
            await loadRelationIfNeeded(force: true)
            // GitHub 读副本偶发仍返回旧 behind；最多再问一次 compare，不是轮询 merge。
            if store.relation(for: repo.id)?.needsSync == true {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await loadRelationIfNeeded(force: true)
            }
        } catch {
            if case NetworkError.clientError(let statusCode, _) = error,
               statusCode == 409 || statusCode == 422 {
                NSWorkspace.shared.open(GitHubURLs.repo(fullName: repo.fullName))
            } else {
                AppLog.network.error(
                    "Sync fork failed for \(self.repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                NSWorkspace.shared.open(GitHubURLs.repo(fullName: repo.fullName))
            }
        }
    }

    static func contributeURL(repo: Repo, relation: GitHubForkRelation) -> URL {
        GitHubURLs.forkContribute(
            parentOwner: relation.parentOwner,
            parentRepo: relation.parentRepoName,
            parentBranch: relation.parentDefaultBranch,
            forkOwner: repo.owner,
            forkRepo: repo.name,
            forkBranch: relation.forkDefaultBranch
        )
    }

    static func statusLine(for relation: GitHubForkRelation) -> String? {
        switch (relation.aheadBy, relation.behindBy) {
        case (nil, nil):
            return nil
        case (0, 0):
            return String.l10n("repo.fork.upToDate")
        case (let ahead?, 0):
            return String(format: String.l10n("repo.fork.aheadFormat"), ahead)
        case (0, let behind?):
            return String(format: String.l10n("repo.fork.behindFormat"), behind)
        case (let ahead?, let behind?):
            return String(format: String.l10n("repo.fork.aheadBehindFormat"), ahead, behind)
        default:
            if let ahead = relation.aheadBy {
                return String(format: String.l10n("repo.fork.aheadFormat"), ahead)
            }
            if let behind = relation.behindBy {
                return String(format: String.l10n("repo.fork.behindFormat"), behind)
            }
            return nil
        }
    }
}

/// 详情第二行、license 后的 “Forked from owner/repo”。
/// 替代灰色 Fork 胶囊：来源本身就是 fork 身份，不必再占一颗标签。
struct ForkedFromCaption: View {
    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    @State private var store = ForkRelationSessionStore.shared
    @State private var didFinishLoad = false

    private var relation: GitHubForkRelation? {
        store.relation(for: repo.id)
    }

    var body: some View {
        Group {
            if let relation {
                HStack(spacing: 6) {
                    BusinessIcon(.forkedRepository, pointSize: 11 * interfaceScale.multiplier)
                        .foregroundStyle(relation.needsSync ? Color.orange : Color.secondary)
                    Button {
                        NSWorkspace.shared.open(relation.parentHTMLURL)
                    } label: {
                        Text(String(format: String.l10n("repo.fork.forkedFromFormat"), relation.parentFullName))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .pressableHover(scale: 1.0)
                    .help("repo.fork.openParent")

                    if let status = ForksMenu.statusLine(for: relation) {
                        Text(verbatim: "·")
                            .foregroundStyle(.secondary)
                        Text(verbatim: status)
                            .foregroundStyle(relation.needsSync ? Color.orange : Color.secondary)
                    }
                }
                .font(interfaceScale.font(.captionSmall))
                .lineLimit(1)
            } else if didFinishLoad {
                HStack(spacing: 6) {
                    BusinessIcon(.forkedRepository, pointSize: 11 * interfaceScale.multiplier)
                        .foregroundStyle(.secondary)
                    Text("repo.fork.parentUnavailable")
                        .foregroundStyle(.secondary)
                }
                .font(interfaceScale.font(.captionSmall))
            } else {
                HStack(spacing: 6) {
                    BusinessIcon(.forkedRepository, pointSize: 11 * interfaceScale.multiplier)
                        .foregroundStyle(.secondary)
                    Text("repo.fork.loading")
                        .foregroundStyle(.secondary)
                }
                .font(interfaceScale.font(.captionSmall))
            }
        }
        .task(id: repo.id) {
            await loadRelation()
        }
    }

    private func githubClient() -> any GitHubAPIClientProtocol {
        repo.isPrivate ? dependencies.projectGitHubAPIClient : dependencies.apiClient
    }

    private func loadRelation() async {
        didFinishLoad = false
        let requestedId = repo.id
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        _ = await store.load(repoId: requestedId) {
            do {
                return try await githubClient().forkRelation(owner: repo.owner, repo: repo.name)
            } catch {
                return nil
            }
        }
        guard repo.id == requestedId else { return }
        didFinishLoad = true
    }
}

/// 进程内 fork 快照。`@Observable` 是为了 Sync 成功后标题行和菜单同时刷新。
///
/// 关键约束：
/// - 失败 / 取消不得把已有 parent 清掉，否则第二行会闪「上游不可用」。
/// - force 刷新必须换新的 inFlight，不能复用同步前那一次 compare。
@MainActor
@Observable
final class ForkRelationSessionStore {
    static let shared = ForkRelationSessionStore()

    private(set) var snapshots: [Int64: GitHubForkRelation] = [:]
    @ObservationIgnored private var inFlight: [Int64: LoadTicket] = [:]

    private struct LoadTicket {
        let id: UUID
        let task: Task<GitHubForkRelation?, Never>
    }

    func relation(for repoId: Int64) -> GitHubForkRelation? {
        snapshots[repoId]
    }

    func replace(_ relation: GitHubForkRelation, for repoId: Int64) {
        snapshots[repoId] = relation
    }

    func load(
        repoId: Int64,
        force: Bool = false,
        loader: @escaping () async -> GitHubForkRelation?
    ) async -> GitHubForkRelation? {
        if !force, let cached = snapshots[repoId] {
            return cached
        }
        if force {
            inFlight[repoId]?.task.cancel()
            inFlight[repoId] = nil
        } else if let existing = inFlight[repoId] {
            return await existing.task.value ?? snapshots[repoId]
        }

        let ticket = LoadTicket(id: UUID(), task: Task { await loader() })
        inFlight[repoId] = ticket
        let result = await ticket.task.value
        let isCurrent = inFlight[repoId]?.id == ticket.id
        if isCurrent {
            inFlight[repoId] = nil
            if let result {
                apply(result, for: repoId)
            }
        }
        return snapshots[repoId] ?? result
    }

    /// 新结果缺 compare 数字时，保留界面上已经亮着的 ahead/behind（含 Sync 后的乐观 0）。
    private func apply(_ result: GitHubForkRelation, for repoId: Int64) {
        if result.aheadBy == nil, result.behindBy == nil, let existing = snapshots[repoId] {
            snapshots[repoId] = result.withCompare(aheadBy: existing.aheadBy, behindBy: existing.behindBy)
            return
        }
        snapshots[repoId] = result
    }
}
