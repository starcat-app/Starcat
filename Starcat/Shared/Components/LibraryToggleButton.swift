//
//  LibraryToggleButton.swift
//  Starcat
//
//  详情页 hero action 区的 Starcat 知识库入口。
//
//  设计约束：
//  - ❤️ 表达 Starcat 私有“入库”动作，不能与 GitHub Star 的 ⭐ 公开动作混用。
//  - 视觉状态由调用方传入的真实 `library_state` 驱动；点击只发起请求，不做乐观更新。
//  - 视觉尺寸对齐 Wiki / 推荐入口的 28×28 capsule icon-only 样式，避免 hero action
//    区出现不同高度的按钮。
//

import SwiftUI

struct LibraryToggleButton: View {
    let isSaved: Bool
    var isWorking: Bool = false
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

    var body: some View {
        Button {
            action()
        } label: {
            Group {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: isSaved ? "heart.fill" : "heart")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(foreground)
                        .symbolEffect(.bounce, value: isSaved)
                        .scaleEffect(pulse ? 1.18 : 1.0)
                }
            }
            .frame(width: 28, height: 28)
            .background {
                Capsule(style: .continuous)
                    .fill(HeroActionIconStyle.background(colorScheme: colorScheme))
            }
            .contentShape(Capsule())
            .accessibilityLabel(Text(helpKey))
        }
        .disabled(isWorking)
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help(Text(helpKey))
        .fixedSize()
        .onChange(of: isSaved) { _, _ in
            guard !reduceMotion else { return }
            pulse = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                pulse = false
            }
        }
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
