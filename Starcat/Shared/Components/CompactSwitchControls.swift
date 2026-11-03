//
//  CompactSwitchControls.swift
//  Starcat
//
//  macOS 26 系统 Switch 在固定 AppKit hosting sheet 中会出现 thumb 消失或拉伸。
//  批量整理、GitHub Lists AI 分组预检等紧凑面板统一用本组件替代 `.toggleStyle(.switch)`：
//  - `CompactSwitchIndicator`：与设置页开关一致的 36×16 轨道 + 胶囊形 thumb 位移动画
//  - `CompactSettingsToggleRow`：Settings 行范式（左 label + Spacer + 右开关，整行可点）
//

import SwiftUI

/// 紧凑 Switch 轨道；thumb 位置同时提供非颜色状态区分。
struct CompactSwitchIndicator: View {
    let isOn: Bool
    /// 父级 disabled 时轨道降对比，避免只剩系统灰化而看不清开/关。
    var isEnabled: Bool = true

    @Environment(\.starcatReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(trackFill)

            // 只收紧可见控件，保留外层整行的点击区；胶囊滑块对齐设置页的原生外观。
            Capsule()
                .fill(.white)
                .overlay {
                    Capsule()
                        .stroke(.black.opacity(0.08), lineWidth: 0.5)
                }
                .frame(width: 20, height: 12)
                .shadow(color: .black.opacity(isEnabled ? 0.18 : 0.08), radius: 1, y: 1)
                .padding(.leading, 2)
                .offset(x: isOn ? 12 : 0)
        }
        .frame(width: 36, height: 16)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isOn)
        .accessibilityHidden(true)
    }

    private var trackFill: Color {
        guard isEnabled else {
            return Color.secondary.opacity(isOn ? 0.28 : 0.20)
        }
        return isOn ? Color.accentColor : Color.secondary.opacity(0.36)
    }
}

/// 右对齐紧凑开关行；与 sessionFact / 阈值 slider 标题行保持同一水平节奏。
struct CompactSettingsToggleRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    /// 子选项缩进（如「自动创建标签」依赖主开关）。
    var isNested: Bool = false
    var isDisabled: Bool = false

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                Text(title)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(labelForeground)
                    .lineLimit(1)

                Spacer(minLength: 4)

                CompactSwitchIndicator(isOn: isOn, isEnabled: !isDisabled)
            }
            .padding(.leading, isNested ? 10 : 0)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .toggleStyle(.button)
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isDisabled)
    }

    private var labelForeground: Color {
        isDisabled ? .secondary : .primary
    }
}
