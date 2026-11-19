//
//  DailyRadarWeeklyTopicCard.swift
//  Starcat
//
//  每日热点总分类的每周 AI 大事入口。叠卡只预览真实报告封面，
//  鼠标、键盘与辅助功能激活统一进入分类，不直接打开某期文章。
//  轮播与流光跟随视口、窗口和减少动态效果设置，暂停时保留当前选期。
//

import SwiftUI

/// 封面中心、日期标记与鼠标选期共用同一组锚点；首尾预留完整封面的空间。
struct DailyRadarWeeklyDeckLayout {
    let width: CGFloat
    let count: Int
    let cardWidth: CGFloat
    let spacing: CGFloat
    private let inset: CGFloat

    init(stageWidth: CGFloat, scale: CGFloat, count: Int) {
        width = max(0, stageWidth)
        self.count = max(1, count)
        cardWidth = min(246 * scale, width * 0.49)
        inset = min(width / 2, cardWidth / 2 + 12 * scale)
        spacing = self.count > 1 ? (width - 2 * inset) / CGFloat(self.count - 1) : 0
    }

    /// 坐标属于固定图片区，不跟随 hover 动画移动，避免鼠标在相邻卡片间反复跳选。
    func center(at index: Int) -> CGFloat {
        guard count > 1 else { return width / 2 }
        return inset + CGFloat(index) * spacing
    }

    /// 相邻日期中心的中点就是命中边界，两侧留白仍归最近一期。
    func index(at x: CGFloat) -> Int {
        guard spacing > 0 else { return 0 }
        let boundedX = min(width, max(0, x))
        return min(count - 1, max(0, Int(((boundedX - inset) / spacing).rounded())))
    }
}

/// 单一可聚焦按钮承载整张专题卡；动画局限在图片区，不改变文案或命中区。
struct DailyRadarWeeklyTopicCard: View {
    let reports: [DailyRadarReport]
    let isLoading: Bool
    /// 宿主先扣除两侧页面 padding，再限制为 1120pt，与实际内容区使用同一宽度。
    let availableWidth: CGFloat
    let action: () -> Void

