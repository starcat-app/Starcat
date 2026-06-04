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

struct ReleaseTimelineView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss

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
        .frame(minWidth: 720, minHeight: 520)
        .frame(idealWidth: 880, idealHeight: 640)
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
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
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
            Button {
                Task { await viewModel?.checkNow() }
            } label: {
                Label("releases.timeline.checkNow", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .focusEffectDisabled()
            .disabled(viewModel?.isChecking == true)
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
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("releases.timeline.empty.title")
                .font(.headline)
            Text("releases.timeline.empty.subtitle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func copyToPasteboard(_ url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        withAnimation(.easeOut(duration: 0.18)) {
            copyToast = String(localized: "releases.assetCopied")
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.18)) {
                copyToast = nil
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
            errorMessage = String(localized: "releases.timeline.error.loadFailed")
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
            errorMessage = String(localized: "releases.timeline.error.markReadFailed")
        }
    }

    func markAllRead() async {
        do {
            try await releaseRepository.markAllRead()
            await reload()
        } catch {
            errorMessage = String(localized: "releases.timeline.error.markAllReadFailed")
        }
    }
}

// MARK: - Row

private struct ReleaseTimelineRow: View {

    let entry: ReleaseTimelineEntry
    let assetFilter: String
    let onToggleRead: (Bool) -> Void
    let onCopyAsset: (String) -> Void

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // 未读 / 已读圆点
                Circle()
                    .fill(entry.release.isRead ? Color.clear : Color.accentColor)
                    .frame(width: 8, height: 8)

                // repo 名称
                Text(verbatim: entry.repo.fullName)
                    .font(.subheadline.weight(.medium))

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

            if let body = entry.release.bodyTruncated, !body.isEmpty {
                Text(verbatim: body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? nil : 3)
            }

            assetsSection
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
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
                Text(String(format: String(localized: "releases.row.assetsCountFormat"), assets.count))
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
