//
//  StarsSyncButton.swift
//  Starcat
//
//  GitHub Stars 全量 / 增量同步按钮。
//
//  原位于侧边栏「全部仓库」行右侧（`SidebarSyncButton`）；2026-06-17 迁到
//  Manage 列表顶栏，与排序 Picker 同排，对齐 Activity / Weekly 中栏布局。
//
//  交互约束（与旧 Sidebar 版一致）：
//  - 同步中：图标旋转；hover 切 `xmark.circle.fill` 取消
//  - Rate limit：hover 切 xmark 取消等待
//  - 空闲 / 完成 / 失败：点击触发 `SyncManager.performFullSync`
//

import SwiftUI

/// Manage 列表顶栏的 Stars 同步按钮（保留侧边栏时代的取消 / 限流交互）。
struct StarsSyncButton: View {
    @Environment(SyncManager.self) private var syncManager
    @Environment(AuthSession.self) private var authSession
    /// 同步图标旋转在「关闭应用内动画」时跳过，仅瞬切角度给"刷新中"提示。
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var rotation: Double = 0

    var body: some View {
        Button {
            if syncManager.state == .syncing {
                syncManager.cancel()
            } else if case .rateLimited = syncManager.state {
                syncManager.cancel()
            } else if case .authenticated(let user) = authSession.state {
                syncManager.performFullSync(userID: user.id)
            }
        } label: {
            Image(systemName: iconName)
                .font(.caption)
                .rotationEffect(.degrees(rotation))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onAppear {
            updateRotation(isSyncing: isSyncing)
        }
        .onChange(of: isSyncing) { _, newValue in
            updateRotation(isSyncing: newValue)
        }
        .help(helpText)
    }

    private var isSyncing: Bool {
        if case .syncing = syncManager.state { return true }
        return false
    }

    private var iconName: String {
        switch syncManager.state {
        case .syncing:
            return isHovering ? "xmark.circle.fill" : "arrow.triangle.2.circlepath"
        case .rateLimited:
            return isHovering ? "xmark.circle.fill" : "hourglass"
        case .idle, .completed, .failed:
            return "arrow.triangle.2.circlepath"
        }
    }

    private var helpText: Text {
        switch syncManager.state {
        case .syncing:
            return Text("action.cancelSync")
        case .rateLimited:
            return Text("action.syncRateLimited")
        case .idle, .completed, .failed:
            return Text("action.syncInProgress")
        }
    }

    private func updateRotation(isSyncing: Bool) {
        if isSyncing {
            if reduceMotion {
                rotation = 360
            } else {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
        } else {
            if reduceMotion {
                rotation = 0
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    rotation = 0
                }
            }
        }
    }
}
