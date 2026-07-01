//
//  CompanionEventHub.swift
//  Starcat
//
//  Browser Plugin 轻量事件广播中心。
//
//  关键约束:
//  - 只广播 Starcat 已落库后的本地事件, 不做乐观推送;
//  - 当前只支持 notes, 但事件 envelope 保留 type/repoID, 后续可扩展 health/wiki;
//  - 客户端按 repoID 订阅, 避免把无关仓库的私有笔记发到 GitHub 页面。
//

import Foundation

@MainActor
final class CompanionEventHub {
    typealias Sink = (CompanionEventEnvelope) -> Void

    private struct Client {
        let repoID: Int64?
        let sink: Sink
    }

    private var clients: [UUID: Client] = [:]
    private var observationTask: Task<Void, Never>?

    init(notificationCenter: NotificationCenter = .default) {
        observationTask = Task { @MainActor [weak self] in
            let stream = notificationCenter.notifications(named: .repoNoteContentDidChange)
            for await notification in stream {
                guard let repoID = notification.userInfo?["repoId"] as? Int64 else { continue }
                let content = notification.userInfo?["content"] as? String ?? ""
                let editedAt = notification.userInfo?["editedAt"] as? String
                self?.publishNote(repoID: repoID, content: content, editedAt: editedAt)
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    func addClient(repoID: Int64?, sink: @escaping Sink) -> UUID {
        let id = UUID()
        clients[id] = Client(repoID: repoID, sink: sink)
        return id
    }

    func removeClient(_ id: UUID) {
        clients[id] = nil
    }

    private func publishNote(repoID: Int64, content: String, editedAt: String?) {
        let envelope = CompanionEventEnvelope(
            schemaVersion: 1,
            type: "note.updated",
            repoID: repoID,
            note: CompanionNoteDTO(editable: true, content: content, editedAt: editedAt)
        )
        for client in clients.values where client.repoID == nil || client.repoID == repoID {
            client.sink(envelope)
        }
    }
}
