//
//  WidgetSnapshotPublicationGateTests.swift
//  StarcatTests
//
//  Widget 异步发布门禁测试：覆盖账号切换与并发发布的失效规则。
//

import Testing
@testable import Starcat

@MainActor
@Suite("WidgetSnapshotPublicationGate")
struct WidgetSnapshotPublicationGateTests {

    @Test("empty 发布立即使旧账号 ticket 失效")
    func invalidatesTicketOnAccountBoundary() throws {
        let gate = WidgetSnapshotPublicationGate()
        let oldTicket = try #require(gate.beginReady(userID: 1))

        gate.invalidate()

        #expect(!gate.permits(oldTicket, currentUserID: 1))
    }

    @Test("同账号并发发布只有最后开始的一次可保存")
    func onlyLatestReadyPublicationWins() throws {
        let gate = WidgetSnapshotPublicationGate()
        let first = try #require(gate.beginReady(userID: 1))
        let second = try #require(gate.beginReady(userID: 1))

        #expect(!gate.permits(first, currentUserID: 1))
        #expect(gate.permits(second, currentUserID: 1))
    }

    @Test("revision 相同但当前用户不同仍拒绝保存")
    func rejectsMismatchedUser() throws {
        let gate = WidgetSnapshotPublicationGate()
        let ticket = try #require(gate.beginReady(userID: 1))

        #expect(!gate.permits(ticket, currentUserID: 2))
        #expect(!gate.permits(ticket, currentUserID: nil))
    }

    @Test("匿名数据库不会生成 ready ticket 且会推进 revision")
    func rejectsAnonymousReadyPublication() throws {
        let gate = WidgetSnapshotPublicationGate()
        let oldTicket = try #require(gate.beginReady(userID: 1))

        #expect(gate.beginReady(userID: nil) == nil)
        #expect(!gate.permits(oldTicket, currentUserID: 1))
    }
}
