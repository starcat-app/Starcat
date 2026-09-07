//
//  View+LiquidGlass.swift
//  Starcat
//
//  Centralizes macOS 26 Liquid Glass compatibility boundaries so feature views
//  can keep expressing intent without duplicating availability checks.
//

import SwiftUI

extension View {
    /// Lets macOS 26 render the native Liquid Glass window toolbar while preserving
    /// Starcat's transparent-toolbar appearance on macOS 15 through macOS 25.
    ///
    /// The fallback is intentionally limited to older systems. Hiding the toolbar
    /// background on macOS 26 would suppress the system-provided window chrome and
    /// force each workspace to recreate Liquid Glass manually.
    @ViewBuilder
    func starcatWindowToolbarChrome() -> some View {
        if #available(macOS 26.0, *) {
            self
        } else {
            toolbarBackground(.hidden, for: .windowToolbar)
        }
    }

    /// 为悬浮提示和小型控件统一切换系统 Liquid Glass，同时保留 macOS 15/16 的原有材质表现。
    ///
    /// 该入口只用于脱离正文层级的瞬时表面；内容卡片继续使用不透明背景或 Material，
    /// 避免在 macOS 26 上形成层层叠加的玻璃层级。
    @ViewBuilder
    func starcatGlassSurface<S: Shape>(
        _ legacyMaterial: Material,
        in shape: S,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            background(legacyMaterial, in: shape)
        }
    }

    /// 标记可点击玻璃表面，使 macOS 26 能按指针交互提供系统级高光反馈。
    @ViewBuilder
    func starcatInteractiveGlassSurface<S: Shape>(
        _ legacyMaterial: Material,
        in shape: S
    ) -> some View {
        starcatGlassSurface(legacyMaterial, in: shape, interactive: true)
    }
}
