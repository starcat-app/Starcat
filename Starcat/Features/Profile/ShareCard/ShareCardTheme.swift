//
//  ShareCardTheme.swift
//  Starcat
//
//  HOM-173 用户分享卡片：三种封面主题的色彩 / 调色板定义。
//
//  设计动机（来自 issue HOM-173 dong4j 最终方案）：
//  - 卡片布局必须三套主题保持一致（Magazine v2），仅切换配色。
//  - 既能表达"我是 GitHub 玩家"（绿色草坪），也能切到品牌中性色（黑白）或
//    传播向暖色（橙），让用户在不同社交平台都能选到合适的封面。
//
//  把"主题色板"独立成数据结构而不是散落在 View 里，是为了：
//  ① 主题枚举可在 Picker / 单测 / 持久化里复用（rawValue: String）
//  ② 草坪格子色与主标题色严格对齐——避免在 View 里手算配色丢失对照关系
//  ③ 未来加新主题（赛博紫 / 樱花粉…）只在这个文件加一个 case，不动 View 代码
//
//  与现有 `ContributionPalette`（草坪色板）解耦：本文件不引用 light/dark 系统
//  调色板，而是为分享卡专门定义"导出到图片"的固定色——分享图要在任何设备上看
//  起来都一样，不能跟着系统 colorScheme 飘。
//

import SwiftUI

/// 分享卡封面主题枚举。
///
/// `rawValue` 写英文（minimal / heatOrange / lightCard …）便于持久化与单测稳定，
/// 显示文案走 `Localizable.xcstrings` 的 `sharecard.theme.*` key（中英双语）。
///
/// **HOM-173 follow-up（2026-06-06）**：新增 `.lightCard` / `.darkCard` 两个 ID 卡风格主题——
/// dong4j 反馈"前 3 个杂志卡都好，但希望加个 ID 卡风：去掉草坪、去掉 follow，右下角是二维码"。
/// 为了不动既有 3 个主题的渲染路径，引入 `layout` 维度区分 magazine / idCard 两种布局。
enum ShareCardTheme: String, CaseIterable, Identifiable, Hashable {

    // MARK: - Magazine 布局（既有 3 个，HOM-173 v1）

    /// 极简黑白：纯黑底 + 白字 + 灰阶草坪。中性、克制，适合 LinkedIn / 简历类传播。
    case minimal = "minimal"
    /// 热力橙：深炭底 + 橙金高光。暖色驱动情绪，适合朋友圈 / 小红书。
    case heatOrange = "heatOrange"
    /// GitHub Green：深绿底 + GitHub 经典草坪绿。"我是 GitHub 玩家"的最直接表达。
    case githubGreen = "githubGreen"

    // MARK: - ID Card 布局（HOM-173 v2，2026-06-06 新增）

    /// 简约白卡：纯白底 + 黑字 + 大圆角头像 + 右下角 QR。
    /// 灵感来自 dong4j 提供的 ID 卡设计图（左侧白卡形态）。
    case lightCard = "lightCard"
    /// 极夜黑卡：纯黑底 + 白字 + 大圆角头像 + 右下角 QR。
    /// 灵感来自 dong4j 提供的 ID 卡设计图（右侧黑卡形态）。
    case darkCard = "darkCard"

    var id: String { rawValue }

    /// Picker 显示用的 i18n key。
    var localizationKey: LocalizedStringKey {
        switch self {
        case .minimal:      return "sharecard.theme.minimal"
        case .heatOrange:   return "sharecard.theme.heatOrange"
        case .githubGreen:  return "sharecard.theme.githubGreen"
        case .lightCard:    return "sharecard.theme.lightCard"
        case .darkCard:     return "sharecard.theme.darkCard"
        }
    }

    /// 主题对应的 SF Symbol（Picker 选项前缀图标）。
    var symbolName: String {
        switch self {
        case .minimal:      return "circle.lefthalf.filled"
        case .heatOrange:   return "flame.fill"
        case .githubGreen:  return "leaf.fill"
        case .lightCard:    return "person.text.rectangle"
        case .darkCard:     return "person.text.rectangle.fill"
        }
    }

    /// 取出该主题的实际色板。
    var palette: ShareCardPalette {
        switch self {
        case .minimal:      return .minimalPalette
        case .heatOrange:   return .heatOrangePalette
        case .githubGreen:  return .githubGreenPalette
        case .lightCard:    return .lightCardPalette
        case .darkCard:     return .darkCardPalette
        }
    }

