//
//  AITaskPromptSheet.swift
//  Starcat
//
//  当前任务的提示词或仓库向量化模板编辑入口：复用原生编辑器、重置和占位符帮助。
//  编辑直接使用原任务绑定，关闭只结束展示，不引入新的暂存、保存或回滚语义。
//

import SwiftUI

/// 由宿主指定任务及其绑定；任务能力限制与原设置页一致，不创建独立提示词副本。
@MainActor
struct AITaskPromptSheet: View {
    let task: AIModelTask
    @Binding var systemPrompt: String
    @Binding var userPromptTemplate: String
    let onRestoreDefault: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isPlaceholderHelpPresented = false

    var body: some View {
        // 内容结构和编辑区高度固定且规模小，由 SwiftUI 自动 sheet 持有自然高度。
        // 只有 TextEditor 的长文本内部滚动，表单本身不增加外层滚动容器。
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(verbatim: editorTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .help(Text(verbatim: editorTitle))
                Spacer(minLength: 8)
                SheetCloseButton(action: close)
            }

            Divider()

            // Embedding 没有 system role，对话也不套固定用户模板；不展示无效的灰色编辑区。
            if task.supportsSystemPrompt {
                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.ai.prompt.system")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextEditor(text: $systemPrompt)
                        // 可编辑提示词使用系统正文等宽字号，caption 仅用于辅助说明。
                        .font(.body.monospaced())
                        .accessibilityLabel("settings.ai.prompt.system")
                        .frame(height: 180)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                        )
                }
            }

            if task.supportsSystemPrompt && task.supportsUserPromptTemplate {
                Divider()
            }

            if task.supportsUserPromptTemplate {
                VStack(alignment: .leading, spacing: 6) {
                    Text(userPromptTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextEditor(text: $userPromptTemplate)
                        .font(.body.monospaced())
                        .accessibilityLabel(userPromptTitle)
                        // 仅一个输入模板时复用两编辑区的内容预算，不留下空白 system 区。
                        .frame(height: task.supportsSystemPrompt ? 80 : 260)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                        )
                }
            }

            Divider()

            HStack(spacing: 12) {
                Spacer(minLength: 0)
                placeholderHelpButton
                ResetIconButton(help: Text("settings.ai.prompt.restoreHelpFormat \(task.displayName)")) {
                    // 仍由宿主的原恢复函数写回当前任务，不复制默认提示词或修改其他任务。
                    onRestoreDefault()
                }
                Button("settings.ai.models.prompt.done", action: close)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 向量化配置编辑的是输入模板，而非生成型提示词；标题沿用对应功能的现有文案。
    private var editorTitle: String {
        task == .embedding
            ? String.l10n("settings.ai.models.embedding.template.title")
            : String(format: String.l10n("settings.ai.models.prompt.editorTitle"), task.displayName)
    }

    private var userPromptTitle: LocalizedStringKey {
        task == .embedding ? "settings.ai.models.embedding.template.title" : "settings.ai.prompt.user"
    }

    /// 保留原占位符目录与弹出帮助，目录只依赖当前任务，避免跨任务显示旧说明。
    private var placeholderHelpButton: some View {
        Button {
            isPlaceholderHelpPresented.toggle()
        } label: {
            Text("settings.ai.prompt.placeholders.open")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("settings.ai.prompt.placeholders.openHelp")
        .popover(isPresented: $isPlaceholderHelpPresented, arrowEdge: .top) {
            AIPromptPlaceholderPopover(catalog: AIPromptPlaceholderCatalog.catalog(for: task))
                .appLocaleEnvironment()
        }
    }

    /// 提示词沿用即时写入绑定；“完成”和右上关闭只关闭窗口，不额外保存或撤销。
    private func close() {
        dismiss()
    }
}
