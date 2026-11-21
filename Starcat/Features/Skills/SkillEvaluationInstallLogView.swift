//
//  SkillEvaluationInstallLogView.swift
//  Starcat
//
//  两个评估入口共用的安装日志。展开与浏览位置属于各自面板，正文由应用服务保留。
//

import AppKit
import SwiftUI

/// 新日志有自己的视图身份，所以重试会自动展开，阶段变化和最终结果则保留用户的操作。
struct SkillEvaluationInstallLogView: View {
    let log: SkillEvaluationInstallLog

    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                            .font(interfaceScale.font(.captionSmall, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12 * interfaceScale.multiplier)
                            .accessibilityHidden(true)
                        Text("skills.evaluation.installLog.title")
                            .font(interfaceScale.font(.body, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityValue(isExpanded
                                    ? Text("settings.general.disclosure.expanded")
                                    : Text("settings.general.disclosure.collapsed"))

                CopyFeedbackButton(performCopy: copy, tooltip: "skills.evaluation.installLog.copy", style: .bordered) { copied in
                    Label("skills.evaluation.installLog.copy", systemImage: copied ? "checkmark.circle.fill" : "document.on.document")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(copied ? Color.green : Color.primary)
                }
                .controlSize(.small)
            }
            if isExpanded {
                Transcript(chunks: log.chunks, fontSize: 12 * interfaceScale.multiplier)
                    .frame(height: 208)
                    .clipShape(.rect(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor))
                            .allowsHitTesting(false)
                    }
            }
        }
    }

    /// 复制的是服务中的完整内容，即使正文折叠、或用户停在较早的段落也能复制。
    private func copy() -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(log.text, forType: .string)
    }

    /// 只追加新片段到原生可选文本。替换整个字符串会在实时输出时打断跨行选中和翻阅。
    private struct Transcript: NSViewRepresentable {
        let chunks: [String]
        let fontSize: CGFloat

        final class Coordinator {
            var displayedCount = 0
            var fontSize: CGFloat = 0
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSTextView.scrollableTextView()
            scroll.autohidesScrollers = true
            guard let text = scroll.documentView as? NSTextView else { return scroll }
            text.isEditable = false
            text.isSelectable = true
            text.isRichText = false
            text.isAutomaticLinkDetectionEnabled = false
            // 命令和安装路径通常很长，在正文宽度内折行，复制仍保留原始换行。
            text.isHorizontallyResizable = false
            text.textContainer?.widthTracksTextView = true
            text.textContainerInset = NSSize(width: 8, height: 8)
            text.setAccessibilityLabel(String.l10n("skills.evaluation.installLog.title"))
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            guard let text = scroll.documentView as? NSTextView, let storage = text.textStorage else { return }
            let coordinator = context.coordinator
            let newOutput = coordinator.displayedCount < chunks.count
            let newFont = coordinator.fontSize != fontSize
            guard newOutput || newFont else { return }

            // 首次载入从开头看。后续追加前读旧位置，只有在底部且未选中文字时才跟随。
            let followsTail = coordinator.displayedCount > 0 && newOutput
                && text.selectedRange().length == 0
                && scroll.documentVisibleRect.maxY >= text.bounds.maxY - 8
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            storage.beginEditing()
            if newOutput {
                let delta = chunks.dropFirst(coordinator.displayedCount).joined()
                storage.append(NSAttributedString(string: delta, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
                coordinator.displayedCount = chunks.count
            }
            if newFont {
                storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
                coordinator.fontSize = fontSize
            }
            storage.endEditing()
            if followsTail {
                text.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
            }
        }
    }
}
