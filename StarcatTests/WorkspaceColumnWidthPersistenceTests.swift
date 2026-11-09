//
//  WorkspaceColumnWidthPersistenceTests.swift
//  StarcatTests
//
//  验证栏宽保存不反馈到当前窗口，以及连续测量不会被过期的去抖任务覆盖。
//

import Foundation
import Testing
@testable import Starcat

/// 使用独立的 UserDefaults suite，避免布局测试修改用户真实栏宽。
@Suite("工作台栏宽恢复与保存")
@MainActor
struct WorkspaceColumnWidthPersistenceTests {
    @Test("保存拖拽宽度只影响下次恢复，当前窗口的布局输入保持不变", arguments: [false, true])
    func savedWidthsOnlyAffectNextWindow(rag: Bool) throws {
        let layout = rag ? RAGWorkspaceLayoutMetrics.columnLayout : AgentWorkspaceLayoutMetrics.columnLayout
        let suite = "AgentColumnWidthTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let widths = WorkspaceColumnWidthPersistence(layout: layout, defaults: defaults)
        defer { widths.cancelPendingPersistence() }

        widths.scheduleLeftWidthPersistence(360, isCollapsed: false)
        widths.scheduleRightWidthPersistence(480, isCollapsed: false)
        widths.persistLastMeasuredWidths()

        #expect(widths.initialLeftColumnWidth == layout.left.ideal)
        #expect(widths.initialRightColumnWidth == 320)
        #expect(widths.rightColumnWidthForPresentation == 480)
        let reopened = WorkspaceColumnWidthPersistence(layout: layout, defaults: defaults)
        #expect(reopened.initialLeftColumnWidth == 360)
        #expect(reopened.initialRightColumnWidth == 480)
    }

    @Test("恢复的历史宽度仍受原生分栏上下限约束", arguments: [false, true])
    func restoredWidthsAreClamped(rag: Bool) throws {
        let layout = rag ? RAGWorkspaceLayoutMetrics.columnLayout : AgentWorkspaceLayoutMetrics.columnLayout
        let suite = "AgentColumnWidthTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(100, forKey: layout.left.defaultsKey)
        defaults.set(9_999, forKey: layout.right.defaultsKey)
        let widths = WorkspaceColumnWidthPersistence(layout: layout, defaults: defaults)

        #expect(widths.initialLeftColumnWidth == 250)
        #expect(widths.initialRightColumnWidth == 520)
    }

    @Test("回到已保存宽度或隐藏后，旧测量不能延迟覆盖恢复值", arguments: [false, true])
    func obsoleteMeasurementsAreCancelled(rag: Bool) async throws {
        let layout = rag ? RAGWorkspaceLayoutMetrics.columnLayout : AgentWorkspaceLayoutMetrics.columnLayout
        let suite = "AgentColumnWidthTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(312, forKey: layout.left.defaultsKey)
        defaults.set(420, forKey: layout.right.defaultsKey)
        let widths = WorkspaceColumnWidthPersistence(layout: layout, defaults: defaults)
        defer { widths.cancelPendingPersistence() }

        widths.scheduleLeftWidthPersistence(360, isCollapsed: false)
        widths.scheduleLeftWidthPersistence(312, isCollapsed: false)
        widths.scheduleRightWidthPersistence(480, isCollapsed: false)
        widths.scheduleRightWidthPersistence(0, isCollapsed: true)
        // 跨过实际去抖间隔，证明已排队的旧写入被取消，而非只检查内存里的标记。
        try await Task.sleep(for: .milliseconds(320))
        #expect(defaults.double(forKey: layout.left.defaultsKey) == 312)
        #expect(defaults.double(forKey: layout.right.defaultsKey) == 420)
    }
}
