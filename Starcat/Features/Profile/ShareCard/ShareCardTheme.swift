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
/// 2026-06-25 二次调整：保留最早的 2 种版式，其余 4 种按 dong4j 给的原型重做。
/// 原型里只因颜色不同而重复的样式（1/2、4/5）在这里合并为同一个 case，由
/// `supportedColors` 区分颜色，避免为了换色复制整套布局。
enum ShareCardStyle: String, CaseIterable, Identifiable, Hashable {
    /// 杂志卡：顶栏 + 头像 + 三栏统计 + 草坪 + 注脚。HOM-173 v1。
    case magazine = "magazine"
    /// ID 卡：大头像 + 身份区 + QR。HOM-173 v2。
    case idCard = "idCard"
    /// 社交资料卡：原型 1/2 合并，深色 / 浅色由配色区分。
    case social = "social"
    /// 终端卡：原型 3，命令行视觉 + 绿色草坪数据。
    case terminal = "terminal"
    /// 冒险背景卡：原型 4，使用草地山丘背景图。
    case adventure = "adventure"
    /// 聚光海报卡：原型 4/5 的抽象渐变版本，颜色差异由配色区分。
    case spotlight = "spotlight"

    var id: String { rawValue }

    /// 样式按钮 tooltip / accessibility 使用的 i18n key。
    var localizationKey: LocalizedStringKey {
        switch self {
        case .magazine:  return "sharecard.style.magazine"
        case .idCard:    return "sharecard.style.idCard"
        case .social:    return "sharecard.style.social"
        case .terminal:  return "sharecard.style.terminal"
        case .adventure: return "sharecard.style.adventure"
        case .spotlight: return "sharecard.style.spotlight"
        }
    }

    /// 当前版式允许的配色。原型重复样式通过颜色区分，而不是复制 case。
    var supportedColors: [ShareCardColorSet] {
        switch self {
        case .idCard:
            return [.lightCard, .darkCard]
        case .social:
            return [.githubGreen, .lightCard, .auroraBlue, .berryPurple]
        case .terminal:
            return [.githubGreen, .minimal, .heatOrange, .auroraBlue]
        case .adventure:
            return [.lightCard, .adventureSunrise, .adventureShadow, .adventureFel]
        case .spotlight:
            return [.auroraBlue, .berryPurple]
        case .magazine:
            return ShareCardColorSet.socialPalette
        }
    }

