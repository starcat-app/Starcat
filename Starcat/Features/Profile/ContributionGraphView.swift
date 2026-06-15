//
//  ContributionGraphView.swift
//  Starcat
//
//  GitHub 贡献草坪 SwiftUI 原生渲染（53 周 × 7 天）+ 可插拔贪吃蛇动画。
//  HOM-PROFILE 2026-06-05 引入，2026-06-05 v2 加贪吃蛇，
//  2026-06-05 v3 修复"草坪太窄"，
//  HOM-SNAKE-MODES 2026-06-05 v4 把蛇玩法抽成 SnakeAnimator 协议，
//  支持 dong4j 在 Settings 切换 6 种玩法（off / zigzag / greedy / multiMode /
//  foodChase / hilbert / multiSnake）。
//
//  设计动机：
//  - dong4j 希望"零第三方依赖、自动适配明暗主题"。
//  - 比 Platane/snk 输出 SVG 再渲染更优：原生 Canvas 一次绘制完成、矢量缩放、
//    `Color` 自动响应 colorScheme，无需备双 SVG。
//  - **贪吃蛇可插拔**（v4）：本 View 不再写死 zigzag 路径，改用 `SnakeAnimator`
//    协议；切换 settings.snakeStyle 后通过 onChange 重建 animator 即可。
//    各玩法实现见 `Features/Profile/SnakeAnimator/*.swift`。
//
//  布局：
//  - 53 列 × 7 行 = 一年草坪。每格 10pt 宽 × 14pt 高（矩形，非 GitHub 同款正方形），
//    间距 2 pt。
//  - sidebar 宽度 240-320，Canvas 自身按可用尺寸等比缩放（aspectRatio 保证不变形）。
//  - **关键约束**：草坪外层 frame 高度由 `aspectRatio` 自动算出，**禁止再用固定
//    heightScale**——否则 frame 高 ≠ Canvas 实际渲染高，多出来的空白会把 sidebar
//    下方"管理/趋势/活动"挤下去、进而遮住 List 顶部的分类（dong4j 2026-06-05 反馈）。
//  - 不显示星期/月份标签（sidebar 紧凑环境下省略）。
//  - 顶部一行：贡献总数 + "更新于 X 分前"，无右侧跳转按钮（头像已可点击跳转）。
//
//  颜色规范（与 GitHub 主页 1:1 对齐）：
//  - light 模式：#ebedf0 / #9be9a8 / #40c463 / #30a14e / #216e39
//  - dark  模式：#161b22 / #0e4429 / #006d32 / #26a641 / #39d353
//
//  蛇渲染细节：
//  - **蛇身**：每节 head 在前，尾部按 alpha 阶梯衰减；蛇头比格子稍大 1.2x 让它
//    "包住"目标格子，符合 snk 视觉。多条蛇并发时各自独立渲染。
//  - **吃格**：animator 返回的 eatenCells 集合内的格子渲染为 NONE 色，
//    模拟"被吃掉"。每轮重启时由 animator 自己控制是否清空（zigzag/greedy 等不清，
//    新一轮通过 currentStep nil → 完整草坪回归）。
//  - **食物**（FoodChase 专属）：在 foodCells 集合的格子叠一层脉冲高亮圆环。
//  - **reduceMotion**：完全跳过蛇，只静态显示草坪——前庭敏感用户优先。
//
//  关键约束：
//  - `Canvas` 在 List/ScrollView 中要给定 `frame(height:)` 否则尺寸坍缩。
//  - 不要加 `drawingGroup()`：Canvas 本身是 immediate 模式，再叠 MTL renderer 反而拖慢。
//  - `TimelineView(.animation)` 在 window 不在前台时自动暂停，不耗电。
//

import SwiftUI

/// 贡献草坪渲染视图。
///
/// 用法：
/// ```swift
/// ContributionGraphView(
///     payload: service.payload,
///     isLoading: service.isLoading,
///     lastFetchedAt: service.lastFetchedAt,
///     login: user.login
/// )
/// ```
struct ContributionGraphView: View {

    /// 贡献数据；nil 时显示占位（首次加载未完成）。
    let payload: ContributionCalendarPayload?

    /// 是否处于加载中（用于占位骨架颜色微调，避免空白突兀）。
    var isLoading: Bool = false

    /// 上次成功加载时间戳；用于显示 "更新于 X 分前"。nil 表示从未成功加载过。
    var lastFetchedAt: Date?

