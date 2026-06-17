//
//  SidebarAnimationCoordinator.swift
//  Starcat
//
//  Sidebar 装饰动画协调器（仅头像 tint；贡献草坪与 Activity 完全解耦）。
//
//  2026-06-17 dong4j：Activity 切分类时只抑制头像卡 tint 的 0.45s 补间。
//  **草坪蛇不参与**——暂停 Timeline 并用 `.empty` 帧重画会让已吃格子全部回弹，体验更糟。
//

import Foundation
import Observation

@MainActor
@Observable
final class SidebarAnimationCoordinator {

    /// 头像卡 tint：Activity 切分类过渡期间禁用 `.animation(..., value: sidebarTintColor)`。
    private(set) var suppressSidebarTintAnimation = false

    private var transitionEndTask: Task<Void, Never>?

    /// Activity 侧边栏分类切换（HomeView `onChange(of: selectedActivityCategory)`）。
    func beginActivityCategoryTransition(duration: TimeInterval = 0.35) {
        suppressSidebarTintAnimation = true

        transitionEndTask?.cancel()
        transitionEndTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(duration, 0.05) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.suppressSidebarTintAnimation = false
        }
    }
}
