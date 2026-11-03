//
//  CommonActionIconButtons.swift
//  Starcat
//
//  常用 icon-only 操作按钮的共享入口。
//
//  设计约束：
//  - 只承接全 App 重复出现的轻量工具按钮，避免每个页面手写字号 / 命中区 / focus ring。
//  - 删除入口默认不使用红色；危险色留给确认弹窗中的最终 destructive 按钮。
//  - 重置入口使用同一个 `arrow.counterclockwise.circle` 语义，调用方按所在 surface 传入尺寸。
//  - Finder 入口与重置共用设置页 15pt / 28pt 口径，避免和 SyncIconButton 默认 18pt 混用。
//  - 点击成功后短暂显示绿色 `checkmark.circle.fill`（与 CopyFeedbackButton 同窗口）。
//

import SwiftUI

/// 设置页（`SettingsView` 全部 Tab 及由设置页打开的 sheet / popover）图标统一口径。
///
/// 规范来源：`docs/5-规范/UI-设置页规范.md` §3 / §5。设置域内所有图标按钮的
/// 字号与命中区都引用这里，禁止再手抄 `Font.system(size:)` 字面量；
/// 例外（如 chip 内联小按钮、等宽光学对齐 ±1pt）必须按规范 §9 在调用处注释说明。
enum SettingsIconMetrics {
    /// 15pt medium：icon-only 按钮 glyph（§5.2）与带文本按钮 / body 行首图标（§5.1）。
    static let standardGlyphSize: CGFloat = 15
    static let standardGlyph: Font = .system(size: standardGlyphSize, weight: .medium)

    /// icon-only 按钮 28×28pt 命中区（§5.2）。
    static let actionFrameSize: CGFloat = 28

    /// 13pt medium：caption 级行首图标 / 分组图标。
    /// 与 `SettingsSectionHeader` prominent 的 13pt 图标同源（DESIGN.md icon-small）。
    static let smallGlyph: Font = .system(size: 13, weight: .medium)
}

/// icon-only 删除 / 清空入口。
struct DestructiveIconButton: View {
    let help: Text
    let action: () -> Void
    var font: Font = SyncIconButton.defaultFont
    var frameSize: CGFloat = SyncIconButton.defaultFrameSize

