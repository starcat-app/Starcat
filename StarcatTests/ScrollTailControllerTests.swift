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

    @Test("每个流式快照都生成独立尾部请求")
    func streamingSnapshotsIssueDistinctTailRequests() {
        var requests = ScrollTailRequestSequencer()

        requests.issue()
        let firstRequestID = requests.requestID
        requests.issue(animatesScroll: true)

        #expect(firstRequestID == 1)
        #expect(requests.requestID == 2)
        #expect(requests.animatesScroll)
    }

    @Test("自动跟随请求保持无动画")
    func automaticTailRequestDoesNotAnimate() {
        var requests = ScrollTailRequestSequencer()

        requests.issue(animatesScroll: true)
        requests.issue()

        #expect(!requests.animatesScroll)
    }

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
}
