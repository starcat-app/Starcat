//
//  ContextDegradationReasonTests.swift
//  StarcatTests
//
//  覆盖代码上下文降级文案：超限提示必须跟当前生效阈值走，不能再写死 100MB。
//

import Testing
@testable import Starcat

@Suite("ContextDegradationReason")
struct ContextDegradationReasonTests {

    @Test("超限文案按传入阈值格式化")
    func archiveTooLargeUsesConfiguredLimit() {
        let message = ContextDegradationReason.archiveTooLarge.bannerMessage(maximumArchiveMB: 50)
        #expect(message.contains("50"))
        #expect(!message.contains("100"))
    }

    @Test("超限文案默认按共享 100MB 安全上限渲染")
    func archiveTooLargeDefaultsToSharedLimit() {
        let message = ContextDegradationReason.archiveTooLarge.bannerMessage()
        #expect(message.contains("100"))
    }

    @Test("非超限原因仍走固定本地化 key")
    func otherReasonsUseStaticKeys() {
        let message = ContextDegradationReason.networkUnavailable.bannerMessage(maximumArchiveMB: 50)
        #expect(message == String.l10n("ai.context.degraded.networkUnavailable"))
    }
}
