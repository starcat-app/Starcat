//
//  RecommendationHistoryDetailView.swift
//  Starcat
//
//  历史仅补充推荐事实与反馈，README、Star、洞察继续复用现有探索详情。
//

import SwiftUI
import AppKit
import Kingfisher

/// 保持中栏历史选择，不通过 openCompanionRepository 跳回星标管理页。
struct RecommendationHistoryDetailView: View {
    let entry: RecommendationHistoryEntry?
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.locale) private var locale
    private var explanationIdentity: String {
        "\(dependencies.database.currentUserId ?? 0)|\(dependencies.databaseScopeRevision)|\(entry?.id ?? 0)|\(locale.identifier)|\(dependencies.entitlementGate.isProUser)"
    }

    var body: some View {
        if let entry, let item = entry.item {
            DiscoveryDetailView(
                item: item.historyDiscoveryItem,
                supplementalHeader: AnyView(historyHeader(entry, item: item)),
                requiresCompleteMetadata: true
            )
            .task(id: explanationIdentity) {
                guard let accountID = dependencies.database.currentUserId else { return }
                await dependencies.dailyRecommendationExplanationStore.loadSaved(
                    items: [item], accountID: accountID, revision: dependencies.databaseScopeRevision,
                    locale: locale.identifier, isPro: dependencies.entitlementGate.isProUser
                )
            }
        } else if entry != nil {
            ContentUnavailableView("recommendations.history.unavailable", systemImage: "archivebox")
        } else {
            RepoDetailNoSelectionPlaceholder(messageKey: "explore.detail.empty")
        }
    }

    /// 折叠状态绑定所选项目，切到另一条历史时恢复折叠，把视口留给 README。
    private func historyHeader(_ entry: RecommendationHistoryEntry, item: RepoRecommendationItem) -> some View {
        RecommendationEvidenceHeader(entry: entry, item: item)
            .id(entry.id)
    }
}

