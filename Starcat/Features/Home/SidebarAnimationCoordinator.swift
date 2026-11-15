//
//  SidebarAnimationCoordinator.swift
//  Starcat
//
//  Sidebar 头像 tint 与导航内容淡化；贡献草坪与 Activity 完全解耦。
//
//  2026-06-17 dong4j：Activity 切分类时只抑制头像卡 tint 的 0.45s 补间。
//  **草坪蛇不参与**——暂停 Timeline 并用 `.empty` 帧重画会让已吃格子全部回弹，体验更糟。
//

import Foundation
import Observation
import SwiftUI

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

/// 侧栏内容的展示选择与业务选择分离，只在旧内容退完后换入最后一次选择。
///
/// 不重置 List 或后台服务的 identity；仅靠透明度与动画完成回调衔接两个阶段，
/// 避免分类 section 的布局插值拖动整窗，也避免用固定延时猜测退场是否结束。
@MainActor
@Observable
final class SidebarContentTransition<Selection: Equatable> {
    private(set) var displayedSelection: Selection?
    private(set) var opacity = 1.0

    @ObservationIgnored private var pendingSelection: Selection?
    @ObservationIgnored private var isFadingOut = false
    @ObservationIgnored private var revision = 0

    /// 首次展示或减少动效时瞬切；淡出期间的重复请求只更新目的地，不排队播放。
    func update(to selection: Selection, reduceMotion: Bool) {
        pendingSelection = selection
        if displayedSelection == nil || reduceMotion {
            revision &+= 1
            isFadingOut = false
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                displayedSelection = selection
                opacity = 1
            }
            return
        }
        guard !isFadingOut, displayedSelection != selection else { return }
        isFadingOut = true
        revision &+= 1
        let currentRevision = revision
        withAnimation(.easeOut(duration: 0.12), completionCriteria: .removed) {
            opacity = 0
        } completion: {
            // 宿主消失或切到减少动效时，旧回调不能重新开始入场。
            guard self.revision == currentRevision else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.displayedSelection = self.pendingSelection
                self.isFadingOut = false
            }
            withAnimation(.easeIn(duration: 0.12)) {
                self.opacity = 1
            }
        }
    }
}
