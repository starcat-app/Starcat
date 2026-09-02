//
//  BorderBeamSearchField.swift
//  Starcat
//
//  独立于 SmartSearchField 的 Border Beam 搜索条实验组件。
//
//  为什么单独新建：
//  - dong4j 要用 [BorderBeamKit](https://github.com/Jakubantalik/Libraries) 验证
//    demo 里 Search（`size: .line`）的视觉效果，再决定是否替换正式 toolbar 搜索；
//  - 正式 `SmartSearchField` 承载折叠/模式/Pro/历史等业务，实验期间禁止改动。
//
//  关键约束：
//  - 仅作视觉验收；交互只做本地输入草稿，不接 FTS5 / 语义搜索；
//  - `#if DEBUG` 整文件门控，Release 不编译实验 UI；
//  - Reduce Motion / 失活时把 `active` 关掉，避免 Metal 动画空转。
//

#if DEBUG
import BorderBeamKit
import SwiftUI

/// Border Beam `line` 预设包装的胶囊搜索条，对齐上游 demo 的 MockSearchBar 气质。
struct BorderBeamSearchField: View {
    @Binding var text: String

    /// 是否播放 beam 动画；外部可强制关闭做 A/B。
    var isBeamActive: Bool = true
    var colorVariant: BeamColorVariant = .colorful
    var theme: BeamTheme = .auto
    var strength: Double = 1
    var duration: Double = 3.1
    var onSubmit: ((String) -> Void)?

    @Environment(\.starcatReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool

    private let height: CGFloat = 42
    private let cornerRadius: Double = 20

    private var beamShouldRun: Bool {
        isBeamActive && !reduceMotion
    }

    var body: some View {
        BorderBeam(
            size: .line,
            colorVariant: colorVariant,
            theme: theme,
            duration: duration,
            active: beamShouldRun,
            borderRadius: cornerRadius,
            strength: strength
        ) {
            searchContent
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "Border Beam Search (Lab)"))
    }

    private var searchContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(
                "",
                text: $text,
                prompt: Text(verbatim: "Search")
            )
            .textFieldStyle(.plain)
            .font(.system(size: 15, weight: .regular))
            .focused($isFocused)
            .onSubmit {
                onSubmit?(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            if !text.isEmpty {
                Button {
                    text = ""
                    onSubmit?("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text(verbatim: "Clear"))
            }
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onTapGesture {
            isFocused = true
        }
    }
}

#Preview("BorderBeamSearchField") {
    @Previewable @State var text = ""
    BorderBeamSearchField(text: $text)
        .padding(40)
        .frame(width: 420)
}
#endif