    init(
        help: Text,
        font: Font = SyncIconButton.defaultFont,
        frameSize: CGFloat = SyncIconButton.defaultFrameSize,
        action: @escaping () -> Void
    ) {
        self.help = help
        self.action = action
        self.font = font
        self.frameSize = frameSize
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(font)
                .foregroundStyle(.secondary)
                .frame(width: frameSize, height: frameSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// icon-only 重置 / 恢复默认入口。
///
/// 默认点击后与 `CopyFeedbackButton` 对齐：1.5s 内切为绿色 `checkmark.circle.fill`，
/// 连点取消旧复位任务并重新计时；开启「减少动态效果」时跳过状态与 Symbol 动画。
/// 仅发起确认或引导流程的入口应关闭成功反馈，避免把开始流程误报为重置完成。
///
/// 静止态用 `arrow.counterclockwise.circle`（圆形同源），避免与 `checkmark.circle.fill`
/// 做 `.symbolEffect(.replace)` 时几何差太大、回切时卡在成功态不还原（RAG 设置页曾踩）。
struct ResetIconButton: View {
    let help: Text
    let action: () -> Void
    /// 只打开确认或引导流程的入口不代表重置完成，不应立即显示成功标记。
    let showsSuccessFeedback: Bool
    /// 设置页 icon-only 统一采用 15pt glyph + 28pt 命中区；不要再继承旧刷新按钮的 18pt 紧凑尺寸。
    var font: Font = SettingsIconMetrics.standardGlyph
    var frameSize: CGFloat = SettingsIconMetrics.actionFrameSize

    @State private var didReset = false
    @State private var feedbackResetTask: Task<Void, Never>?
    @Environment(\.starcatReduceMotion) private var reduceMotion

    init(
        help: Text,
        font: Font = SettingsIconMetrics.standardGlyph,
        frameSize: CGFloat = SettingsIconMetrics.actionFrameSize,
        showsSuccessFeedback: Bool = true,
        action: @escaping () -> Void
    ) {
        self.help = help
        self.action = action
        self.font = font
        self.frameSize = frameSize
        self.showsSuccessFeedback = showsSuccessFeedback
    }

    var body: some View {
        Button(action: performReset) {
            Image(systemName: didReset ? "checkmark.circle.fill" : "arrow.counterclockwise.circle")
                .font(font)
                .foregroundStyle(didReset ? Color.green : .secondary)
                .frame(width: frameSize, height: frameSize)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help(help)
        .accessibilityLabel(help)
        .onDisappear {
            // Sheet / 分组重建时收掉未完成复位，避免悬挂 Task 写已释放 @State。
            feedbackResetTask?.cancel()
            feedbackResetTask = nil
        }
    }

    /// 先执行业务重置；等父级状态落定后再进成功反馈，避免同帧重建打断 Symbol 回切。
    private func performReset() {
        action()
        guard showsSuccessFeedback else { return }
        feedbackResetTask?.cancel()
        feedbackResetTask = Task { @MainActor in
            // 让 `apply` / `restoreCurrentTab` 触发的父级刷新先跑完。
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                didReset = true
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) {
                didReset = false
            }
        }
    }
}

/// icon-only「在 Finder 中显示」入口。
///
/// 设置页与 `ResetIconButton` 共用 15pt glyph + 28pt 命中区 + `.secondary`。
/// 不要改用 `SyncIconButton` 的 18pt caption 默认值：`folder` 和圆形重置在那套尺寸下
/// 会一眼看出大小不一致（Agent Runtime 设置页已经踩过）。
struct RevealInFinderIconButton: View {
    let help: Text
    let action: () -> Void
    var font: Font = SettingsIconMetrics.standardGlyph
    var frameSize: CGFloat = SettingsIconMetrics.actionFrameSize

    init(
        help: Text,
        font: Font = SettingsIconMetrics.standardGlyph,
        frameSize: CGFloat = SettingsIconMetrics.actionFrameSize,
        action: @escaping () -> Void
    ) {
        self.help = help
        self.action = action
        self.font = font
        self.frameSize = frameSize
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "folder")
                .font(font)
                .foregroundStyle(.secondary)
                .frame(width: frameSize, height: frameSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help(help)
        .accessibilityLabel(help)
        .fixedSize()
    }
}

/// icon-only 新增 / 添加入口。
///
/// 与 `RevealInFinderIconButton` 同用设置页 15pt glyph + 28pt 命中区口径，
/// 供「添加 Provider」「添加目录」这类行尾轻操作使用；新增语义用 `plus`，
/// 不携带删除 / 重置的成功反馈状态。
struct AddIconButton: View {
    let help: Text
    let action: () -> Void
    var font: Font = SettingsIconMetrics.standardGlyph
    var frameSize: CGFloat = SettingsIconMetrics.actionFrameSize

    init(
        help: Text,
        font: Font = SettingsIconMetrics.standardGlyph,
        frameSize: CGFloat = SettingsIconMetrics.actionFrameSize,
        action: @escaping () -> Void
    ) {
        self.help = help
        self.action = action
        self.font = font
        self.frameSize = frameSize
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(font)
                .foregroundStyle(.secondary)
                .frame(width: frameSize, height: frameSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// icon-only 取消 / 放弃草稿入口。
///
/// 与 `AddIconButton` 同口径（15pt / 28pt）。`plus` 是新增唯一入口，对应的退出
/// 用 `xmark` 而不是 `trash`：垃圾桶仍表示删除已保存服务商，避免草稿态误删当前选中项。
struct CancelIconButton: View {
    let help: Text
    let action: () -> Void
    var font: Font = SettingsIconMetrics.standardGlyph
    var frameSize: CGFloat = SettingsIconMetrics.actionFrameSize

    init(
        help: Text,
        font: Font = SettingsIconMetrics.standardGlyph,
        frameSize: CGFloat = SettingsIconMetrics.actionFrameSize,
        action: @escaping () -> Void
    ) {
        self.help = help
        self.action = action
        self.font = font
        self.frameSize = frameSize
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(font)
                .foregroundStyle(.secondary)
                .frame(width: frameSize, height: frameSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// icon-only「从外部配置导入」入口。
///
/// 与 `AddIconButton` 同用设置页 15pt glyph + 28pt 命中区；导入不是草稿新增，
/// 默认用 `square.and.arrow.down`；指定来源时保留官方图标原色，便于识别导入对象。
struct ImportIconButton: View {
    let help: Text
    let image: Image?
    let action: () -> Void
    var font: Font = SettingsIconMetrics.standardGlyph
    var frameSize: CGFloat = SettingsIconMetrics.actionFrameSize

    init(
        help: Text,
        image: Image? = nil,
        font: Font = SettingsIconMetrics.standardGlyph,
        frameSize: CGFloat = SettingsIconMetrics.actionFrameSize,
        action: @escaping () -> Void
    ) {
        self.help = help
        self.image = image
        self.action = action
        self.font = font
        self.frameSize = frameSize
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let image {
                    image
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: SettingsIconMetrics.standardGlyphSize, height: SettingsIconMetrics.standardGlyphSize)
                } else {
                    Image(systemName: "square.and.arrow.down")
                        .font(font)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: frameSize, height: frameSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 胶囊 chip 内的移除小按钮（语言 chip、过滤 chip 等）。
///
/// 例外说明（规范 §9）：chip 是 20pt 上下的紧凑胶囊，28×28pt 标准命中区会撑破
/// chip 本体，因此这里用 13pt glyph + 20×20pt 命中框（与 chip 内 `+` 添加钮
/// 13pt 口径同源）。仅限 chip / pill 内部使用，不要当作独立行内操作按钮。
struct ChipRemoveButton: View {
    let help: Text
    let action: () -> Void

    init(help: Text, action: @escaping () -> Void) {
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(SettingsIconMetrics.smallGlyph)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
        .accessibilityLabel(help)
    }
}
