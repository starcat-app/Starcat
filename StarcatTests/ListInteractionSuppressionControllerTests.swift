//
//  ListInteractionSuppressionControllerTests.swift
//  StarcatTests
//
//  长列表滚动交互门控的防抖语义测试。
//

import Testing
@testable import Starcat

@Suite("List interaction suppression")
@MainActor
struct ListInteractionSuppressionControllerTests {

    @Test("离散滚轮事件只在最后一次 idle 后恢复")
    func coalescesDiscreteScrollPhases() async throws {
        let controller = ListInteractionSuppressionController(resumeDelay: .milliseconds(30))

        controller.update(isActive: true)
        #expect(controller.isSuppressed)

        controller.update(isActive: false)
        try await Task.sleep(for: .milliseconds(15))
        controller.update(isActive: true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(controller.isSuppressed)

        controller.update(isActive: false)
        try await Task.sleep(for: .milliseconds(45))
        #expect(!controller.isSuppressed)
    }

    @Test("取消时立即恢复且不会发生延迟回写")
    func cancellationRestoresImmediately() async throws {
        let controller = ListInteractionSuppressionController(resumeDelay: .milliseconds(20))

        controller.update(isActive: true)
        controller.update(isActive: false)
        controller.cancel()
        #expect(!controller.isSuppressed)

        try await Task.sleep(for: .milliseconds(30))
        #expect(!controller.isSuppressed)
    }
}
