//
//  FollowGraphUserCard.swift
//  Starcat
//
//  图谱固定资料卡：复用详情页 OwnerCardView 与公开资料缓存，只为选中用户补全信息。
//  视图身份由节点 ID 决定；异步返回前检查取消，避免快速切换后的旧资料覆盖新用户。
//

import AppKit
import SwiftUI

/// 右下角卡片的内容层；尺寸、滚动和出现 / 关闭动画由图谱宿主统一负责。
struct FollowGraphUserCard: View {
    let node: FollowGraphNode
    @Bindable var model: FollowGraphViewModel
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.locale) private var locale

    @State private var profile: GitHubUserDTO?
    @State private var socialAccounts: [GitHubSocialAccountDTO] = []
    @State private var contribution: ContributionCalendarPayload?
    @State private var followRetry = 0

    var body: some View {
        // 捕获创建该卡片时的画布身份，不能在迟到回调中重新读取新画布的 revision。
        let renderer = model.rendererRevision
        return VStack(alignment: .leading, spacing: 12) {
            OwnerCardView(
                avatarURL: profile?.avatarUrl ?? node.avatarURL,
                displayName: displayName,
                login: node.login,
                bio: profile?.bio,
                followers: profile?.followers,
                following: profile?.following,
                externalLinks: OwnerCardExternalLink.make(profile: profile, socialAccounts: socialAccounts),
                emailAddress: profile?.email,
                contributionPayload: contribution,
                isFollowing: model.followState.values[node.id],
                isCompact: true,
                showsFollowAction: node.id != model.snapshot?.rootID,
                isFollowInFlight: model.followState.inFlight.contains(node.id) ||
                    (model.followState.values[node.id] == nil && model.followState.errors[node.id] == nil),
                isFollowActionEnabled: model.followState.values[node.id] != nil,
                onOpenGitHub: { open(GitHubURLs.userProfile(login: node.login)) },
                onClose: { model.select(nil, expand: false) },
                onOpenExternalLink: open,
                onComposeEmail: composeEmail,
                onOpenFollowers: { open(GitHubURLs.userFollowersTab(login: node.login)) },
                onOpenFollowing: { open(GitHubURLs.userFollowingTab(login: node.login)) },
                onToggleFollow: { model.toggleFollow(node, service: dependencies.ownerFollowService) },
                onAvatarLoaded: { url in
                    Task { @MainActor in
                        guard (try? await FollowGraphAvatarCache.shared.promoteCardImage(from: url)) == true else { return }
                        model.avatarDidLoad(nodeID: node.id, source: url.absoluteString, renderer: renderer)
                    }
                }
            )

            if let error = model.followState.errors[node.id] {
                HStack(alignment: .top) {
                    Text(verbatim: error.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("action.retry") {
                        switch error {
                        case .query: followRetry += 1
                        case .write:
                            model.toggleFollow(node, service: dependencies.ownerFollowService)
                        }
                    }
                    .disabled(model.followState.inFlight.contains(node.id))
                }
            }

            Divider()

            // 操作与对应信息同排，保留按钮命中尺寸；长路径换行而不挤压定位入口。
            HStack(alignment: .center, spacing: 10) {
                Text(verbatim: model.path.compactMap { model.snapshot?.nodes[$0]?.login }.joined(separator: " → "))
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button { model.focus(node.id) } label: {
                    Label("followGraph.action.locate", systemImage: "scope")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("followGraph.action.locate")
            }

            HStack(alignment: .center, spacing: 10) {
                Text(verbatim: loadCountLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(loadCountLabel + "\n" + String.l10n(loadStateKey))
                Spacer(minLength: 0)
                if model.canLoadMore(node.id, fallbackTotal: relationTotal) {
                    Button("followGraph.action.more") { model.loadMore(node.id, fallbackTotal: relationTotal) }
                        .fixedSize()
                        .disabled(model.isLoading || model.isRevealingRelations(for: node.id))
                }
            }
        }
        .padding(16)
        // 独立的视图任务先到先显示，并随节点身份销毁取消；不把 SwiftUI 状态送入任务组。
        .task(id: node.id) {
            let value = try? await dependencies.ownerFollowService.profile(login: node.login)
            guard !Task.isCancelled else { return }
            profile = value
        }
        .task(id: node.id) {
            let value = try? await dependencies.ownerFollowService.socialAccounts(login: node.login)
            guard !Task.isCancelled else { return }
            socialAccounts = value ?? []
        }
        .task(id: node.id) {
            let value = try? await dependencies.ownerFollowService.contribution(login: node.login)
            guard !Task.isCancelled else { return }
            contribution = value
        }
        .task(id: followRetry) {
            guard node.id != model.snapshot?.rootID else { return }
            await model.followState.load(node, service: dependencies.ownerFollowService)
        }
    }

    private var displayName: String {
        if let name = profile?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return node.name ?? node.login
    }

    /// 分页总数优先；尚未查询该用户时，按当前图谱方向复用已取得的公开资料人数。
    private var relationTotal: Int? {
        let graph = model.displayedSnapshot
        return graph?.progress[node.id]?.totalCount ??
            (graph?.relation == .followers ? profile?.followers : profile?.following)
    }

    private var loadCountLabel: String {
        let loaded = model.renderedRelationCount(for: node.id).formatted(.number.locale(locale))
        if let total = relationTotal {
            return String(format: .l10n("followGraph.status.loadedCountKnown"), locale: locale,
                          arguments: [loaded, total.formatted(.number.locale(locale))])
        }
        return String(format: .l10n("followGraph.status.loadedCount"), locale: locale, arguments: [loaded])
    }

    private var loadStateKey: String {
        guard model.displayedSnapshot?.progress[node.id]?.complete == true else { return "followGraph.status.partial" }
        return model.snapshot?.relation == .followers ? "followGraph.status.followersComplete" : "followGraph.status.complete"
    }

    private func open(_ url: URL) { NSWorkspace.shared.open(url) }

    private func composeEmail() {
        guard let email = profile?.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty, let url = URL(string: "mailto:\(email)") else { return }
        open(url)
    }
}
