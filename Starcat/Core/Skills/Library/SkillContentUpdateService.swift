//
//  SkillContentUpdateService.swift
//  Starcat
//
//  三方比较基于逐文件 SHA-256 与权限，不自动合并 YAML。
//  用户批准覆盖本地修改后仍冻结 L，确认期间再编辑会使事务拒绝。
//

import Foundation

struct SkillFileDifference: Identifiable, Sendable {
    enum Kind: String, Sendable { case added, removed, modified, permissions }
    let path: String
    let kind: Kind
    var id: String { path }
}

struct PreparedSkillUpdate: Sendable, Identifiable {
    let content: PreparedSkillImport
    let localFingerprint: SkillDirectoryFingerprint
    let localDifferences: [SkillFileDifference]
    let remoteDifferences: [SkillFileDifference]
    let baseManifest: String?
    let localManifest: String
    let remoteManifest: String
    let assignments: [SkillAssignment]
    var id: UUID { content.id }
    var hasLocalChanges: Bool { content.plan.previousReceipt?.fingerprint != localFingerprint }
    var isUnchanged: Bool { localFingerprint == content.plan.fingerprint }
}

/// 更新、回退和批量更新共用同一个审核与内容事务入口。
actor SkillContentUpdateService {
    private let store: SkillLibraryStore
    private let imports: SkillImportService
    private let operations: SkillOperationCoordinator

    init(
        store: SkillLibraryStore, imports: SkillImportService, operations: SkillOperationCoordinator,
        distributionGate: DistributionGate = DistributionGate()
    ) throws {
        try distributionGate.requireDirect(.skillManagement)
        self.store = store
        self.imports = imports
        self.operations = operations
    }

    func prepare(
        entryID: UUID, commit: String? = nil, payloadCache: SkillImportPayloadCache? = nil
    ) async throws -> PreparedSkillUpdate {
        let content = try await imports.prepareUpdate(entryID: entryID, commit: commit, payloadCache: payloadCache)
        do {
            let update = try await compare(content, fetchBaseline: true)
            try Task.checkCancellation()
            return update
        }
        catch { await imports.discard(content); throw error }
    }

    func prepareRollback(entryID: UUID) async throws -> PreparedSkillUpdate {
        let plan = try await operations.prepareRollback(entryID: entryID)
        return try await compare(
            PreparedSkillImport(plan: plan, temporaryRoot: nil, authorizationID: nil), fetchBaseline: false
        )
    }

    /// 明确确认前不能把 L 的指纹加入批准计划；默认仅允许 L 等于原始安装基线。
    func execute(_ update: PreparedSkillUpdate, replacingLocalChanges: Bool = false) async -> SkillOperationResult {
        guard !update.hasLocalChanges || replacingLocalChanges else {
            return SkillOperationResult(
                id: update.id, entryID: update.content.plan.entry.id, status: .conflict,
                message: SkillOperationError.localChanges.localizedDescription
            )
        }
        var plan = update.content.plan
        plan.approvedLocalFingerprint = update.localFingerprint
        let preview = PreparedSkillImport(
            plan: plan, temporaryRoot: update.content.temporaryRoot, authorizationID: update.content.authorizationID
        )
        return await imports.execute(preview)
    }

    /// 保留副本是一次单独确认的本地导入；失败时不继续执行远端覆盖。
    func saveLocalCopy(_ update: PreparedSkillUpdate) async -> SkillOperationResult {
        do {
            let original = localDirectory(update.content.plan.entry)
            guard try await SkillFilePrimitives.fingerprint(original) == update.localFingerprint
            else { throw SkillOperationError.planChanged }
            let copy = try await imports.prepareLocal(original)
            guard copy.plan.fingerprint == update.localFingerprint else {
                await imports.discard(copy)
                throw SkillOperationError.planChanged
            }
            return await imports.execute(copy)
        } catch {
            return SkillOperationResult(
                id: UUID(), entryID: update.content.plan.entry.id, status: .failed, message: error.localizedDescription
            )
        }
    }

    func discard(_ update: PreparedSkillUpdate) async { await imports.discard(update.content) }

    private func compare(_ content: PreparedSkillImport, fetchBaseline: Bool) async throws -> PreparedSkillUpdate {
        let plan = content.plan
        guard let baseline = plan.previousReceipt else { throw SkillOperationError.ownership }
        let local = localDirectory(plan.entry)
        let fingerprint = try await SkillFilePrimitives.fingerprint(local)
        let localBytes = try await SkillImportService.manifestBytes(local)
        let remoteBytes = try await SkillImportService.manifestBytes(URL(fileURLWithPath: plan.incomingDirectory))
        guard fingerprint.members.first(where: { $0.path == "SKILL.md" })?.digest == SkillFilePrimitives.digest(localBytes)
        else { throw SkillOperationError.planChanged }
        var baseManifest: String?
        if baseline.fingerprint.members.first(where: { $0.path == "SKILL.md" })?.digest == SkillFilePrimitives.digest(localBytes) {
            baseManifest = String(decoding: localBytes, as: UTF8.self)
        } else if fetchBaseline {
            let snapshot = try await store.snapshot()
            if let revision = snapshot.revisions.first(where: { $0.id == baseline.revisionID }),
               let commit = revision.upstreamCommit {
                let original = try await imports.prepareUpdate(entryID: plan.entry.id, commit: commit)
                do {
                    let bytes = try await SkillImportService.manifestBytes(URL(fileURLWithPath: original.plan.incomingDirectory))
                    guard baseline.fingerprint.members.first(where: { $0.path == "SKILL.md" })?.digest == SkillFilePrimitives.digest(bytes)
                    else { throw SkillOperationError.planChanged }
                    baseManifest = String(decoding: bytes, as: UTF8.self)
                    await imports.discard(original)
                } catch { await imports.discard(original); throw error }
            }
        }
        let snapshot = try await store.snapshot()
        return PreparedSkillUpdate(
            content: content, localFingerprint: fingerprint,
            localDifferences: Self.differences(baseline.fingerprint, fingerprint),
            remoteDifferences: Self.differences(baseline.fingerprint, plan.fingerprint),
            baseManifest: baseManifest, localManifest: String(decoding: localBytes, as: UTF8.self),
            remoteManifest: String(decoding: remoteBytes, as: UTF8.self),
            assignments: snapshot.assignments.filter { $0.entryID == plan.entry.id }
        )
    }

    private func localDirectory(_ entry: SkillLibraryEntry) -> URL {
        store.paths.entryDirectory(entry.id).appendingPathComponent("content").appendingPathComponent(entry.manifestName)
    }

    /// 文件集合、类型、内容与权限单独表达；根目录模式以 “.” 作为稳定差异路径。
    nonisolated static func differences(
        _ baseline: SkillDirectoryFingerprint, _ other: SkillDirectoryFingerprint
    ) -> [SkillFileDifference] {
        let old = Dictionary(uniqueKeysWithValues: baseline.members.map { ($0.path, $0) })
        let new = Dictionary(uniqueKeysWithValues: other.members.map { ($0.path, $0) })
        var result: [SkillFileDifference] = []
        if baseline.rootMode != other.rootMode { result.append(.init(path: ".", kind: .permissions)) }
        for path in Set(old.keys).union(new.keys).sorted() {
            let kind: SkillFileDifference.Kind?
            switch (old[path], new[path]) {
            case (nil, _): kind = .added
            case (_, nil): kind = .removed
            case (let before?, let after?):
                if before.kind != after.kind || before.digest != after.digest || before.byteCount != after.byteCount { kind = .modified }
                else if before.mode != after.mode { kind = .permissions }
                else { kind = nil }
            }
            if let kind { result.append(.init(path: path, kind: kind)) }
        }
        return result
    }
}
