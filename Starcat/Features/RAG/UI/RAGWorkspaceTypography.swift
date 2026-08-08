//
//  RAGWorkspaceTypography.swift
//  Starcat
//
//  知识库 RAG 工作台共用字体、胶囊样式与轻量状态类型。
//

import SwiftUI

/// RAG 对话区的阅读层级 token。
///
/// 左侧标题、用户问题和 Composer 维持紧凑基线；AI 正文单独提高一级，补偿
/// Markdown regular 相对选中标题 semibold 的视觉尺寸差。执行步骤再按标题/详情递减。
enum RAGConversationTypography {
    static let text = StarcatTypography.bodyEmphasis
    static let answerText = StarcatTypography.rowTitle
    static let executionTitle = StarcatTypography.bodyEmphasis
    static let executionDetail = StarcatTypography.body
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

/// 输入框底栏模型 / 范围菜单的无边框样式。
/// 保留字号和点击留白，但不再绘制背景或描边，避免两个常驻菜单抢占输入区视觉层级。
extension View {
    func ragComposerMenuLabelStyle(font: Font) -> some View {
        self
            .font(font)
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
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

/// 侧栏标题编辑请求。
///
/// 必须由工作台根视图 `.sheet(item:)` 呈现：若挂在窄左栏上，macOS 会把 sheet
/// 压成接近系统 alert 的宽度，长对话标题仍然截断。
enum RAGWorkspaceTitleEditRequest: Identifiable, Equatable {
    case renameConversation(UUID)
    case renameGroup(UUID)
    case createGroup

    var id: String {
        switch self {
        case .renameConversation(let conversationID):
            return "rename-conversation-\(conversationID.uuidString)"
        case .renameGroup(let groupID):
            return "rename-group-\(groupID.uuidString)"
        case .createGroup:
            return "create-group"
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .renameConversation:
            return "rag.workspace.conversation.rename.title"
        case .renameGroup:
            return "rag.workspace.group.rename.title"
        case .createGroup:
            return "rag.workspace.group.create.title"
        }
    }

    var placeholderKey: LocalizedStringKey {
        switch self {
        case .renameConversation:
            return "rag.workspace.conversation.rename.placeholder"
        case .renameGroup, .createGroup:
            return "rag.workspace.group.rename.placeholder"
        }
    }
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
