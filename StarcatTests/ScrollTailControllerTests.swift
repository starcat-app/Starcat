//
//  ScrollTailControllerTests.swift
//  StarcatTests
//
//  锁住 AI 流式内容“跟随尾部”的用户手势生命周期。
//
//  关键约束：用户一开始滚动就暂停；滚动过程中即使经过底部也不恢复；
//  只有用户滚动结束并停在底部时恢复。程序化滚动不能改变用户意图状态。
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

        controller.updatePhase(.tracking, distanceFromBottom: 0)

        #expect(!controller.isFollowing)
    }

    @Test("滚动过程中经过底部仍保持暂停")
    func reachingBottomDuringGestureDoesNotReengage() {
        let controller = ScrollTailController()
        controller.updatePhase(.interacting, distanceFromBottom: 120)

        controller.updateGeometry(distanceFromBottom: 0)

        #expect(!controller.isFollowing)
    }

    @Test("用户结束滚动且停在底部后恢复跟随")
    func userScrollEndingAtBottomReengages() {
        let controller = ScrollTailController()
        controller.updatePhase(.interacting, distanceFromBottom: 120)

        controller.updatePhase(.idle, distanceFromBottom: 4)

        #expect(controller.isFollowing)
    }

    @Test("用户结束滚动但未到底部时保持暂停")
    func userScrollEndingAwayFromBottomStaysDisengaged() {
        let controller = ScrollTailController()
        controller.updatePhase(.interacting, distanceFromBottom: 120)

        controller.updatePhase(.idle, distanceFromBottom: 20)

        #expect(!controller.isFollowing)
    }

    @Test("程序化滚动不暂停也不恢复跟随")
    func programmaticScrollPreservesState() {
        let following = ScrollTailController()
        following.updatePhase(.animating, distanceFromBottom: 100)
        #expect(following.isFollowing)

        let paused = ScrollTailController()
        paused.updatePhase(.interacting, distanceFromBottom: 100)
        paused.updatePhase(.idle, distanceFromBottom: 100)
        paused.updatePhase(.animating, distanceFromBottom: 0)
        #expect(!paused.isFollowing)
    }
}
