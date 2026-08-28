//
//  AwesomeSourceCard.swift
//  Starcat
//
//  来源选择 Sheet 的固定三列卡片：上半 GitHub OG + 语言色条，下半只说明清单内项目数。
//
//  OG 由客户端按仓库全名拼 CDN URL；加载中用居中小 Logo，禁止把头像拉满 banner。
//  不展示来源仓库自身的 Stars / Issues / 语言胶囊：选 Awesome 关心的是清单里有多少项目。
//  语言色条保留，它是 OG 和正文之间的结构分割，不是语言胶囊。
//  底栏铺满剩余高度，背景走 LanguageColor（与中栏 RepoRowSurface 同一套语言色），不要从 logo 像素取色。
//  暗色不整图压黑，只在 OG 底部淡入票根。
//  LazyVGrid 里禁止在 KFImage onSuccess 写 @State，否则会取消请求并被当成失败。
//  取消不当失败；进 Sheet 由 Store 预拉全部 URL（缓存优先）。
//  刷新同一张 OG 不能改 KFImage identity；每次打开 Sheet、以及小时键变了换图，
//  都走同一套「先糊后清晰」。不要用 Kingfisher `.blur` 处理器。
//

import Kingfisher
import SwiftUI

/// 用稳定高度承载 OG 与一行说明，避免勾选或刷新改变网格节奏。
struct AwesomeSourceCard: View {
    let source: AwesomeSource
    let isSelected: Bool
    let hasRefreshError: Bool
    let parseState: AwesomeCustomSourceParseState?
    /// 用户点刷新后递增；只清掉真失败标记，不当 KFImage 的 identity。
    let ogRetryToken: Int
    /// 每次弹出 Sheet 换一次；入场糊化跟这个走，不跟 URL 走。
    let ogRevealSession: Int
    let onToggle: () -> Void
    let onRetry: (() -> Void)?
    let onDelete: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var isHovering = false
    /// 只在 OG 真正失败（403/404 等）时置位，取消请求不当失败。
    @State private var ogLoadFailed = false
    /// 正在展示的 OG URL。小时键变了先保持旧 URL，糊住后再切，避免 KFImage 卸掉闪 Logo。
    @State private var displayedOGURL: URL?
    /// 替换时糊住旧图的半径。不要用 Kingfisher `.blur`（那是处理器，会改 cache key）。
    /// 入场首帧就必须是糊的，否则缓存命中会先闪清晰图。
    private static let ogReplaceBlurRadius: CGFloat = 10
    private static let ogReplaceBlurInDuration: TimeInterval = 0.10
    private static let ogReplaceBlurOutDuration: TimeInterval = 0.24
    @State private var ogRevealBlur: CGFloat = Self.ogReplaceBlurRadius

