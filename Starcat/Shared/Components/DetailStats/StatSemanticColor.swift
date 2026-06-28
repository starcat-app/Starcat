//
//  StatSemanticColor.swift
//  Starcat
//
//  详情页 / 搜索结果卡通用的 stat 语义色。
//
//  模块职责：
//  - 单一信息源管理 Stars / Forks / Watchers / Issues / Branch 等 stat 的主题色；
//  - light / dark 各一套 hex,避免亮色主题对比不足或暗色主题过艳；
//  - 提供 `resolved(colorScheme:)` 给 view 层消费,以及 `background(...)` 给 capsule 底色用。
//
//  关键约束：
//  - 不要用 `.tertiary` 或 systemColor 默认色:在 macOS SwiftUI 的 toolbar / 详情头里
//    对比度不稳定(参见 `docs/5-规范/UI-颜色规范.md`)。
//  - 新增 case 时必须同时给 lightHex / darkHex 两个分支补上,否则编译器会先报
//    non-exhaustive switch 提醒。
//  - 本 enum 历史出处:从 `SearchCenterView.swift` 的 `private enum SearchDetailSemanticColor`
//    (2026-06-21 引入,2026-06-29 抽到共享位置)抽出,case 一致,仅改名。
//

import SwiftUI

/// 详情 stat / 操作 chip 的语义色。
///
/// 用法:
/// ```swift
/// Image(systemName: "tuningfork")
///     .foregroundStyle(StatSemanticColor.fork.resolved(colorScheme: colorScheme))
/// ```
enum StatSemanticColor {
    case star
    case fork
    case watchers
    case issues
    case branch
    case language
    case wikiDeepWiki
    case wikiZread
    case wikiCodeWiki
    case actionStar
    case actionAI
    case actionGitHub

    /// 亮色主题下的图标 / 前景色。
    private var lightHex: UInt32 {
        switch self {
        case .star, .actionStar: return 0xD97706
        case .fork: return 0x2563EB
        case .watchers: return 0x7C3AED
        case .issues: return 0xDC2626
        case .branch: return 0x7C3AED
        case .language: return 0x059669
        case .wikiDeepWiki: return 0x4F46E5
        case .wikiZread: return 0x0891B2
        case .wikiCodeWiki: return 0x059669
        case .actionAI: return 0x9333EA
        case .actionGitHub: return 0x1F2937
        }
    }

    /// 暗色主题下的图标 / 前景色(整体提亮一档,保证深色底可读)。
    private var darkHex: UInt32 {
        switch self {
        case .star, .actionStar: return 0xFBBF24
        case .fork: return 0x60A5FA
        case .watchers: return 0xA78BFA
        case .issues: return 0xF87171
        case .branch: return 0xA78BFA
        case .language: return 0x34D399
        case .wikiDeepWiki: return 0x818CF8
        case .wikiZread: return 0x22D3EE
        case .wikiCodeWiki: return 0x34D399
        case .actionAI: return 0xC084FC
        case .actionGitHub: return 0xE5E7EB
        }
    }

    /// 当前主题下的色值。view 层用 `@Environment(\.colorScheme)` 拿主题后调用。
    func resolved(colorScheme: ColorScheme) -> Color {
        Color.fromHex6(colorScheme == .dark ? darkHex : lightHex)
    }

    /// capsule 底色透明度:暗色主题略高,hover 时再抬一档。
    func background(colorScheme: ColorScheme, hovered: Bool) -> Color {
        let base = colorScheme == .dark ? 0.20 : 0.12
        let hoverBoost = colorScheme == .dark ? 0.08 : 0.06
        let opacity = hovered ? base + hoverBoost : base
        return resolved(colorScheme: colorScheme).opacity(opacity)
    }
}