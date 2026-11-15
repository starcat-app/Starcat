//
//  RepoContributorsStatItem.swift
//  Starcat
//
//  详情 Hero stats 行的贡献者列：top 3 重叠头像 + 溢出人数，点击弹出样本名单。
//
//  关键约束：
//  - 整列一个按钮，头像不各自跳 GitHub，避免和「点开看全部」抢手势。
//  - Popover 必须 `.appLocaleEnvironment()`，关闭钮走 `SheetCloseButton`。
//  - `+x` 相对 GitHub 前 12 人样本，不是仓库全量贡献者人数。
//  - 趋势本周贡献者经常为空；本列展示 GitHub all-time 样本，所有详情场景都开。
//  - 占比条和右侧百分比都相对样本 commits 合计（合计为 100%），第一名 80% 就不能画成满格。
//

import SwiftUI
import AppKit

/// Hero stats 行最末列的贡献者 facepile。
struct RepoContributorsStatItem: View {
    let repo: Repo

    @Environment(AuthSession.self) private var authSession
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    /// 百分比列只按「100.0%」预留，避免再给条和数字之间塞出一块空列。
    private static let percentColumnWidth: CGFloat = 44

    @State private var viewModel: RepositoryContributorHeroViewModel
    @State private var isPopoverPresented = false
    @State private var hoveredContributorID: String?

    init(repo: Repo, service: any RepositoryContributorHeroServing) {
        self.repo = repo
        _viewModel = State(initialValue: RepositoryContributorHeroViewModel(service: service))
    }

    var body: some View {
        Group {
            if viewModel.shouldShowColumn {
                contributorButton
            } else {
                // 空 Group 在 macOS 上会被优化出渲染树，`.task` 不再调度。
                // 1pt 占位只在确认无样本后出现，不影响 stats 行视觉。
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
        }
        .task(id: repo.id) {
            isPopoverPresented = false
            hoveredContributorID = nil
            await viewModel.load(
                repo: repo,
                isAuthenticated: authSession.state.isAuthenticated
            )
        }
    }

    private var contributorButton: some View {
        Button {
            guard !viewModel.contributors.isEmpty else { return }
            isPopoverPresented = true
        } label: {
            VStack(alignment: .center, spacing: 2) {
                facepile
                Text("repo.contributors")
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help("repo.contributors.help")
        .disabled(viewModel.contributors.isEmpty)
        .accessibilityLabel(Text("repo.contributors"))
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .fixedSize()
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            contributorsPopover
                .appLocaleEnvironment()
        }
    }

    @ViewBuilder
    private var facepile: some View {
        HStack(spacing: 0) {
            HStack(spacing: -8) {
                if viewModel.contributors.isEmpty {
                    ForEach(0..<RepositoryContributorHeroViewModel.visibleAvatarLimit, id: \.self) { index in
                        placeholderAvatar
                            .zIndex(Double(RepositoryContributorHeroViewModel.visibleAvatarLimit - index))
                    }
                } else {
                    ForEach(Array(viewModel.visibleAvatars.enumerated()), id: \.element.id) { index, contributor in
                        contributorAvatar(contributor)
                            .zIndex(Double(viewModel.visibleAvatars.count - index))
                    }
                }
            }
            if viewModel.overflowCount > 0 {
                Text(verbatim: "+\(viewModel.overflowCount)")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.leading, 6)
            }
        }
        .frame(height: 22)
    }

    private var placeholderAvatar: some View {
        Circle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 22, height: 22)
            .overlay(
                Circle()
                    .stroke(Color(nsColor: .controlBackgroundColor).opacity(0.9), lineWidth: 2)
            )
    }

    private func contributorAvatar(_ contributor: RepositoryContributor) -> some View {
        RemoteAvatar(
            urlString: contributor.avatarURL?.absoluteString,
            size: 22,
            showBorder: false
        )
        .overlay(
            Circle()
                .stroke(Color(nsColor: .controlBackgroundColor).opacity(0.9), lineWidth: 2)
        )
        .help(Text(verbatim: contributor.login))
    }

