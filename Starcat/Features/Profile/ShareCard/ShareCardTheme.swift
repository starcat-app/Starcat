//
//  ShareCardTheme.swift
//  Starcat
//
//  HOM-173 用户分享卡片：封面版式 / 配色 / 调色板定义。
//
//  设计动机（来自 issue HOM-173 dong4j 最终方案）：
//  - 卡片的"版式"和"配色"必须独立：新增颜色不复制布局，新增布局不复制颜色。
//  - 既能表达"我是 GitHub 玩家"（绿色草坪），也能切到品牌中性色（靛蓝冰蓝）或
//    传播向暖色（橙），让用户在不同社交平台都能选到合适的封面。
//
//  把"版式 / 配色 / 色板"独立成数据结构而不是散落在 View 里，是为了：
//  ① 版式和配色枚举可在 Picker / 单测 / 持久化里复用（rawValue: String）
//  ② 草坪格子色与主标题色严格对齐——避免在 View 里手算配色丢失对照关系
//  ③ 未来加新配色（赛博紫 / 樱花粉…）只在这个文件加一个 case，不动 layout 代码
//
//  与现有 `ContributionPalette`（草坪色板）解耦：本文件不引用 light/dark 系统
//  调色板，而是为分享卡专门定义"导出到图片"的固定色——分享图要在任何设备上看
//  起来都一样，不能跟着系统 colorScheme 飘。
//

import SwiftUI

/// 分享卡版式枚举。
///
/// 2026-06-25 设计调整：把原先"主题 = 版式 + 配色"拆成两个维度。
/// 原编号 1-5 现在是同一个 `.magazine` 版式的 5 套配色；编号 6-7 是 `.idCard`
/// 版式的白/黑两套配色；新增版式默认复用 5 套传播向配色。
enum ShareCardStyle: String, CaseIterable, Identifiable, Hashable {
    /// 杂志卡：顶栏 + 头像 + 三栏统计 + 草坪 + 注脚。HOM-173 v1。
    case magazine = "magazine"
    /// ID 卡：大头像 + 身份区 + QR。HOM-173 v2。
    case idCard = "idCard"
    /// 海报：大头像居中 + 统计横幅，适合社交媒体首屏扫读。
    case poster = "poster"
    /// 数据看板：统计和草坪优先，适合强调 GitHub 活跃数据。
    case dashboard = "dashboard"
    /// 通行证：左侧身份 + 右侧 QR，模拟开发者 badge。
    case pass = "pass"
    /// 终端卡：命令行视觉，用等宽文本表达开发者身份。
    case terminal = "terminal"

    var id: String { rawValue }

    /// 样式按钮 tooltip / accessibility 使用的 i18n key。
    var localizationKey: LocalizedStringKey {
        switch self {
        case .magazine:  return "sharecard.style.magazine"
        case .idCard:    return "sharecard.style.idCard"
        case .poster:    return "sharecard.style.poster"
        case .dashboard: return "sharecard.style.dashboard"
        case .pass:      return "sharecard.style.pass"
        case .terminal:  return "sharecard.style.terminal"
        }
    }

    /// 当前版式允许的配色。ID 卡保留黑/白名片语义，其余版式共享传播向 5 色。
    var supportedColors: [ShareCardColorSet] {
        switch self {
        case .idCard:
            return [.lightCard, .darkCard]
        case .magazine, .poster, .dashboard, .pass, .terminal:
            return ShareCardColorSet.socialPalette
        }
    }

    /// 切换到当前版式时，如果当前配色不被支持，使用这个默认配色。
    var defaultColor: ShareCardColorSet {
        switch self {
        case .idCard:
            return .lightCard
        case .magazine, .poster, .dashboard, .pass, .terminal:
            return .githubGreen
        }
    }
}

