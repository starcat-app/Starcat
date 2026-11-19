//
//  MarkdownTypography.swift
//  Starcat
//
//  Markdown 阅读字号的单一来源。WebKit CSS 与 MarkdownUI 使用相同逻辑尺寸，
//  不复用用于紧凑表单的 13pt body token，也不重复叠加 Dynamic Type。
//

import MarkdownUI
import SwiftUI

/// 阅读正文、标题与代码的尺寸契约；保留现有阅读偏移键及用户已保存的设置。
enum MarkdownTypography {
    static let bodySize: CGFloat = 16
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
    static func bodyFontSize(scale: InterfaceScale, adjustment: Int = 0) -> CGFloat {
        scale.scaled(bodySize + CGFloat(AppSettings.clampedReadmeFontSizeAdjustment(adjustment)))
    }

    /// 提供基础排版；业务主题可继续追加表格、复制、图片等已有能力。
    @MainActor
    static func theme(scale: InterfaceScale, adjustment: Int = 0) -> Theme {
        Theme.basic
            .text {
                ForegroundColor(.primary)
                BackgroundColor(nil)
                FontSize(bodyFontSize(scale: scale, adjustment: adjustment))
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
    @Environment(\.starcatInterfaceScale) private var scale
    @Environment(AppSettings.self) private var settings: AppSettings?

    func body(content: Content) -> some View {
        content.markdownTheme(MarkdownTypography.theme(
            scale: scale, adjustment: settings?.readmeFontSizeAdjustment ?? 0
        ))
    }
}

/// 流式尾部保持纯 Text，避免重新解析；其字号必须与冻结块及完成态相同。
private struct StarcatMarkdownBodyFont: ViewModifier {
    @Environment(\.starcatInterfaceScale) private var scale
    @Environment(AppSettings.self) private var settings: AppSettings?

    func body(content: Content) -> some View {
        content.font(.system(size: MarkdownTypography.bodyFontSize(
            scale: scale, adjustment: settings?.readmeFontSizeAdjustment ?? 0
        )))
    }
}

extension View {
    /// 普通 MarkdownUI 阅读入口统一调用；专用主题直接从 MarkdownTypography.theme 派生。
    func starcatMarkdownStyle() -> some View { modifier(StarcatMarkdownStyle()) }

    /// 只用于与 Markdown 正文交接的纯文本尾部，不改变工具栏与辅助信息字号。
    func starcatMarkdownBodyFont() -> some View { modifier(StarcatMarkdownBodyFont()) }
}
