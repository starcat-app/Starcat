// 标签图谱的右下角资料卡。外壳、紧凑头部和操作沿用关注者图谱。
import AppKit
import GRDB
import SwiftUI

/// 标签显示当前归属页的进度，仓库按需读取当前账户的本地资料。
struct TagGraphNodeCard: View {
    let node: TagGraphNode
    let model: TagGraphViewModel
    let reader: any DatabaseReader
    let isCurrent: () -> Bool
    let onLocate: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var repo: Repo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FollowGraphCardHeader(title: repo?.name ?? node.name,
                                  subtitle: node.kind == .repo ? repo?.owner : nil,
                                  onClose: { model.select(nil) }) {
                avatar
            } actions: {
                if node.kind == .repo {
                    FollowGraphGitHubButton { NSWorkspace.shared.open(GitHubURLs.repo(fullName: node.name)) }
                }
            }
            if let description = repo?.description, !description.isEmpty {
                Text(verbatim: description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(description)
            }
            Divider()
            HStack(spacing: 10) {
                creationDate
                Spacer(minLength: 4)
                FollowGraphLocateButton(action: onLocate)
            }
            if node.kind == .tag {
                pageProgress
            } else if let repo {
                HStack(spacing: 14) {
                    Label {
                        Text(repo.starsCount, format: .number)
                    } icon: {
                        Image(systemName: "star")
                    }
                    .accessibilityLabel(Text("repo.stats.stars"))
                    .accessibilityValue(Text(repo.starsCount, format: .number))
                    if let language = repo.language, !language.isEmpty {
                        Label(language, systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .task(id: node.id) { await loadRepo() }
    }

    @ViewBuilder private var avatar: some View {
        if node.kind == .tag {
            let color = node.color.flatMap(Color.init(hex:)) ?? .accentColor
            ZStack {
                Circle().fill(color.opacity(0.18))
                Circle().strokeBorder(color.opacity(0.30), lineWidth: 1)
                Image(systemName: node.icon ?? "tag")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.primary)
            }
        } else {
            RemoteAvatar(urlString: node.avatarURL, size: 56, fallbackSymbol: "book.closed", showBorder: false)
        }
    }

    private var creationDate: some View {
        let date = node.kind == .tag ? model.tagCreationDate(node.id) :
            ISO8601DateFormatter.githubDate(from: repo?.createdAt)
        return HStack(spacing: 8) {
            Label("repo.stats.created", systemImage: "calendar.badge.plus")
                .foregroundStyle(.secondary)
            if let date {
                Text(date, format: .dateTime.year().month(.abbreviated).day().locale(locale))
                    .monospacedDigit()
            } else {
                Text(verbatim: "—").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    /// 数字由 Canvas 确认。维持相同的「更多」按钮样式，尾页入场后自动收起。
    private var pageProgress: some View {
        let loaded = model.renderedMembershipCount
        let total = model.totalCount(for: node.id)
        let format = String.l10n("tagGraph.card.loadedCount")
        let count = String(format: format, locale: locale,
                           arguments: [loaded.formatted(.number.locale(locale)),
                                       total.formatted(.number.locale(locale))])
        return HStack(spacing: 10) {
            Text(verbatim: count)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: loaded)
            Spacer(minLength: 0)
            if model.hasMore(for: node.id) {
                FollowGraphMoreButton { model.loadMore(node.id) }
                    .disabled(model.isRevealing(node.id))
            }
        }
    }

    /// 卡片销毁或切号时放弃结果，避免快速选换时把旧仓库资料呈现到新账户。
    private func loadRepo() async {
        guard node.kind == .repo, isCurrent(), let id = Int64(node.id.dropFirst("repo:".count)) else { return }
        let value = try? await reader.read { try Repo.fetchOne($0, key: id) }
        guard !Task.isCancelled, isCurrent(), model.selectedID == node.id else { return }
        repo = value
    }
}
