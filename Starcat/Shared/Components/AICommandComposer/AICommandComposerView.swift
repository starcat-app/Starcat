//
//  AICommandComposerView.swift
//  Starcat
//
//  RAG 与 Agent 工作台共享的 Composer 视觉容器。
//

import SwiftUI

/// 统一输入主体的内边距、背景与边框；上下文区和业务按钮仍由调用方投影。
///
/// 组件刻意不依赖任何 ViewModel。RAG 可以继续提供检索预算、深度思考等动作，Agent
/// 也可以提供审批和运行控制，而不会把两个工作台重新耦合到同一状态对象。
struct AICommandComposerView<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(10)
        .aiCommandComposerSurface()
    }
}

extension View {
    @ViewBuilder
    func aiCommandComposerSurface() -> some View {
        if #available(macOS 26.0, *) {
            // Composer 是输入与执行操作的统一控制层；玻璃仅包裹控制层，不进入消息正文。
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        }
    }

    @ViewBuilder
    func aiCommandAuxiliarySurface(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func aiCommandGlassContainer(spacing: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            // 多个相邻 chip 共享一次玻璃采样，减少渲染 pass，并允许系统平滑合并边界。
            GlassEffectContainer(spacing: spacing) {
                self
            }
        } else {
            self
        }
    }
}
