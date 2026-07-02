//
//  LibraryToggleButton.swift
//  Starcat
//
//  详情页 hero action 区的 Starcat 知识库入口。
//
//  设计约束：
//  - ❤️ 表达 Starcat 私有“入库”动作，不能与 GitHub Star 的 ⭐ 公开动作混用。
//  - 第一版先做 UI 与运行期二态反馈；持久化后续接入 `repo_notes.library_state`。
//  - 视觉尺寸对齐 Wiki / 推荐入口的 28×28 capsule icon-only 样式，避免 hero action
//    区出现不同高度的按钮。
//

import SwiftUI

struct LibraryToggleButton: View {
    let isSaved: Bool
    let action: () -> Void

    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var pulse = false

    private var helpKey: LocalizedStringKey {
        isSaved ? "library.action.remove" : "library.action.add"
    }

    private var foreground: Color {
        if isSaved {
            return Color.fromHex6(colorScheme == .dark ? 0xFB7185 : 0xE11D48)
        }
        return Color.fromHex6(colorScheme == .dark ? 0xFDA4AF : 0xE11D48)
    }

    private var background: Color {
        foreground.opacity(colorScheme == .dark ? 0.20 : 0.12)
    }

    var body: some View {
        Button {
            action()
            guard !reduceMotion else { return }
            pulse = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                pulse = false
            }
        } label: {
            Image(systemName: isSaved ? "heart.fill" : "heart")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(foreground)
                .symbolEffect(.bounce, value: isSaved)
                .scaleEffect(pulse ? 1.18 : 1.0)
                .frame(width: 28, height: 28)
                .background {
                    Capsule(style: .continuous)
                        .fill(background)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(foreground.opacity(isSaved ? 0.28 : 0.16), lineWidth: 1)
                }
                .contentShape(Capsule())
                .accessibilityLabel(Text(helpKey))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help(Text(helpKey))
        .fixedSize()
        .animation(
            reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.58),
            value: pulse
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.16),
            value: isSaved
        )
    }
}

