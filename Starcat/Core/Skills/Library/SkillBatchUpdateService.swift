//
//  SkillBatchUpdateService.swift
//  Starcat
//
//  批量更新冻结选择与每项 R；不扩大授权覆盖本地修改。
//  每项沿用内容事务，部分失败和取消可见，重试必须重新生成审核计划。
//

import Foundation

struct SkillBatchUpdateRow: Identifiable, Sendable {
    let id: UUID
    let name: String
    var preview: PreparedSkillUpdate?
    var result: SkillOperationResult?
    var isReady: Bool { preview != nil && result == nil }
}

enum SkillBatchUpdateEvent: Sendable {
    case started(UUID)
    case finished(UUID, SkillOperationResult)
}

/// 同一批次只保留 256 MiB 待审核内容；网络 head／tree 由既有请求层共享。
actor SkillBatchUpdateService {
    private let store: SkillLibraryStore
    private let updates: SkillContentUpdateService
    private let maximumBytes: Int64

    init(
        store: SkillLibraryStore, updates: SkillContentUpdateService,
        distributionGate: DistributionGate = DistributionGate(), maximumBytes: Int64 = 268_435_456
    ) throws {
        try distributionGate.requireDirect(.skillManagement)
        self.store = store
        self.updates = updates
        self.maximumBytes = maximumBytes
    }

    /// 重复选择只审核一次；外部／消失条目仍保留拒绝结果，不悄悄缩小范围。
    func prepare(entryIDs: [UUID]) async throws -> [SkillBatchUpdateRow] {
        let snapshot = try await store.snapshot()
        let names = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0.manifestName) })
        let payloads = SkillImportPayloadCache()
        var seen: Set<UUID> = []
        var rows: [SkillBatchUpdateRow] = []
        var bytes: Int64 = 0
        for id in entryIDs where seen.insert(id).inserted {
            var row = SkillBatchUpdateRow(id: id, name: names[id] ?? id.uuidString)
            do {
                try Task.checkCancellation()
                let preview = try await updates.prepare(entryID: id, payloadCache: payloads)
                if preview.hasLocalChanges {
                    await updates.discard(preview)
                    throw SkillOperationError.localChanges
                }
                let size = preview.content.plan.fingerprint.members.reduce(Int64(0)) { $0 + $1.byteCount }
                guard bytes + size <= maximumBytes else {
                    await updates.discard(preview)
                    row.result = SkillOperationResult(
                        id: preview.id, entryID: id, status: .conflict, message: String.l10n("skills.update.batch.limit")
                    )
                    rows.append(row)
                    continue
                }
                bytes += size
                row.preview = preview
            } catch {
                row.result = SkillOperationResult(
                    id: UUID(), entryID: id, status: error is CancellationError ? .cancelled : .conflict,
                    message: error.localizedDescription
                )
            }
            rows.append(row)
        }
        await payloads.close()
        return rows
    }

    /// 成功项保持结果；失败／取消项先丢弃旧下载，再冻结新的来源与现场。
    func retryPreview(_ rows: [SkillBatchUpdateRow]) async throws -> [SkillBatchUpdateRow] {
        let retrying = rows.filter { $0.result?.canRetry == true }
        await discard(retrying)
        let retried = try await prepare(entryIDs: retrying.map(\.id))
        let replacements = Dictionary(uniqueKeysWithValues: retried.map { ($0.id, $0) })
        return rows.map { replacements[$0.id] ?? $0 }
    }

    /// 取消不把已经提交的项伪装成撤销；后续项逐一产生 cancelled。
    func execute(
        _ rows: [SkillBatchUpdateRow],
        progress: @escaping @MainActor @Sendable (SkillBatchUpdateEvent) -> Void = { _ in }
    ) async -> [SkillBatchUpdateRow] {
        var finished: [SkillBatchUpdateRow] = []
        for var row in rows {
            guard row.isReady, let preview = row.preview else { finished.append(row); continue }
            if Task.isCancelled {
                row.result = SkillOperationResult(id: preview.id, entryID: row.id, status: .cancelled, message: nil)
                await updates.discard(preview)
            } else {
                await progress(.started(row.id))
                row.result = await updates.execute(preview)
            }
            finished.append(row)
            if let result = row.result { await progress(.finished(row.id, result)) }
        }
        return finished
    }

    func discard(_ rows: [SkillBatchUpdateRow]) async {
        for row in rows {
            if let preview = row.preview { await updates.discard(preview) }
        }
    }
}
