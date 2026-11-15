//
//  SkillRemovalCoordinator.swift
//  Starcat
//
//  Direct 库条目的确认后移除。先用既有回执解除自有分配，再在共同提交队列内
//  暂存整个受管目录、原子删除索引并移入废纸篓；中断后只处理证据仍匹配的现场。
//

import Foundation

/// 与导入、更新、分配共用队列；不能在 exclusively 闭包内调用再次排队的分配 execute。
actor SkillRemovalCoordinator {
    typealias Trash = @Sendable (URL) throws -> URL

    private let store: SkillLibraryStore
    private let operations: SkillOperationCoordinator
    private let assignments: SkillAssignmentCoordinator
    private let trash: Trash
    private let checkpoint: @Sendable (SkillRemovalCheckpoint) throws -> Void
    private var recoveryTask: Task<[SkillOperationResult], Never>?

    init(
        store: SkillLibraryStore, operations: SkillOperationCoordinator,
        assignments: SkillAssignmentCoordinator,
        distributionGate: DistributionGate = DistributionGate(),
        trash: @escaping Trash = SkillRemovalCoordinator.moveToTrash,
        checkpoint: @escaping @Sendable (SkillRemovalCheckpoint) throws -> Void = { _ in }
    ) throws {
        try distributionGate.requireDirect(.skillManagement)
        self.store = store
        self.operations = operations
        self.assignments = assignments
        self.trash = trash
        self.checkpoint = checkpoint
    }

    /// 审核时冻结链接身份、完整目录和当前内容基线；本地修改必须先另存或恢复。
    func prepare(entryID: UUID) async throws -> SkillRemovalPlan {
        let snapshot = try await store.snapshot()
        guard let entry = snapshot.entries.first(where: { $0.id == entryID && $0.managementKind == .managed }),
              let receipt = try await store.receipt(for: entryID),
              receipt.revisionID == entry.currentRevisionID else { throw SkillOperationError.ownership }
        try validatePath(store.paths.entryDirectory(entryID))
        guard try await SkillFilePrimitives.fingerprint(content(entry)) == receipt.fingerprint
        else { throw SkillOperationError.localChanges }
        var plans: [SkillAssignmentPlan] = []
        for assignment in snapshot.assignments.filter({ $0.entryID == entryID }).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            plans.append(try await assignments.prepare(entryID: entryID, action: .uninstall, assignmentID: assignment.id))
        }
        let plan = SkillRemovalPlan(
            entry: entry, receipt: receipt,
            fingerprint: try await fingerprint(store.paths.entryDirectory(entryID)),
            assignments: plans,
            discoveredPaths: Array(Set(snapshot.locations.filter { $0.entryID == entryID }.map(\.lexicalPath))).sorted()
        )
        try await validate(plan, requireNoAssignments: false)
        return plan
    }

    /// 解除分配逐项排队；任一项失败就保留库内容。最终移除重新入队并复核无新增分配。
    func execute(_ plan: SkillRemovalPlan) async -> SkillRemovalOutcome {
        _ = await operations.recover()
        _ = await assignments.recover()
        _ = await recover()
        var results: [SkillOperationResult] = []
        do {
            if let recorded = try await store.operations().first(where: { $0.id == plan.id })?.result {
                return SkillRemovalOutcome(result: recorded, assignmentResults: [])
            }
            try await validate(plan, requireNoAssignments: false)
            for assignment in plan.assignments {
                try Task.checkCancellation()
                let outcome = await assignments.execute(assignment)
                results.append(outcome)
                guard outcome.isSuccess else {
                    return SkillRemovalOutcome(
                        result: result(plan, outcome.status, message: outcome.message), assignmentResults: results
                    )
                }
            }
            let outcome = await operations.exclusively { await self.perform(plan) }
            return SkillRemovalOutcome(result: outcome, assignmentResults: results)
        } catch {
            let status: SkillOperationStatus = error is CancellationError ? .cancelled
                : error is SkillOperationError ? .conflict : .failed
            return SkillRemovalOutcome(
                result: result(plan, status, message: error.localizedDescription), assignmentResults: results
            )
        }
    }

    /// 整轮恢复排队且合并并发请求，不读取另一项仍在执行中的 removal journal。
    func recover() async -> [SkillOperationResult] {
        if let recoveryTask { return await recoveryTask.value }
        let task = Task { await self.operations.exclusively { await self.recoverAll() } }
        recoveryTask = task
        let results = await task.value
        recoveryTask = nil
        return results
    }

    private func perform(_ plan: SkillRemovalPlan) async -> SkillOperationResult {
        var journal = SkillRemovalJournal(plan: plan, phase: .prepared)
        var created = false
        do {
            if let recorded = try await store.operations().first(where: { $0.id == plan.id })?.result { return recorded }
            try await validate(plan, requireNoAssignments: true)
            guard !SkillFilePrimitives.exists(directory(plan)) else { throw SkillOperationError.journal }
            try write(journal)
            created = true
            try await store.save(record(journal, state: "running"))
            try Task.checkCancellation()
            try checkpoint(.beforeMove)
            journal.phase = .committing
            try write(journal)
            return try await complete(&journal)
        } catch {
            let committed = journal.phase != .prepared
            let status: SkillOperationStatus = if committed { .needsRecovery }
                else if error is CancellationError || Task.isCancelled { .cancelled }
                else if error is SkillOperationError { .conflict } else { .failed }
            if created { return await finish(journal, status: status, message: error.localizedDescription, preserve: committed) }
            return result(plan, status, message: error.localizedDescription)
        }
    }

    /// Trash 与 SQLite 不能组成一个原子事务。目录先留在本库暂存区，DB 失败时可继续恢复；
    /// Trash 成功但 journal 尚未落盘的缺口不能推断成功，保留记录供人工核对。
    private func complete(_ journal: inout SkillRemovalJournal) async throws -> SkillOperationResult {
        let plan = journal.plan
        let original = store.paths.entryDirectory(plan.entry.id)
        let payload = directory(plan).appendingPathComponent("payload", isDirectory: true)
        try validatePath(original)
        try validatePath(payload)
        if journal.phase == .trashed {
            guard !SkillFilePrimitives.exists(original), !SkillFilePrimitives.exists(payload),
                  journal.trashPath != nil,
                  try await store.snapshot().entries.allSatisfy({ $0.id != plan.entry.id })
            else { throw SkillOperationError.recovery }
            return await finish(journal, status: .succeeded, message: journal.trashPath)
        }
        if journal.phase == .committing, SkillFilePrimitives.exists(original) {
            try await validate(plan, requireNoAssignments: true, operationID: plan.id)
            guard !SkillFilePrimitives.exists(payload) else { throw SkillOperationError.ownership }
            try SkillFilePrimitives.moveExclusively(original, to: payload)
            try checkpoint(.afterMove)
            journal.phase = .staged
            try write(journal)
        }
        guard !SkillFilePrimitives.exists(original),
              try await fingerprint(payload) == plan.fingerprint else { throw SkillOperationError.recovery }
        try checkpoint(.beforeMetadata)
        try await store.commitRemoval(plan)
        journal.phase = .metadataCommitted
        try write(journal)
        try checkpoint(.afterMetadata)
        // 数据库提交期间外部程序仍可能修改暂存目录，移入废纸篓前再次检查完整现场。
        guard try await fingerprint(payload) == plan.fingerprint else { throw SkillOperationError.ownership }
        let trashed = try trash(payload)
        journal.trashPath = trashed.path
        journal.phase = .trashed
        try write(journal)
        try checkpoint(.afterTrash)
        return await finish(journal, status: .succeeded, message: trashed.path)
    }

    private func validate(
        _ plan: SkillRemovalPlan, requireNoAssignments: Bool, operationID: UUID? = nil
    ) async throws {
        let snapshot = try await store.snapshot()
        guard snapshot.entries.first(where: { $0.id == plan.entry.id }) == plan.entry,
              plan.entry.managementKind == .managed,
              try await store.receipt(for: plan.entry.id) == plan.receipt,
              plan.receipt.revisionID == plan.entry.currentRevisionID
        else { throw SkillOperationError.planChanged }
        let current = snapshot.assignments.filter { $0.entryID == plan.entry.id }.sorted { $0.id.uuidString < $1.id.uuidString }
        guard requireNoAssignments ? current.isEmpty : current == plan.assignments.compactMap(\.previous)
        else { throw SkillOperationError.planChanged }
        guard try await store.operations().allSatisfy({
            $0.entryID != plan.entry.id || $0.id == operationID || !["running", "needsRecovery"].contains($0.state)
        }) else { throw SkillOperationError.recovery }
        try validatePath(store.paths.entryDirectory(plan.entry.id))
        guard try await fingerprint(store.paths.entryDirectory(plan.entry.id)) == plan.fingerprint,
              try await SkillFilePrimitives.fingerprint(content(plan.entry)) == plan.receipt.fingerprint
        else { throw SkillOperationError.localChanges }
    }

    private func recoverAll() async -> [SkillOperationResult] {
        var results: [SkillOperationResult] = []
        do {
            try validatePath(store.paths.removalTransactions)
            let folders: [URL]
            do { folders = try FileManager.default.contentsOfDirectory(at: store.paths.removalTransactions, includingPropertiesForKeys: nil) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { folders = [] }
            var seen: Set<UUID> = []
            for folder in folders {
                guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
                seen.insert(id)
                do {
                    try validatePath(folder)
                    let file = folder.appendingPathComponent("journal.json")
                    guard !SkillFilePrimitives.isSymbolicLink(file) else { throw SkillOperationError.journal }
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    let bytes = try handle.read(upToCount: 8_388_609) ?? Data()
                    guard bytes.count <= 8_388_608 else { throw SkillOperationError.journal }
                    var journal = try JSONDecoder().decode(SkillRemovalJournal.self, from: bytes)
                    guard journal.formatVersion == 1, journal.plan.id == id else { throw SkillOperationError.journal }
                    if journal.phase == .prepared {
                        guard !SkillFilePrimitives.exists(folder.appendingPathComponent("payload"))
                        else { throw SkillOperationError.recovery }
                        results.append(await finish(journal, status: .cancelled))
                    } else {
                        results.append(try await complete(&journal))
                    }
                } catch {
                    results.append(SkillOperationResult(id: id, entryID: nil, status: .needsRecovery, message: error.localizedDescription))
                }
            }
            for record in try await store.operations() where record.kind == "removeEntry"
                && ["running", "needsRecovery"].contains(record.state) && !seen.contains(record.id) {
                results.append(SkillOperationResult(
                    id: record.id, entryID: record.entryID, status: .needsRecovery,
                    message: SkillOperationError.journal.localizedDescription
                ))
            }
        } catch {
            results.append(SkillOperationResult(id: UUID(), entryID: nil, status: .needsRecovery, message: error.localizedDescription))
        }
        return results
    }

    private func finish(
        _ journal: SkillRemovalJournal, status: SkillOperationStatus,
        message: String? = nil, preserve: Bool = false
    ) async -> SkillOperationResult {
        do {
            if !preserve {
                let remaining = try FileManager.default.contentsOfDirectory(atPath: directory(journal.plan).path)
                guard remaining == ["journal.json"] else { throw SkillOperationError.recovery }
            }
            let outcome = result(journal.plan, status, message: message)
            var record = record(journal, state: status.rawValue)
            record.resultJSON = String(decoding: try JSONEncoder().encode(outcome), as: UTF8.self)
            try await store.save(record)
            if !preserve { try FileManager.default.removeItem(at: directory(journal.plan)) }
            return outcome
        } catch { return result(journal.plan, .needsRecovery, message: error.localizedDescription) }
    }

    private func write(_ journal: SkillRemovalJournal) throws {
        let directory = directory(journal.plan)
        try validatePath(directory)
        let file = directory.appendingPathComponent("journal.json")
        guard !SkillFilePrimitives.isSymbolicLink(file) else { throw SkillOperationError.journal }
        let bytes = try JSONEncoder().encode(journal)
        guard bytes.count <= 8_388_608 else { throw SkillOperationError.journal }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: file, options: .atomic)
    }

    private func validatePath(_ url: URL) throws {
        guard !SkillFilePrimitives.isSymbolicLink(url),
              url.resolvingSymlinksInPath().path.hasPrefix(store.paths.root.resolvingSymlinksInPath().path + "/")
        else { throw SkillOperationError.journal }
    }

    /// 一个条目可能同时保留当前内容、上个版本和本地修改备份；预算覆盖已有双版本约束。
    private func fingerprint(_ directory: URL) async throws -> SkillDirectoryFingerprint {
        try await SkillFilePrimitives.fingerprint(
            directory, maximumEntries: 10_100, maximumBytes: 268_435_456, maximumDepth: 20
        )
    }

    private func content(_ entry: SkillLibraryEntry) -> URL {
        store.paths.entryDirectory(entry.id).appendingPathComponent("content").appendingPathComponent(entry.manifestName)
    }

    private func directory(_ plan: SkillRemovalPlan) -> URL {
        store.paths.removalTransactions.appendingPathComponent(plan.id.uuidString, isDirectory: true)
    }

    private func record(_ journal: SkillRemovalJournal, state: String) -> SkillOperationRecord {
        SkillOperationRecord(
            id: journal.plan.id, entryID: journal.plan.entry.id, kind: "removeEntry", state: state,
            journalPath: directory(journal.plan).appendingPathComponent("journal.json").path
        )
    }

    private func result(_ plan: SkillRemovalPlan, _ status: SkillOperationStatus, message: String? = nil) -> SkillOperationResult {
        SkillOperationResult(id: plan.id, entryID: plan.entry.id, status: status, message: message)
    }

    /// 不支持废纸篓或系统调用失败时保留暂存区，绝不回退为永久删除。
    private static func moveToTrash(_ directory: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: directory, resultingItemURL: &resultingURL)
        guard let resultingURL else { throw SkillOperationError.recovery }
        return resultingURL as URL
    }
}