/// 分享卡配色枚举。
///
/// `rawValue` 写英文（minimal / heatOrange / lightCard …）便于持久化与单测稳定，
/// 显示文案走 `Localizable.xcstrings` 的 `sharecard.theme.*` key（中英双语）。
enum ShareCardColorSet: String, CaseIterable, Identifiable, Hashable {
    /// 靛蓝冰蓝：靛蓝灰底 + 冰蓝高光 + 蓝阶草坪。中性克制，适合 LinkedIn / 简历类传播。
    case minimal = "minimal"
    /// 热力橙：深炭底 + 橙金高光。暖色驱动情绪，适合朋友圈 / 小红书。
    case heatOrange = "heatOrange"
    /// GitHub Green：深绿底 + GitHub 经典草坪绿。"我是 GitHub 玩家"的最直接表达。
    case githubGreen = "githubGreen"
    /// Aurora Blue：深海蓝底 + 青蓝高光。冷静、科技感，适合技术向分享。
    case auroraBlue = "auroraBlue"
    /// Berry Purple：深莓紫底 + 粉紫高光。更偏社交传播，补足暖橙之外的亮色选择。
    case berryPurple = "berryPurple"
    /// 简约白卡：纯白底 + 黑字 + 大圆角头像 + 右下角 QR。
    case lightCard = "lightCard"
    /// 极夜黑卡：纯黑底 + 白字 + 大圆角头像 + 右下角 QR。
    case darkCard = "darkCard"

    static let socialPalette: [ShareCardColorSet] = [
        .minimal, .heatOrange, .githubGreen, .auroraBlue, .berryPurple
    ]

    var id: String { rawValue }

    /// Picker 显示用的 i18n key。
    var localizationKey: LocalizedStringKey {
        switch self {
        case .minimal:      return "sharecard.theme.minimal"
        case .heatOrange:   return "sharecard.theme.heatOrange"
        case .githubGreen:  return "sharecard.theme.githubGreen"
        case .auroraBlue:   return "sharecard.theme.auroraBlue"
        case .berryPurple:  return "sharecard.theme.berryPurple"
        case .lightCard:    return "sharecard.theme.lightCard"
        case .darkCard:     return "sharecard.theme.darkCard"
        }
    }

    /// 取出该配色的实际色板。
    var palette: ShareCardPalette {
        switch self {
        case .minimal:      return .minimalPalette
        case .heatOrange:   return .heatOrangePalette
        case .githubGreen:  return .githubGreenPalette
        case .auroraBlue:   return .auroraBluePalette
        case .berryPurple:  return .berryPurplePalette
        case .lightCard:    return .lightCardPalette
        case .darkCard:     return .darkCardPalette
        }
    }

    /// Picker 预览专用的色板对（background / accent 两色）。
    ///
    /// **为什么不直接复用 `palette.cardBackground` / `palette.accent`**：
    /// 导出色板可能出现纯黑 / 纯白，在 30pt 小色块里会过暗、过亮或融入背景。
    /// pickerSwatch 单独避开极端明度，只保留每套配色的色相记忆点。
    var pickerSwatch: (background: Color, accent: Color) {
        switch self {
        case .minimal:
            return (Color.fromHex6(0x27324A), Color.fromHex6(0xB8D7FF))
        case .heatOrange:
            return (Color.fromHex6(0x3A201A), Color.fromHex6(0xFF7A0F))
        case .githubGreen:
            return (Color.fromHex6(0x0F2A1A), Color.fromHex6(0x39D353))
        case .auroraBlue:
            return (Color.fromHex6(0x102A43), Color.fromHex6(0x38BDF8))
        case .berryPurple:
            return (Color.fromHex6(0x3B1D4A), Color.fromHex6(0xF472B6))
        case .lightCard:
            return (Color.fromHex6(0xD8F3F0), Color.fromHex6(0x155E75))
        case .darkCard:
            return (Color.fromHex6(0x4C3A64), Color.fromHex6(0xC4B5FD))
        }
    }
}

/// 分享卡色板。
///
/// 字段命名按"功能位置"而非"色相"，目的是写 View 时按位置取色不用反查色相。
/// 例如 `accent` 永远是用于品牌强调（数字、标题装饰线、分享按钮底色），
/// 实际色相在不同主题下可能是橙、绿、白——但调用点的语义不变。
struct ShareCardPalette {
    /// 卡片整体背景色（卡片不再用渐变叠加用户头像主色，因为分享出去是固定图，
    /// 跟随头像主色会让"同一个人发不同主题"配色还是一样，失去主题切换的意义）。
    let cardBackground: Color
    /// 卡片背景的副色，用作渐变第二点（让深色背景有一点呼吸感而不是死黑死绿）。
    let cardBackgroundSecondary: Color
    /// 卡片描边（极细描边，区分卡片与外层 sheet 背景）。
    let cardBorder: Color

    /// 主文字色（用户名 / 大标题）。
    let primaryText: Color
    /// 次级文字色（@login / Bio / 标签）。
    let secondaryText: Color
    /// 三级文字色（提示、品牌注脚）。
    let tertiaryText: Color

