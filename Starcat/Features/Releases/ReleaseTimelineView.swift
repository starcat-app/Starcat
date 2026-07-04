//
//  ReleaseTimelineView.swift
//  Starcat
//
//  Release 订阅时间线视图（HOM-47）。
//
//  组件结构：
//  - `ReleaseTimelineView` (View)：sheet / 独立窗口的根视图
//  - `ReleaseTimelineViewModel` (@MainActor @Observable)：数据加载 / 已读切换 / 立即刷新
//  - `ReleaseTimelineRow` (View)：单条 release 行 + 资产展开
//  - `ReleaseAssetRowView`：单个资产 + 复制 + 应用内下载
//
//  设计目标：
//  - 独立路径展示所有订阅的 Release，不复用 RepoListView 的复杂状态机
//  - 已读 / 未读切换 + "全部已读" 一键操作
//  - 资产过滤：按文件名 / 平台关键字过滤；UI 简单地用一个 TextField + 下拉
//  - 复制下载链接：按钮 → NSPasteboard
//

import SwiftUI
import AppKit
import MarkdownUI

struct ReleaseTimelineView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    /// 2026-06-15:toast 出/收的 0.18s 滑入与「关闭应用内动画」联动跳过。
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    @State private var viewModel: ReleaseTimelineViewModel?
    @State private var copyToast: String?
    /// 折叠/展开前锚定当前 release 行，避免 ScrollView 因高度突变乱跳。
    @State private var scrollAnchorReleaseID: Int64?

    /// 资产过滤关键字（空 = 不过滤）。
    @State private var assetFilter: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        // 2026-06-04 宽度迭代：
        //   - 第一版 720/880 偏宽，挤主窗口
        //   - 第二版 480/587 窄，但 header 在中文 / 英文环境里"时间线 + 过滤框 + 检查 +
        //     全部已读 + 关闭"五件套都要塞进去 → 文字换行 (dong4j 截图反馈)
        //   - 现在 540/620：在第二版基础上加 60pt，刚好够容纳 header 五件套+
        //     英文 "Mark all read" / "Check" 也不再 truncation；高度不变
        .frame(minWidth: 540, minHeight: 520)
        .frame(idealWidth: 620, idealHeight: 640)
        .task {
            if viewModel == nil {
                viewModel = ReleaseTimelineViewModel(
                    subscriptionRepository: dependencies.releaseSubscriptionRepository,
                    releaseRepository: dependencies.releaseRepository,
                    poller: dependencies.releasePoller
                )
            }
            await viewModel?.reload()
        }
        .overlay(alignment: .bottom) {
            if let toast = copyToast {
                Text(toast)
                    .font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                Text("releases.timeline.title")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(interfaceScale.font(.bodyEmphasis, weight: .semibold))
            // 标题是弹窗身份标识，不能在中英环境或大字号下被右侧工具压成两行。
            .layoutPriority(2)
            if let vm = viewModel, vm.unreadCount > 0 {
                Text(verbatim: "\(vm.unreadCount)")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 8)
            assetFilterField
            // 立即检查：图标与 SidebarSyncButton（"全部仓库"右侧刷新图标）保持一致——
            // `arrow.triangle.2.circlepath` + 进行中线性 1s repeatForever 转圈，
            // dong4j 反馈"图标也要保持统一"。
            ReleaseCheckNowButton(isChecking: viewModel?.isChecking == true) {
                Task { await viewModel?.checkNow() }
            }
            Button {
                Task { await viewModel?.markAllRead() }
            } label: {
                Image(systemName: "checkmark.circle")
                    .font(interfaceScale.font(.iconSmall))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .focusEffectDisabled()
            .disabled(viewModel?.entries.isEmpty == true)
            .help("releases.timeline.markAllRead")
            SheetCloseButton(
                action: { dismiss() },
                iconFont: .title3,
                helpKey: "general.close"
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var assetFilterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
                .font(interfaceScale.font(.captionSmall))
            TextField("releases.assetFilter.placeholder", text: $assetFilter)
                .textFieldStyle(.plain)
                .frame(minWidth: 96, idealWidth: 150, maxWidth: 170)
                .font(interfaceScale.font(.captionSmall))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar, in: RoundedRectangle(cornerRadius: 6))
        .help("releases.assetFilter.help")
        .layoutPriority(1)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let vm = viewModel {
            if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.entries.isEmpty {
                emptyState
            } else {
                // 不用 List：macOS 上 List 行高固定，嵌套 DisclosureGroup / 多行资产会被裁切，
                // 用户只能看到「资产 N 个」标题，看不到文件名与下载按钮（dong4j 2026-06-17 反馈）。
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(vm.entries) { entry in
                            ReleaseTimelineRow(
                                entry: entry,
                                assetFilter: assetFilter,
                                onPinScrollAnchor: { scrollAnchorReleaseID = entry.id },
                                onToggleRead: { isRead in
                                    Task { await vm.markRead(entry: entry, isRead: isRead) }
                                },
                                onCopyAsset: { url in
                                    copyToPasteboard(url)
                                }
                            )
                            .id(entry.id)
                            .onAppear {
                                Task { await vm.loadMoreIfNeeded(currentEntry: entry) }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            Divider()
                                .padding(.leading, 16)
                        }
                        if vm.isLoadingMore {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    }
                    .scrollTargetLayout()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollPosition(id: $scrollAnchorReleaseID, anchor: .top)
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "shippingbox",
            title: "releases.timeline.empty.title",
            subtitle: "releases.timeline.empty.subtitle",
            iconSize: 40,
            spacing: 12
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func copyToPasteboard(_ url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        // 2026-06-15:reduceMotion 兜底——toast 直接瞬切显示/隐藏。
        let toastAnimation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.18)
        withAnimation(toastAnimation) {
            copyToast = String.l10n("releases.assetCopied")
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(toastAnimation) {
                copyToast = nil
            }
        }
    }
}

// MARK: - 立即检查按钮

/// 与 `SidebarSyncButton`（"全部仓库"右侧刷新图标）视觉一致的立即检查按钮：
/// `arrow.triangle.2.circlepath` 图标，进行中时线性 1s repeatForever 旋转，
/// 完成后 0.2s easeOut 回正。dong4j 反馈刷新类按钮在 App 内必须图标 + 动效统一，
/// 否则用户在不同界面看到不同 spinner 形态会产生认知负担。
private struct ReleaseCheckNowButton: View {

    let isChecking: Bool
    let action: () -> Void

    /// 用 `@State` 单独追踪 rotation，配 `withAnimation` repeatForever 才能保持
    /// 转圈顺滑——直接对 `isChecking` 做 .rotationEffect 动画在状态切换瞬间会跳。
    @State private var rotation: Double = 0
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(interfaceScale.font(.iconSmall))
                .rotationEffect(.degrees(rotation))
                .foregroundStyle(isChecking ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .focusEffectDisabled()
        .disabled(isChecking)
        .help("releases.timeline.checkNow")
        .onAppear { updateRotation(isChecking: isChecking) }
        .onChange(of: isChecking) { _, newValue in
            updateRotation(isChecking: newValue)
        }
    }

    /// 与 `SidebarSyncButton.updateRotation` 同款：进行中无限转，完成后回正。
    /// reduceMotion 时跳过 repeatForever（保留可访问性）。
    private func updateRotation(isChecking: Bool) {
        if isChecking {
            if reduceMotion { return }
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        } else {
            if reduceMotion {
                rotation = 0
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    rotation = 0
                }
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class ReleaseTimelineViewModel {

    private static let pageSize = 20

    private(set) var entries: [ReleaseTimelineEntry] = []
    private(set) var unreadCount: Int = 0
    private(set) var isLoading: Bool = false
    private(set) var isLoadingMore: Bool = false
    private(set) var hasMore: Bool = true
    private(set) var isChecking: Bool = false
    private(set) var errorMessage: String?

    private let subscriptionRepository: any ReleaseSubscriptionRepositoryProtocol
    private let releaseRepository: any ReleaseRepositoryProtocol
    private let poller: ReleasePoller

    init(
        subscriptionRepository: any ReleaseSubscriptionRepositoryProtocol,
        releaseRepository: any ReleaseRepositoryProtocol,
        poller: ReleasePoller
    ) {
        self.subscriptionRepository = subscriptionRepository
        self.releaseRepository = releaseRepository
        self.poller = poller
    }

    func reload() async {
        isLoading = true
        hasMore = true
        defer { isLoading = false }
        do {
            async let entriesTask = releaseRepository.fetchTimeline(limit: Self.pageSize, offset: 0)
            async let countTask = releaseRepository.unreadCount()
            let page = try await entriesTask
            entries = page
            hasMore = page.count == Self.pageSize
            unreadCount = try await countTask
            errorMessage = nil
        } catch {
            errorMessage = String.l10n("releases.timeline.error.loadFailed")
        }
    }

    func loadMoreIfNeeded(currentEntry entry: ReleaseTimelineEntry) async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        guard entries.suffix(5).contains(where: { $0.id == entry.id }) else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await releaseRepository.fetchTimeline(limit: Self.pageSize, offset: entries.count)
            entries.append(contentsOf: page)
            hasMore = page.count == Self.pageSize
            errorMessage = nil
        } catch {
            errorMessage = String.l10n("releases.timeline.error.loadFailed")
        }
    }

    /// 立即触发一次轮询；UI 期间显示 spinner，完成后重 reload。
    func checkNow() async {
        isChecking = true
        defer { isChecking = false }
        _ = await poller.runNow()
        await reload()
    }

    func markRead(entry: ReleaseTimelineEntry, isRead: Bool) async {
        do {
            try await releaseRepository.markRead(releaseId: entry.release.id, isRead: isRead)
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index].release.isRead = isRead
            }
            unreadCount = try await releaseRepository.unreadCount()
            errorMessage = nil
        } catch {
            errorMessage = String.l10n("releases.timeline.error.markReadFailed")
        }
    }

    func markAllRead() async {
        do {
            try await releaseRepository.markAllRead()
            entries = entries.map { entry in
                var updated = entry
                updated.release.isRead = true
                return updated
            }
            unreadCount = 0
            errorMessage = nil
        } catch {
            errorMessage = String.l10n("releases.timeline.error.markAllReadFailed")
        }
    }
}

// MARK: - Row

private struct ReleaseTimelineRow: View {

    /// 2026-06-16:`RelativeDateTimeFormatter` 默认走系统 locale,需显式注入 SwiftUI
    /// `\.locale` 才会跟随 LocaleStore 切换;父级 `.sheet { }` 已挂 `appLocaleEnvironment()`。
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let entry: ReleaseTimelineEntry
    let assetFilter: String
    /// 布局高度即将变化前调用，把 ScrollView 锚定到本行。
    let onPinScrollAnchor: () -> Void
    let onToggleRead: (Bool) -> Void
    let onCopyAsset: (String) -> Void

    /// Release notes 全文展开（点击摘要区切换）。
    @State private var isBodyExpanded = false
    /// 资产数超过 3 个时默认折叠，避免长资产清单把时间线首屏挤满。
    @State private var isAssetsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 仓库标识行（dong4j 反馈：原版没显示头像 + 字号偏小看不清是哪个仓库）
            // 改造：加 22pt 圆形头像 + repo 名称从 subheadline 升到 body.semibold，
            // 视觉权重接近 RepoRowView 的 compact 模式，保证用户在时间线扫读时
            // 能优先识别"这是哪个仓库的发布"。
            //
            // 2026-06-04 dong4j 反馈：原方案在头像前面留了一个 8x8 圆点位（已读时
            // `Color.clear` 仍占布局空间），所以 read 行的头像前莫名空一块。
            // 改成把未读小红点 overlay 到头像右上角（不占主轴空间），头像直接顶左
            // 缘对齐；read 行因为没 overlay，视觉上也没有 8pt 空白。
            HStack(spacing: 8) {
                // 仓库头像（22pt 与 RepoRowView compact 行一致；不描边避免视觉嘈杂）
                // overlay 一个未读小红点（accent 色 8x8 + 1pt 白描边模拟"通知红点"），
                // 已读时 overlay 整个被条件渲染掉，不影响布局
                RemoteAvatar(
                    urlString: RepoAvatarURL.from(owner: entry.repo.owner),
                    size: 22,
                    showBorder: false
                )
                .overlay(alignment: .topTrailing) {
                    if !entry.release.isRead {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                            .overlay(
                                Circle()
                                    .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                            )
                            .offset(x: 2, y: -2)
                    }
                }

                // repo 名称：升到 body.semibold，比 tag / 时间这些副信息明显大一档
                Text(verbatim: entry.repo.fullName)
                    .font(interfaceScale.font(.body, weight: .semibold))
                    .lineLimit(1)

                // tag
                Text(verbatim: entry.release.tagName)
                    .font(interfaceScale.font(.code, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.bar, in: Capsule())

                if entry.release.isPrerelease {
                    Text("releases.row.prerelease")
                        .font(interfaceScale.font(.captionSmall, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.orange)
                }

                Spacer()

                if let date = relativeDate(entry.release.publishedAt) {
                    Text(verbatim: date)
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                }

                Button {
                    onToggleRead(!entry.release.isRead)
                } label: {
                    Image(systemName: entry.release.isRead ? "circle" : "checkmark.circle.fill")
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(entry.release.isRead ? .secondary : Color.accentColor)
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .help(entry.release.isRead ? Text("releases.row.markUnread") : Text("releases.row.markRead"))

                Button {
                    if let url = URL(string: entry.release.htmlUrl) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(interfaceScale.font(.caption))
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .help("releases.openOnGitHub")
            }

            if let title = entry.release.name, !title.isEmpty, title != entry.release.tagName {
                Text(verbatim: title)
                    .font(interfaceScale.font(.body, weight: .medium))
                    .foregroundStyle(.primary)
            }

            if let body = entry.release.bodyMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
               !body.isEmpty {
                notesSection(body)
            }

            assetsSection
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func notesSection(_ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            disclosureRow(
                titleKey: isBodyExpanded ? "releases.row.hideDetails" : "releases.row.viewDetails",
                isExpanded: isBodyExpanded,
                action: pinAndToggleBody
            )
            .help(isBodyExpanded ? Text("releases.row.collapseNotes") : Text("releases.row.expandNotes"))
            if isBodyExpanded {
                Markdown(body)
                    .font(interfaceScale.font(.caption))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func pinAndToggleBody() {
        onPinScrollAnchor()
        // 不用 withAnimation：高度突变 + ScrollView 动画会导致滚动条乱跳。
        isBodyExpanded.toggle()
    }

    @ViewBuilder
    private var assetsSection: some View {
        let assets = filteredAssets
        if !assets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if assets.count > 3 {
                    disclosureRow(
                        title: String(format: String.l10n(
                            isAssetsExpanded ? "releases.row.hideAssetsFormat" : "releases.row.viewAssetsFormat"
                        ), assets.count),
                        isExpanded: isAssetsExpanded,
                        action: pinAndToggleAssets
                    )
                } else {
                    Text(String(format: String.l10n("releases.row.assetsCountFormat"), assets.count))
                        .font(interfaceScale.font(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                if assets.count <= 3 || isAssetsExpanded {
                    ForEach(assets) { asset in
                        ReleaseAssetRowView(asset: asset, layout: .compact, onCopyLink: onCopyAsset)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                            .background(.bar.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(.top, 6)
        } else if !assetFilter.isEmpty {
            // 用户在过滤但本条没匹配资产，给一个占位提示
            Text("releases.row.noMatchingAsset")
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func disclosureRow(
        titleKey: LocalizedStringKey,
        isExpanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        disclosureRow(title: nil, titleKey: titleKey, isExpanded: isExpanded, action: action)
    }

    @ViewBuilder
    private func disclosureRow(
        title: String,
        isExpanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        disclosureRow(title: title, titleKey: nil, isExpanded: isExpanded, action: action)
    }

    private func disclosureRow(
        title: String? = nil,
        titleKey: LocalizedStringKey? = nil,
        isExpanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 16, height: 16)
                if let title {
                    Text(verbatim: title)
                } else if let titleKey {
                    Text(titleKey)
                }
                Spacer(minLength: 0)
            }
            .font(interfaceScale.font(.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func pinAndToggleAssets() {
        onPinScrollAnchor()
        // 与 notes 展开同理：高度突变时只锚定，不做动画，避免 ScrollView 抖动。
        isAssetsExpanded.toggle()
    }

    private var filteredAssets: [ReleaseAsset] {
        let assets = ReleaseAssetCodec.decode(entry.release.assetsJson)
        let q = assetFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return assets }
        if releaseMetadataMatches(q) {
            return assets
        }
        return assets.filter { asset in
            asset.name.lowercased().contains(q) ||
            (asset.contentType?.lowercased().contains(q) ?? false)
        }
    }

    private func releaseMetadataMatches(_ query: String) -> Bool {
        // 过滤入口仍服务于资产列表：命中项目名 / 版本 / Release 标题时展示该条 Release 的全部资产，
        // 避免用户按版本或项目定位后还被文件名二次过滤掉。
        entry.repo.fullName.lowercased().contains(query) ||
        entry.release.tagName.lowercased().contains(query) ||
        (entry.release.name?.lowercased().contains(query) ?? false)
    }

    private func relativeDate(_ iso: String?) -> String? {
        guard let iso, let date = ISO8601DateFormatter.shared.date(from: iso) else { return nil }
        return RelativeTimeText.pastEvent(date, locale: locale)
    }
}
