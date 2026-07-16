//
//  RAGWorkspaceTypography.swift
//  Starcat
//
//  知识库 RAG 工作台共用字体、胶囊样式与轻量状态类型。
//

import SwiftUI

/// RAG 对话正文与左侧会话标题共用的字号 token。
///
/// 用户问题、AI 正文和 Composer 必须保持同一字号；字重仍由各自场景决定，
/// 避免选中会话标题的 semibold 意外传到正文。
enum RAGConversationTypography {
    static let text = StarcatTypography.bodyEmphasis
}

enum RAGFontRole {
    case headline, subheadline, body, callout, caption, caption2

    var typography: StarcatTypography {
        switch self {
        case .headline: return .panelTitle
        case .subheadline: return .rowTitle
        case .body: return .body
        case .callout: return .bodyEmphasis
        case .caption: return .caption
        case .caption2: return .captionSmall
        }
    }
}

func ragFont(
    _ role: RAGFontRole,
    scale: InterfaceScale,
    weight: Font.Weight? = nil,
    design: Font.Design = .default
) -> Font {
    scale.font(role.typography, weight: weight, design: design)
}

func iconFont(
    size: CGFloat,
    scale: InterfaceScale,
    weight: Font.Weight = .regular
) -> Font {
    scale.font(size: size, weight: weight)
}

/// 输入框底栏模型 / 范围菜单胶囊。
/// 关键约束：
/// - 必须用 `Capsule()`；`RoundedRectangle(cornerRadius: 7)` 看起来仍是圆角矩形，胶囊样式不会生效。
/// - 底色不用 `.thinMaterial`：材质在深色输入区上与背景糊成一片，胶囊轮廓几乎不可见
///   （dong4j 2026-07-15 截图反馈）。改用与上方上下文 chip 同款的 `Color.primary` 低透明度
///   实底 + 细描边，透明度在黑白主题下都能自适应，轮廓清晰。
extension View {
    func ragComposerCapsuleChip(font: Font) -> some View {
        self
            .font(font)
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
    }

    /// 输入区上方的「上下文 chip」（@仓库 / 附件 / 链接）胶囊底。
    /// 关键约束：用 `Color.primary` 低透明度实底 + 细描边，取代 `.thinMaterial`——
    /// 后者在浅色输入区上对比过低、且明暗主题观感不一致；primary 透明度在黑白主题下都能自适应。
    func ragContextChipCapsule() -> some View {
        self
            .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
    }
}

/// 用户 / AI 消息头像统一边长，保证两侧视觉对称。
enum RAGMessageAvatarMetrics {
    static let size: CGFloat = 26
    static let cornerRadius: CGFloat = 5
}

/// 助手消息头像下方的阅读列宽度：Think 时间线、正文 Markdown、引用与操作条共用同一上限，
/// 避免宽屏下执行轨迹铺满而正文仍停在较窄列里的视觉错位。
enum RAGMessageContentMetrics {
    static let maxWidth: CGFloat = 900
}

enum RAGConversationDropTarget: Equatable {
    case group(UUID)
    case ungrouped
}

enum RAGInspectorTab: String, CaseIterable, Identifiable {
    case evidence
    case plan
    case index
    #if DEBUG
    case debug
    #endif

    var id: String { rawValue }
    var titleKey: LocalizedStringKey {
        switch self {
        case .evidence: return "rag.workspace.inspector.tab.evidence"
        case .plan: return "rag.workspace.inspector.tab.plan"
        case .index: return "rag.workspace.inspector.tab.index"
        #if DEBUG
        case .debug: return "rag.workspace.inspector.tab.debug"
        #endif
        }
    }
}
