//
//  ToastOverlay.swift
//  Starcat
//
//  轻量 Toast：浮动文案 + 自动/手动消失 + 可选操作按钮。
//
//  用法：
//      @State private var toast: String?
//      VStack { ... }
//          .toast(message: $toast, icon: "doc.on.clipboard")
//      // 触发：toast = "clone.copiedHttps"（message 存 localization key）
//
//      // 手动关闭 + 操作按钮：
//      .toast(
//          message: $toast,
//          icon: "exclamationmark.triangle.fill",
//          iconColor: .orange,
//          autoDismiss: false,
//          actionLabel: "前往设置",
//          onAction: { openSettings() }
//      )
//
//  设计取舍：
//  - 不引第三方 Toast 库；SwiftUI overlay + 自动消失 50 行搞定
//  - 用 ViewModifier 让 API 链式 + 复用
//  - macOS 没有 iOS 那种隐式动画底栏，所以走"右下角浮层 + 模糊背景"风格
//
//  2026-07-04 扩展：
//  - autoDismiss: false → 不自动消失，显示 X 关闭按钮
//  - actionLabel + onAction → 右侧操作按钮（如"前往设置"）
//

import SwiftUI

private struct ToastModifier: ViewModifier {

    @Binding var message: String?
    let icon: String
    let duration: TimeInterval
    let iconColor: Color?
    let bottomPadding: CGFloat
    let autoDismiss: Bool
    let actionLabel: String?
    let onAction: (() -> Void)?

    /// 2026-06-15:Toast 进出场 0.25s snappy 在「关闭应用内动画」时跳过,
    /// 直接显示/隐藏避免吸引视线。
    @Environment(\.starcatReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(iconColor ?? Color.primary)
                    Text(LocalizedStringKey(message))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let actionLabel, let onAction {
                        Button {
                            onAction()
                            self.message = nil
                        } label: {
                            Text(LocalizedStringKey(actionLabel))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }

                    if !autoDismiss {
                        Button {
                            self.message = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .padding(4)
                        .contentShape(Circle())
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, (!autoDismiss || actionLabel != nil) ? 8 : 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.15)))
                .padding(.bottom, bottomPadding)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .id(message) // 切换 message 重置动画
                // 仅 autoDismiss 时挂自动消失 timer
                .task(id: message) {
                    guard autoDismiss else { return }
                    try? await Task.sleep(for: .seconds(duration))
                    if !Task.isCancelled {
                        self.message = nil
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: message)
    }
}

extension View {

    /// 给当前 View 挂一个底部 Toast 浮层。
    /// - Parameters:
    ///   - message: 双向 binding；写非 nil 即弹出，duration 后自动归零（或用户手动关）
    ///   - icon: SF Symbol 名（默认 checkmark.circle.fill）
    ///   - duration: 自动消失时间（秒），默认 2.0；autoDismiss=false 时忽略
    ///   - iconColor: 仅覆盖图标色；文案继续继承系统主色，保证可读性
    ///   - bottomPadding: 底部浮动距离；详情页可避开 README 状态栏
    ///   - autoDismiss: 是否自动消失，默认 true；false 时显示 X 关闭按钮
    ///   - actionLabel: 操作按钮文案（localization key），nil 则不显示
    ///   - onAction: 操作按钮回调，点击后自动关闭 toast
    func toast(
        message: Binding<String?>,
        icon: String = "checkmark.circle.fill",
        duration: TimeInterval = 2.0,
        iconColor: Color? = nil,
        bottomPadding: CGFloat = 16,
        autoDismiss: Bool = true,
        actionLabel: String? = nil,
        onAction: (() -> Void)? = nil
    ) -> some View {
        modifier(ToastModifier(
            message: message,
            icon: icon,
            duration: duration,
            iconColor: iconColor,
            bottomPadding: bottomPadding,
            autoDismiss: autoDismiss,
            actionLabel: actionLabel,
            onAction: onAction
        ))
    }
}
