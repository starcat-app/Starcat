//
//  AgentWorkspaceColumnWidthPersistence.swift
//  Starcat
//
//  Agent 工作台栏宽测量的非响应式持久化缓存。
//

import Foundation

/// 缓存 Sidebar / Inspector 的连续测量结果，并在拖拽静止后写入 UserDefaults。
///
/// 恢复值只在创建时读取一次，测量结果只写 UserDefaults，不通过 `@AppStorage`
/// 回传给当前分栏的 idealWidth。否则显隐期间会形成“测量 → 保存 → 重布局”的回路。
@MainActor
final class AgentWorkspaceColumnWidthPersistence {

    let initialLeftColumnWidth: CGFloat
    let initialRightColumnWidth: CGFloat
    private let defaults: UserDefaults
    private var lastMeasuredLeftColumnWidth: CGFloat?
    private var lastMeasuredRightColumnWidth: CGFloat?
    private var leftWidthPersistenceTask: Task<Void, Never>?
    private var rightWidthPersistenceTask: Task<Void, Never>?

    /// Inspector 收起后会重建内容，用最近的有效测量恢复本窗口内的拖动结果。
    /// 缓存本身不发布观察更新；测量与写盘都不会立即反向触发布局。
    var rightColumnWidthForPresentation: CGFloat {
        lastMeasuredRightColumnWidth ?? initialRightColumnWidth
    }

    /// 一个缓存实例对应一个窗口生命周期，下一次打开窗口才读取本次保存的宽度。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        initialLeftColumnWidth = AgentWorkspaceLayoutMetrics.clampedLeftWidth(
            (defaults.object(forKey: AgentWorkspaceLayoutMetrics.leftWidthDefaultsKey) as? NSNumber)?
                .doubleValue ?? Double(AgentWorkspaceLayoutMetrics.leftIdealWidth)
        )
        initialRightColumnWidth = AgentWorkspaceLayoutMetrics.clampedRightWidth(
            (defaults.object(forKey: AgentWorkspaceLayoutMetrics.rightWidthDefaultsKey) as? NSNumber)?
                .doubleValue ?? Double(AgentWorkspaceLayoutMetrics.rightDefaultWidth)
        )
    }

    /// 原生 Sidebar 会连续报告尺寸；静止 250ms 后才保存最终值。
    func scheduleLeftWidthPersistence(
        _ measuredWidth: CGFloat,
        isCollapsed: Bool
    ) {
        // 包括隐藏和回到已保存宽度的情况，都要撤销之前尚未落盘的旧测量。
        leftWidthPersistenceTask?.cancel()
        guard !isCollapsed,
              measuredWidth >= AgentWorkspaceLayoutMetrics.leftMinimumWidth else { return }

        let width = AgentWorkspaceLayoutMetrics.clampedLeftWidth(Double(measuredWidth))
        lastMeasuredLeftColumnWidth = width
        guard abs(defaults.double(forKey: AgentWorkspaceLayoutMetrics.leftWidthDefaultsKey) - Double(width)) > 0.5 else { return }

        leftWidthPersistenceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            defaults.set(Double(width), forKey: AgentWorkspaceLayoutMetrics.leftWidthDefaultsKey)
        }
    }

    /// 原生 Inspector 与 Sidebar 使用同一套去抖策略，避免拖拽期间频繁写 UserDefaults。
    func scheduleRightWidthPersistence(
        _ measuredWidth: CGFloat,
        isCollapsed: Bool
    ) {
        rightWidthPersistenceTask?.cancel()
        guard !isCollapsed,
              measuredWidth >= AgentWorkspaceLayoutMetrics.rightMinimumWidth else { return }

        let width = AgentWorkspaceLayoutMetrics.clampedRightWidth(Double(measuredWidth))
        lastMeasuredRightColumnWidth = width
        guard abs(defaults.double(forKey: AgentWorkspaceLayoutMetrics.rightWidthDefaultsKey) - Double(width)) > 0.5 else { return }

        rightWidthPersistenceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            defaults.set(Double(width), forKey: AgentWorkspaceLayoutMetrics.rightWidthDefaultsKey)
        }
    }

    /// 窗口关闭前同步提交最后一次有效测量，避免 debounce 任务尚未执行就被销毁。
    func persistLastMeasuredWidths() {
        if let width = lastMeasuredLeftColumnWidth {
            defaults.set(Double(width), forKey: AgentWorkspaceLayoutMetrics.leftWidthDefaultsKey)
        }
        if let width = lastMeasuredRightColumnWidth {
            defaults.set(Double(width), forKey: AgentWorkspaceLayoutMetrics.rightWidthDefaultsKey)
        }
    }

    func cancelPendingPersistence() {
        leftWidthPersistenceTask?.cancel()
        rightWidthPersistenceTask?.cancel()
    }
}
