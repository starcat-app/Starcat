//
//  AIPromptPlaceholderPopover.swift
//  Starcat
//
//  AI 设置 → Prompt 区的「可用占位符」说明。
//
//  设计约束：
//  - 交互对齐 RAG 工作台设置：底部入口按钮 → popover 内按 token 分行展示含义，
//    不再在设置页底部堆一长段 bullet 文案。
//  - 各 AIModelTask 占位符命名空间互不共享（与 AIDefaultPrompts 注释一致）。
//  - popover 内必须挂 `.appLocaleEnvironment()`（由调用方负责）。
//

import SwiftUI

/// 单条占位符：token 原文 + SF Symbol + 含义 i18n key。
struct AIPromptPlaceholderItem: Identifiable {
    let token: String
    let systemImage: String
    let meaningKey: LocalizedStringKey
    var id: String { token }
}

/// 某任务的占位符说明内容：条目列表 + 可选任务专属脚注。
struct AIPromptPlaceholderCatalog {
    let items: [AIPromptPlaceholderItem]
    /// 任务专属补充说明（如 Chat 不用 User Prompt）；通用「删占位符」注脚在 popover 里固定写。
    let footnoteKey: LocalizedStringKey?

    /// 按当前 Prompt 任务 tab 给出说明条目。
    static func catalog(
        for task: AIModelTask,
        translationMode: ReadmeTranslationMode = .segmented
    ) -> AIPromptPlaceholderCatalog {
        switch task {
        case .summary:
            return AIPromptPlaceholderCatalog(
                items: [
                    .init(token: "{outputLanguage}", systemImage: "globe", meaningKey: "settings.ai.prompt.placeholder.outputLanguage.summary"),
                    .init(token: "{metadata}", systemImage: "list.bullet.rectangle", meaningKey: "settings.ai.prompt.placeholder.metadata"),
                    .init(token: "{readme}", systemImage: "doc.text", meaningKey: "settings.ai.prompt.placeholder.readme"),
                    .init(token: "{codeContext}", systemImage: "chevron.left.forwardslash.chevron.right", meaningKey: "settings.ai.prompt.placeholder.codeContext"),
                    .init(token: "{externalContext}", systemImage: "network", meaningKey: "settings.ai.prompt.placeholder.externalContext"),
                ],
                footnoteKey: nil
            )
        case .tags:
            return AIPromptPlaceholderCatalog(
                items: [
                    .init(token: "{outputLanguage}", systemImage: "globe", meaningKey: "settings.ai.prompt.placeholder.outputLanguage.tags"),
                    .init(token: "{metadata}", systemImage: "list.bullet.rectangle", meaningKey: "settings.ai.prompt.placeholder.metadata"),
                    .init(token: "{readme}", systemImage: "doc.text", meaningKey: "settings.ai.prompt.placeholder.readme"),
                    .init(token: "{codeContext}", systemImage: "chevron.left.forwardslash.chevron.right", meaningKey: "settings.ai.prompt.placeholder.codeContext"),
                    .init(token: "{repoTags}", systemImage: "tag", meaningKey: "settings.ai.prompt.placeholder.repoTags"),
                    .init(token: "{libraryTags}", systemImage: "tray.full", meaningKey: "settings.ai.prompt.placeholder.libraryTags"),
                ],
                footnoteKey: nil
            )
        case .chat:
            return AIPromptPlaceholderCatalog(
                items: [
                    .init(token: "{outputLanguage}", systemImage: "globe", meaningKey: "settings.ai.prompt.placeholder.outputLanguage.chat"),
                    .init(token: "{metadata}", systemImage: "list.bullet.rectangle", meaningKey: "settings.ai.prompt.placeholder.metadata"),
                    .init(token: "{readme}", systemImage: "doc.text", meaningKey: "settings.ai.prompt.placeholder.readme"),
                    .init(token: "{codeContext}", systemImage: "chevron.left.forwardslash.chevron.right", meaningKey: "settings.ai.prompt.placeholder.codeContext"),
                    .init(token: "{summary}", systemImage: "text.alignleft", meaningKey: "settings.ai.prompt.placeholder.summary"),
                    .init(token: "{externalContext}", systemImage: "network", meaningKey: "settings.ai.prompt.placeholder.externalContext"),
                ],
                footnoteKey: "settings.ai.prompt.placeholders.footnote.chat"
            )
        case .embedding:
            return AIPromptPlaceholderCatalog(
                items: [
                    .init(token: "{fullName}", systemImage: "textformat", meaningKey: "settings.ai.prompt.placeholder.fullName"),
                    .init(token: "{description}", systemImage: "text.alignleft", meaningKey: "settings.ai.prompt.placeholder.description"),
                    .init(token: "{language}", systemImage: "character.book.closed", meaningKey: "settings.ai.prompt.placeholder.language"),
                    .init(token: "{topics}", systemImage: "number", meaningKey: "settings.ai.prompt.placeholder.topics"),
                    .init(token: "{license}", systemImage: "doc.badge.gearshape", meaningKey: "settings.ai.prompt.placeholder.license"),
                    .init(token: "{homepage}", systemImage: "link", meaningKey: "settings.ai.prompt.placeholder.homepage"),
                    .init(token: "{body}", systemImage: "doc.richtext", meaningKey: "settings.ai.prompt.placeholder.body"),
                    .init(token: "{notes}", systemImage: "note.text", meaningKey: "settings.ai.prompt.placeholder.notes"),
                ],
                footnoteKey: "settings.ai.prompt.placeholders.footnote.embedding"
            )
        case .translation:
            return AIPromptPlaceholderCatalog(
                items: [
                    .init(token: "{targetLanguage}", systemImage: "globe", meaningKey: "settings.ai.prompt.placeholder.targetLanguage"),
                    translationMode == .segmented
                        ? .init(
                            token: "{readmeSegments}",
                            systemImage: "text.alignleft",
                            meaningKey: "settings.ai.prompt.placeholder.readmeSegments"
                        )
                        : .init(
                            token: "{readmeTextNodes}",
                            systemImage: "text.page",
                            meaningKey: "settings.ai.prompt.placeholder.readmeTextNodes"
                        ),
                ],
                footnoteKey: "settings.ai.prompt.placeholders.footnote.translation"
            )
        }
    }
}

/// 占位符说明 Popover：当前任务的 token 与含义（视觉对齐 RAG 工作台）。
struct AIPromptPlaceholderPopover: View {
    let catalog: AIPromptPlaceholderCatalog

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "curlybraces")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("settings.ai.prompt.placeholders.title")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(catalog.items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .center)
                            .padding(.top, 2)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.token)
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                            Text(item.meaningKey)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Text("settings.ai.prompt.placeholders.note")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let footnoteKey = catalog.footnoteKey {
                Text(footnoteKey)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
