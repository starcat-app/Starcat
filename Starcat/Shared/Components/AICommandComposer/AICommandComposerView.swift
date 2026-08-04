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
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}
