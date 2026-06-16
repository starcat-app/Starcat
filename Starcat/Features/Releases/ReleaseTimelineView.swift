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
//  - `ReleaseAssetRow` (View)：单个资产 + 复制下载链接 + 平台 / 类型过滤已通过 ViewModel 传入的 query 处理
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

    @State private var viewModel: ReleaseTimelineViewModel?
    @State private var copyToast: String?

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
            Label("releases.timeline.title", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            if let vm = viewModel, vm.unreadCount > 0 {
                Text(verbatim: "\(vm.unreadCount)")
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
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
                Label("releases.timeline.markAllRead", systemImage: "checkmark.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .focusEffectDisabled()
            .disabled(viewModel?.entries.isEmpty == true)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("general.close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var assetFilterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("releases.assetFilter.placeholder", text: $assetFilter)
                .textFieldStyle(.plain)
                .frame(width: 160)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar, in: RoundedRectangle(cornerRadius: 6))
        .help("releases.assetFilter.help")
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
                List {
                    ForEach(vm.entries) { entry in
                        ReleaseTimelineRow(
                            entry: entry,
                            assetFilter: assetFilter,
                            onToggleRead: { isRead in
                                Task { await vm.markRead(entry: entry, isRead: isRead) }
                            },
                            onCopyAsset: { url in
                                copyToPasteboard(url)
                            }
                        )
                    }
                }
                .listStyle(.inset)
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

    var body: some View {
        Button(action: action) {
            Label {
                Text("releases.timeline.checkNow").font(.caption)
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .rotationEffect(.degrees(rotation))
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .focusEffectDisabled()
        .disabled(isChecking)
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

    private(set) var entries: [ReleaseTimelineEntry] = []
    private(set) var unreadCount: Int = 0
    private(set) var isLoading: Bool = false
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
        defer { isLoading = false }
        do {
            async let entriesTask = releaseRepository.fetchTimeline(limit: 200)
            async let countTask = releaseRepository.unreadCount()
            entries = try await entriesTask
            unreadCount = try await countTask
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
            await reload()
        } catch {
            errorMessage = String.l10n("releases.timeline.error.markReadFailed")
        }
    }

    func markAllRead() async {
        do {
            try await releaseRepository.markAllRead()
            await reload()
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

    let entry: ReleaseTimelineEntry
    let assetFilter: String
    let onToggleRead: (Bool) -> Void
    let onCopyAsset: (String) -> Void

    @State private var isExpanded: Bool = false

    /// 2026-06-15:tap 展开/折叠的 0.18s 平滑过渡与「关闭应用内动画」联动跳过。
    @Environment(\.starcatReduceMotion) private var reduceMotion

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
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                // tag
                Text(verbatim: entry.release.tagName)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.bar, in: Capsule())

                if entry.release.isPrerelease {
                    Text("releases.row.prerelease")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.orange)
                }

                Spacer()

                if let date = relativeDate(entry.release.publishedAt) {
                    Text(verbatim: date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button {
                    onToggleRead(!entry.release.isRead)
                } label: {
                    Image(systemName: entry.release.isRead ? "circle" : "checkmark.circle.fill")
                        .font(.caption)
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
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .help("releases.openOnGitHub")
            }

            if let title = entry.release.name, !title.isEmpty, title != entry.release.tagName {
                Text(verbatim: title)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }

            if let body = entry.release.bodyMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
               !body.isEmpty {
                if isExpanded {
                    Markdown(body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(verbatim: body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            assetsSection
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        }
    }

    @ViewBuilder
    private var assetsSection: some View {
        let assets = filteredAssets
        if !assets.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(assets) { asset in
                        ReleaseAssetRow(asset: asset, onCopy: onCopyAsset)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text(String(format: String.l10n("releases.row.assetsCountFormat"), assets.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .disclosureGroupStyle(.automatic)
        } else if !assetFilter.isEmpty {
            // 用户在过滤但本条没匹配资产，给一个占位提示
            Text("releases.row.noMatchingAsset")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var filteredAssets: [ReleaseAsset] {
        let assets = ReleaseAssetCodec.decode(entry.release.assetsJson)
        let q = assetFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return assets }
        return assets.filter { asset in
            asset.name.lowercased().contains(q) ||
            (asset.contentType?.lowercased().contains(q) ?? false)
        }
    }

    private func relativeDate(_ iso: String?) -> String? {
        guard let iso, let date = ISO8601DateFormatter.shared.date(from: iso) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = locale
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - AssetRow

private struct ReleaseAssetRow: View {
    let asset: ReleaseAsset
    let onCopy: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: assetIcon)
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(width: 16)
            Text(verbatim: asset.name)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(asset.size), countStyle: .file))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            Button {
                onCopy(asset.browserDownloadUrl)
            } label: {
                Label("releases.copyDownloadLink", systemImage: "doc.on.clipboard")
                    .font(.caption2)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .focusEffectDisabled()
            .help("releases.copyDownloadLink")
            Button {
                if let url = URL(string: asset.browserDownloadUrl) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("releases.downloadAsset", systemImage: "arrow.down.circle")
                    .font(.caption2)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .focusEffectDisabled()
            .help("releases.downloadAsset")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    /// 按文件扩展名 / contentType 给个有视觉区分度的图标。
    /// 没有命中规则就回退默认 `doc`，避免 UI 突兀。
    private var assetIcon: String {
        let lower = asset.name.lowercased()
        if lower.hasSuffix(".dmg") { return "internaldrive" }
        if lower.hasSuffix(".pkg") { return "shippingbox.fill" }
        if lower.hasSuffix(".zip") || lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return "doc.zipper" }
        if lower.hasSuffix(".exe") || lower.hasSuffix(".msi") { return "pc" }
        if lower.hasSuffix(".deb") || lower.hasSuffix(".rpm") || lower.hasSuffix(".appimage") { return "terminal" }
        if lower.hasSuffix(".app") { return "macwindow" }
        return "doc"
    }
}
