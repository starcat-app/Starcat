//
//  ScrollTailControllerTests.swift
//  StarcatTests
//
//  锁住 AI 流式内容“跟随尾部”的用户手势生命周期。
//
//  关键约束：用户一开始滚动就暂停；滚动过程中即使经过底部也不恢复；
//  只有用户滚动结束且底部锚点可见时恢复。流式布局变化不能改变用户意图状态。
//

import SwiftUI
import Testing
@testable import Starcat

@MainActor
@Suite("ScrollTailController")
struct ScrollTailControllerTests {

    @Test("用户开始滚动立即暂停跟随")
    func userScrollImmediatelyDisengages() {
        let controller = ScrollTailController()

        controller.updatePhase(.tracking)

        #expect(!controller.isFollowing)
    }

    @Test("滚动过程中经过底部仍保持暂停")
    func reachingBottomDuringGestureDoesNotReengage() {
        let controller = ScrollTailController()
        controller.updatePhase(.interacting)

        controller.updateBottomVisibility(true)

        #expect(!controller.isFollowing)
    }

    @Test("用户结束滚动且停在底部后恢复跟随")
    func userScrollEndingAtBottomReengages() {
        let controller = ScrollTailController()
        controller.updateBottomVisibility(false)
        controller.updatePhase(.interacting)
        controller.updateBottomVisibility(true)

        controller.updatePhase(.idle)

        #expect(controller.isFollowing)
    }

    @Test("用户结束滚动但未到底部时保持暂停")
    func userScrollEndingAwayFromBottomStaysDisengaged() {
        let controller = ScrollTailController()
        controller.updatePhase(.interacting)
        controller.updateBottomVisibility(false)

        controller.updatePhase(.idle)

        #expect(!controller.isFollowing)
    }

    @Test("流式增长导致底部锚点暂时不可见时保持跟随")
    func contentGrowthDoesNotDisengageFollowing() {
        let following = ScrollTailController()
        following.updateBottomVisibility(false)
        #expect(following.isFollowing)
    }

    @Test("重复的底部可见性回调不改变跟随状态")
    func duplicateBottomVisibilityKeepsFollowingStable() {
        let controller = ScrollTailController()

        controller.updateBottomVisibility(true)
        controller.updateBottomVisibility(true)

        #expect(controller.isFollowing)
    }

    @Test("idle 先到且随后锚点可见时仍恢复跟随")
    func visibilityAfterIdleReengages() {
        let paused = ScrollTailController()
        paused.updateBottomVisibility(false)
        paused.updatePhase(.interacting)
        paused.updatePhase(.idle)
        #expect(!paused.isFollowing)

        paused.updateBottomVisibility(true)

        #expect(paused.isFollowing)
    }

    @Test("程序化滚动不改变跟随状态")
    func programmaticScrollPreservesState() {
        let controller = ScrollTailController()
        controller.updateBottomVisibility(false)
        controller.updatePhase(.interacting)
        controller.updatePhase(.idle)

        controller.updatePhase(.animating)

        #expect(!controller.isFollowing)
    }

    @Test("内容增长按时间窗口合并自动尾随")
    func contentGrowthScrollsAtMostOncePerWindow() {
        let controller = ScrollTailController(minimumAutomaticScrollInterval: 0.20)

        let first = controller.shouldFollowContentHeightChange(from: 100, to: 120, now: 1.00)
        let coalesced = controller.shouldFollowContentHeightChange(from: 120, to: 140, now: 1.10)
        let nextWindow = controller.shouldFollowContentHeightChange(from: 140, to: 160, now: 1.21)

        #expect(first)
        #expect(!coalesced)
        #expect(nextWindow)
    }

    @Test("内容折叠缩短时立即重新贴底")
    func contentShrinkBypassesGrowthThrottle() {
        let controller = ScrollTailController(minimumAutomaticScrollInterval: 0.20)
        #expect(controller.shouldFollowContentHeightChange(from: 100, to: 120, now: 1.00))

        let shrink = controller.shouldFollowContentHeightChange(from: 120, to: 80, now: 1.05)

        #expect(shrink)
    }

    @Test("用户已暂停跟随时内容高度变化不抢滚动")
    func pausedFollowingIgnoresContentHeightChanges() {
        let controller = ScrollTailController(minimumAutomaticScrollInterval: 0)
        controller.pauseFollowing()

        let shouldScroll = controller.shouldFollowContentHeightChange(from: 100, to: 150, now: 1.00)

        #expect(!shouldScroll)
    }

    @Test("亚像素高度抖动不会触发自动尾随")
    func subpixelHeightJitterDoesNotScroll() {
        let controller = ScrollTailController(minimumAutomaticScrollInterval: 0)

        let shouldScroll = controller.shouldFollowContentHeightChange(from: 100, to: 100.4, now: 1.00)

        #expect(!shouldScroll)
    }

    @Test("手动恢复跟随后清空旧限频窗口")
    func resumeFollowingResetsGrowthThrottle() {
        let controller = ScrollTailController(minimumAutomaticScrollInterval: 0.20)
        #expect(controller.shouldFollowContentHeightChange(from: 100, to: 120, now: 1.00))
        controller.resumeFollowing()

        let shouldScroll = controller.shouldFollowContentHeightChange(from: 120, to: 140, now: 1.05)

        #expect(shouldScroll)
    }

    @Test("手动恢复跟随不会伪造底部可见状态")
    func resumeFollowingPreservesBottomVisibility() {
        let controller = ScrollTailController()
        controller.updateBottomVisibility(false)
        controller.resumeFollowing()

        controller.updatePhase(.interacting)
        controller.updatePhase(.idle)

        #expect(!controller.isFollowing)
    }
}
