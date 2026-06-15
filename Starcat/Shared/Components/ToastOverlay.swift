//
//  ToastOverlay.swift
//  Starcat
//
//  轻量 Toast：浮动文案 + 自动消失。
//
//  用法：
//      @State private var toast: String?
//      VStack { ... }
//          .toast(message: $toast, icon: "doc.on.clipboard")
//      // 触发：toast = "clone.copiedHttps"（message 存 localization key）
//
//  设计取舍：
//  - 不引第三方 Toast 库；SwiftUI overlay + 自动消失 50 行搞定
//  - 用 ViewModifier 让 API 链式 + 复用
//  - 默认 2 秒自动消失；用户主动覆盖新 message 时 timer 重置
//  - macOS 没有 iOS 那种隐式动画底栏，所以走"右下角浮层 + 模糊背景"风格
//

import SwiftUI

private struct ToastModifier: ViewModifier {

    @Binding var message: String?
    let icon: String
    let duration: TimeInterval

    /// 2026-06-15:Toast 进出场 0.25s snappy 在「关闭应用内动画」时跳过,
    /// 直接显示/隐藏避免吸引视线。
    @Environment(\.starcatReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                    Text(LocalizedStringKey(message))
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.15)))
                .padding(.bottom, 16)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .id(message) // 切换 message 重置动画
                // task(id:) 跟随 message 重置；duration 后清空
                .task(id: message) {
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
    ///   - message: 双向 binding；写非 nil 即弹出，duration 后自动归零
    ///   - icon: SF Symbol 名（默认 checkmark.circle.fill）
    ///   - duration: 自动消失时间（秒），默认 2.0
    func toast(message: Binding<String?>, icon: String = "checkmark.circle.fill", duration: TimeInterval = 2.0) -> some View {
        modifier(ToastModifier(message: message, icon: icon, duration: duration))
    }
}
