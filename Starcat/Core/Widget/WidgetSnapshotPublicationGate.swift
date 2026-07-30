//
//  WidgetSnapshotPublicationGate.swift
//  Starcat
//
//  Widget 快照异步发布的 revision 与用户身份门禁。
//
//  快照构建和头像下载都会跨 `await`。只依赖 Task cancellation 无法保证旧任务不在
//  账号切换后恢复，因此保存前必须同时验证“仍是最后一次发布”和“仍是同一用户”。
//

import Foundation

struct WidgetSnapshotPublicationTicket: Equatable, Sendable {
    let revision: UInt64
    let userID: Int64
}

@MainActor
final class WidgetSnapshotPublicationGate {
    private var revision: UInt64 = 0

    /// 开始一次 ready 发布；匿名数据库不能产生 ready ticket。
    ///
    /// 即使 userID 为 nil 也先推进 revision，使此前正在运行的 ticket 失效。
    func beginReady(userID: Int64?) -> WidgetSnapshotPublicationTicket? {
        advanceRevision()
        guard let userID else { return nil }
        return WidgetSnapshotPublicationTicket(revision: revision, userID: userID)
    }

    /// preparing / signedOut / unavailable 都立即使所有在途 ready 发布失效。
    func invalidate() {
        advanceRevision()
    }

    /// 只有最后开始、且数据库仍属于同一用户的任务可以写共享容器。
    func permits(
        _ ticket: WidgetSnapshotPublicationTicket,
        currentUserID: Int64?
    ) -> Bool {
        ticket.revision == revision && ticket.userID == currentUserID
    }

    private func advanceRevision() {
        revision &+= 1
    }
}
