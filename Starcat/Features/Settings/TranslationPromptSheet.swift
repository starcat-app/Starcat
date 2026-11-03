//
//  TranslationPromptSheet.swift
//  Starcat
//
//  AI 翻译提示词的独立编辑入口：分段和全文模式只切换当前编辑的提示词，不复制模型配置。
//  所有输入和恢复默认仍由宿主提供的原绑定处理，关闭不新增保存或回滚流程。
//

import SwiftUI

/// 单一任务的原生提示词编辑弹窗；绑定工厂按模式定位存储，防止切换后误写另一模式。
@MainActor
struct TranslationPromptSheet: View {
    @Binding var mode: ReadmeTranslationMode
    let systemPrompt: (ReadmeTranslationMode) -> Binding<String>
    let userPrompt: (ReadmeTranslationMode) -> Binding<String>
    let onRestoreDefault: (ReadmeTranslationMode) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isPlaceholderHelpPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("settings.translation.ai.prompt")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .help(Text("settings.translation.ai.prompt"))
                Spacer(minLength: 8)
                SheetCloseButton(action: close)
            }

            Divider()

            // 选择器与整个两行说明块垂直居中，避免按标题基线对齐后显得上浮。
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.translation.layout.prompt.mode")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(Text("settings.translation.layout.prompt.mode"))
                    Text("settings.translation.layout.prompt.modeHelp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(Text("settings.translation.layout.prompt.modeHelp"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Picker("settings.ai.prompt.translation.mode.pickerLabel", selection: $mode) {
                    ForEach(ReadmeTranslationMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.displayNameKey)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("settings.ai.prompt.translation.mode.pickerLabel")
            }

            Divider()

            // 模式变化时重建两个原生编辑器，避免 NSTextView 保留旧模式的编辑状态或绑定。
            VStack(alignment: .leading, spacing: 12) {
                promptEditor(
                    title: "settings.ai.prompt.system",
                    text: systemPrompt(mode),
                    height: 180
                )
                Divider()
                promptEditor(
                    title: "settings.ai.prompt.user",
                    text: userPrompt(mode),
                    height: 80
                )
            }
            .id(mode)

            Divider()

            HStack(spacing: 12) {
                Spacer(minLength: 0)
                placeholderHelpButton
                ResetIconButton(
                    help: Text("settings.translation.ai.prompt.restoreHelp \(String.l10n(mode.displayNameKey))")
                ) {
                    onRestoreDefault(mode)
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
        .onChange(of: mode) { _, _ in
            // 关闭旧模式目录，下一次打开时按当前模式重新构建占位符帮助。
            isPlaceholderHelpPresented = false
        }
    }

    /// 保留原生编辑器的单一区域滚动与正文等宽字号，外层不再加入滚动表单。
    private func promptEditor(title: LocalizedStringKey, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextEditor(text: text)
                .font(.body.monospaced())
                .accessibilityLabel(title)
                .frame(height: height)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )
        }
    }

    /// 占位符目录继续读取原翻译模式的定义，不在弹窗中维护另一份模板规则。
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
            AIPromptPlaceholderPopover(catalog: AIPromptPlaceholderCatalog.catalog(
                for: .translation,
                translationMode: mode
            ))
            .appLocaleEnvironment()
        }
    }

    /// 提示词沿用原即时写入语义，完成和右上关闭都只结束展示。
    private func close() {
        dismiss()
    }
}
