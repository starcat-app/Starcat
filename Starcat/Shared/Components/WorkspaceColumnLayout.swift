//
//  WorkspaceColumnLayout.swift
//  Starcat
//
//  Agent / RAG 原生分栏的尺寸与偏好键；仅保存布局值，不包含业务状态。
//

import Foundation

/// 每个工作台独立提供配置，共享分栏不依赖具体功能的尺寸常量。
struct WorkspaceColumnLayout {
    /// 一个侧栏的可拖动范围、默认值与既有持久化键。
    struct Column {
        let minimum: CGFloat
        let ideal: CGFloat
        let maximum: CGFloat
        let defaultsKey: String

        /// 历史偏好和测量值都必须落在当前原生分栏支持的范围内。
        func clampedWidth(_ width: Double) -> CGFloat {
            min(max(CGFloat(width), minimum), maximum)
        }
    }

    let left: Column
    let right: Column
}