    /// 用户登录名，预留扩展用（如果未来需要 deep link 等）；当前不渲染跳转按钮，
    /// 因为头像已经承担"跳 GitHub 主页"的语义。
    var login: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatReduceMotion) private var reduceMotion
    /// HOM-SNAKE-MODES：读取用户选的玩法。
    @Environment(AppSettings.self) private var settings

    /// 当前绑定的 animator。`@State` 让 onChange 重建 animator 时 SwiftUI 自动重渲染。
    /// nil 表示 `.off` 玩法或数据未到位——只画静态草坪。
    /// 用 `(any SnakeAnimator)?` 而非具体类型，让协议替换零负担。
    @State private var animator: (any SnakeAnimator)?

    /// 每格宽度（pt）。
    ///
    /// **为什么 width / height 拆开（dong4j 2026-06-05 反馈"草坪太窄"修正）**：
    /// GitHub 主页的格子是 11×11 正方形（aspect ratio 1:1），53 列横排后整图比例
    /// 约 7.7:1。sidebar 可用宽度只有 ~212pt（240pt - 横向 padding 28pt），按等比
    /// 缩放出来高度只剩 ~27pt——视觉上是"一条窄带子"，方块都挤压成像素点。
    ///
    /// 修复：让格子拉伸成 10:14 矩形（纵向 +40%）。
    /// trade-off：格子不再 1:1 但 sidebar 紧凑空间下视觉份量大幅提升。如果以后
    /// sidebar 能拓宽，可以把 cellHeight 改回 10pt 恢复 GitHub 同款正方形。
    private let cellWidth: CGFloat = 10

    /// 每格高度（pt）。1.4x cellWidth，让方块在 sidebar 紧凑空间下看起来更"实"。
    private let cellHeight: CGFloat = 14

    /// 格子间距（pt）。横纵共用同一间距，保留正交栅格感。
    private let cellSpacing: CGFloat = 2

    /// 圆角（pt）。GitHub 是直角，但 macOS 视觉风格圆一点更柔和。
    private let cellCornerRadius: CGFloat = 2

    // MARK: - 蛇身渲染常量

    /// 蛇身最多展示几节（在多节 alpha 渐淡之外的硬上限）。FoodChase 蛇可能变得很长，
    /// 这个上限只影响"渲染时画几节"，不影响 animator 内部状态。
    private let maxRenderedSegments: Int = 16

    /// 整图固有尺寸（不考虑 aspectRatio 缩放）。
    /// width = 53 × 10 + 52 × 2 = 634pt
    /// height = 7 × 14 + 6 × 2 = 110pt
    /// → aspect ratio ≈ 5.76（旧 10×10 正方形是 7.73，矩形把竖向"撑高"了）
    private var intrinsicSize: CGSize {
        let weeksCount = 53
        let daysPerWeek = 7
        let w = CGFloat(weeksCount) * cellWidth + CGFloat(weeksCount - 1) * cellSpacing
        let h = CGFloat(daysPerWeek) * cellHeight + CGFloat(daysPerWeek - 1) * cellSpacing
        return CGSize(width: w, height: h)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow

            // 草坪本体 + 蛇身叠加。
            //
            // **为什么用 aspectRatio 而不是 GeometryReader + frame(height:)**（v3 修复）：
            // 旧方案 frame(height: intrinsicSize.height × heightScale=0.56) → 给 46pt 高，
            // 但内部 GeometryReader 按 width 算 scale 只渲染了 ~27pt → 多 19pt 空白把
            // sidebar 下面的"管理/趋势/活动"挤下去、遮住 List 顶部分类。
            //
            // 新方案：Canvas 直接拿自身 size 算 scale，外层用 aspectRatio 按 intrinsic
            // 比例自动算高度 → frame 高度 = Canvas 实际渲染高度，零空白。
            gridContent
                .aspectRatio(intrinsicSize.width / intrinsicSize.height, contentMode: .fit)
        }
        .help(payload != nil ? Text("contribution.hoverHint") : Text("contribution.loading"))
        .opacity(isLoading && payload == nil ? 0.6 : 1.0)
        // v4 HOM-SNAKE-MODES：根据玩法 / 数据变化重建 animator
        .onAppear { rebuildAnimator() }
        .onChange(of: settings.snakeStyle) { _, _ in rebuildAnimator() }
        // payload 从 nil → 有数据时也要重建，让 greedy / foodChase / multiSnake 拿到真实 weeks
        .onChange(of: payload?.totalContributions) { _, _ in rebuildAnimator() }
    }

    /// 根据当前 settings.snakeStyle + payload 重建 animator。
    /// 频次很低（用户切换 / 数据到位），每次 init 可能要做几十毫秒的预计算（greedy 最重），
    /// 但仍在主线程能容忍范围；避免在 frame(at:) 这种每帧路径上做重活。
    private func rebuildAnimator() {
        animator = SnakeAnimatorFactory.make(style: settings.snakeStyle,
                                             weeks: payload?.weeks)
    }

    // MARK: - Header

    /// 顶部一行：左侧"近一年贡献 X 次"，右侧"更新于 X 分前"。
    ///
    /// dong4j 2026-06-05 反馈：去掉右上角跳转链接图标（头像已可点击跳转）；
    /// 加"更新于 X 分前"但 i18n 要简短。这里用 SwiftUI 自带 `.relative` 时间格式，
    /// 配合 `unitsStyle: .narrow` 让英文是 `1m` / 中文是 `1分钟前`，自动跟随 locale。
    /// 加 `clock` 图标省去 "更新于"/"Updated" 文字前缀，更紧凑。
    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 6) {
            if let count = payload?.totalContributions {
                Text(String(format: String(localized: "contribution.totalCount"), count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("contribution.title")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if let lastFetchedAt {
                // 图标 + 相对时间双 view 组合，整体作为"更新时间戳"展示。
                // `.relative` 在 SwiftUI 5 上会自动选 narrow/short 风格（按 locale）。
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                    Text(lastFetchedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .monospacedDigit()
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help(Text("contribution.lastUpdated"))
            }
        }
    }

    // MARK: - 草坪 + 蛇身绘制

    /// 草坪 + 蛇身合成视图。
    ///
    /// reduceMotion 开启或 animator nil（off 玩法 / 数据未到）→ 仅画静态草坪；
    /// 否则 `TimelineView(.animation)` 驱动每帧重绘，由 elapsed time 算 step。
    ///
    /// **scale 由 Canvas 内部算**：Canvas closure 的 `size` 参数就是实际渲染尺寸；
    /// 外层 aspectRatio 保证 size 与 intrinsicSize 等比，所以 scale = size.width / intrinsicSize.width
    /// 即可（scaleX == scaleY，取 width 即可）。
    @ViewBuilder
    private var gridContent: some View {
        if reduceMotion || animator == nil {
            Canvas { ctx, size in
                let scale = size.width / intrinsicSize.width
                drawGrid(ctx: ctx, scale: scale, frame: .empty)
            }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                let frame = currentFrame(at: context.date)
                Canvas { ctx, size in
                    let scale = size.width / intrinsicSize.width
                    drawGrid(ctx: ctx, scale: scale, frame: frame)
                    drawSnakes(ctx: ctx, scale: scale, snakes: frame.snakes)
                    drawFood(ctx: ctx, scale: scale, food: frame.foodCells, time: context.date)
                }
            }
        }
    }

    /// 把当前时间映射到 animator 的当前帧。
    /// nil → animator 在"轮间暂停"或没数据，返回 empty frame（草坪完整、不画蛇）。
    private func currentFrame(at date: Date) -> AnimationFrame {
        guard let animator else { return .empty }
        guard let step = animator.currentStep(at: date) else { return .empty }
        return animator.frame(at: step)
    }

    /// 在 Canvas 上绘制 53×7 草坪。
    /// - Parameters:
    ///   - frame: 当前帧；`frame.eatenCells` 内的格子渲染为 NONE 色。
    private func drawGrid(ctx: GraphicsContext, scale: CGFloat, frame: AnimationFrame) {
        let palette = ContributionPalette.palette(for: colorScheme)
        let scaledCellW = cellWidth * scale
        let scaledCellH = cellHeight * scale
        let scaledSpacing = cellSpacing * scale
        let scaledCorner = cellCornerRadius * scale

        guard let weeks = payload?.weeks else {
            drawPlaceholderGrid(ctx: ctx, palette: palette,
                                cellW: scaledCellW, cellH: scaledCellH,
                                spacing: scaledSpacing, corner: scaledCorner)
            return
        }

        // weeks 可能不足 53 周（账号较新）；按实际长度从左对齐绘制。
        // GitHub GraphQL 返回的 weeks 数组按时间正序（最近一周在末尾），
        // 这里 startColumn 让"过早的空位"留在左侧，与 GitHub 主页一致。
        let startColumn = max(0, 53 - weeks.count)

        for (weekIdx, week) in weeks.enumerated() {
            let col = startColumn + weekIdx
            let x = CGFloat(col) * (scaledCellW + scaledSpacing)

            for day in week.contributionDays {
                let row = day.weekday
                let y = CGFloat(row) * (scaledCellH + scaledSpacing)
                let rect = CGRect(x: x, y: y, width: scaledCellW, height: scaledCellH)
                let path = Path(roundedRect: rect, cornerRadius: scaledCorner)

                // 关键：判断该格是否在已吃集合内
                let pos = GridPosition(col: col, row: row)
                let level = frame.eatenCells.contains(pos)
                    ? .none
                    : day.contributionLevel
                ctx.fill(path, with: .color(palette.color(for: level)))
            }
        }
    }

    /// 全部 NONE 颜色的占位网格（首次加载未拿到数据时用）。
    private func drawPlaceholderGrid(
        ctx: GraphicsContext,
        palette: ContributionPalette,
        cellW: CGFloat, cellH: CGFloat, spacing: CGFloat, corner: CGFloat
    ) {
        let color = palette.color(for: .none)
        for col in 0..<53 {
            for row in 0..<7 {
                let x = CGFloat(col) * (cellW + spacing)
                let y = CGFloat(row) * (cellH + spacing)
                let rect = CGRect(x: x, y: y, width: cellW, height: cellH)
                let path = Path(roundedRect: rect, cornerRadius: corner)
                ctx.fill(path, with: .color(color))
            }
        }
    }

    /// 绘制 N 条蛇（每节从蛇头往尾部 alpha 渐淡）。
    ///
    /// 蛇头比格子稍大（1.2x），向中心扩展——视觉上"咬"住目标格子，符合 snk 风格；
    /// 后续节按格子原尺寸 + alpha 渐淡画出尾迹。多条蛇并发时各自独立渲染、互不干涉。
    ///
    /// **alpha 阶梯**：head 100%、第 2 节 85%、之后线性衰减到 25%，最多渲染
    /// `maxRenderedSegments` 节（FoodChase 蛇可能很长）。
    private func drawSnakes(ctx: GraphicsContext, scale: CGFloat, snakes: [[GridPosition]]) {
        guard !snakes.isEmpty else { return }
        let palette = ContributionPalette.palette(for: colorScheme)
        let snakeColor = palette.color(for: .fourthQuartile)
        let scaledCellW = cellWidth * scale
        let scaledCellH = cellHeight * scale
        let scaledSpacing = cellSpacing * scale
        let scaledCorner = cellCornerRadius * scale

        for body in snakes {
            let segCount = min(body.count, maxRenderedSegments)
            for i in 0..<segCount {
                let pos = body[i]
                let baseX = CGFloat(pos.col) * (scaledCellW + scaledSpacing)
                let baseY = CGFloat(pos.row) * (scaledCellH + scaledSpacing)

                // alpha 阶梯：head 1.0；之后每节线性衰减至 0.2，避免长蛇尾部消失太突兀
                let alpha: Double = (i == 0) ? 1.0 :
                    max(0.2, 0.85 - Double(i - 1) * (0.65 / Double(max(1, segCount - 1))))

                // 蛇头放大到 1.2x，向中心展开
                let inflate: CGFloat = (i == 0) ? 0.2 : 0.0
                let segW = scaledCellW * (1.0 + inflate)
                let segH = scaledCellH * (1.0 + inflate)
                let offsetX = (segW - scaledCellW) / 2
                let offsetY = (segH - scaledCellH) / 2
                let rect = CGRect(
                    x: baseX - offsetX,
                    y: baseY - offsetY,
                    width: segW,
                    height: segH
                )
                let segCorner = scaledCorner * (1.0 + inflate)
                let path = Path(roundedRect: rect, cornerRadius: segCorner)
                ctx.fill(path, with: .color(snakeColor.opacity(alpha)))
            }
        }
    }

    /// 绘制食物（仅 FoodChase 玩法非空）。
    ///
    /// 视觉：在格子上叠一个金黄色脉冲圆环，1Hz 频率呼吸——让用户一眼看出"目标"。
    /// 圆环用 `.color.opacity(脉冲)` 走 stroke 而非 fill，与蛇头（fill）形成对比。
    private func drawFood(ctx: GraphicsContext, scale: CGFloat,
                          food: Set<GridPosition>, time: Date) {
        guard !food.isEmpty else { return }
        let scaledCellW = cellWidth * scale
        let scaledCellH = cellHeight * scale
        let scaledSpacing = cellSpacing * scale

        // 1Hz 呼吸：sin(2π·t) 映射到 [0.4, 1.0]
        let phase = time.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.0)
        let pulse = 0.7 + 0.3 * sin(phase * 2 * .pi)

        let foodColor = Color(.sRGB, red: 1.0, green: 0.78, blue: 0.2, opacity: 1.0)  // 金黄

        for pos in food {
            let baseX = CGFloat(pos.col) * (scaledCellW + scaledSpacing)
            let baseY = CGFloat(pos.row) * (scaledCellH + scaledSpacing)
            // 比格子稍大的圆环，强调"目标"
            let inflate: CGFloat = 0.4
            let segW = scaledCellW * (1.0 + inflate)
            let segH = scaledCellH * (1.0 + inflate)
            let rect = CGRect(
                x: baseX - (segW - scaledCellW) / 2,
                y: baseY - (segH - scaledCellH) / 2,
                width: segW, height: segH
            )
            ctx.stroke(
                Path(ellipseIn: rect),
                with: .color(foodColor.opacity(pulse)),
                lineWidth: 1.5 * scale
            )
        }
    }
}

