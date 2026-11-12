//
//  DailyRadarWeeklyTopicCard.swift
//  Starcat
//
//  每日热点总分类的每周 AI 大事入口。叠卡只预览真实报告封面，
//  鼠标、键盘与辅助功能激活统一进入分类，不直接打开某期文章。
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
    @State private var hovered = false
    @State private var selectedIndex = 0
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
    private var activeIndex: Int? { hovered || focused || reduceMotion ? currentIndex : nil }
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
                        avatarSize: 34 * scale.multiplier, style: .hero
                    )
                    .padding(.trailing, 20 * scale.multiplier)
                    .padding(.bottom, 20 * scale.multiplier)
                }
            }
            .background {
                DailyRadarProgrammaticCover(
                    category: "ai-weekly-events", seed: "ai-weekly-events", textSafeLeading: 0.4
                )
                .overlay(Color.black.opacity(0.35))
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
        .onHover { isInside in
            hovered = isInside
            if !isInside && !focused { selectedIndex = 0 }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused && !hovered { selectedIndex = 0 }
        }
        .onChange(of: editions.map(\.contentIdentity)) { _, _ in
            selectedIndex = 0
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
                Text("dailyRadar.featured")
                    .font(scale.font(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
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
            HStack(spacing: 8) {
                Text("insights.drilldown.viewAll")
                Image(systemName: "arrow.right").accessibilityHidden(true)
            }
            .font(scale.font(size: 12, weight: .semibold))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(24 * scale.multiplier)
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
                            .fill(Color.primary.opacity(activeIndex == index ? 0.9 : 0.35))
                            .frame(width: activeIndex == index ? 14 : 3, height: 3)
                            .frame(width: coverCount > 1 ? layout.spacing : layout.width)
                        .position(x: layout.center(at: index), y: geometry.size.height - 25 * scale.multiplier)
                        .allowsHitTesting(false)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let location) = phase {
                    selectedIndex = layout.index(at: location.x)
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.48), value: activeIndex)
            .clipped()
        }
        .accessibilityHidden(true)
    }

    /// 无数据时仅画一张通用封面；日期、标题与摘要只从真实报告读取。
    private func cover(at index: Int) -> some View {
        let report = editions.indices.contains(index) ? editions[index] : nil
        return ZStack {
            DailyRadarProgrammaticCover(category: "ai-weekly-events", seed: report?.id ?? "ai-weekly-events")
                .overlay(Color.black.opacity(0.48))
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
        guard let activeIndex else {
            let position = CGFloat(index) / CGFloat(max(1, coverCount - 1))
            return CoverPose(
                x: x, y: position * 12,
                rotation: coverCount > 1 ? Double(position) * 16 - 8 : 0,
                scale: 0.94 - position * 0.12,
                opacity: index == 0 ? 1 : 0.82, z: Double(coverCount - index)
            )
        }
        if index == activeIndex { return CoverPose(x: x, y: -9, z: 10) }
        let distance = index - activeIndex
        let direction: CGFloat = distance < 0 ? -1 : 1
        return CoverPose(
            x: x,
            y: CGFloat(23 + abs(distance) * 3),
            rotation: Double(direction) * Double(12 + abs(distance) * 2),
            scale: 0.65, opacity: 0.65, z: Double(5 - abs(distance))
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
}