    /// 160pt 在三列约 320pt 宽时接近 GitHub OG 的 2:1。
    private let ogHeight: CGFloat = 160
    private let cardHeight: CGFloat = 222
    private let languageBarHeight: CGFloat = 6

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 0) {
                ogBanner
                languageDivider
                footer
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(stubFill)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: cardHeight, alignment: .topLeading)
            .background(cardBackground)
            .overlay(cardBorder)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            // 阴影必须在 clip 之后，否则会被圆角裁掉。只在 hover 时出现，避免格子默认浮起来。
            .shadow(
                color: .black.opacity(hoverShadowOpacity),
                radius: isHovering ? 5 : 0,
                y: isHovering ? 1 : 0
            )
            .opacity(source.isAvailable ? 1 : 0.62)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!source.isAvailable)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .onChange(of: ogRetryToken) { _, _ in
            ogLoadFailed = false
        }
        .onAppear {
            if reduceMotion {
                ogRevealBlur = 0
            }
        }
        .task(id: ogRevealTaskID) {
            await revealOpenGraphIfNeeded()
        }
        .accessibilityLabel(Text(source.displayName))
        .accessibilityValue(Text(LocalizedStringKey(
            isSelected ? "awesome.sources.selected" : "awesome.sources.notSelected"
        )))
    }

    private var ogBanner: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let url = displayedOGURL ?? ogImageURL, !ogLoadFailed {
                    KFImage(url)
                        .resizable()
                        .placeholder { ogPlaceholder }
                        .onFailure { error in
                            // 取消不是 CDN 拒绝；格子重建后应继续用缓存或再拉。
                            if isCancelledOGLoad(error) { return }
                            ogLoadFailed = true
                        }
                        .loadDiskFileSynchronously()
                        .startLoadingBeforeViewAppear()
                        .fade(duration: 0.15)
                        .scaledToFill()
                        .overlay {
                            // GitHub OG 是白底分享图。暗色里当照片贴在深色票根上，只在底部淡入，避免整图压脏。
                            if colorScheme == .dark {
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0.52),
                                        .init(color: Color.black.opacity(0.38), location: 1)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .allowsHitTesting(false)
                            }
                        }
                } else {
                    ogPlaceholder
                }
            }
            .blur(radius: ogRevealBlur)
            .frame(maxWidth: .infinity)
            .frame(height: ogHeight)
            .clipped()
            .accessibilityHidden(true)

            if source.featured {
                featuredBadge
                    .padding(10)
            }
        }
    }

    private var ogImageURL: URL? {
        AwesomeSourceOpenGraph.imageURL(
            repoFullName: source.repoFullName,
            updatedAt: source.updatedAt,
            lastSyncedAt: source.lastSyncedAt
        )
    }

    /// 打开 Sheet 和换小时键都要跑揭示；同一张图刷新不换 id，避免再闪。
    private var ogRevealTaskID: String {
        "\(ogRevealSession)|\(ogImageURL?.absoluteString ?? "")"
    }

    /// 加载中和 OG 失败都用居中小 Logo，不要把方形头像 scaledToFill 拉成整条 banner。
    private var ogPlaceholder: some View {
        ZStack {
            Color.primary.opacity(0.04)
            AwesomeSourceLogo(source: source, size: 52)
        }
    }

    private var featuredBadge: some View {
        Label(String.l10n("awesome.sources.featured"), systemImage: "sparkles")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var languageDivider: some View {
        let segments = languageSegments
        Group {
            if segments.isEmpty {
                Divider()
            } else {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                            Rectangle()
                                .fill(LanguageColor.color(for: segment.language))
                                .frame(width: max(2, proxy.size.width * segment.ratio))
                                .help("\(segment.language) · \(segment.ratio, format: .percent.precision(.fractionLength(1)))")
                        }
                    }
                }
                .accessibilityLabel(Text(verbatim: source.sourceLanguage ?? "Languages"))
            }
        }
        .frame(height: languageBarHeight)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 7) {
            sourceStatus
            if !source.isAvailable || hasRefreshError {
                staleBadge
            }
            Spacer(minLength: 8)
            if parseState?.phase == .failed, let onRetry {
                SyncIconButton(
                    isRefreshing: false,
                    tooltip: String.l10n("action.retry"),
                    action: onRetry
                )
                .padding(5)
                .background(.regularMaterial, in: Circle())
                .help(parseState?.errorMessage ?? String.l10n("action.retry"))
            }
            actionIsland
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 27, height: 27)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text("awesome.sources.removeCustom"))
                .accessibilityLabel(Text("awesome.sources.removeCustom"))
            }
        }
    }

    /// 自定义来源的后台任务状态占用原“项目数”位置，卡片高度不变；完成后再恢复项目数。
    /// 这样用户点击添加后能立即看到卡片，也不会因为进度更新导致三列网格跳动。
    @ViewBuilder
    private var sourceStatus: some View {
        if source.kind == .custom, let parseState {
            switch parseState.phase {
            case .queued:
                parseStatusLabel("awesome.sources.custom.parse.queued")
            case .readingReadme:
                parseStatusLabel("awesome.sources.custom.parse.readingReadme")
            case .enrichingRepositories:
                enrichingProgress(parseState)
            case .completed:
                containedCountLabel
                    .lineLimit(1)
            case .failed:
                Label("awesome.sources.custom.parse.failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(parseState.errorMessage ?? "")
            }
        } else {
            containedCountLabel
                .lineLimit(1)
        }
    }

    private func parseStatusLabel(_ key: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func enrichingProgress(_ state: AwesomeCustomSourceParseState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                String(
                    format: String.l10n("awesome.sources.custom.parse.progressFormat"),
                    state.processedCount,
                    state.totalCount ?? 0
                )
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if let progress = state.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 130)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
        }
    }

    /// GitHub 跳转和勾选收进同一胶囊，两个图标同等大小，避免一大一小的圆钮并排。
    private var actionIsland: some View {
        HStack(spacing: 0) {
            Link(destination: source.repoURL) {
                Image("github")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(source.repoFullName)
            .accessibilityLabel(Text(source.repoFullName))

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.green : Color.secondary)
                .frame(width: 32, height: 28)
                .accessibilityHidden(true)
        }
        .background(islandFill, in: Capsule())
    }

    /// 整句仍走同一条 format，只把数字加重，避免拆成两段 key 把中英语序弄坏。
    private var containedCountLabel: Text {
        let count = source.totalEntryCount
        let full = String(
            format: String.l10n("awesome.sources.containedCountFormat"),
            count
        )
        var attributed = AttributedString(full)
        attributed.font = .caption
        attributed.foregroundColor = Color.secondary

        if let range = attributed.range(of: String(count)) {
            attributed[range].font = .body.weight(.semibold).monospacedDigit()
            attributed[range].foregroundColor = Color.primary
        }
        return Text(attributed)
    }

    private var languageSegments: [(language: String, ratio: Double)] {
        let valid = source.languageBytes.filter { !$0.key.isEmpty && $0.value > 0 }
        let total = valid.values.reduce(0, +)
        guard total > 0 else { return [] }
        return valid
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .map { ($0.key, Double($0.value) / Double(total)) }
    }

    private var staleBadge: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.1), in: Capsule())
            .help(Text(LocalizedStringKey(
                source.isAvailable ? "awesome.sources.stale" : "awesome.sources.unavailable"
            )))
            .accessibilityLabel(Text(LocalizedStringKey(
                source.isAvailable ? "awesome.sources.stale" : "awesome.sources.unavailable"
            )))
    }

    /// 与中栏 `RepoRowSurface` 相同：有语言用 `LanguageColor`，没有才回退系统色。
    /// 票根是整块色区，透明度比列表行默认 0.045 略高，否则大面积上看不出颜色。
    private var stubFill: Color {
        let opacity: Double
        if isSelected {
            opacity = colorScheme == .dark ? 0.24 : 0.16
        } else if isHovering {
            opacity = colorScheme == .dark ? 0.18 : 0.12
        } else {
            opacity = colorScheme == .dark ? 0.16 : 0.10
        }
        return stubTint.opacity(opacity)
    }

    private var islandFill: Color {
        if isSelected {
            return Color.green.opacity(colorScheme == .dark ? 0.24 : 0.16)
        }
        return stubTint.opacity(colorScheme == .dark ? 0.28 : 0.18)
    }

    /// 色条最宽的那段语言优先，和 OG 下那根色带对齐；bytes 为空再看 sourceLanguage。
    private var stubTint: Color {
        DetailHeroTintBackground.accentColor(
            language: languageSegments.first?.language ?? source.sourceLanguage,
            fallback: Color.primary
        )
    }

    private var hoverShadowOpacity: Double {
        guard isHovering else { return 0 }
        return colorScheme == .dark ? 0.38 : 0.08
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.background)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(
                isSelected ? Color.accentColor : Color.secondary.opacity(isHovering ? 0.34 : 0.2),
                lineWidth: isSelected ? 2 : 1
            )
    }

    /// 打开 Sheet：首帧已是糊的，等缓存后拉清晰。小时键变了：先糊旧图再换新图。
    @MainActor
    private func revealOpenGraphIfNeeded() async {
        ogLoadFailed = false
        guard let ogImageURL else {
            displayedOGURL = nil
            ogRevealBlur = 0
            return
        }
        if displayedOGURL == nil || displayedOGURL == ogImageURL {
            await playUnblurReveal(ogImageURL)
            return
        }
        await replaceOpenGraph(with: ogImageURL)
    }

    @MainActor
    private func playUnblurReveal(_ url: URL) async {
        displayedOGURL = url
        if reduceMotion {
            ogRevealBlur = 0
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            ogRevealBlur = Self.ogReplaceBlurRadius
        }
        await AwesomeSourceOpenGraph.retrieve(url: url)
        guard !Task.isCancelled else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: Self.ogReplaceBlurOutDuration)) {
            ogRevealBlur = 0
        }
    }

    @MainActor
    private func replaceOpenGraph(with newURL: URL) async {
        if reduceMotion {
            displayedOGURL = newURL
            ogRevealBlur = 0
            return
        }

        async let ready: Void = AwesomeSourceOpenGraph.retrieve(url: newURL)
        withAnimation(.easeIn(duration: Self.ogReplaceBlurInDuration)) {
            ogRevealBlur = Self.ogReplaceBlurRadius
        }
        try? await Task.sleep(for: .seconds(Self.ogReplaceBlurInDuration))
        await ready
        guard !Task.isCancelled else { return }
        displayedOGURL = newURL
        await Task.yield()
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: Self.ogReplaceBlurOutDuration)) {
            ogRevealBlur = 0
        }
    }
}

/// Kingfisher 把任务取消也送进 onFailure；那不是 403，不能钉死 Logo。
private func isCancelledOGLoad(_ error: Error) -> Bool {
    if let kingfisherError = error as? KingfisherError {
        return kingfisherError.isTaskCancelled
    }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
}