    @Environment(\.starcatInterfaceScale) private var scale
    @Environment(\.locale) private var locale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.starcatListInteractionSuppressed) private var interactionSuppressed
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    @State private var selectedIndex = 0
    @State private var isCardVisible = false
    @FocusState private var focused: Bool

    /// 最新一期始终在最左侧；先排序再截取，避免输入顺序影响最近六期的选择。
    private var editions: [DailyRadarReport] {
        Array(reports.sorted {
            if $0.editionDate != $1.editionDate { return $0.editionDate > $1.editionDate }
            return $0.id < $1.id
        }.prefix(DailyRadarWorkspaceViewModel.weeklyTopicLimit))
    }
    private var coverCount: Int { max(1, editions.count) }
    private var currentIndex: Int { min(selectedIndex, coverCount - 1) }
    private var isWindowActive: Bool { scenePhase == .active && appearsActive }
    private var shouldRunCarousel: Bool {
        isVisualEffectActive && coverCount > 1
            && !hovered && !focused && !voiceOverEnabled
    }
    /// 选期、报告身份或播放条件改变时取消旧倒计时，恢复后从完整五秒重新开始。
    private var carouselIdentity: [String]? {
        shouldRunCarousel ? editions.map(\.contentIdentity) + [String(currentIndex)] : nil
    }
    private var isVisualEffectActive: Bool {
        // 首页保留挂载以保存位置；阅读层覆盖时 isEnabled=false，也必须停止后台绘制。
        !reduceMotion && isCardVisible && isWindowActive && isEnabled && !interactionSuppressed
    }
    private var compact: Bool { availableWidth < 640 * scale.multiplier }
    private var categoryTitle: String {
        DailyRadarCatalog.Category.localizedTitle(for: "ai-weekly-events")
    }
    private var accessibilityPreview: String {
        guard editions.indices.contains(currentIndex) else { return categoryTitle }
        let report = editions[currentIndex]
        return "\(DailyRadarDateFormatting.label(report.editionDate, locale: locale)) · \(report.title)"
    }

    var body: some View {
        Button(action: action) {
            let layout = compact ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                copy
                    .frame(
                        width: compact ? nil : availableWidth * 0.46,
                        height: scale.scaled(compact ? 230 : 320)
                    )
                deck
                    .frame(maxWidth: .infinity)
                    .frame(height: scale.scaled(compact ? 250 : 320))
            }
            .frame(maxWidth: .infinity)
            .frame(height: scale.scaled(compact ? 480 : 320))
            .overlay(alignment: .bottomTrailing) {
                if let latest = editions.first, let heroBadges = latest.relatedProjectBadges, !heroBadges.isEmpty {
                    // 专题入口大卡右下角叠加最新一期项目徽标；右侧卡片区足够容纳。
                    DailyRadarProjectBadgeCluster(
                        badges: heroBadges, maxVisible: 6,
                        avatarSize: 36 * scale.multiplier, style: .hero
                    )
                    .padding(.trailing, 20 * scale.multiplier)
                    .padding(.bottom, 20 * scale.multiplier)
                }
            }
            .background {
                animatedBackground
                .overlay(Color.black.opacity(0.16))
                .allowsHitTesting(false)
            }
            // 与现有专题大卡一致：插画固定为深色，文字随局部语义环境保持对比；
            // 页面、描边与后续专题仍跟随应用明暗主题。
            .foregroundStyle(.primary)
            .environment(\.colorScheme, .dark)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        focused ? Color.accentColor : Color.primary.opacity(hovered ? 0.28 : 0.12),
                        lineWidth: focused ? 2 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focusable()
        .focused($focused)
        .pointerStyle(.link)
        // LazyVStack 中卡片可能先被构建但尚未进入视口；只有真正可见且窗口活跃时才轮播。
        .onScrollVisibilityChange(threshold: 0.2) { isVisible in
            isCardVisible = isVisible
        }
        .onHover { isInside in
            hovered = isInside
        }
        .onChange(of: editions.map(\.contentIdentity)) { _, _ in
            selectedIndex = 0
        }
        .task(id: carouselIdentity) {
            guard shouldRunCarousel else { return }
            do {
                try await Task.sleep(for: .seconds(5))
                try Task.checkCancellation()
            } catch {
                return
            }
            selectedIndex = (currentIndex + 1) % coverCount
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { key in
            selectedIndex = (currentIndex + (key.key == .rightArrow ? 1 : coverCount - 1)) % coverCount
            return .handled
        }
        .onKeyPress(keys: [.return, .space]) { _ in
            action()
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: categoryTitle))
        .accessibilityValue(Text(verbatim: accessibilityPreview))
        .accessibilityHint(Text("insights.drilldown.viewAll"))
        // 日期倒序后，“上一期”对应更早的报告，数组下标随之递增。
        .accessibilityAction(named: Text("dailyRadar.previousEdition")) {
            selectedIndex = (currentIndex + 1) % coverCount
        }
        .accessibilityAction(named: Text("dailyRadar.nextEdition")) {
            selectedIndex = (currentIndex + coverCount - 1) % coverCount
        }
    }

    /// 左侧只依赖最近一期摘要，不随当前封面的 hover 改写，避免文字跳动。
    private var copy: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                DailyRadarPillLabel(onDark: true) {
                    Text("dailyRadar.featured")
                }
                if isLoading { ProgressView().controlSize(.small) }
            }
            Spacer(minLength: 0)
            Text(verbatim: categoryTitle)
                .font(scale.font(size: 30, weight: .bold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let latest = editions.first, !latest.summary.isEmpty {
                Text(verbatim: latest.summary)
                    .font(scale.font(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            DailyRadarPillLabel(emphasized: true, onDark: true) {
                HStack(spacing: 6) {
                    Text("insights.drilldown.viewAll")
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                }
                .font(scale.font(size: 12, weight: .semibold))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(24 * scale.multiplier)
    }

    /// 背景跟随当前预览期次；静态主体和循环光效分层，切换期次时只交叉渐变主体。
    private var animatedBackground: some View {
        let seed = editions.indices.contains(currentIndex)
            ? editions[currentIndex].id
            : "ai-weekly-events"
        return ZStack {
            DailyRadarProgrammaticCover(
                category: "ai-weekly-events", seed: seed, textSafeLeading: 0.4
            )
            .id(seed)
            .transition(.opacity)
            if isVisualEffectActive {
                DailyRadarWeeklyTopicGlow(seed: seed)
                    .id("glow|\(seed)")
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: seed)
    }

    /// 图片层完全禁用命中；日期与静态感应区复用封面锚点，动画不会反过来改变选期。
    private var deck: some View {
        GeometryReader { geometry in
            let layout = DailyRadarWeeklyDeckLayout(
                stageWidth: geometry.size.width, scale: scale.multiplier, count: coverCount
            )
            let cardHeight = min(184 * scale.multiplier, geometry.size.height * 0.68)
            ZStack {
                ZStack {
                    ForEach(0..<coverCount, id: \.self) { index in
                        let pose = pose(for: index, layout: layout)
                        cover(at: index)
                            .frame(width: layout.cardWidth, height: cardHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.primary.opacity(0.28), lineWidth: 1)
                            }
                            .overlay {
                                if index == currentIndex && !reduceMotion {
                                    DailyRadarWeeklyCoverEdgeGlow(
                                        seed: editions.indices.contains(index)
                                            ? editions[index].id
                                            : "ai-weekly-events",
                                        isAnimated: isVisualEffectActive
                                    )
                                }
                            }
                            .shadow(color: .black.opacity(0.22), radius: 8, y: 5)
                            .scaleEffect(pose.scale)
                            .rotationEffect(.degrees(pose.rotation))
                            .offset(x: pose.x, y: pose.y)
                            .opacity(pose.opacity)
                            .zIndex(pose.z)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height * 0.88)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
                if !editions.isEmpty {
                    ForEach(Array(editions.enumerated()), id: \.element.id) { index, _ in
                        // 只保留指示点，不显示日期文案，避免与右下角项目徽标重叠。
                        Capsule()
                            .fill(Color.primary.opacity(currentIndex == index ? 0.9 : 0.35))
                            .frame(width: currentIndex == index ? 14 : 3, height: 3)
                            .frame(width: coverCount > 1 ? layout.spacing : layout.width)
                        .position(x: layout.center(at: index), y: geometry.size.height - 25 * scale.multiplier)
                        .allowsHitTesting(false)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if !interactionSuppressed, case .active(let location) = phase {
                    let index = layout.index(at: location.x)
                    if selectedIndex != index { selectedIndex = index }
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: currentIndex)
            .clipped()
        }
        .accessibilityHidden(true)
    }

    /// 无数据时仅画一张通用封面；日期、标题与摘要只从真实报告读取。
    private func cover(at index: Int) -> some View {
        let report = editions.indices.contains(index) ? editions[index] : nil
        return ZStack {
            DailyRadarProgrammaticCover(category: "ai-weekly-events", seed: report?.id ?? "ai-weekly-events")
                // 只在文字需要的位置保留遮罩，让程序化封面的主体保持更高亮度。
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.20), location: 0),
                            .init(color: .clear, location: 0.32),
                            .init(color: .black.opacity(0.18), location: 0.62),
                            .init(color: .black.opacity(0.38), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: categoryTitle)
                    .font(scale.font(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: report?.title.replacingOccurrences(of: "\n", with: " ") ?? categoryTitle)
                    .font(scale.font(size: 15, weight: .semibold))
                    .lineLimit(4)
                Spacer(minLength: 0)
                if let report {
                    Text(verbatim: DailyRadarDateFormatting.label(report.editionDate, locale: locale))
                        .font(scale.font(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(14 * scale.multiplier)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// 抬升只改变纵向与层级，横向始终对齐日期；减少动态时直接切换，不播放位移动画。
    private func pose(for index: Int, layout: DailyRadarWeeklyDeckLayout) -> CoverPose {
        let x = layout.center(at: index) - layout.width / 2
        if reduceMotion {
            return CoverPose(x: x, opacity: index == currentIndex ? 1 : 0, z: index == currentIndex ? 10 : 0)
        }
        // 暂停只停止计时与流光，不收回前景卡片，避免失焦时背景与预览期次错位。
        if index == currentIndex { return CoverPose(x: x, y: -12, z: 10) }
        let distance = index - currentIndex
        let direction: CGFloat = distance < 0 ? -1 : 1
        return CoverPose(
            x: x,
            y: CGFloat(23 + abs(distance) * 3),
            rotation: Double(direction) * Double(12 + abs(distance) * 2),
            scale: 0.72, opacity: 0.80, z: Double(5 - abs(distance))
        )
    }

    /// 只有封面视觉参与变换；静态命中区与外层布局不读取这些值。
    private struct CoverPose {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rotation: Double = 0
        var scale: CGFloat = 1
        var opacity: Double = 1
        var z: Double = 0
    }

    /// 专题背景的独立循环光层；不可见或窗口失活时整层移除，不再产生帧更新。
    private struct DailyRadarWeeklyTopicGlow: View {
        let seed: String

        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { context, size in
                    guard size.width > 0, size.height > 0 else { return }
                    let composition = DailyRadarCoverComposition(
                        category: "ai-weekly-events", seed: seed
                    )
                    let phase = timeline.date.timeIntervalSinceReferenceDate / 7
                    DailyRadarProgrammaticCover.drawDynamicPulse(
                        context, rect: CGRect(origin: .zero, size: size),
                        composition: composition, phase: phase
                    )
                }
            }
            // 光效在文字区逐渐减弱，左侧仍由静态封面的文字保护渐变保证对比度。
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(0.12), location: 0.4),
                        .init(color: .white, location: 0.68),
                        .init(color: .white, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .allowsHitTesting(false)
        }
    }

    /// 当前封面使用随期次配色的低强度边缘流光，叠在固定圆角内不改变命中区。
    private struct DailyRadarWeeklyCoverEdgeGlow: View {
        let seed: String
        let isAnimated: Bool

        var body: some View {
            let composition = DailyRadarCoverComposition(category: "ai-weekly-events", seed: seed)
            let primary = Color(hue: composition.hue, saturation: 0.70, brightness: 0.86)
            let accent = Color(hue: composition.accentHue, saturation: 0.82, brightness: 0.90)
            return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimated)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 9) / 9
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                primary.opacity(0.18), primary.opacity(0.18),
                                accent.opacity(0.85), .white.opacity(0.75),
                                primary.opacity(0.18)
                            ],
                            center: .center,
                            angle: .degrees(phase * 360)
                        ),
                        lineWidth: 2
                    )
            }
            .allowsHitTesting(false)
        }
    }
}