    private var contributorsPopover: some View {
        let ranked = viewModel.contributors
        let total = RepositoryContributorHeroViewModel.sampleTotal(ranked)

        return VStack(alignment: .leading, spacing: 12) {
            popoverHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(ranked.enumerated()), id: \.element.id) { index, contributor in
                        contributorRow(
                            contributor,
                            rank: index + 1,
                            sampleShare: RepositoryContributorHeroViewModel.sampleShare(
                                commits: contributor.commits,
                                total: total
                            )
                        )
                        .listRowSurface(index: index)
                        if index < ranked.count - 1 {
                            Divider()
                        }
                    }
                }
                // macOS overlay 滚动条会盖在内容上；百分比右对齐，给滚动槽让出宽度。
                .padding(.trailing, 10)
            }
            .frame(maxHeight: 360)

            popoverFooter
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }

    private var popoverHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.2.fill")
                .font(interfaceScale.font(.iconLarge))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("repo.contributors")
                    .font(interfaceScale.font(.bodyEmphasis, weight: .semibold))
                Text("repo.contributors.subtitle")
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            SheetCloseButton(
                action: { isPopoverPresented = false },
                iconFont: .system(size: 16, weight: .medium),
                frameSize: 22
            )
        }
    }

    private var popoverFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(alignment: .center, spacing: 10) {
                Image("github")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("repo.contributors.sampleFootnote")
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                viewAllContributorsButton
                    .layoutPriority(1)
            }
        }
    }

    private var viewAllContributorsButton: some View {
        Button {
            isPopoverPresented = false
            NSWorkspace.shared.open(
                GitHubURLs.repoContributors(owner: repo.owner, repo: repo.name)
            )
        } label: {
            HStack(spacing: 4) {
                Text("repo.contributors.viewAll")
                    .lineLimit(1)
                Image(systemName: "arrow.right")
            }
            .font(interfaceScale.font(.caption, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .fixedSize()
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover(scale: 1.0)
        .help("repo.contributors.viewAllHelp")
        .accessibilityLabel(Text("repo.contributors.viewAll"))
    }

    private func contributorRow(
        _ contributor: RepositoryContributor,
        rank: Int,
        sampleShare: Double
    ) -> some View {
        let isHovered = hoveredContributorID == contributor.id
        let isOwner = RepositoryContributorHeroViewModel.isOwner(
            login: contributor.login,
            repoOwner: repo.owner
        )
        return Button {
            isPopoverPresented = false
            NSWorkspace.shared.open(profileURL(for: contributor))
        } label: {
            HStack(alignment: .center, spacing: 8) {
                rankBadge(rank: rank)
                RemoteAvatar(
                    urlString: contributor.avatarURL?.absoluteString,
                    size: 28,
                    showBorder: false
                )
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: contributor.login)
                            .font(interfaceScale.font(.caption, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if isOwner {
                            ownerBadge
                        }
                        Spacer(minLength: 8)
                        commitsLabel(contributor.commits)
                    }
                    HStack(spacing: 6) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary.opacity(0.08))
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.85))
                                    .frame(width: max(4, proxy.size.width * sampleShare))
                            }
                        }
                        .frame(height: 6)
                        Text(verbatim: formattedPercent(sampleShare))
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: Self.percentColumnWidth, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(rowBackground(isHovered: isHovered))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering in
            if hovering {
                hoveredContributorID = contributor.id
            } else if hoveredContributorID == contributor.id {
                hoveredContributorID = nil
            }
        }
    }

    /// 前三名用领奖台色块编码名次（1 金+皇冠、2 银灰、3 铜橙），这是数据层级不是装饰。
    /// 数字本身仍走 `.primary` / `.secondary`，满足文字对比度。
    private func rankBadge(rank: Int) -> some View {
        let podiumFill: Color? = {
            switch rank {
            case 1: return Color.yellow
            case 2: return Color.primary
            case 3: return Color.orange
            default: return nil
            }
        }()

        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill((podiumFill ?? Color.primary).opacity(rank <= 3 ? 0.18 : 0.0))
            Text(verbatim: "\(rank)")
                .font(interfaceScale.font(.captionSmall, weight: rank <= 3 ? .semibold : .regular))
                .foregroundStyle(rank <= 3 ? .primary : .secondary)
                .monospacedDigit()
        }
        .overlay(alignment: .top) {
            if rank == 1 {
                Image(systemName: "crown.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.yellow)
                    .offset(y: -5)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private var ownerBadge: some View {
        Text("repo.contributors.owner")
            .font(interfaceScale.font(.captionSmall, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .accessibilityLabel(Text("repo.contributors.owner"))
    }

    private func commitsLabel(_ commits: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(verbatim: commits.formatted(.number.locale(locale)))
                .font(interfaceScale.font(.body, weight: .semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
            Text("repo.contributors.commitsUnit")
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
        }
        .layoutPriority(1)
    }

    /// hover 用 accent 浅底贴合选中态，不用斑马纹，避免和原型的细分隔线打架。
    private func rowBackground(isHovered: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private func formattedPercent(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(1)).locale(locale))
    }

    private func profileURL(for contributor: RepositoryContributor) -> URL {
        if let profileHTMLURL = contributor.profileHTMLURL {
            return profileHTMLURL
        }
        return GitHubURLs.userProfile(login: contributor.login)
    }

    private var accessibilityValue: String {
        if viewModel.contributors.isEmpty {
            return ""
        }
        let names = viewModel.visibleAvatars.map(\.login).joined(separator: ", ")
        if viewModel.overflowCount > 0 {
            return "\(names) +\(viewModel.overflowCount)"
        }
        return names
    }
}
