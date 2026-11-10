//
//  AppBackgroundTaskList.swift
//  Starcat
//
//  状态浮层内的紧凑任务列表：仅文字数量，不绘制进度条，取消与窗口入口是独立按钮。
//

import SwiftUI

/// 最多显示四行后滚动，避免任务数变化撑出状态面板；所有语言都保持两行固定结构。
struct AppBackgroundTaskList: View {
    let tasks: [AppBackgroundTask]
    let onOpen: (AppBackgroundTask.ID) -> Void
    let onCancel: (AppBackgroundTask.ID) -> Void
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(tasks) { task in
                    AppBackgroundTaskRow(task: task, onOpen: { onOpen(task.id) }, onCancel: { onCancel(task.id) })
                    if task.id != tasks.last?.id { Divider() }
                }
            }
        }
        .frame(height: CGFloat(min(tasks.count, 4)) * interfaceScale.scaled(52) + CGFloat(max(0, min(tasks.count, 4) - 1)))
        .background(StarcatSurface.panel(colorScheme: colorScheme), in: RoundedRectangle(cornerRadius: 8))
    }

    @Environment(\.colorScheme) private var colorScheme
}
