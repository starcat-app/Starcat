//
//  SettingsConnectionTestTests.swift
//  StarcatTests
//
//  设置页连接测试的竞态回归：旧请求不能提交、新请求的忙碌状态不能被旧请求清除。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("Settings connection test")
struct SettingsConnectionTestTests {
    private enum Failure: Error { case rejected }

    @Test("旧请求成功或失败都不能覆盖新请求或落盘", arguments: [false, true])
    func staleRequestCannotOverwriteNewRequest(fails: Bool) async throws {
        let state = SettingsConnectionTest<String>()
        var oldContinuation: CheckedContinuation<String, Error>?
        var newContinuation: CheckedContinuation<String, Error>?
        var saved: [String] = []
        let old = Task {
            await state.run {
                try await withCheckedThrowingContinuation { oldContinuation = $0 }
            } save: { saved.append($0) }
        }
        for _ in 0..<100 where oldContinuation == nil { await Task.yield() }
        let oldPending = try #require(oldContinuation)
        state.invalidate()
        let next = Task {
            await state.run {
                try await withCheckedThrowingContinuation { newContinuation = $0 }
            } save: { saved.append($0) }
        }
        for _ in 0..<100 where newContinuation == nil { await Task.yield() }
        let newPending = try #require(newContinuation)
        if fails { oldPending.resume(throwing: Failure.rejected) }
        else { oldPending.resume(returning: "old") }
        await old.value
        #expect(state.isTesting)
        #expect(state.result == nil)
        #expect(state.errorMessage == nil)
        #expect(saved.isEmpty)
        newPending.resume(returning: "new")
        await next.value
        #expect(state.result == "new")
        #expect(saved == ["new"])
        #expect(!state.isTesting)
    }

    @Test("测试取消后不保存也不显示错误")
    func cancellationDoesNotCommit() async throws {
        let state = SettingsConnectionTest<String>()
        var continuation: CheckedContinuation<String, Never>?
        var saved = false
        let task = Task {
            await state.run {
                await withCheckedContinuation { continuation = $0 }
            } save: { _ in saved = true }
        }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        task.cancel()
        pending.resume(returning: "cancelled")
        await task.value
        #expect(!saved)
        #expect(state.result == nil)
        #expect(state.errorMessage == nil)
        #expect(!state.isTesting)
    }

    @Test("保存失败不显示连接成功，编辑后清除失败状态")
    func saveFailureIsNotSuccess() async {
        let state = SettingsConnectionTest<String>()
        await state.run(probe: { "connected" }, save: { _ in throw Failure.rejected })
        #expect(state.result == nil)
        #expect(state.errorMessage != nil)
        #expect(!state.isSaving)
        #expect(!state.isTesting)
        state.invalidate()
        #expect(state.errorMessage == nil)
    }

    @Test("保存期间拒绝重复测试和重置")
    func savingExcludesOtherCommits() async throws {
        let state = SettingsConnectionTest<String>()
        var continuation: CheckedContinuation<Void, Never>?
        var secondProbe = false
        let first = Task {
            await state.run(probe: { "first" }) { _ in
                await withCheckedContinuation { continuation = $0 }
            }
        }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        #expect(state.isSaving)
        await state.run(probe: { secondProbe = true; return "second" })
        let reset = await state.reset { Issue.record("A reset must not overlap saving") }
        #expect(!secondProbe)
        #expect(!reset)
        pending.resume()
        await first.value
        #expect(state.result == "first")
        #expect(!state.isSaving)
    }
}