/// 沿用 Awesome「收录来源」的整行展开交互；反馈按钮独立，不能点击反馈时误展开。
private struct RecommendationEvidenceHeader: View {
    let entry: RecommendationHistoryEntry
    let item: RepoRecommendationItem
    @Environment(AppDependencies.self) private var dependencies
    @Environment(HomeViewModel.self) private var homeViewModel
    @Environment(\.locale) private var locale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var openingSourceID: Int64?
    @State private var sourceTask: Task<Void, Never>?
    @State private var sourceError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        BusinessIcon(.recommendations, pointSize: 16).foregroundStyle(.secondary)
                        Text("recommendations.daily.reasonTitle").font(.headline)
                        if let sources = item.matchedSeeds, !sources.isEmpty {
                            Text(sources.count, format: .number).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if !isExpanded, let name = item.matchedSeeds?.first?.fullName {
                            Text(verbatim: name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityValue(Text(LocalizedStringKey(isExpanded ? "settings.general.disclosure.expanded" : "settings.general.disclosure.collapsed")))
                feedbackButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let explanation = dependencies.dailyRecommendationExplanationStore.text(
                        for: item, locale: locale.identifier, isPro: dependencies.entitlementGate.isProUser
                    ) {
                        evidenceText(explanation)
                    } else {
                        evidenceText(item.basicRecommendationReason)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .toast(message: $sourceError, icon: "exclamationmark.triangle")
        .onDisappear { sourceTask?.cancel() }
    }

    /// 来源只认服务端提供的真实项目，链接仍交给独立详情窗口，避免改变每日推荐选中项。
    private func evidenceText(_ text: String) -> some View {
        RecommendationEvidenceText(
            markdown: RecommendationEvidenceMarkdown.make(text: text, sources: item.matchedSeeds ?? []),
            sources: item.matchedSeeds ?? []
        )
            .environment(\.openURL, OpenURLAction { url in
                guard let source = item.matchedSeeds?.first(where: {
                    url == GitHubURLs.repo(fullName: $0.fullName)
                }) else { return .handled }
                openSource(source)
                return .handled
            })
    }

    /// 查询和公开资料补齐都不改主窗口选择；异步完成后只把 Repo 交给独立窗口。
    private func openSource(_ source: RecommendationSeed) {
        guard openingSourceID == nil else { return }
        let parts = source.fullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        openingSourceID = source.repoID
        sourceError = nil
        let revision = dependencies.databaseScopeRevision
        sourceTask = Task {
            defer { openingSourceID = nil }
            do {
                let repo = try await PublicRepoMetadataResolver.resolve(
                    owner: parts[0], name: parts[1],
                    repository: dependencies.repoRepository, apiClient: dependencies.apiClient,
                    isCurrent: { dependencies.databaseScopeRevision == revision }
                )
                try Task.checkCancellation()
                RepoDetailWindowController.show(repo: repo, dependencies: dependencies, homeViewModel: homeViewModel)
            } catch is CancellationError {
                return
            } catch {
                sourceError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var feedbackButton: some View {
        if entry.feedback(starredIDs: dependencies.starredRegistry.ids) == .dismissed {
            Button("recommendations.history.restore") {
                Task { await dependencies.dailyRecommendationStore.restoreInterest(entry.id) }
            }
        } else if !dependencies.starredRegistry.contains(ghRepoId: entry.id) {
            Button("recommendations.history.dismissed") {
                Task { await dependencies.dailyRecommendationStore.dismiss(entry.id) }
            }
        }
    }
}

/// 推荐理由是纯正文加受控项目链接；原生附件让头像和链接共用文字排版、换行及链接光标。
/// MarkdownUI 会把链接内的图片走 AttributedString 路径丢弃，不能仅靠补 Markdown 图片修复。
struct RecommendationEvidenceText: View {
    let markdown: String
    let sources: [RecommendationSeed]
    @Environment(\.openURL) private var openURL
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var avatars: [String: NSImage] = [:]

    var body: some View {
        RecommendationEvidenceNativeText(
            content: Self.attributedContent(
                markdown: markdown,
                avatars: avatars,
                fontSize: interfaceScale.scaled(RAGConversationTypography.answerText.pointSize)
            ),
            onOpen: { openURL($0) }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: sources.map(\.fullName)) {
            // 共用列表头像的 Kingfisher 缓存；请求失败仍保留行内占位，不让其他头像一起消失。
            let owners = Set(sources.compactMap { $0.fullName.split(separator: "/").first.map(String.init) })
            for owner in owners {
                guard !Task.isCancelled,
                      let url = GitHubAvatarURL.imageURL(from: RepoAvatarURL.from(owner: owner), displayDiameter: 14)
                else { continue }
                let image: NSImage? = try? await withCheckedThrowingContinuation { continuation in
                    KingfisherManager.shared.retrieveImage(with: url) { result in
                        continuation.resume(with: result.map(\.image))
                    }
                }
                guard !Task.isCancelled else { return }
                if let image { avatars[owner.lowercased()] = image }
            }
        }
    }

    /// 链接属性覆盖头像附件和完整 owner/repo；正文不注册手型区域，也不自动识别模型外链。
    static func attributedContent(markdown: String, avatars: [String: NSImage], fontSize: CGFloat) -> NSAttributedString {
        let parsed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
        let result = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * 0.22
        let avatarSize = fontSize * 14 / RAGConversationTypography.answerText.pointSize
        result.addAttributes([
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ], range: NSRange(location: 0, length: result.length))
        var links: [(NSRange, URL)] = []
        result.enumerateAttribute(.link, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if let url = value as? URL { links.append((range, url)) }
        }
        // 倒序插入附件，保留尚未处理的链接范围。
        for (range, url) in links.reversed() {
            guard let owner = url.pathComponents.dropFirst().first else { continue }
            let source = avatars[owner.lowercased()]
                ?? NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
                ?? NSImage(size: CGSize(width: avatarSize, height: avatarSize))
            let thumbnail = NSImage(size: CGSize(width: avatarSize, height: avatarSize))
            thumbnail.lockFocus()
            NSBezierPath(ovalIn: NSRect(origin: .zero, size: thumbnail.size)).addClip()
            source.draw(in: NSRect(origin: .zero, size: thumbnail.size))
            thumbnail.unlockFocus()
            let attachment = NSTextAttachment()
            attachment.image = thumbnail
            attachment.bounds = NSRect(x: 0, y: -avatarSize / 7, width: avatarSize, height: avatarSize)
            let prefix = NSMutableAttributedString(attachment: attachment)
            prefix.append(NSAttributedString(string: "\u{00a0}"))
            prefix.addAttributes([
                .link: url, .font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: paragraph
            ], range: NSRange(location: 0, length: prefix.length))
            result.insert(prefix, at: range.location)
        }
        return result
    }
}

/// NSTextView 只负责行内排版和系统链接交互；点击由 SwiftUI 的 openURL 环境继续分流。
private struct RecommendationEvidenceNativeText: NSViewRepresentable {
    let content: NSAttributedString
    let onOpen: (URL) -> Void

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isAutomaticLinkDetectionEnabled = false
        view.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.onOpen = onOpen
        if view.attributedString() != content {
            view.textStorage?.setAttributedString(content)
        }
    }

    /// 使用正文实际容器宽度测高，避免固定高度在窄详情栏或大字号时裁掉最后一行。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let container = nsView.textContainer, let layout = nsView.layoutManager else {
            return nil
        }
        container.containerSize = CGSize(width: max(1, width), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(onOpen: onOpen) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpen: (URL) -> Void
        init(onOpen: @escaping (URL) -> Void) { self.onOpen = onOpen }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            onOpen(url)
            return true
        }
    }
}

extension RepoRecommendationItem {
    /// 只做 DTO 适配；未提供的公共属性保持缺省，不触发收藏或私有入库。
    var historyDiscoveryItem: DiscoveryRepoDTO {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        return DiscoveryRepoDTO(
            repoID: repoID, fullName: fullName, owner: parts.first ?? "",
            name: parts.count == 2 ? parts[1] : "", description: description,
            homepage: nil, language: language, stars: stars, forks: forks,
            watchers: 0, subscribers: 0, openIssues: 0, ownerAvatar: nil,
            defaultBranch: nil, licenseSpdx: nil, topics: [], platforms: [],
            pushedAt: nil, updatedAt: nil, createdAt: nil, isArchived: archived, isFork: false,
            latestReleaseTag: nil, latestReleaseAt: nil, latestReleaseURL: nil,
            releaseDownloadCount: 0, rank: nil, score: nil, reasons: reasons, signals: []
        )
    }
}