// MARK: - 颜色调色板

/// 贡献草坪颜色调色板（5 档 × 2 主题）。
///
/// 严格按照 GitHub 主页色值：
/// - light: `#ebedf0` (none) / `#9be9a8` / `#40c463` / `#30a14e` / `#216e39`
/// - dark : `#161b22` (none) / `#0e4429` / `#006d32` / `#26a641` / `#39d353`
///
/// 拆成独立结构而非散落 hex 字符串：①便于单测；②未来用户自定义主题时只换这一处。
struct ContributionPalette {
    let none: Color
    let l1: Color
    let l2: Color
    let l3: Color
    let l4: Color

    func color(for level: ContributionLevel) -> Color {
        switch level {
        case .none:            return none
        case .firstQuartile:   return l1
        case .secondQuartile:  return l2
        case .thirdQuartile:   return l3
        case .fourthQuartile:  return l4
        }
    }

    static let light = ContributionPalette(
        none: Color(hex6: 0xebedf0),
        l1:   Color(hex6: 0x9be9a8),
        l2:   Color(hex6: 0x40c463),
        l3:   Color(hex6: 0x30a14e),
        l4:   Color(hex6: 0x216e39)
    )

    static let dark = ContributionPalette(
        none: Color(hex6: 0x161b22),
        l1:   Color(hex6: 0x0e4429),
        l2:   Color(hex6: 0x006d32),
        l3:   Color(hex6: 0x26a641),
        l4:   Color(hex6: 0x39d353)
    )

