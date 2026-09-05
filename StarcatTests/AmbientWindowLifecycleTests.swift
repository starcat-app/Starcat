//
//  AmbientWindowLifecycleTests.swift
//  StarcatTests
//
//  不启动真实 NSWindow，验证进入、快速退出、系统退出与失败必达关闭态。
//

import Testing
@testable import Starcat

@Suite("Ambient Window Lifecycle")
struct AmbientWindowLifecycleTests {
    @Test("正常打开进入退出并关闭")
    func normalLifecycle() {
        var lifecycle = AmbientWindowLifecycle()

        lifecycle.beginOpening()
        #expect(lifecycle.requestEnterFullScreen() == .enterFullScreen)
        #expect(lifecycle.didEnterFullScreen() == nil)
        #expect(lifecycle.phase == .fullScreen)
        #expect(lifecycle.requestClose() == .exitFullScreen)
        #expect(lifecycle.didExitFullScreen() == .close)
        lifecycle.didClose()
        #expect(lifecycle.phase == .closed)
    }

    @Test("进入过程中快速退出只在进入完成后 toggle 一次")
    func closeWhileEnteringWaitsForDidEnter() {
        var lifecycle = AmbientWindowLifecycle()

        lifecycle.beginOpening()
        #expect(lifecycle.requestEnterFullScreen() == .enterFullScreen)
        #expect(lifecycle.requestClose() == nil)
        #expect(lifecycle.requestClose() == nil)
        #expect(lifecycle.didEnterFullScreen() == .exitFullScreen)
        #expect(lifecycle.phase == .exitingFullScreen)
    }

    @Test("进入失败直接请求关闭")
    func failedEntryClosesWindow() {
        var lifecycle = AmbientWindowLifecycle()

        lifecycle.beginOpening()
        _ = lifecycle.requestEnterFullScreen()
        #expect(lifecycle.didFailToEnterFullScreen() == .close)
        #expect(lifecycle.phase == .closing)
    }

    @Test("系统 Esc 退出全屏同样最终关闭")
    func systemExitClosesWindow() {
        var lifecycle = AmbientWindowLifecycle()

        lifecycle.beginOpening()
        _ = lifecycle.requestEnterFullScreen()
        _ = lifecycle.didEnterFullScreen()
        #expect(lifecycle.didExitFullScreen() == .close)
        #expect(lifecycle.phase == .closing)
    }
}
