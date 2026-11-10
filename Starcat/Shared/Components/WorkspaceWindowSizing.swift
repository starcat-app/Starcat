//
//  WorkspaceWindowSizing.swift
//  Starcat
//
//  Agent / RAG 生产 Scene 与未显示窗口回归共用的尺寸入口。
//

import AppKit
import SwiftUI

/// 生产 Scene 与窗口回归共用尺寸入口，避免测试只约束内容容器而遗漏整窗变化。
struct WorkspaceWindowSizing: ViewModifier {
    let reference: WorkspaceSceneWindowReference
    let minimumContentSize: NSSize

    /// 窗口下限与内容布局分离，具体 AppKit 配置仍由共享窗口探针管理。
    func body(content: Content) -> some View {
        content
            .frame(
                minWidth: minimumContentSize.width,
                minHeight: minimumContentSize.height
            )
            .background {
                WorkspaceSceneWindowReader(
                    reference: reference,
                    minimumContentSize: minimumContentSize
                )
            }
    }
}
