//
//  ContributionGraphView.swift
//  Starcat
//
//  GitHub 贡献草坪 SwiftUI 原生渲染（53 周 × 7 天）+ 贪吃蛇动画。
//  HOM-PROFILE 2026-06-05 引入，2026-06-05 v2 加贪吃蛇，
//  2026-06-05 v3 修复"草坪太窄"（格子改 10×14 矩形 + aspectRatio 自适应消除空白）。
//
//  设计动机：
//  - dong4j 希望"零第三方依赖、自动适配明暗主题"。
//  - 比 Platane/snk 输出 SVG 再渲染更优：原生 Canvas 一次绘制完成、矢量缩放、
//    `Color` 自动响应 colorScheme，无需备双 SVG。
//  - **贪吃蛇模仿 snk 视觉**：蛇沿 zigzag 路径遍历 53×7 = 371 个格子，
//    蛇头经过的格子被"吃掉"变成 NONE 颜色（暂时性，下一轮重启时恢复）；
//    snk 的"最优蛇路径"是 NP-hard，我们用 zigzag 简化——视觉效果接近，工程零负担。
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
//  贪吃蛇渲染细节（snk 同款视觉）：
//  - **路径**：zigzag 横扫——奇数列从下到上，偶数列从上到下；GitHub 主页是
//    "最旧在左、最新在右"，蛇从最左侧 col 0 row 0 开始向右移动。
//  - **节奏**：每格 80ms，371 格约 30 秒走一轮，结束后 pause 1.5s 重启。
//  - **蛇身**：5 节，头部最饱和（用调色板 l4 色），尾部按 0.85 / 0.65 / 0.45 / 0.25
//    alpha 衰减；蛇头比格子稍大 (1.2x) 让它"包住"目标格子，符合 snk 视觉。
//  - **吃格**：蛇头到达过的格子（index < snakeHead）渲染为 NONE 色，
//    模拟"被吃掉"。下一轮 timeline 回到 phase 0 时，所有格子瞬时复原。
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    // MARK: - 贪吃蛇参数

    /// 蛇身段数；snk 默认 4，我们取 5 让尾迹更长更明显。
    private let snakeLength: Int = 5
    /// 每个格子停留多少秒；80ms 是节奏舒适区——肉眼能看清单格、又不至于太慢一直没走完。
    private let stepDuration: Double = 0.08
    /// 一轮结束后暂停多久再开始下一轮（让用户能短暂看到"完整草坪"形态）。
    private let pauseDuration: Double = 1.5

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
    /// reduceMotion 开启 → 仅画静态草坪（不绘蛇，避免前庭不适）。
    /// 否则 `TimelineView(.animation)` 驱动每帧重绘，由 elapsed time 算 snake head index。
    ///
    /// **scale 由 Canvas 内部算**：Canvas closure 的 `size` 参数就是实际渲染尺寸；
    /// 外层 aspectRatio 保证 size 与 intrinsicSize 等比，所以 scale = size.width / intrinsicSize.width
    /// 即可（scaleX == scaleY，取 width 即可）。
    @ViewBuilder
    private var gridContent: some View {
        if reduceMotion {
            Canvas { ctx, size in
                let scale = size.width / intrinsicSize.width
                drawGrid(ctx: ctx, scale: scale, snakeHeadIdx: -1)
            }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                let snakeHeadIdx = currentSnakeHeadIdx(at: context.date)
                Canvas { ctx, size in
                    let scale = size.width / intrinsicSize.width
                    drawGrid(ctx: ctx, scale: scale, snakeHeadIdx: snakeHeadIdx)
                    drawSnake(ctx: ctx, scale: scale, headIdx: snakeHeadIdx)
                }
            }
        }
    }

    /// 根据当前时间算蛇头在 path 上的 step index（[-1, pathCount)）。
    ///
    /// 返回 -1 表示当前处于"轮间暂停"，蛇暂时消失（草坪完整显示）。
    /// 否则返回 [0, pathCount) 中的某一格——蛇头正在的位置。
    ///
    /// 用 `truncatingRemainder` 实现循环；timeline 起始锚定 `timeIntervalSinceReferenceDate`
    /// 是稳定值，组件多次重建蛇仍能"接着上次走"，看不出突变。
    private func currentSnakeHeadIdx(at date: Date) -> Int {
        let pathCount = Self.snakePath.count
        let totalDuration = Double(pathCount) * stepDuration + pauseDuration
        let t = date.timeIntervalSinceReferenceDate
        let phase = t.truncatingRemainder(dividingBy: totalDuration)
        // phase 末尾 pauseDuration 秒进入暂停区，蛇消失
        let activeDuration = Double(pathCount) * stepDuration
        if phase >= activeDuration {
            return -1
        }
        return min(Int(phase / stepDuration), pathCount - 1)
    }

    /// 在 Canvas 上绘制 53×7 草坪。
    /// - Parameters:
    ///   - snakeHeadIdx: 当前蛇头位置；该位置及之前的格子被视为"已吃"，渲染 NONE 色。
    ///     传 -1 表示暂停区（蛇消失），所有格子按原始 level 渲染。
    private func drawGrid(ctx: GraphicsContext, scale: CGFloat, snakeHeadIdx: Int) {
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

                // 关键：判断该格是否在蛇头已走过的路径内
                let level = isEaten(col: col, row: row, snakeHeadIdx: snakeHeadIdx)
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

    /// 判断 (col, row) 是否在蛇头已走过的路径内（即"被吃掉"）。
    ///
    /// O(1) 查表 —— 用预构造的 `snakePathIndex` 反向映射，避免每格 O(N) 扫描 path。
    private func isEaten(col: Int, row: Int, snakeHeadIdx: Int) -> Bool {
        guard snakeHeadIdx >= 0 else { return false }
        let stepIdx = Self.snakePathIndex[col][row]
        // 蛇头自己也算被吃（蛇身覆盖了那格），所以是 <=
        return stepIdx <= snakeHeadIdx
    }

    /// 绘制蛇身（5 节，从蛇头往尾部 alpha 渐淡）。
    ///
    /// 蛇头比格子稍大（1.2x），向中心扩展——视觉上"咬"住目标格子，符合 snk 风格；
    /// 后续节按格子原尺寸 + alpha 渐淡画出尾迹。
    private func drawSnake(ctx: GraphicsContext, scale: CGFloat, headIdx: Int) {
        guard headIdx >= 0 else { return }
        let palette = ContributionPalette.palette(for: colorScheme)
        let snakeColor = palette.color(for: .fourthQuartile)
        let scaledCellW = cellWidth * scale
        let scaledCellH = cellHeight * scale
        let scaledSpacing = cellSpacing * scale
        let scaledCorner = cellCornerRadius * scale

        // alpha 衰减表：head 100% / 第2节 85% / 第3节 65% / 第4节 45% / 第5节 25%
        let alphas: [Double] = [1.0, 0.85, 0.65, 0.45, 0.25]

        for i in 0..<snakeLength {
            let segIdx = headIdx - i
            guard segIdx >= 0, segIdx < Self.snakePath.count else { continue }
            let (col, row) = Self.snakePath[segIdx]
            let baseX = CGFloat(col) * (scaledCellW + scaledSpacing)
            let baseY = CGFloat(row) * (scaledCellH + scaledSpacing)

            let alpha = alphas[i]
            // 蛇头放大到 1.2x，向中心展开（横纵各按各的格子尺寸算 inflate，
            // 保证矩形格子下蛇头依旧"贴边咬住"格子，不会变成奇怪的纵横比）。
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

    // MARK: - 蛇路径（静态预构造）

    /// zigzag 路径：53 列 × 7 行 = 371 步。
    ///
    /// 列向横扫：偶数列从上到下（row 0 → 6），奇数列从下到上（row 6 → 0），
    /// 起点 (col=0, row=0)，终点 (col=52, row=0)。
    /// snk 的"最优蛇路径"是 NP-hard 优化，我们用 zigzag 简化——
    /// 视觉效果接近 snk（蛇从左到右把草坪吃光），实现 0 复杂度。
    ///
    /// `static` 让所有 view 实例共享一份，App 生命周期内只构造一次。
    static let snakePath: [(col: Int, row: Int)] = {
        var path: [(Int, Int)] = []
        path.reserveCapacity(53 * 7)
        for col in 0..<53 {
            if col % 2 == 0 {
                for row in 0..<7 { path.append((col, row)) }
            } else {
                for row in (0..<7).reversed() { path.append((col, row)) }
            }
        }
        return path
    }()

    /// `snakePath` 的反向映射：`snakePathIndex[col][row] = step`。
    ///
    /// `drawGrid` 要 O(1) 判断"某个 (col, row) 是否被蛇头吃过"，O(N) 扫描 path
    /// 在 371 格 × 30 FPS 下会成为瓶颈；反向映射查表是常数时间。
    static let snakePathIndex: [[Int]] = {
        var m: [[Int]] = Array(repeating: Array(repeating: -1, count: 7), count: 53)
        for (idx, (col, row)) in snakePath.enumerated() {
            m[col][row] = idx
        }
        return m
    }()
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
}

#Preview("Contribution Graph - 加载中") {
    ContributionGraphView(payload: nil, isLoading: true, login: nil)
        .frame(width: 260)
        .padding()
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