    /// 品牌强调色：数字、装饰线、"分享到 X" 主按钮底色。
    let accent: Color
    /// accent 之上的前景色（按钮文字 / 数字内文）。
    let onAccent: Color

    /// 分隔线颜色（统计栏分隔条 / 顶部底部装饰横线）。
    let divider: Color

    /// 草坪 5 档色（none / l1 / l2 / l3 / l4），与 GitHub 主页同结构。
    /// 之所以独立一份而不是复用 `ContributionPalette`：
    /// - 靛蓝冰蓝主题需要蓝阶草坪（none → 4 档靛蓝到冰蓝）
    /// - 热力橙主题需要橙色梯度
    /// - GitHub Green 主题才用经典绿
    /// 三套都自己持有，View 渲染时直接 `palette.contribution.color(for: level)`，
    /// 不再跟系统 colorScheme 绑定。
    let contribution: ContributionPalette
}

extension ShareCardPalette {

    // MARK: - 靛蓝冰蓝

    /// 靛蓝冰蓝：靛蓝灰底 + 冰蓝高光 + 蓝阶草坪。
    ///
    /// 配色逻辑（2026-06-25 dong4j 反馈：第一个主题不要黑白灰，草坪要有色相）：
    /// - 背景：#1E2840（靛蓝灰）→ #27324A（顶部稍亮），与 picker 色块一致。
    /// - 草坪：5 档靛蓝→冰蓝梯度，none 贴近背景，l4 用 #B8D7FF 与 accent 呼应。
    /// - 强调色：#B8D7FF 冰蓝；onAccent 用深靛蓝保证按钮 / 数字可读。
    static let minimalPalette = ShareCardPalette(
        cardBackground: Color.fromHex6(0x1E2840),
        cardBackgroundSecondary: Color.fromHex6(0x27324A),
        cardBorder: Color.fromHex6(0x3A4A66),

        primaryText: Color.fromHex6(0xF0F4FF),
        secondaryText: Color.fromHex6(0xA8BDE0),
        tertiaryText: Color.fromHex6(0x6B7FA3),

        accent: Color.fromHex6(0xB8D7FF),
        onAccent: Color.fromHex6(0x1E2840),

        divider: Color.fromHex6(0x3A4A66),

        contribution: ContributionPalette(
            none: Color.fromHex6(0x1A2236),
            l1:   Color.fromHex6(0x2A4266),
            l2:   Color.fromHex6(0x4A6E99),
            l3:   Color.fromHex6(0x7AA8D4),
            l4:   Color.fromHex6(0xB8D7FF)
        )
    )

    // MARK: - 热力橙

    /// 热力橙：深炭底 + 橙金高光。
    ///
    /// 配色逻辑：
    /// - 背景：#1A0F0A（深棕红）→ #2A1810（顶部淡棕），暗示"火光"。
    /// - 草坪：5 档橙金梯度 #2D1F15 → #FFB44D → #FF7A0F，从干柴到火焰。
    /// - 强调色：#FF7A0F（GitHub commit 火焰橙），用在数字、连续提交进度条、
    ///   "分享到 X"按钮底色——按钮选 onAccent=黑保证对比度（橙底白字眩光）。
    static let heatOrangePalette = ShareCardPalette(
        cardBackground: Color.fromHex6(0x1A0F0A),
        cardBackgroundSecondary: Color.fromHex6(0x2A1810),
        cardBorder: Color.fromHex6(0x4A2818),

        primaryText: Color.fromHex6(0xFFF6E8),
        secondaryText: Color.fromHex6(0xE6BFA0),
        tertiaryText: Color.fromHex6(0x9E7350),

        accent: Color.fromHex6(0xFF7A0F),
        onAccent: Color.fromHex6(0x1A0F0A),

        divider: Color.fromHex6(0x4A2818),

        contribution: ContributionPalette(
            none: Color.fromHex6(0x2D1F15),
            l1:   Color.fromHex6(0x7A3F0A),
            l2:   Color.fromHex6(0xC56716),
            l3:   Color.fromHex6(0xFFB44D),
            l4:   Color.fromHex6(0xFF7A0F)
        )
    )

    // MARK: - GitHub Green

