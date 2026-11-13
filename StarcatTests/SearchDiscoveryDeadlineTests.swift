//
//  SearchDiscoveryDeadlineTests.swift
//  StarcatTests
//
//  验证真正的等待边界，Provider 无视取消时也不能拖延整轮搜索。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Search Discovery Deadline")
@MainActor
struct SearchDiscoveryDeadlineTests {
    @Test("截止后不等待不响应取消的 Provider")
    func timeoutDoesNotWaitForProvider() async {
        let gate = DeadlineProviderGate()
        let cleanup = Task {
            try? await Task.sleep(for: .seconds(1))
            gate.release()
        }
        defer {
            cleanup.cancel()
            gate.release()
        }
        do {
            _ = try await SearchDiscoveryDeadline.run(until: Date().addingTimeInterval(0.03)) {
                await gate.wait()
                return 1
            }
            Issue.record("Expected deadline failure")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
        #expect(gate.started)
        #expect(!gate.released)
    }

    @Test("已过期的截止时间不会启动 Provider")
    func expiredDeadlineDoesNotStartWork() async {
        let gate = DeadlineProviderGate()
        do {
            _ = try await SearchDiscoveryDeadline.run(until: Date().addingTimeInterval(-1)) {
                await gate.wait()
                return 1
            }
            Issue.record("Expected deadline failure")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
        #expect(!gate.started)
    }
}

/// 故意不响应 Task 取消，模拟仍在退出的本地模型或第三方服务。
@MainActor
private final class DeadlineProviderGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private(set) var released = false

    func wait() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
