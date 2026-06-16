//
//  AIModelParametersPopover.swift
//  Starcat
//
//  HOM-68 follow-up v9 (dong4j 反馈 2026-06-05 23:35)：
//
//  模型粒度的参数编辑器（popover 形态）。挂在"已发现模型"行的齿轮按钮上。
//
//  设计要点：
//  - 参数与"模型"绑定，不再与"任务"绑定。同一个模型即使被摘要 / 标签 / 翻译
//    复用，也共用同一份参数（temperature / topP / topK / maxToken / timeout /
//    stream）。这避免了"用户在'模型参数 → 摘要'调温度，结果只对'用 X 模型的摘要
//    任务'生效，其它任务用 X 模型时还是默认温度"的反直觉行为。
//  - Binding<AIModelParameters> 在 getter 里把 descriptor.parameters == nil 时
//    显示 capability 默认（不写回），setter 写回时立即把 descriptor.parameters
//    materialize 成非 nil。这样用户**首次打开 popover 不会污染任何数据**，只在
//    实际改值后才记为"覆盖"。
//  - "重置默认"按钮把 descriptor.parameters 清回 nil，下次调用回到 capability
//    默认；按钮在没有覆盖时禁用，UI 上有"是否已覆盖"的视觉提示。
//

import SwiftUI
import AppKit

/// 模型粒度参数编辑 popover 内容。
struct AIModelParametersPopover: View {

    let model: AIModelDescriptor
    /// 双向绑定到 descriptor.parameters。getter 在 nil 时返回 capability 默认（不写回）；
    /// setter 写入时把 descriptor.parameters materialize 为非 nil 值。
    @Binding var parameters: AIModelParameters
    /// 当前模型是否存在用户级覆盖（descriptor.parameters != nil）。
    /// 决定"重置默认"按钮是否可点 + 是否显示"已自定义"标识。
    let hasOverride: Bool
    /// 把 descriptor.parameters 清回 nil 的回调。
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            controls
        }
        .padding(20)
        .frame(width: 420)
        // HOM-68 follow-up v10 (dong4j 反馈 2026-06-05 23:55)：
        // docs/详细设计/07-UI交互设计.md §3.1——Popover 打开时 macOS 会把焦点自动
        // 放到内部第一个可聚焦元素上。在 popover 根加 .focusEffectDisabled()，
        // 让 plain Button / Toggle / TextField 等 SwiftUI 一等控件不画 focus ring。
        .focusEffectDisabled()
        // HOM-68 follow-up v11 (dong4j 反馈 2026-06-06 00:14)：
        // .focusEffectDisabled() 对 Slider 内部的 NSSlider 不生效——popover 出现时
        // 系统仍把第一个 Slider（Temperature）设为首响应者，NSSlider 会自己画出
        // thumb 周围那圈蓝色 focus halo（截图里的圆形蓝圈），SwiftUI 没暴露关闭
        // NSSlider focus ring 的开关。沿用项目既有"AppKit 窄范围修正"思路（见
        // 已废弃的 ToolbarSearchFocusRingDisabler 模式），在 popover 出现的下一
        // 个 runloop 把首响应者清回 nil，让 popover 以"无焦点"状态出现，从根上
        // 避免 thumb 蓝 halo。
        .onAppear {
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(model.capability.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if hasOverride {
                        Text("settings.ai.modelParams.overridden")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.orange.opacity(0.5), lineWidth: 0.5)
                            )
                    }
                }
            }
            Spacer()
            Button {
                onReset()
            } label: {
                Label("settings.ai.modelParams.resetDefault", systemImage: "arrow.counterclockwise")
            }
            .disabled(!hasOverride)
            .help(hasOverride
                  ? Text("settings.ai.modelParams.resetHelp.activeFormat \(model.capability.displayName)")
                  : Text("settings.ai.modelParams.resetHelp.empty"))
        }
    }

    @ViewBuilder
    private var controls: some View {
        let isEmbedding = model.capability == .embedding

        slider("Temperature", value: $parameters.temperature, range: 0...2, disabled: isEmbedding)
        slider("Top P", value: $parameters.topP, range: 0...1, disabled: isEmbedding)

        intField("Top K", value: clampedInt($parameters.topK, in: 0...500), unit: nil, disabled: isEmbedding)
        intField(
            String(localized: "settings.ai.modelParams.maxTokens"),
            value: maxTokensKBinding,
            unit: "K",
            disabled: isEmbedding
        )
        intField(
            String(localized: "settings.ai.modelParams.timeout"),
            value: timeoutSecondsBinding,
            unit: String(localized: "settings.ai.modelParams.unit.seconds"),
            disabled: false
        )

        HStack {
            Text("settings.ai.modelParams.streamPreferred")
            Spacer(minLength: 8)
            Toggle("", isOn: $parameters.streamEnabled)
                .labelsHidden()
                .disabled(isEmbedding)
            Color.clear.frame(width: 44)
        }
    }

    // MARK: - 控件原语

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        disabled: Bool
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
                .disabled(disabled)
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func intField(
        _ title: String,
        value: Binding<Int>,
        unit: String?,
        disabled: Bool
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 90, alignment: .leading)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .disabled(disabled)
            if let unit {
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            } else {
                Color.clear.frame(width: 44)
            }
        }
    }

    // MARK: - Binding helpers

    /// 整数 binding 的钳制 wrapper：set 时把超界值修回 range 内，避免用户键入巨大值
    /// 后 OpenAI 直接 400。get 时不动，让用户中途键入的过渡值能正常显示。
    private func clampedInt(_ binding: Binding<Int>, in range: ClosedRange<Int>) -> Binding<Int> {
        Binding(
            get: { binding.wrappedValue },
            set: { binding.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
        )
    }

    /// 最大 Token 用 K 为单位显示与输入；内部仍以原始 token 数 persist，
    /// 给 OpenAI / 通义千问 等下游不需要换算。范围 1K ~ 512K。
    private var maxTokensKBinding: Binding<Int> {
        Binding(
            get: { max(0, parameters.maxCompletionTokens / 1024) },
            set: { k in
                let clamped = min(max(k, 1), 512)
                parameters.maxCompletionTokens = clamped * 1024
            }
        )
    }

    /// 超时秒数 binding：底层是 Double，UI 整数秒。30 ~ 3600 秒。
    private var timeoutSecondsBinding: Binding<Int> {
        Binding(
            get: { Int(parameters.timeoutSeconds.rounded()) },
            set: { seconds in
                let clamped = min(max(seconds, 30), 3_600)
                parameters.timeoutSeconds = Double(clamped)
            }
        )
    }
}