    /// GitHub Green：深绿底 + GitHub 经典草坪绿。
    ///
    /// 配色逻辑：
    /// - 背景：#0D1117（GitHub dark mode 底色）→ #161B22（GitHub canvas-default
    ///   sidebar 色），让用过 GitHub 的人一眼觉得熟悉。
    /// - 草坪：直接复用 ContributionPalette.dark 的官方 5 档色——
    ///   #161b22 / #0e4429 / #006d32 / #26a641 / #39d353。
    /// - 强调色：#39D353（GitHub 草坪 l4 的最亮绿）。"分享到 X"按钮也用这个色，
    ///   配 onAccent=深绿黑（#0D1117）保证可读。
    static let githubGreenPalette = ShareCardPalette(
        cardBackground: Color.fromHex6(0x0D1117),
        cardBackgroundSecondary: Color.fromHex6(0x161B22),
        cardBorder: Color.fromHex6(0x30363D),

        primaryText: Color.fromHex6(0xF0F6FC),
        secondaryText: Color.fromHex6(0x8B949E),
        tertiaryText: Color.fromHex6(0x6E7681),

        accent: Color.fromHex6(0x39D353),
        onAccent: Color.fromHex6(0x0D1117),

        divider: Color.fromHex6(0x30363D),

        contribution: ContributionPalette(
            none: Color.fromHex6(0x161B22),
            l1:   Color.fromHex6(0x0E4429),
            l2:   Color.fromHex6(0x006D32),
            l3:   Color.fromHex6(0x26A641),
            l4:   Color.fromHex6(0x39D353)
        )
    )

    // MARK: - Aurora Blue

    /// Aurora Blue：深海蓝底 + 青蓝高光。
    ///
    /// 配色逻辑：
    /// - 背景：#071927 → #102A43，保持深色科技感，但比 GitHub Green 更冷、更蓝。
    /// - 草坪：青蓝梯度，none 用低饱和海军蓝，l4 用 #38BDF8 形成"极光"高光。
    /// - 强调色：#38BDF8。按钮 / 数字在深蓝底上对比明确，适合技术内容分享。
    static let auroraBluePalette = ShareCardPalette(
        cardBackground: Color.fromHex6(0x071927),
        cardBackgroundSecondary: Color.fromHex6(0x102A43),
        cardBorder: Color.fromHex6(0x1E4E6D),

        primaryText: Color.fromHex6(0xE0F2FE),
        secondaryText: Color.fromHex6(0x93C5FD),
        tertiaryText: Color.fromHex6(0x5B8FB9),

        accent: Color.fromHex6(0x38BDF8),
        onAccent: Color.fromHex6(0x071927),

        divider: Color.fromHex6(0x1E4E6D),

        contribution: ContributionPalette(
            none: Color.fromHex6(0x0B2638),
            l1:   Color.fromHex6(0x075985),
            l2:   Color.fromHex6(0x0284C7),
            l3:   Color.fromHex6(0x0EA5E9),
            l4:   Color.fromHex6(0x38BDF8)
        )
    )

    // MARK: - Berry Purple

    /// Berry Purple：深莓紫底 + 粉紫高光。
    ///
    /// 配色逻辑：
    /// - 背景：#1F102A → #321845，和既有橙 / 绿 / 蓝拉开色相距离。
    /// - 草坪：紫到莓粉的 5 档梯度，视觉更社交、更适合发图传播。
    /// - 强调色：#F472B6；onAccent 用深紫，保证粉色按钮和数字区域的可读性。
    static let berryPurplePalette = ShareCardPalette(
        cardBackground: Color.fromHex6(0x1F102A),
        cardBackgroundSecondary: Color.fromHex6(0x321845),
        cardBorder: Color.fromHex6(0x5B2D73),

        primaryText: Color.fromHex6(0xFDF2F8),
        secondaryText: Color.fromHex6(0xF0ABFC),
        tertiaryText: Color.fromHex6(0xA77AB8),

        accent: Color.fromHex6(0xF472B6),
        onAccent: Color.fromHex6(0x1F102A),

        divider: Color.fromHex6(0x5B2D73),

        contribution: ContributionPalette(
            none: Color.fromHex6(0x2A1638),
            l1:   Color.fromHex6(0x6B21A8),
            l2:   Color.fromHex6(0xA21CAF),
            l3:   Color.fromHex6(0xDB2777),
            l4:   Color.fromHex6(0xF472B6)
        )
    )

    // MARK: - 简约白卡（ID Card 布局）

