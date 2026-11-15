//
//  SkillOperationCoordinator.swift
//  Starcat
//
//  Direct 本机库的确认后写入与恢复。完整操作排队，await 不会让同一库的两次发布交错；
//  文件 journal 先于发布落盘，目录、receipt 与 SQLite 分开收敛，失败保留恢复证据。
//

import Foundation

enum SkillOperationError: LocalizedError {
    case planChanged, localChanges, ownership, recovery, journal

    var errorDescription: String? {
        let key = switch self {
        case .planChanged: "planChanged"
        case .localChanges: "localChanges"
        case .ownership: "ownership"
        case .recovery: "recovery"
        case .journal: "journal"
        }
        return String.l10n("skills.operation.error.\(key)")
    }
}

/// 只由显式打开的管理环境创建。关闭窗口不取消已进入提交阶段的操作。
actor SkillOperationCoordinator {
    nonisolated let store: SkillLibraryStore
    private let checkpoint: @Sendable (SkillOperationCheckpoint) throws -> Void
    private var tail: Task<Void, Never>?
    private var recoveryTask: Task<[SkillOperationResult], Never>?

    init(
        store: SkillLibraryStore,
        distributionGate: DistributionGate = DistributionGate(),
        checkpoint: @escaping @Sendable (SkillOperationCheckpoint) throws -> Void = { _ in }
    ) throws {
        try distributionGate.requireDirect(.skillManagement)
        self.store = store
        self.checkpoint = checkpoint
    }

    /// 合并同时到达的恢复请求；整轮恢复也排队，不能读取另一项尚在执行的 journal。
    func recover() async -> [SkillOperationResult] {
        if let recoveryTask { return await recoveryTask.value }
        let task = Task { await self.enqueue { await self.recoverAll() } }
        recoveryTask = task
        let results = await task.value
        recoveryTask = nil
        return results
    }

    /// 用户批准的是某个计划；执行仍检查来源、完整内容及当前所有权。
    func execute(_ plan: SkillContentOperationPlan) async -> SkillOperationResult {
        _ = await recover()
        return await enqueue { await self.perform(plan) }
    }

    /// 分配复用同一提交队列，避免内容换版与链接预检跨 await 交错。
    /// 调用方在进入队列之前完成所属 journal 的恢复，不在此闭包中递归排队。
    func exclusively<Value: Sendable>(_ work: @escaping @Sendable () async -> Value) async -> Value {
        await enqueue(work)
    }

    /// 回退也生成普通内容事务，确认时再次核对当前内容，分配仍指向稳定 canonical 路径。
    func prepareRollback(entryID: UUID) async throws -> SkillContentOperationPlan {
        let snapshot = try await store.snapshot()
        let rollback = try readRollback(entryID)
        guard let entry = snapshot.entries.first(where: { $0.id == entryID && $0.managementKind == .managed }),
              entry.currentRevisionID == rollback.currentRevisionID,
              let source = snapshot.sources.first(where: { $0.id == entry.sourceID }),
              let receipt = try await store.receipt(for: entryID),
              receipt.revisionID == entry.currentRevisionID
        else { throw SkillOperationError.planChanged }
        let directory = backupPath(rollback)
        try validateLibraryPath(directory)
        let fingerprint = try await SkillFilePrimitives.fingerprint(directory)
        guard fingerprint == rollback.fingerprint else { throw SkillOperationError.ownership }
        let manifest = try await SkillImportService.manifestBytes(directory)
        let metadata = try SkillFrontmatter.parse(String(decoding: manifest, as: UTF8.self), directory: entry.manifestName)
        var restored = entry
        restored.summary = metadata.description
        restored.updatedAt = Date().timeIntervalSince1970
        let revision = snapshot.revisions.first { $0.entryID == entryID && $0.contentDigest == fingerprint.digest }
            ?? SkillLibraryRevision(
                entryID: entryID, contentDigest: fingerprint.digest, manifestDigest: SkillFilePrimitives.digest(manifest),
                upstreamCommit: nil
            )
        return SkillContentOperationPlan(
            source: source, entry: restored, revision: revision, incomingDirectory: directory.path,
            fingerprint: fingerprint, previousEntry: entry, previousReceipt: receipt
        )
    }

    /// Task 的 predecessor 链约束整个异步操作，不把 actor 的方法互斥误当作事务互斥。
    private func enqueue<Value: Sendable>(
        _ work: @escaping @Sendable () async -> Value
    ) async -> Value {
        let previous = tail
        let task = Task {
            if let previous { _ = await previous.value }
            return await work()
        }
        tail = Task { _ = await task.value }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func perform(_ plan: SkillContentOperationPlan) async -> SkillOperationResult {
        var journal = SkillContentJournal(plan: plan, phase: .preparing)
        var journalCreated = false
        do {
            try Task.checkCancellation()
            let history = try await store.operations()
            if let previous = history.first(where: { $0.id == plan.id }) {
                return previous.result ?? result(plan, .needsRecovery, SkillOperationError.recovery)
            }
            guard !history.contains(where: {
                $0.entryID == plan.entry.id && ["running", "needsRecovery"].contains($0.state)
            })
            else { throw SkillOperationError.recovery }
            try validate(plan)
            let paths = transactionPaths(plan)
            guard !SkillFilePrimitives.exists(paths.stage), !SkillFilePrimitives.exists(paths.backup) else {
                throw SkillOperationError.planChanged
            }
            try await validateCurrent(plan)
            let source = URL(fileURLWithPath: plan.incomingDirectory, isDirectory: true)
            guard !paths.stage.resolvingSymlinksInPath().path.hasPrefix(source.resolvingSymlinksInPath().path + "/"),
                  try await SkillFilePrimitives.fingerprint(source) == plan.fingerprint else {
                throw SkillOperationError.planChanged
            }
            try Task.checkCancellation()
            // 无变化也要先完成当前内容、来源与所有权复核，不能用旧预览假报成功。
            if plan.previousEntry?.currentRevisionID == plan.revision.id,
               plan.expectedCurrentFingerprint == plan.fingerprint {
                return result(plan, .alreadySatisfied)
            }
            try write(journal)
            journalCreated = true
            try await store.save(record(plan, state: "running"))
            try ensureContentParent(plan)
            try checkpoint(.beforeStage)
            try await SkillFilePrimitives.stageCopy(from: source, expected: plan.fingerprint, paths: paths)
            journal.phase = .staged
            try write(journal)
            try checkpoint(.afterStage)
            try await validateCurrent(plan)
            try Task.checkCancellation()
            try checkpoint(.beforeCommit)
            journal.phase = .committing
            try write(journal)
            // 从这里开始不检查取消。当前项要提交或留下恢复记录，不能假报已回滚。
            try SkillFilePrimitives.publish(
                paths: paths, destination: destination(plan), replacing: plan.previousEntry != nil
            )
            journal.phase = .contentCommitted
            try write(journal)
            try checkpoint(.afterContentCommit)
            try checkpoint(.beforeReceipt)
            try writeReceipt(plan.receipt, entryID: plan.entry.id)
            try checkpoint(.beforeMetadata)
            try await store.commitContent(plan)
            journal.phase = .metadataCommitted
            try write(journal)
            try checkpoint(.afterMetadata)
            return await finish(journal, status: .succeeded)
        } catch {
            let committed = journal.phase == .committing || journal.phase == .contentCommitted || journal.phase == .metadataCommitted
            let status: SkillOperationStatus
            if committed { status = .needsRecovery }
            else if error is CancellationError || Task.isCancelled { status = .cancelled }
            else if error is SkillOperationError || error is RepoSkillError { status = .conflict }
            else { status = .failed }
            let outcome = result(plan, status, error)
            if journalCreated {
                try? await saveResult(plan, outcome)
                if !committed { return await finish(journal, status: status, error: error) }
            }
            return outcome
        }
    }

    /// 只读取受控 transactions 的 journal，恢复不访问原导入目录或重新下载。
    private func recoverAll() async -> [SkillOperationResult] {
        var results: [SkillOperationResult] = []
        let directory = store.paths.transactions
        do {
            guard !SkillFilePrimitives.isSymbolicLink(directory) else { throw SkillOperationError.journal }
            let folders: [URL]
            do { folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { folders = [] }
            var seen: Set<UUID> = []
            for folder in folders {
                guard let identifier = UUID(uuidString: folder.lastPathComponent) else { continue }
                seen.insert(identifier)
                do {
                    guard !SkillFilePrimitives.isSymbolicLink(folder) else { throw SkillOperationError.journal }
                    let file = folder.appendingPathComponent("journal.json")
                    guard !SkillFilePrimitives.isSymbolicLink(file) else { throw SkillOperationError.journal }
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: 8_388_609) ?? Data()
                    guard data.count <= 8_388_608 else { throw SkillOperationError.journal }
                    let journal = try JSONDecoder().decode(SkillContentJournal.self, from: data)
                    guard journal.formatVersion == 1, journal.plan.id == identifier else { throw SkillOperationError.journal }
                    results.append(await restore(journal))
                } catch {
                    results.append(SkillOperationResult(
                        id: identifier, entryID: nil, status: .needsRecovery, message: error.localizedDescription
                    ))
                }
            }
            for record in try await store.operations()
                where ["importContent", "updateContent"].contains(record.kind)
                    && !seen.contains(record.id) && ["running", "needsRecovery"].contains(record.state) {
                results.append(SkillOperationResult(
                    id: record.id, entryID: record.entryID, status: .needsRecovery,
                    message: SkillOperationError.journal.localizedDescription
                ))
            }
        } catch {
            results.append(SkillOperationResult(
                id: UUID(), entryID: nil, status: .needsRecovery, message: error.localizedDescription
            ))
        }
        return results
    }

    /// 按实际完整 digest 区分新版、旧版、可恢复备份和未知现场，绝不猜测后递归删除。
    private func restore(_ journal: SkillContentJournal) async -> SkillOperationResult {
        let plan = journal.plan
        do {
            try validate(plan)
            let paths = transactionPaths(plan)
            let current = try await fingerprintIfPresent(destination(plan))
            let previous = plan.expectedCurrentFingerprint
            if journal.phase == .preparing || journal.phase == .staged {
                guard current == previous, !SkillFilePrimitives.exists(paths.backup) else {
                    throw SkillOperationError.recovery
                }
                return await finish(journal, status: .cancelled)
            }
            if current == plan.fingerprint {
                let receipt = try await store.receipt(for: plan.entry.id)
                guard receipt == nil || receipt == plan.previousReceipt || receipt == plan.receipt else {
                    throw SkillOperationError.ownership
                }
                try writeReceipt(plan.receipt, entryID: plan.entry.id)
                try await store.commitContent(plan)
                return await finish(journal, status: .succeeded)
            }
            if let previous, current == previous, !SkillFilePrimitives.exists(paths.backup) {
                try await restorePrevious(plan)
                return await finish(journal, status: .cancelled)
            }
            if current == nil, let previous,
               try await fingerprintIfPresent(paths.backup) == previous {
                try FileManager.default.moveItem(at: paths.backup, to: destination(plan))
                try await restorePrevious(plan)
                return await finish(journal, status: .cancelled)
            }
            if current == nil, previous == nil, !SkillFilePrimitives.exists(paths.backup) {
                return await finish(journal, status: .cancelled)
            }
            throw SkillOperationError.recovery
        } catch {
            let outcome = result(plan, .needsRecovery, error)
            try? await saveResult(plan, outcome)
            return outcome
        }
    }

    /// 成功后仅清理本操作 stage，更新备份留给后续版本回退；journal 在元数据完成后删除。
    private func finish(
        _ journal: SkillContentJournal, status: SkillOperationStatus, error: (any Error)? = nil
    ) async -> SkillOperationResult {
        let plan = journal.plan
        do {
            if status == .succeeded { try await retainRollback(plan) }
            try cleanStage(plan)
            let outcome = result(plan, status, error)
            try await saveResult(plan, outcome)
            try FileManager.default.removeItem(at: journalDirectory(plan))
            return outcome
        } catch {
            let outcome = result(plan, .needsRecovery, error)
            try? await saveResult(plan, outcome)
            return outcome
        }
    }

    private func validate(_ plan: SkillContentOperationPlan) throws {
        guard SkillFrontmatter.isValidName(plan.entry.manifestName),
              plan.entry.managementKind == .managed,
              plan.revision.entryID == plan.entry.id,
              plan.revision.contentDigest == plan.fingerprint.digest,
              plan.previousEntry?.id == plan.previousReceipt?.entryID,
              plan.previousEntry == nil || plan.previousEntry?.id == plan.entry.id,
              plan.previousEntry == nil || plan.previousEntry?.manifestName == plan.entry.manifestName,
              plan.fingerprint.members.contains(where: { $0.path == "SKILL.md" && $0.kind == .file })
        else { throw SkillOperationError.planChanged }
        try validateLibraryPath(store.paths.managed)
        try validateLibraryPath(store.paths.entryDirectory(plan.entry.id))
        try validateLibraryPath(destination(plan).deletingLastPathComponent())
    }

    private func validateCurrent(_ plan: SkillContentOperationPlan) async throws {
        try validate(plan)
        let snapshot = try await store.snapshot()
        let current = snapshot.entries.first { $0.id == plan.entry.id }
        if let previous = plan.previousEntry, let receipt = plan.previousReceipt {
            guard current == previous, current?.managementKind == .managed,
                  try await store.receipt(for: plan.entry.id) == receipt else { throw SkillOperationError.ownership }
            guard try await fingerprintIfPresent(destination(plan)) == plan.expectedCurrentFingerprint else {
                throw SkillOperationError.localChanges
            }
        } else {
            guard current == nil, !SkillFilePrimitives.exists(destination(plan)) else { throw SkillOperationError.planChanged }
            guard !SkillFilePrimitives.exists(store.paths.entryDirectory(plan.entry.id).appendingPathComponent("receipt.json"))
            else { throw SkillOperationError.ownership }
        }
    }

    /// 私有库内的子目录不能变成外部链接；库根允许系统既有路径别名。
    private func validateLibraryPath(_ url: URL) throws {
        let root = store.paths.root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(root + "/"), !SkillFilePrimitives.isSymbolicLink(url) else {
            throw SkillOperationError.ownership
        }
    }

    private func ensureContentParent(_ plan: SkillContentOperationPlan) throws {
        try validate(plan)
        try FileManager.default.createDirectory(
            at: destination(plan).deletingLastPathComponent(), withIntermediateDirectories: true
        )
    }

    private func fingerprintIfPresent(_ url: URL) async throws -> SkillDirectoryFingerprint? {
        do { return try await SkillFilePrimitives.fingerprint(url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private func writeReceipt(_ receipt: SkillLibraryReceipt, entryID: UUID) throws {
        let folder = store.paths.entryDirectory(entryID)
        try validateLibraryPath(folder)
        let file = folder.appendingPathComponent("receipt.json")
        guard !SkillFilePrimitives.isSymbolicLink(file) else { throw SkillOperationError.ownership }
        try JSONEncoder().encode(receipt).write(to: file, options: .atomic)
    }

    private func restorePrevious(_ plan: SkillContentOperationPlan) async throws {
        guard let entry = plan.previousEntry, let receipt = plan.previousReceipt else { throw SkillOperationError.recovery }
        let existing = try await store.receipt(for: entry.id)
        guard existing == nil || existing == plan.receipt || existing == receipt else { throw SkillOperationError.ownership }
        try writeReceipt(receipt, entryID: entry.id)
        try await store.restoreEntry(entry)
    }

    private func write(_ journal: SkillContentJournal) throws {
        let directory = journalDirectory(journal.plan)
        try validateLibraryPath(store.paths.transactions)
        try validateLibraryPath(directory)
        let file = directory.appendingPathComponent("journal.json")
        guard !SkillFilePrimitives.isSymbolicLink(file) else { throw SkillOperationError.journal }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        guard data.count <= 8_388_608 else { throw SkillOperationError.journal }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    private func saveResult(_ plan: SkillContentOperationPlan, _ result: SkillOperationResult) async throws {
        var record = record(plan, state: result.status.rawValue)
        record.resultJSON = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        try await store.save(record)
    }

    private func record(_ plan: SkillContentOperationPlan, state: String) -> SkillOperationRecord {
        SkillOperationRecord(
            id: plan.id, entryID: plan.entry.id, kind: plan.kind, state: state,
            journalPath: journalDirectory(plan).appendingPathComponent("journal.json").path,
            createdAt: plan.createdAt
        )
    }

    private func result(
        _ plan: SkillContentOperationPlan, _ status: SkillOperationStatus, _ error: (any Error)? = nil
    ) -> SkillOperationResult {
        SkillOperationResult(id: plan.id, entryID: plan.entry.id, status: status, message: error?.localizedDescription)
    }

    private func destination(_ plan: SkillContentOperationPlan) -> URL {
        store.paths.entryDirectory(plan.entry.id).appendingPathComponent("content", isDirectory: true)
            .appendingPathComponent(plan.entry.manifestName, isDirectory: true)
    }

    private func transactionPaths(_ plan: SkillContentOperationPlan) -> SkillStagingPaths {
        SkillStagingPaths(parent: destination(plan).deletingLastPathComponent(), operationID: plan.id)
    }

    private func journalDirectory(_ plan: SkillContentOperationPlan) -> URL {
        store.paths.transactions.appendingPathComponent(plan.id.uuidString, isDirectory: true)
    }

    private func cleanStage(_ plan: SkillContentOperationPlan) throws {
        let paths = transactionPaths(plan)
        try validateLibraryPath(paths.stage)
        if SkillFilePrimitives.exists(paths.stage) { try FileManager.default.removeItem(at: paths.stage) }
    }

    /// 新内容及其备份已提交后才回收旧备份；journal 留存到新索引落盘，中断可重入。
    private func retainRollback(_ plan: SkillContentOperationPlan) async throws {
        guard let entry = plan.previousEntry, let receipt = plan.previousReceipt,
              let fingerprint = plan.expectedCurrentFingerprint else { return }
        let backup = transactionPaths(plan).backup
        guard try await fingerprintIfPresent(backup) == fingerprint else { throw SkillOperationError.recovery }
        let record = SkillRollbackRecord(
            operationID: plan.id, currentRevisionID: plan.revision.id,
            previousEntry: entry, previousReceipt: receipt, fingerprint: fingerprint
        )
        let file = rollbackFile(entry.id)
        try validateLibraryPath(file)
        if SkillFilePrimitives.exists(file) {
            let previous = try readRollback(entry.id)
            if previous.operationID != plan.id {
                let previousPath = backupPath(previous)
                try validateLibraryPath(previousPath)
                if let existing = try await fingerprintIfPresent(previousPath) {
                    guard existing == previous.fingerprint else { throw SkillOperationError.ownership }
                    try FileManager.default.removeItem(at: previousPath)
                }
            }
        }
        let bytes = try JSONEncoder().encode(record)
        guard bytes.count <= 8_388_608 else { throw SkillOperationError.journal }
        try bytes.write(to: file, options: .atomic)
    }

    private func readRollback(_ entryID: UUID) throws -> SkillRollbackRecord {
        let file = rollbackFile(entryID)
        try validateLibraryPath(file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 8_388_609) ?? Data()
        guard bytes.count <= 8_388_608 else { throw SkillOperationError.journal }
        let record = try JSONDecoder().decode(SkillRollbackRecord.self, from: bytes)
        guard record.formatVersion == 1, record.previousEntry.id == entryID,
              record.previousReceipt.entryID == entryID else { throw SkillOperationError.journal }
        return record
    }

    private func rollbackFile(_ entryID: UUID) -> URL {
        store.paths.entryDirectory(entryID).appendingPathComponent("rollback.json")
    }

    private func backupPath(_ record: SkillRollbackRecord) -> URL {
        store.paths.entryDirectory(record.previousEntry.id).appendingPathComponent("content")
            .appendingPathComponent(".starcat-backup-\(record.operationID.uuidString)")
    }
}
