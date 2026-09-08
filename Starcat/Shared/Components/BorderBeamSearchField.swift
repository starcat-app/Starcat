//
//  BorderBeamSearchField.swift
//  Starcat
//
//  Search Center 共用的 Border Beam 搜索输入框。
//
//  关键约束：
//  - 只负责输入、清空、提交和焦点，不持有任何搜索业务状态；
//  - Beam 是搜索入口的视觉层，系统 Reduce Motion 开启时必须停止动画；
//  - Search Center 与 Debug Lab 复用同一组件，避免实验参数和正式效果漂移。
//

import BorderBeamKit
import SwiftUI

/// BorderBeamKit `line` 预设包装的胶囊搜索框。
struct BorderBeamSearchField: View {
    @Binding var text: String

    /// 是否播放 beam 动画；调用方可在非活跃窗口或视觉对照时关闭。
    var isBeamActive: Bool = true
    var colorVariant: BeamColorVariant = .colorful
    var theme: BeamTheme = .auto
    var strength: Double = 1
    var duration: Double = 3.1
    var prompt: Text = Text("search.searchField.placeholder")
    var accessibilityLabel: Text = Text("search.searchField.placeholder")
    /// Search Center 出现后需要立即接收键盘输入，Lab 本身则保持手动聚焦。
    var autofocusOnAppear: Bool = false
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
        .accessibilityLabel(accessibilityLabel)
        .task {
            guard autofocusOnAppear else { return }
            // Search Center 作为 overlay 插入视图树时，先让出一轮主线程再申请焦点，
            // 否则 macOS 可能在 field editor 尚未就绪时吞掉首次聚焦。
            await Task.yield()
            isFocused = true
        }
    }

    private var searchContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("", text: $text, prompt: prompt)
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
                .help("search.clear")
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
            // 点击 TextField 之外的胶囊留白也应进入输入，而不是要求精确命中文字。
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
