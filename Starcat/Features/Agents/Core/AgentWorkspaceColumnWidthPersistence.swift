//
//  AgentWorkspaceColumnWidthPersistence.swift
//  Starcat
//
//  Agent 工作台栏宽测量的非响应式持久化缓存。
//

import SwiftUI

/// 缓存 Sidebar / Inspector 的连续测量结果，并在拖拽静止后写入 UserDefaults。
///
/// 该对象故意不使用 `@Observable`：测量结果不会直接参与渲染，把它们放进
/// `AgentWorkspaceView` 的值类型 `@State` 会让每次列宽变化都重新计算整棵工作台。
@MainActor
final class AgentWorkspaceColumnWidthPersistence {

    private var lastMeasuredLeftColumnWidth: CGFloat?
    private var lastMeasuredRightColumnWidth: CGFloat?
    private var leftWidthPersistenceTask: Task<Void, Never>?
    private var rightWidthPersistenceTask: Task<Void, Never>?

    /// 原生 Sidebar 会连续报告尺寸；静止 250ms 后才保存最终值。
    func scheduleLeftWidthPersistence(
        _ measuredWidth: CGFloat,
        isCollapsed: Bool,
        persistedWidth: Binding<Double>
    ) {
        guard !isCollapsed,
              measuredWidth >= AgentWorkspaceLayoutMetrics.leftMinimumWidth else { return }

        let width = AgentWorkspaceLayoutMetrics.clampedLeftWidth(Double(measuredWidth))
        lastMeasuredLeftColumnWidth = width
        guard abs(CGFloat(persistedWidth.wrappedValue) - width) > 0.5 else { return }

        leftWidthPersistenceTask?.cancel()
        leftWidthPersistenceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            persistedWidth.wrappedValue = Double(width)
        }
    }

    /// 原生 Inspector 与 Sidebar 使用同一套去抖策略，避免拖拽期间频繁写 UserDefaults。
    func scheduleRightWidthPersistence(
        _ measuredWidth: CGFloat,
        isCollapsed: Bool,
        persistedWidth: Binding<Double>
    ) {
        guard !isCollapsed,
              measuredWidth >= AgentWorkspaceLayoutMetrics.rightMinimumWidth else { return }

        let width = AgentWorkspaceLayoutMetrics.clampedRightWidth(Double(measuredWidth))
        lastMeasuredRightColumnWidth = width
        guard abs(CGFloat(persistedWidth.wrappedValue) - width) > 0.5 else { return }

        rightWidthPersistenceTask?.cancel()
        rightWidthPersistenceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            persistedWidth.wrappedValue = Double(width)
        }
    }

    /// 窗口关闭前同步提交最后一次有效测量，避免 debounce 任务尚未执行就被销毁。
    func persistLastMeasuredWidths(
        leftWidth: Binding<Double>,
        rightWidth: Binding<Double>
    ) {
        if let width = lastMeasuredLeftColumnWidth {
            leftWidth.wrappedValue = Double(width)
        }
        if let width = lastMeasuredRightColumnWidth {
            rightWidth.wrappedValue = Double(width)
        }
    }

    func cancelPendingPersistence() {
        leftWidthPersistenceTask?.cancel()
        rightWidthPersistenceTask?.cancel()
    }
}