    static func palette(for scheme: ColorScheme) -> ContributionPalette {
        scheme == .dark ? .dark : .light
    }
}

// MARK: - Color hex 便捷构造

/// 6 位 RGB hex int 构造 Color。
///
/// 之所以不复用项目里已有的 `Color(hex: String)` 扩展，是因为那个返回 Color? 并需要解析字符串；
/// 这里固定 6 位 RGB int 是编译期常量，更省运行时开销。
private extension Color {
    init(hex6: UInt32) {
        let r = Double((hex6 >> 16) & 0xFF) / 255.0
        let g = Double((hex6 >> 8) & 0xFF) / 255.0
        let b = Double(hex6 & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}

// MARK: - Preview

#Preview("Contribution Graph - 已加载（含贪吃蛇）") {
    let mockPayload = makeMockPayload()
    return VStack {
        ContributionGraphView(
            payload: mockPayload,
            lastFetchedAt: Date().addingTimeInterval(-3 * 60),
            login: "dong4j"
        )
        .frame(width: 260)
        .padding()
        .background(Color.gray.opacity(0.1))

        ContributionGraphView(
            payload: mockPayload,
            lastFetchedAt: Date().addingTimeInterval(-90 * 60),
            login: "dong4j"
        )
        .frame(width: 260)
        .padding()
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
    .padding()
    .environment(AppSettings.shared)
}

#Preview("Contribution Graph - 加载中") {
    ContributionGraphView(payload: nil, isLoading: true, login: nil)
        .frame(width: 260)
        .padding()
        .environment(AppSettings.shared)
}

/// 生成一份近似真实的 mock payload（53 周 × 7 天，随机分级），仅供 Preview 用。
private func makeMockPayload() -> ContributionCalendarPayload {
    let levels: [ContributionLevel] = [.none, .none, .none, .firstQuartile, .secondQuartile, .thirdQuartile, .fourthQuartile]
    let weeks = (0..<53).map { weekIdx -> ContributionWeek in
        let days = (0..<7).map { dayIdx -> ContributionDay in
            let level = levels.randomElement() ?? .none
            return ContributionDay(
                date: "2026-01-\(String(format: "%02d", weekIdx % 28 + 1))",
                contributionCount: Int.random(in: 0...20),
                contributionLevel: level,
                weekday: dayIdx
            )
        }
        return ContributionWeek(contributionDays: days)
    }
    return ContributionCalendarPayload(totalContributions: 1234, weeks: weeks)
}
