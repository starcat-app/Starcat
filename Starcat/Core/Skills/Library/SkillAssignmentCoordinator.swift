//
//  SkillAssignmentCoordinator.swift
//  Starcat
//
//  只管理显式批准的自有 symlink，不改变外部目录、Agent 配置或原始导入内容。
//  整个异步操作排队；journal 覆盖链接发布／移除与 SQLite 之间的中断。
//

import Foundation

enum SkillAssignmentCheckpoint: Sendable { case beforeLink, afterLink, beforeMetadata }

/// 默认只开放有官方 symlink 证据的 Codex／Claude Code 用户根；其余工具继续只读发现。
actor SkillAssignmentCoordinator {
    nonisolated let store: SkillLibraryStore
    private let operations: SkillOperationCoordinator
    private let home: URL
    private let environment: [String: String]
    private let detectedPresets: Set<RepoSkillTargetPreset>?
    private let checkpoint: @Sendable (SkillAssignmentCheckpoint) throws -> Void

    init(
        store: SkillLibraryStore, operations: SkillOperationCoordinator? = nil,
        distributionGate: DistributionGate = DistributionGate(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        detectedPresets: Set<RepoSkillTargetPreset>? = nil,
        checkpoint: @escaping @Sendable (SkillAssignmentCheckpoint) throws -> Void = { _ in }
    ) throws {
        try distributionGate.requireDirect(.skillManagement)
        self.store = store
        self.operations = try operations ?? SkillOperationCoordinator(store: store, distributionGate: distributionGate)
        self.home = home
        self.environment = environment
        self.detectedPresets = detectedPresets
        self.checkpoint = checkpoint
    }

    /// 一个目标可能对应多个配置根；先按实际父目录合并，再展示共同影响。
    func targets() async throws -> [SkillAssignmentTarget] {
        let snapshot = try await store.snapshot()
        let detected: Set<RepoSkillTargetPreset>
        if let detectedPresets { detected = detectedPresets }
        else { detected = Set(await RepoSkillAgentCatalog.detect(home: home, environment: environment).map(\.preset)) }
        let approved = Set([RepoSkillTargetPreset.codex, .claudeCode].filter { detected.contains($0) }.map {
            $0.agent.directoryURL(home: home, environment: environment).standardizedFileURL.path
        })
        let roots = snapshot.roots.filter {
            $0.scope == .global && approved.contains($0.configuredPath) && !$0.agentIDs.isEmpty
        }
        return Dictionary(grouping: roots) {
            URL(fileURLWithPath: $0.configuredPath).resolvingSymlinksInPath().standardizedFileURL.path
        }.map { path, roots in
            SkillAssignmentTarget(
                configuredPaths: roots.map(\.configuredPath).sorted(), resolvedParent: path,
                agentIDs: Array(Set(roots.flatMap(\.agentIDs))).sorted()
            )
        }.sorted { $0.id < $1.id }
    }

    /// 初次分配只能选择受支持根；暂停／卸载还可处理原配置已离线的自有旧分配。
    func prepare(
        entryID: UUID, action: SkillAssignmentAction,
        targetID: String? = nil, assignmentID: UUID? = nil
    ) async throws -> SkillAssignmentPlan {
        let snapshot = try await store.snapshot()
        guard let entry = snapshot.entries.first(where: { $0.id == entryID }),
              entry.managementKind == .managed else { throw SkillOperationError.ownership }
        let previous: SkillAssignment?
        let target: SkillAssignmentTarget
        if let assignmentID {
            guard let found = snapshot.assignments.first(where: { $0.id == assignmentID && $0.entryID == entryID })
            else { throw SkillOperationError.planChanged }
            previous = found
            target = found.target
        } else {
            guard action == .assign,
                  let found = try await targets().first(where: { $0.id == targetID })
            else { throw SkillOperationError.planChanged }
            target = found
            let path = URL(fileURLWithPath: target.resolvedParent).appendingPathComponent(entry.manifestName).path
            previous = snapshot.assignments.first { $0.targetPath == path }
            guard previous == nil || previous?.entryID == entryID else { throw SkillOperationError.ownership }
        }
        let fingerprint: SkillDirectoryFingerprint?
        if action == .assign || action == .resume {
            fingerprint = try await SkillFilePrimitives.fingerprint(content(entry))
        } else { fingerprint = nil }
        let plan = SkillAssignmentPlan(
            action: action, entry: entry, target: target, previous: previous,
            fingerprint: fingerprint, assignmentID: previous?.id ?? UUID()
        )
        try await validate(plan)
        return plan
    }

    func execute(_ plan: SkillAssignmentPlan) async -> SkillOperationResult {
        _ = await operations.recover()
        _ = await recover()
        return await operations.exclusively { await self.perform(plan) }
    }

    /// 只处理分配 journal，内容事务与分配事务不会把对方的记录误判为损坏。
    func recover() async -> [SkillOperationResult] {
        await operations.exclusively { await self.recoverAll() }
    }

    /// desired state 与现场分开表达；扫描不能偷偷恢复用户或其他工具移除的链接。
    func observations(entryID: UUID) async throws -> [SkillAssignmentObservation] {
        try await store.snapshot().assignments.filter { $0.entryID == entryID }.map { assignment in
            let url = URL(fileURLWithPath: assignment.targetPath)
            let state: SkillAssignmentObservedState = if owns(assignment, at: url) { .linked }
                else if SkillFilePrimitives.exists(url) { .conflict }
                else if assignment.desiredState == .paused { .paused } else { .missing }
            return SkillAssignmentObservation(assignment: assignment, state: state)
        }.sorted { $0.assignment.targetPath < $1.assignment.targetPath }
    }

    private func perform(_ plan: SkillAssignmentPlan) async -> SkillOperationResult {
        var journal = SkillAssignmentJournal(plan: plan)
        var created = false
        do {
            try Task.checkCancellation()
            let records = try await store.operations()
            if let record = records.first(where: { $0.id == plan.id }) {
                return record.result ?? result(plan, .needsRecovery, SkillOperationError.recovery)
            }
            guard !records.contains(where: {
                $0.entryID == plan.entry.id && ["running", "needsRecovery"].contains($0.state)
            }) else { throw SkillOperationError.recovery }
            try await validate(plan)
            let destination = target(plan)
            if satisfies(plan) { return result(plan, .alreadySatisfied) }
            if plan.action == .assign || plan.action == .resume {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try validatePaths(plan)
                let staged = stage(plan)
                guard !SkillFilePrimitives.exists(staged) else { throw SkillOperationError.ownership }
                try FileManager.default.createSymbolicLink(atPath: staged.path, withDestinationPath: content(plan.entry).path)
                journal.stagedIdentity = try SkillLinkIdentity.read(staged)
                journal.assignment = SkillAssignment(
                    id: plan.assignmentID, entryID: plan.entry.id, target: plan.target,
                    targetPath: destination.path, contentPath: content(plan.entry).path,
                    desiredState: .active, linkIdentity: journal.stagedIdentity
                )
            } else if plan.action == .pause, var previous = plan.previous {
                previous.desiredState = .paused
                previous.linkIdentity = nil
                journal.assignment = previous
            }
            // 临时链接在 journal 前创建；写 journal 失败时仅清理本轮确切持有的链接。
            try write(journal)
            created = true
            try await store.save(record(journal, status: "running"))
            try await validate(plan)
            try Task.checkCancellation()
            try checkpoint(.beforeLink)
            journal.phase = .committing
            try write(journal)
            try commitLink(journal)
            try checkpoint(.afterLink)
            try checkpoint(.beforeMetadata)
            try await store.commitAssignment(journal)
            journal.phase = .metadataCommitted
            try write(journal)
            return await finish(journal, status: .succeeded)
        } catch {
            let committed = journal.phase != .prepared
            let status: SkillOperationStatus = if committed { .needsRecovery }
                else if error is CancellationError || Task.isCancelled { .cancelled }
                else if error is SkillOperationError { .conflict } else { .failed }
            if created { return await finish(journal, status: status, error: error, preserve: committed) }
            try? cleanStage(journal)
            return result(plan, status, error)
        }
    }

    private func validate(_ plan: SkillAssignmentPlan) async throws {
        try validatePaths(plan)
        let snapshot = try await store.snapshot()
        guard let entry = snapshot.entries.first(where: { $0.id == plan.entry.id }),
              entry.managementKind == .managed, entry.manifestName == plan.entry.manifestName,
              entry.currentRevisionID == plan.entry.currentRevisionID,
              snapshot.assignments.first(where: { $0.targetPath == target(plan).path }) == plan.previous
        else { throw SkillOperationError.planChanged }
        if plan.action == .assign || plan.action == .resume {
            guard let receipt = try await store.receipt(for: entry.id),
                  receipt.revisionID == entry.currentRevisionID,
                  try await SkillFilePrimitives.fingerprint(content(entry)) == plan.fingerprint else {
                throw SkillOperationError.planChanged
            }
            if plan.previous == nil {
                guard try await targets().contains(plan.target) else { throw SkillOperationError.planChanged }
            }
            guard !SkillFilePrimitives.exists(target(plan)) || owns(plan.previous, at: target(plan))
            else { throw SkillOperationError.ownership }
        } else {
            guard plan.previous != nil,
                  !SkillFilePrimitives.exists(target(plan)) || owns(plan.previous, at: target(plan))
            else { throw SkillOperationError.ownership }
        }
    }

    /// 保存的物理父目录不得换成新链接；原有配置根可以是指向此父目录的别名。
    private func validatePaths(_ plan: SkillAssignmentPlan) throws {
        let parent = URL(fileURLWithPath: plan.target.resolvedParent).standardizedFileURL
        let library = store.paths.root.resolvingSymlinksInPath().path
        let canonical = content(plan.entry)
        guard SkillFrontmatter.isValidName(plan.entry.manifestName),
              parent.path == plan.target.resolvedParent, parent.path != "/",
              parent.resolvingSymlinksInPath().path == parent.path,
              !parent.path.hasPrefix(library + "/"), parent.path != library,
              canonical.resolvingSymlinksInPath().path == canonical.standardizedFileURL.path,
              !SkillFilePrimitives.isSymbolicLink(canonical),
              !plan.target.configuredPaths.isEmpty,
              plan.target.configuredPaths.allSatisfy({
                  URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == parent.path
              })
        else { throw SkillOperationError.ownership }
        if let previous = plan.previous {
            guard previous.entryID == plan.entry.id, previous.target == plan.target,
                  previous.targetPath == target(plan).path, previous.contentPath == canonical.path,
                  previous.id == plan.assignmentID else { throw SkillOperationError.ownership }
        }
        if plan.target.agentIDs.contains(RepoSkillTargetPreset.claudeCode.rawValue),
           ["synced", "anthropic-skills"].contains(plan.entry.manifestName) {
            throw SkillOperationError.planChanged
        }
    }

    private func owns(_ assignment: SkillAssignment?, at url: URL) -> Bool {
        guard let assignment, let identity = assignment.linkIdentity,
              (try? SkillLinkIdentity.read(url)) == identity,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == assignment.contentPath
        else { return false }
        return true
    }

    private func satisfies(_ plan: SkillAssignmentPlan) -> Bool {
        switch plan.action {
        case .assign, .resume: plan.previous?.desiredState == .active && owns(plan.previous, at: target(plan))
        case .pause: plan.previous?.desiredState == .paused && !SkillFilePrimitives.exists(target(plan))
        case .uninstall: false
        }
    }

    /// 短提交区间不 await、不检查取消；removeItem 的对象必须仍是已证明自有的 symlink。
    private func commitLink(_ journal: SkillAssignmentJournal) throws {
        let plan = journal.plan
        try validatePaths(plan)
        try validateJournal(journal)
        let destination = target(plan)
        if plan.action == .assign || plan.action == .resume {
            if owns(journal.assignment, at: destination) { return }
            guard !SkillFilePrimitives.exists(destination),
                  owns(journal.assignment, at: stage(plan)) else { throw SkillOperationError.ownership }
            try SkillFilePrimitives.moveExclusively(stage(plan), to: destination)
        } else if SkillFilePrimitives.exists(destination) {
            guard owns(plan.previous, at: destination) else { throw SkillOperationError.ownership }
            try FileManager.default.removeItem(at: destination)
        }
    }

    private func recoverAll() async -> [SkillOperationResult] {
        var results: [SkillOperationResult] = []
        do {
            try validateJournalPath(store.paths.assignmentTransactions)
            let folders: [URL]
            do { folders = try FileManager.default.contentsOfDirectory(at: store.paths.assignmentTransactions, includingPropertiesForKeys: nil) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { folders = [] }
            var seen: Set<UUID> = []
            for folder in folders {
                guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
                seen.insert(id)
                do {
                    let file = folder.appendingPathComponent("journal.json")
                    try validateJournalPath(folder)
                    guard !SkillFilePrimitives.isSymbolicLink(file) else { throw SkillOperationError.journal }
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    let bytes = try handle.read(upToCount: 8_388_609) ?? Data()
                    guard bytes.count <= 8_388_608 else { throw SkillOperationError.journal }
                    let journal = try JSONDecoder().decode(SkillAssignmentJournal.self, from: bytes)
                    guard journal.formatVersion == 1, journal.plan.id == id else { throw SkillOperationError.journal }
                    try validatePaths(journal.plan)
                    try validateJournal(journal)
                    if journal.phase == .prepared {
                        results.append(await finish(journal, status: .cancelled))
                    } else {
                        try commitLink(journal)
                        try await store.commitAssignment(journal)
                        results.append(await finish(journal, status: .succeeded))
                    }
                } catch {
                    results.append(SkillOperationResult(id: id, entryID: nil, status: .needsRecovery, message: error.localizedDescription))
                }
            }
            for record in try await store.operations() where record.kind.hasPrefix("assignment.")
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
        _ journal: SkillAssignmentJournal, status: SkillOperationStatus,
        error: (any Error)? = nil, preserve: Bool = false
    ) async -> SkillOperationResult {
        do {
            let outcome = result(journal.plan, status, error)
            if !preserve { try cleanStage(journal) }
            var record = record(journal, status: status.rawValue)
            record.resultJSON = String(decoding: try JSONEncoder().encode(outcome), as: UTF8.self)
            try await store.save(record)
            if !preserve { try FileManager.default.removeItem(at: journalDirectory(journal.plan)) }
            return outcome
        } catch { return result(journal.plan, .needsRecovery, error) }
    }

    private func cleanStage(_ journal: SkillAssignmentJournal) throws {
        let staged = stage(journal.plan)
        if SkillFilePrimitives.exists(staged) {
            guard owns(journal.assignment, at: staged) else { throw SkillOperationError.ownership }
            try FileManager.default.removeItem(at: staged)
        }
    }

    private func write(_ journal: SkillAssignmentJournal) throws {
        let directory = journalDirectory(journal.plan)
        try validateJournalPath(store.paths.assignmentTransactions)
        try validateJournalPath(directory)
        let file = directory.appendingPathComponent("journal.json")
        guard !SkillFilePrimitives.isSymbolicLink(file) else { throw SkillOperationError.journal }
        let bytes = try JSONEncoder().encode(journal)
        guard bytes.count <= 8_388_608 else { throw SkillOperationError.journal }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: file, options: .atomic)
    }

    private func validateJournalPath(_ path: URL) throws {
        guard path.resolvingSymlinksInPath().path.hasPrefix(store.paths.root.resolvingSymlinksInPath().path + "/"),
              !SkillFilePrimitives.isSymbolicLink(path) else { throw SkillOperationError.journal }
    }

    /// 恢复记录中的新回执必须仍描述计划的同一条链接，不能只相信文件夹名和 operationID。
    private func validateJournal(_ journal: SkillAssignmentJournal) throws {
        let plan = journal.plan
        switch plan.action {
        case .assign, .resume:
            guard let assignment = journal.assignment,
                  assignment.id == plan.assignmentID, assignment.entryID == plan.entry.id,
                  assignment.target == plan.target, assignment.targetPath == target(plan).path,
                  assignment.contentPath == content(plan.entry).path, assignment.desiredState == .active,
                  assignment.linkIdentity != nil, assignment.linkIdentity == journal.stagedIdentity
            else { throw SkillOperationError.journal }
        case .pause:
            guard var expected = plan.previous else { throw SkillOperationError.journal }
            expected.desiredState = .paused
            expected.linkIdentity = nil
            guard journal.assignment == expected else { throw SkillOperationError.journal }
        case .uninstall:
            guard plan.previous != nil, journal.assignment == nil else { throw SkillOperationError.journal }
        }
    }

    private func content(_ entry: SkillLibraryEntry) -> URL {
        store.paths.root.resolvingSymlinksInPath().appendingPathComponent("managed")
            .appendingPathComponent(entry.id.uuidString).appendingPathComponent("content")
            .appendingPathComponent(entry.manifestName)
    }
    private func target(_ plan: SkillAssignmentPlan) -> URL {
        URL(fileURLWithPath: plan.target.resolvedParent).appendingPathComponent(plan.entry.manifestName)
    }
    private func stage(_ plan: SkillAssignmentPlan) -> URL {
        URL(fileURLWithPath: plan.target.resolvedParent).appendingPathComponent(".starcat-link-\(plan.id.uuidString)")
    }
    private func journalDirectory(_ plan: SkillAssignmentPlan) -> URL {
        store.paths.assignmentTransactions.appendingPathComponent(plan.id.uuidString)
    }
    private func record(_ journal: SkillAssignmentJournal, status: String) -> SkillOperationRecord {
        SkillOperationRecord(
            id: journal.plan.id, entryID: journal.plan.entry.id,
            kind: "assignment.\(journal.plan.action.rawValue)", state: status,
            journalPath: journalDirectory(journal.plan).appendingPathComponent("journal.json").path
        )
    }
    private func result(
        _ plan: SkillAssignmentPlan, _ status: SkillOperationStatus, _ error: (any Error)? = nil
    ) -> SkillOperationResult {
        SkillOperationResult(id: plan.id, entryID: plan.entry.id, status: status, message: error?.localizedDescription)
    }
}