    /// 切换到当前版式时，如果当前配色不被支持，使用这个默认配色。
    var defaultColor: ShareCardColorSet {
        switch self {
        case .idCard:
            return .lightCard
        case .social, .terminal:
            return .githubGreen
        case .adventure:
            return .lightCard
        case .spotlight:
            return .auroraBlue
        case .magazine:
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
    /// 暖阳冒险：第 5 种样式专属背景图变体，复用浅色文字色板，只替换插画背景。
    case adventureSunrise = "adventureSunrise"
    /// 暗影冒险：第 5 种样式专属黑暗背景变体，需要独立暗色文字 / 面板 / 草坪色板。
    case adventureShadow = "adventureShadow"
    /// 邪焰冒险：第 5 种样式专属黑暗绿光背景变体，使用独立荧绿色板。
    case adventureFel = "adventureFel"

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
        case .adventureSunrise: return "sharecard.theme.adventureSunrise"
        case .adventureShadow:  return "sharecard.theme.adventureShadow"
        case .adventureFel:     return "sharecard.theme.adventureFel"
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
        case .adventureSunrise:
            // 这个 case 是第 5 种样式的背景图开关，不引入新的排版或文字色规则；
            // 复用 lightCard 色板能保持现有冒险样式在浅色插画上的可读性。
            return .lightCardPalette
        case .adventureShadow:
            return .adventureShadowPalette
        case .adventureFel:
            return .adventureFelPalette
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
        case .adventureSunrise:
            return (Color.fromHex6(0xFFE7A6), Color.fromHex6(0xF59E0B))
        case .adventureShadow:
            return (Color.fromHex6(0x241B2A), Color.fromHex6(0xFF6B4A))
        case .adventureFel:
            return (Color.fromHex6(0x1D2420), Color.fromHex6(0xA3E635))
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

    /// 简约白卡：纯白底 + 彩色强调 + 绿色草坪。
    ///
    /// 配色逻辑（2026-06-25 dong4j 反馈：第 3 套白色主题不要黑白灰墓碑感）：
    /// - 背景：#FFFFFF 纯白，secondary 也保持纯白，避免导出卡片发灰。
    /// - 强调色：蓝色负责链接 / 标题点缀，头像和统计图标在 View 层再做语义色。
    /// - 草坪：白卡使用 GitHub light 绿色草坪，不再使用灰阶贡献图。
    static let lightCardPalette = ShareCardPalette(
        cardBackground: Color.fromHex6(0xFFFFFF),
        cardBackgroundSecondary: Color.fromHex6(0xFFFFFF),
        cardBorder: Color.fromHex6(0xDBEAFE),

        primaryText: Color.fromHex6(0x111827),
        secondaryText: Color.fromHex6(0x475569),
        tertiaryText: Color.fromHex6(0x94A3B8),

        accent: Color.fromHex6(0x2563EB),
        onAccent: Color.fromHex6(0xFFFFFF),

        divider: Color.fromHex6(0xD7DEE8),

        contribution: ContributionPalette(
            none: Color.fromHex6(0xEBEDF0),
            l1:   Color.fromHex6(0x9BE9A8),
            l2:   Color.fromHex6(0x40C463),
            l3:   Color.fromHex6(0x30A14E),
            l4:   Color.fromHex6(0x216E39)
        )
    )

    // MARK: - 暗影冒险（Adventure 布局）

    /// 暗影冒险：深紫黑底 + 熔火红高光 + 暗红草坪。
    ///
    /// 这是第 5 种样式的黑暗插画专用色板，不复用 `darkCardPalette`：
    /// - 黑卡是 ID Card 布局，强调黑白反差；暗影冒险需要和背景里的红云 / 火光同频。
    /// - 底部语言面板与贡献草坪会覆盖在暗色插画上，必须给足透明深底和暖色描边。
    /// - 草坪若继续用 GitHub 绿会和背景氛围冲突，所以改成暗红阶梯。
    static let adventureShadowPalette = ShareCardPalette(
        cardBackground: Color.fromHex6(0x15111C),
        cardBackgroundSecondary: Color.fromHex6(0x241B2A),
        cardBorder: Color.fromHex6(0x5A2B36),

        primaryText: Color.fromHex6(0xFFF1E8),
        secondaryText: Color.fromHex6(0xD7A6A0),
        tertiaryText: Color.fromHex6(0x9E6B72),

        accent: Color.fromHex6(0xFF6B4A),
        onAccent: Color.fromHex6(0x1A0F14),

        divider: Color.fromHex6(0x6B2E3A),

        contribution: ContributionPalette(
            none: Color.fromHex6(0x261C26),
            l1:   Color.fromHex6(0x4A1F2E),
            l2:   Color.fromHex6(0x7A2E39),
            l3:   Color.fromHex6(0xC2413F),
            l4:   Color.fromHex6(0xFF6B4A)
        )
    )

    // MARK: - 邪焰冒险（Adventure 布局）

    /// 邪焰冒险：近黑绿灰底 + 荧绿高光 + 暗绿草坪。
    ///
    /// 这张背景里的高亮集中在绿色裂隙和武器轮廓上，所以色板不复用红色暗影：
    /// - `accent` 使用偏黄的荧绿，能和背景光源同频，同时在深色面板上保持清晰。
    /// - `secondaryText` 保留少量暖黄绿，避免纯灰文字在暗紫云层上显脏。
    /// - 草坪改成暗绿阶梯，让底部贡献图成为背景绿光的延续，而不是额外贴一块 GitHub 绿。
    static let adventureFelPalette = ShareCardPalette(
        cardBackground: Color.fromHex6(0x111511),
        cardBackgroundSecondary: Color.fromHex6(0x1D2420),
        cardBorder: Color.fromHex6(0x3F5F34),

        primaryText: Color.fromHex6(0xF2F7E8),
        secondaryText: Color.fromHex6(0xBED7A3),
        tertiaryText: Color.fromHex6(0x7D9B65),

        accent: Color.fromHex6(0xA3E635),
        onAccent: Color.fromHex6(0x11160A),

        divider: Color.fromHex6(0x36522E),

        contribution: ContributionPalette(
            none: Color.fromHex6(0x20251F),
            l1:   Color.fromHex6(0x2F4626),
            l2:   Color.fromHex6(0x4F7F2C),
            l3:   Color.fromHex6(0x76B82A),
            l4:   Color.fromHex6(0xB8F84A)
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