    /// Picker 预览专用的色板对（background / accent 两色）。
    ///
    /// **为什么不直接复用 `palette.cardBackground` / `palette.accent`**
    /// （2026-06-06 dong4j 反馈："黑色卡片在明亮模式下太刺眼、暗黑模式下不明显，
    /// 换成更协调的颜色"）：
    /// - `palette` 是"导出图"的固定色，必然出现纯黑 `#0A0A0A` / 纯白 `#FFFFFF`
    /// - 在 picker 36×28pt 的小色块里：
    ///   * 纯黑在 light 模式下像"挖了个洞"过于刺眼
    ///   * 纯黑在 dark 模式下又与 sheet 背景融成一片
    ///   * 纯白在 light 模式下同样会融合（反向问题）
    /// - 这里返回 picker 专用色，特性：
    ///   1) 避开 #0A 以下和 #F5 以上的极端值
    ///   2) 保留每个主题的"色相记忆点"（橙的暖、绿的草、黑卡的灰、白卡的米）
    ///   3) 5 个主题相互之间视觉上仍可区分（避免 minimal vs darkCard 撞色）
    /// - 不影响导出图：导出走 `palette`，picker 走 `pickerSwatch`，两条独立路径。
    var pickerSwatch: (background: Color, accent: Color) {
        switch self {
        case .minimal:
            // 极简：深石墨 + 近白。比纯黑 #0B0B0F 柔一档，保留"克制中性"语义。
            return (Color.fromHex6(0x2C2C2E), Color.fromHex6(0xF5F5F7))
        case .heatOrange:
            // 热力橙：深暖棕 + 火焰橙。背景从 #1A0F0A 提亮到 #3A201A，
            // 减少"黑感"突出"棕暖"，accent 维持 palette 取色保持火焰识别度。
            return (Color.fromHex6(0x3A201A), Color.fromHex6(0xFF7A0F))
        case .githubGreen:
            // GitHub Green：墨绿 + 草坪绿。背景从 GitHub 蓝黑 #0D1117 提亮到 #0F2A1A，
            // 让"绿主题"在 picker 里更绿少黑，accent 维持草坪 #39D353。
            return (Color.fromHex6(0x0F2A1A), Color.fromHex6(0x39D353))
        case .lightCard:
            // 白卡：近白 + 深石墨。背景从纯白 #FFFFFF 微调到 #F5F5F7（macOS systemGray6），
            // 在 light sheet 里仍能与 sheet 背景区分；accent 从纯黑 #0A0A0A 提到 #3A3A3C
            // 让"白卡 + 黑徽章"对比柔和不刺眼。
            return (Color.fromHex6(0xF5F5F7), Color.fromHex6(0x3A3A3C))
        case .darkCard:
            // 黑卡：中度石墨 + 近白。比 minimal 浅整整一档（#48484A vs #2C2C2E），
            // 用"中灰 vs 深灰"双卡区分 minimal vs darkCard；accent 维持近白。
            return (Color.fromHex6(0x48484A), Color.fromHex6(0xF5F5F7))
        }
    }

    /// 卡片整体布局——magazine（既有杂志卡）或 idCard（新增 ID 卡）。
    ///
    /// 引入这个维度是为了让 `ShareCardContent` 在 body 里走两条独立渲染路径——
    /// **既有 3 个主题（minimal/heatOrange/githubGreen）零改动**，新主题独立加渲染分支，
    /// 把"加新主题"的影响半径锁在新文件 / 新分支内，避免回归。
    var layout: ShareCardLayout {
        switch self {
        case .minimal, .heatOrange, .githubGreen:
            return .magazine
        case .lightCard, .darkCard:
            return .idCard
        }
    }
}

/// 卡片布局类型。
enum ShareCardLayout {
    /// 杂志卡：顶栏 + 头像 + 三栏统计 + 草坪 + 注脚。HOM-173 v1。
    case magazine
    /// ID 卡：大圆角头像主图 + 用户名 + Bio + 底部（左 stats + 右 QR）。HOM-173 v2。
    case idCard
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
    /// - 极简主题需要灰阶草坪（none → 4 档不同灰度）
    /// - 热力橙主题需要橙色梯度
    /// - GitHub Green 主题才用经典绿
    /// 三套都自己持有，View 渲染时直接 `palette.contribution.color(for: level)`，
    /// 不再跟系统 colorScheme 绑定。
    let contribution: ContributionPalette
}

extension ShareCardPalette {

    // MARK: - 极简黑白

    /// 极简黑白：纯黑底 + 灰阶草坪。
    ///
    /// 配色逻辑：
    /// - 背景：#0B0B0F（近黑微蓝）→ #15151A（顶部稍亮一点形成柔和渐变）
    /// - 草坪：5 档纯灰梯度，none 用 #1F1F24（与背景区分但不抢眼），
    ///   l4 是 #FFFFFF（最贡献日 = 高光纯白），形成"贡献越多越亮"的极简观感。
    /// - 强调色：纯白 #FFFFFF。"分享到 X" 按钮也是白底黑字，呼应 X.com 的极简品牌。
    static let minimalPalette = ShareCardPalette(
        cardBackground: Color.fromHex6(0x0B0B0F),
        cardBackgroundSecondary: Color.fromHex6(0x15151A),
        cardBorder: Color.fromHex6(0x2A2A30),

        primaryText: Color.fromHex6(0xFFFFFF),
        secondaryText: Color.fromHex6(0xB8B8BE),
        tertiaryText: Color.fromHex6(0x6E6E76),

        accent: Color.fromHex6(0xFFFFFF),
        onAccent: Color.fromHex6(0x0B0B0F),

        divider: Color.fromHex6(0x2A2A30),

        contribution: ContributionPalette(
            none: Color.fromHex6(0x1F1F24),
            l1:   Color.fromHex6(0x4A4A52),
            l2:   Color.fromHex6(0x7A7A82),
            l3:   Color.fromHex6(0xB0B0B6),
            l4:   Color.fromHex6(0xFFFFFF)
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
