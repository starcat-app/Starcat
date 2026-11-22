//
//  MarkdownTypography.swift
//  Starcat
//
//  Markdown 阅读字号的单一来源。WebKit CSS 与 MarkdownUI 使用相同逻辑尺寸，
//  不复用用于紧凑表单的 13pt body token，也不重复叠加 Dynamic Type。
//

import AppKit
import MarkdownUI
import SwiftUI

/// 阅读正文、标题与代码的尺寸契约；保留现有阅读偏移键及用户已保存的设置。
enum MarkdownTypography {
    /// 紧凑基准供仓库笔记、仓库 AI 助手及规范指定的编辑和查看入口共用。
    enum BodyBaseline: Int {
        case standard = 16
        case compact = 14
    }

    static let bodySize = CGFloat(BodyBaseline.standard.rawValue)
    static let inlineCodeRatio: CGFloat = 0.85
    static let codeBlockRatio: CGFloat = 1

    enum Heading: CaseIterable {
        case h1, h2, h3, h4, h5, h6

        var ratio: CGFloat {
            switch self {
            case .h1: 1.8
            case .h2: 1.45
            case .h3: 1.2
            case .h4: 1
            case .h5: 0.9
            case .h6: 0.85
            }
        }
    }

    /// 先钳制旧偏好，再缩放一次；WebView、原生 Markdown 与流式 Text 尾部共用。
    @MainActor
    static func bodyFontSize(
        scale: InterfaceScale,
        adjustment: Int = 0,
        baseline: BodyBaseline = .standard
    ) -> CGFloat {
        let adjustment = AppSettings.clampedReadmeFontSizeAdjustment(adjustment)
        return scale.scaled(CGFloat(baseline.rawValue + adjustment))
    }

    /// 原生编辑器与自绘占位提示共用阅读尺寸，避免系统默认正文退回 13pt。
    @MainActor
    static func nativeFont(
        scale: InterfaceScale,
        adjustment: Int = 0,
        baseline: BodyBaseline = .standard
    ) -> NSFont {
        .systemFont(ofSize: bodyFontSize(scale: scale, adjustment: adjustment, baseline: baseline))
    }

    /// 只改排版，不回填草稿或重置选择；typingAttributes 保证后续键入沿用同一字体。
    @MainActor
    @discardableResult
    static func applyEditorFont(_ font: NSFont, to textView: NSTextView) -> Bool {
        let changed = textView.font != font
        if changed {
            textView.font = font
            textView.needsDisplay = true
        }
        textView.typingAttributes[.font] = font
        return changed
    }

    /// 提供基础排版；业务主题可继续追加表格、复制、图片等已有能力。
    @MainActor
    static func theme(
        scale: InterfaceScale,
        adjustment: Int = 0,
        baseline: BodyBaseline = .standard
    ) -> Theme {
        Theme.basic
            .text {
                ForegroundColor(.primary)
                BackgroundColor(nil)
                FontSize(bodyFontSize(scale: scale, adjustment: adjustment, baseline: baseline))
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(inlineCodeRatio))
            }
            .heading1 { heading($0, level: .h1) }
            .heading2 { heading($0, level: .h2) }
            .heading3 { heading($0, level: .h3) }
            .heading4 { heading($0, level: .h4) }
            .heading5 { heading($0, level: .h5) }
            .heading6 { heading($0, level: .h6) }
            .codeBlock { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.15))
                        .relativePadding(.leading, length: .rem(1))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(codeBlockRatio))
                        }
                }
                .markdownMargin(top: .zero, bottom: .em(1))
            }
    }

    /// 保留基础主题的段落间距，只将六级标题的字号层级对齐共享阅读器。
    @MainActor
    private static func heading(_ configuration: BlockConfiguration, level: Heading) -> some View {
        configuration.label
            .markdownMargin(top: .rem(1.5), bottom: .rem(1))
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(.em(level.ratio))
            }
    }
}

/// 在 body 内读取 Observable 偏好，保证已打开窗口与冻结的 Markdown 块仍响应字号变化。
private struct StarcatMarkdownStyle: ViewModifier {
    let baseline: MarkdownTypography.BodyBaseline
    @Environment(\.starcatInterfaceScale) private var scale
    @Environment(AppSettings.self) private var settings: AppSettings?

    func body(content: Content) -> some View {
        content.markdownTheme(MarkdownTypography.theme(
            scale: scale, adjustment: settings?.readmeFontSizeAdjustment ?? 0, baseline: baseline
        ))
    }
}

/// 流式尾部保持纯 Text，避免重新解析；其字号必须与冻结块及完成态相同。
private struct StarcatMarkdownBodyFont: ViewModifier {
    let baseline: MarkdownTypography.BodyBaseline
    var weight: Font.Weight? = nil
    var design: Font.Design = .default
    @Environment(\.starcatInterfaceScale) private var scale
    @Environment(AppSettings.self) private var settings: AppSettings?

    func body(content: Content) -> some View {
        content.font(.system(size: MarkdownTypography.bodyFontSize(
            scale: scale, adjustment: settings?.readmeFontSizeAdjustment ?? 0, baseline: baseline
        ), weight: weight, design: design))
    }
}

extension View {
    /// 普通 MarkdownUI 阅读入口统一调用；专用主题直接从 MarkdownTypography.theme 派生。
    func starcatMarkdownStyle(baseline: MarkdownTypography.BodyBaseline = .standard) -> some View {
        modifier(StarcatMarkdownStyle(baseline: baseline))
    }

    /// 用于阅读尾部、内容输入及其占位提示；工具栏与辅助信息仍采用界面 token。
    func starcatMarkdownBodyFont(
        baseline: MarkdownTypography.BodyBaseline = .standard,
        weight: Font.Weight? = nil,
        design: Font.Design = .default
    ) -> some View {
        modifier(StarcatMarkdownBodyFont(baseline: baseline, weight: weight, design: design))
    }
}