    /// 简约白卡：纯白底 + 黑字 + 浅灰描边。
    ///
    /// 配色逻辑（参考 dong4j 提供的设计图左侧白卡）：
    /// - 背景：#FFFFFF 纯白；secondary 给一点不可见的 #FAFAFA 让外层渐变路径不报错。
    /// - 卡片描边：#E5E7EB（与系统 separator 接近的浅灰），描出实体名片的"边"。
    /// - 主文字：#0A0A0A 近黑（不死黑，避免印刷感太重）。
    /// - 强调色：#0A0A0A 黑——`accent` 在 ID 卡布局里用作"verified 徽章背景"和"stats pill 背景"。
    /// - 草坪色板：白卡不渲染草坪，但 palette 字段必须填——给一份纯灰梯度兜底，
    ///   防止未来不小心用 `palette.contribution` 时出现透明色。
    static let lightCardPalette = ShareCardPalette(
        cardBackground: Color.fromHex6(0xFFFFFF),
        cardBackgroundSecondary: Color.fromHex6(0xFAFAFA),
        cardBorder: Color.fromHex6(0xE5E7EB),

        primaryText: Color.fromHex6(0x0A0A0A),
        secondaryText: Color.fromHex6(0x4B5563),
        tertiaryText: Color.fromHex6(0x9CA3AF),

        accent: Color.fromHex6(0x0A0A0A),
        onAccent: Color.fromHex6(0xFFFFFF),

        divider: Color.fromHex6(0xE5E7EB),

        contribution: ContributionPalette(
            none: Color.fromHex6(0xF3F4F6),
            l1:   Color.fromHex6(0xD1D5DB),
            l2:   Color.fromHex6(0x9CA3AF),
            l3:   Color.fromHex6(0x4B5563),
            l4:   Color.fromHex6(0x0A0A0A)
        )
    )

    // MARK: - 极夜黑卡（ID Card 布局）

    /// 极夜黑卡：纯黑底 + 白字 + 微亮描边。
    ///
    /// 配色逻辑（参考 dong4j 提供的设计图右侧黑卡）：
    /// - 背景：#0A0A0A 近黑（不死黑保留少量"墨黑"质感）；secondary 略亮 #141414 给外层渐变。
    /// - 卡片描边：#262626（dark-mode separator 量级），勾出卡片轮廓避免与外层 sheet 融成一片。
    /// - 主文字：#FAFAFA（不死白，更柔和）。
    /// - 强调色：白 #FFFFFF——黑卡上"verified 徽章 / stats pill"反色，与白卡互为镜像。
    /// - 草坪色板：黑卡也不渲染草坪，给一份反向灰梯度（none 最暗 / l4 最亮）兜底。
    static let darkCardPalette = ShareCardPalette(
        cardBackground: Color.fromHex6(0x0A0A0A),
        cardBackgroundSecondary: Color.fromHex6(0x141414),
        cardBorder: Color.fromHex6(0x262626),

        primaryText: Color.fromHex6(0xFAFAFA),
        secondaryText: Color.fromHex6(0xA3A3A3),
        tertiaryText: Color.fromHex6(0x6B7280),

        accent: Color.fromHex6(0xFFFFFF),
        onAccent: Color.fromHex6(0x0A0A0A),

        divider: Color.fromHex6(0x262626),

        contribution: ContributionPalette(
            none: Color.fromHex6(0x171717),
            l1:   Color.fromHex6(0x404040),
            l2:   Color.fromHex6(0x737373),
            l3:   Color.fromHex6(0xA3A3A3),
            l4:   Color.fromHex6(0xFAFAFA)
        )
    )
}

// MARK: - hex int → Color 便捷构造

/// 6 位 RGB hex int 构造 Color。
///
/// **为什么不用 `Color(hex6:)` 这个名字**：`ContributionGraphView.swift` 已经有
/// 一个 `private extension Color { init(hex6: UInt32) }`，虽然 fileprivate，
/// 但 Swift 编译器在 module 维度仍会拦"两个相同 signature 的 init"，导致
/// `invalid redeclaration of 'init(hex6:)'`。这里改用全局 `Color.fromHex6(_:)`
/// 静态工厂，避开 init 冲突，同时让本目录文件能共享同一份转换逻辑。
extension Color {
    /// 6 位 RGB hex int → Color（sRGB，全不透明）。
    /// 例：`Color.fromHex6(0xFF7A0F)` → 火焰橙。
    static func fromHex6(_ hex: UInt32) -> Color {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
