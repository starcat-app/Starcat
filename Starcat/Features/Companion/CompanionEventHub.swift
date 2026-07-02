//
//  CompanionEventHub.swift
//  Starcat
//
//  Browser Plugin 轻量事件广播中心。
//
//  关键约束:
//  - 只广播 Starcat 已落库后的本地事件, 不做乐观推送;
//  - 当前支持 notes / tags / AI summary, envelope 保留 type/repoID, 后续可扩展 health/wiki;
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
    private var noteObservationTask: Task<Void, Never>?
    private var tagsObservationTask: Task<Void, Never>?
    private var summaryObservationTask: Task<Void, Never>?
    private let lookupTags: @Sendable (Int64) async throws -> [CompanionTagDTO]
    private let lookupSummary: @Sendable (Int64) async throws -> CompanionAISummaryDTO?

    init(
        notificationCenter: NotificationCenter = .default,
        lookupTags: @escaping @Sendable (Int64) async throws -> [CompanionTagDTO] = { _ in [] },
        lookupSummary: @escaping @Sendable (Int64) async throws -> CompanionAISummaryDTO? = { _ in nil }
    ) {
        self.lookupTags = lookupTags
        self.lookupSummary = lookupSummary

        noteObservationTask = Task { @MainActor [weak self] in
            let stream = notificationCenter.notifications(named: .repoNoteContentDidChange)
            for await notification in stream {
                guard let repoID = notification.userInfo?["repoId"] as? Int64 else { continue }
                let content = notification.userInfo?["content"] as? String ?? ""
                let editedAt = notification.userInfo?["editedAt"] as? String
                self?.publishNote(repoID: repoID, content: content, editedAt: editedAt)
            }
        }

        tagsObservationTask = Task { @MainActor [weak self] in
            let stream = notificationCenter.notifications(named: .repoTagsDidChange)
            for await notification in stream {
                guard let self,
                      let repoID = notification.userInfo?["repoId"] as? Int64 else { continue }
                do {
                    let tags = try await self.lookupTags(repoID)
                    self.publishTags(repoID: repoID, tags: tags)
                } catch {
                    AppLog.general.warning("CompanionEventHub failed to publish tag update for repoID \(repoID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        summaryObservationTask = Task { @MainActor [weak self] in
            let stream = notificationCenter.notifications(named: .aiSummaryDidChange)
            for await notification in stream {
                guard let self,
                      let repoID = notification.userInfo?["repoId"] as? Int64 else { continue }
                do {
                    guard let summary = try await self.lookupSummary(repoID) else { continue }
                    self.publishSummary(repoID: repoID, summary: summary)
                } catch {
                    AppLog.general.warning("CompanionEventHub failed to publish summary update for repoID \(repoID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    deinit {
        noteObservationTask?.cancel()
        tagsObservationTask?.cancel()
        summaryObservationTask?.cancel()
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
            note: CompanionNoteDTO(editable: true, content: content, editedAt: editedAt),
            tags: nil,
            aiSummary: nil
        )
        publish(envelope)
    }

    func publishTags(repoID: Int64, tags: [CompanionTagDTO]) {
        let envelope = CompanionEventEnvelope(
            schemaVersion: 1,
            type: "tags.updated",
            repoID: repoID,
            note: nil,
            tags: tags,
            aiSummary: nil
        )
        publish(envelope)
    }

    func publishSummary(repoID: Int64, summary: CompanionAISummaryDTO) {
        let envelope = CompanionEventEnvelope(
            schemaVersion: 1,
            type: "summary.updated",
            repoID: repoID,
            note: nil,
            tags: nil,
            aiSummary: summary
        )
        publish(envelope)
    }

    private func publish(_ envelope: CompanionEventEnvelope) {
        for client in clients.values where client.repoID == nil || client.repoID == envelope.repoID {
            client.sink(envelope)
        }
    }
}
