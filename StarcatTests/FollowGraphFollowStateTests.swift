//
//  FollowGraphFollowStateTests.swift
//  StarcatTests
//
//  使用现有 OwnerFollowService 和内存 API 替身验证真实读写调用顺序，不接触登录或网络。
//  可控挂起点模拟慢查询与重复点击，避免用 sleep 掩盖并发次序问题。
//

import Foundation
import Testing
@testable import Starcat

/// 故意忽略取消的服务响应，验证状态层在返回点拒绝旧结果。
private actor FollowGraphFollowGate {
    private var response: CheckedContinuation<Bool, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var requested = false

    func value() async -> Bool {
        await withCheckedContinuation {
            response = $0
            requested = true
            waiter?.resume()
            waiter = nil
        }
    }

    func waitForRequest() async {
        if requested { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release(_ value: Bool) {
        response?.resume(returning: value)
        response = nil
    }
}

/// 每个用例独立模拟账户会话；失败不能触发图谱回写，成功不依赖卡片是否仍在屏幕上。
@MainActor @Suite("FollowGraph follow state")
struct FollowGraphFollowStateTests {
    private let user = FollowGraphNode(id: "2", login: "user2", name: nil, avatarURL: nil)

    @Test("失败保留原状态，重试成功后才能回写图谱，并支持取消关注")
    func successAndFailure() async {
        let mock = MockGitHubAPIClient()
        mock.isFollowingHandler = { _ in false }
        mock.followHandler = { _ in throw URLError(.notConnectedToInternet) }
        mock.unfollowHandler = { _ in }
        let service = OwnerFollowService(apiClient: mock)
        let state = FollowGraphFollowState()
        var changes: [Bool] = []
        await state.load(user, service: service)
        await state.toggle(user, service: service) { changes.append($0) }
        #expect(state.values[user.id] == false)
        #expect(state.errors[user.id] != nil)
        #expect(changes.isEmpty)
        #expect(state.inFlight.isEmpty)

        mock.followHandler = { _ in }
        await state.toggle(user, service: service) { changes.append($0) }
        #expect(state.values[user.id] == true)
        #expect(state.errors[user.id] == nil)
        await state.toggle(user, service: service) { changes.append($0) }
        #expect(state.values[user.id] == false)
        #expect(changes == [true, false])
    }

    @Test("写操作进行中忽略重复点击，只产生一次确认回调")
    func repeatedClicks() async {
        let mock = MockGitHubAPIClient()
        let gate = FollowGraphFollowGate()
        mock.isFollowingHandler = { _ in false }
        mock.followHandler = { _ in _ = await gate.value() }
        let service = OwnerFollowService(apiClient: mock)
        let state = FollowGraphFollowState()
        await state.load(user, service: service)
        var confirmations = 0
        let first = Task {
            await state.toggle(user, service: service) { _ in confirmations += 1 }
        }
        await gate.waitForRequest()
        #expect(state.inFlight.contains(user.id))
        await state.toggle(user, service: service) { _ in confirmations += 1 }
        await gate.release(true)
        await first.value
        #expect(confirmations == 1)
        #expect(state.values[user.id] == true)
        #expect(state.inFlight.isEmpty)
    }

    @Test("写入前开始的慢查询不能把关注成功状态回滚")
    func staleQueryAfterWrite() async {
        let mock = MockGitHubAPIClient()
        mock.isFollowingHandler = { _ in false }
        mock.followHandler = { _ in }
        let service = OwnerFollowService(apiClient: mock)
        let state = FollowGraphFollowState()
        await state.load(user, service: service)
        let gate = FollowGraphFollowGate()
        mock.isFollowingHandler = { _ in await gate.value() }
        let query = Task { await state.load(user, service: service) }
        await gate.waitForRequest()
        await state.toggle(user, service: service) { _ in }
        await gate.release(false)
        await query.value
        #expect(state.values[user.id] == true)
    }

    @Test("保留已关注状态的查询失败必须标记为重查，不能提示重试取消关注")
    func failedQueryKeepsReadIntent() async {
        let mock = MockGitHubAPIClient()
        mock.isFollowingHandler = { _ in true }
        let service = OwnerFollowService(apiClient: mock)
        let state = FollowGraphFollowState()
        await state.load(user, service: service)
        mock.isFollowingHandler = { _ in throw URLError(.notConnectedToInternet) }
        await state.load(user, service: service)
        #expect(state.values[user.id] == true)
        guard case .query? = state.errors[user.id] else {
            Issue.record("A failed status query must only retry the query")
            return
        }
        #expect(state.inFlight.isEmpty)
    }

    @Test("节点切换取消查询后，迟到响应不再写入状态")
    func cancelledQuery() async {
        let mock = MockGitHubAPIClient()
        let gate = FollowGraphFollowGate()
        mock.isFollowingHandler = { _ in await gate.value() }
        let service = OwnerFollowService(apiClient: mock)
        let state = FollowGraphFollowState()
        let query = Task { await state.load(user, service: service) }
        await gate.waitForRequest()
        query.cancel()
        await gate.release(true)
        await query.value
        #expect(state.values[user.id] == nil)
        #expect(state.errors[user.id] == nil)
    }
}
