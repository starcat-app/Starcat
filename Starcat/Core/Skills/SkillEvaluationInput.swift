//
//  SkillEvaluationInput.swift
//  Starcat
//
//  将可信的仓库证据或本机库 UUID 转换成评估快照。待评文件始终是数据，
//  运行器只收到本次操作新建的目录。
//

import Darwin
import Foundation

/// 公共调用和界面都从已有条目构造目标，调用方不传入任意本机路径。
enum SkillEvaluationTarget: Sendable {
    case repository(Repo, RepoSkill)
    case library(UUID)

    var identity: SkillEvaluationSubject {
        switch self {
        case .repository(let repo, let skill): .repository(repo.id, skill.directory)
        case .library(let id): .library(id)
        }
    }
}

/// 稳定身份用于回读旧报告；内容版本单独记录，目录更新后仍能展示上次结果。
enum SkillEvaluationSubject: Codable, Hashable, Sendable {
    case repository(Int64, String)
    case library(UUID)

    var sortKey: String {
        switch self {
        case .repository(let id, let directory): "repo:\(id):\(directory)"
        case .library(let id): "library:\(id.uuidString)"
        }
    }
}

/// 单个快照的内容版本和临时路径。只有完整复制并校验后才交给评估器。
struct SkillEvaluationInput: Sendable {
    let root: URL
    let version: String
    let name: String
}

/// 从已验证的仓库证据或本机库条目生成可交给评估器的完整副本。
struct SkillEvaluationSnapshotter: Sendable {
    static let maximumEntries = 5_000
    static let maximumBytes = RepoFileDownloader.maximumEvaluationBlobBytes
    static let maximumDepth = 16

    let store: SkillLibraryStore?
    let downloader: any RepoFileDownloading

    /// 直接使用 Git 树的固定 SHA。先验证完整性和预算，避免下载一半才发现不能检查。
    @concurrent
    func snapshot(_ target: SkillEvaluationTarget, under parent: URL) async throws -> SkillEvaluationInput {
        try Task.checkCancellation()
        switch target {
        case .repository(let repo, let skill):
            guard skill.repositoryID == repo.id, skill.evaluationSnapshotComplete == true else {
                throw RepoSkillError.incomplete
            }
            // Git 是带终止斜杠的目录证据；层深预算从 Skill 根开始计数。
            let sourcePath = String(decoding: skill.directory.utf8.dropLast(), as: UTF8.self)
            guard skill.directory.isEmpty || (skill.directory.utf8.last == 0x2F && Self.isSafePath(sourcePath, maximumDepth: .max)) else {
                throw RepoSkillError.unsupportedFiles
            }
            let (files, directories) = try Self.repositoryMembers(skill.files)
            let name = sourcePath.isEmpty ? repo.name : SkillFilePrimitives.pathComponents(sourcePath).last ?? repo.name
            return try await Self.makeSnapshot(named: name, displayName: skill.name, under: parent) { root in
                // 目录分别排他创建，避免大小写不敏感卷静默合并两个 Git 路径。
                for directory in directories {
                    try Self.createDirectory(root.appendingPathComponent(directory, isDirectory: true))
                }
                for (file, size) in files {
                    try Task.checkCancellation()
                    let bytes = try await downloader.evaluationBlob(owner: repo.owner, repo: repo.name, sha: file.sha, size: size)
                    guard bytes.count == size else { throw RepoSkillError.verification }
                    let output = try SkillFilePrimitives.createPrivateFile(at: root.appendingPathComponent(file.path))
                    defer { try? output.close() }
                    try output.write(contentsOf: bytes)
                }
                return skill.commitSHA
            }
        case .library(let id):
            let source = try await libraryRoot(id)
            return try await Self.makeSnapshot(named: source.root.lastPathComponent, displayName: source.name, under: parent) { root in
                try await Self.copyLocal(source.root, to: root).digest
            }
        }
    }

    /// 仓库回读不联网。本机只在有旧报告时重算当前内容，用同一套范围和内容身份。
    @concurrent
    func version(of target: SkillEvaluationTarget) async throws -> String {
        try Task.checkCancellation()
        switch target {
        case .repository(let repo, let skill):
            guard repo.id == skill.repositoryID else { throw RepoSkillError.incomplete }
            return skill.commitSHA
        case .library(let id):
            let source = try await libraryRoot(id)
            return try await Self.copyLocal(source.root, to: nil).digest
        }
    }

    private func libraryRoot(_ id: UUID) async throws -> (root: URL, name: String) {
        guard let store else { throw SkillContentReadError.unavailable }
        let library = try await store.snapshot()
        guard let entry = library.entries.first(where: { $0.id == id }) else {
            throw SkillContentReadError.unavailable
        }
        let root: URL
        if entry.managementKind == .managed {
            guard Self.isSafePath(entry.manifestName, maximumDepth: 1) else {
                throw SkillContentReadError.invalidPath
            }
            // 只打开已登记条目的正文目录。UUID 目录还含回执，不能进入评估输入。
            let library = store.paths.root.standardizedFileURL
            guard !SkillFilePrimitives.isSymbolicLink(library) else { throw SkillContentReadError.pathChanged }
            let physicalPaths = SkillLibraryPaths(root: library.resolvingSymlinksInPath().standardizedFileURL)
            root = physicalPaths.entryDirectory(id).appendingPathComponent("content", isDirectory: true)
                .appendingPathComponent(entry.manifestName, isDirectory: true)
        } else {
            let locations = library.locations.filter { $0.entryID == id && $0.scanState == .present }
            guard !locations.isEmpty else { throw SkillContentReadError.unavailable }
            let roots = Dictionary(uniqueKeysWithValues: library.roots.map { ($0.id, $0) })
            // 同一实体可以有多个入口。跳过失效入口，仍要求可验证的入口指向同一物理目录。
            let paths = Set(locations.compactMap { location in
                roots[location.rootID].flatMap { Self.discoveredPath(location, in: $0) }
            })
            guard paths.count == 1, let path = paths.first else {
                throw SkillContentReadError.pathChanged
            }
            root = URL(fileURLWithPath: path, isDirectory: true)
        }
        let canonical = root.standardizedFileURL
        guard canonical.path == canonical.resolvingSymlinksInPath().path else {
            throw SkillContentReadError.pathChanged
        }
        return (canonical, entry.manifestName)
    }

    /// 允许根本身就是 Skill，也允许仍指向根内原位置的发现入口。
    private static func discoveredPath(_ location: SkillLibraryLocation, in root: SkillLibraryRoot) -> String? {
        guard let resolvedRoot = root.resolvedPath,
              [root.configuredPath, resolvedRoot, location.lexicalPath, location.resolvedPath].allSatisfy({
                  $0.hasPrefix("/") && !$0.contains("\0")
              }) else { return nil }
        let configured = URL(fileURLWithPath: root.configuredPath, isDirectory: true).standardizedFileURL
        let lexical = URL(fileURLWithPath: location.lexicalPath, isDirectory: true).standardizedFileURL
        let physical = URL(fileURLWithPath: location.resolvedPath, isDirectory: true).standardizedFileURL
        guard lexical.path == location.lexicalPath, physical.path == location.resolvedPath,
              isWithin(lexical.path, root: configured.path), isWithin(physical.path, root: resolvedRoot),
              configured.resolvingSymlinksInPath().standardizedFileURL.path == resolvedRoot,
              lexical.resolvingSymlinksInPath().standardizedFileURL.path == physical.path else { return nil }
        return physical.path
    }

    private static func isWithin(_ path: String, root: String) -> Bool {
        path.utf8.elementsEqual(root.utf8) || path.utf8.starts(with: (root == "/" ? root : root + "/").utf8)
    }

    /// Git 树只保存 blob 文件清单，物化的隐式目录也按相同的成员预算计数。
    private static func repositoryMembers(_ members: [RepoSkillFile]) throws -> ([(RepoSkillFile, Int)], [String]) {
        guard members.count <= maximumEntries else { throw SkillFileTransactionError.budgetExceeded }
        var files: [(RepoSkillFile, Int)] = []
        // Git 按字节区分路径，不能让 Swift String 的 Unicode 等价规则提前合并目录。
        var paths: Set<Data> = []
        var directories: [Data: String] = [:]
        var remaining = maximumBytes
        for file in members {
            guard isSafePath(file.path), paths.insert(Data(file.path.utf8)).inserted,
                  ["100644", "100755"].contains(file.mode), let size = file.size, size >= 0 else {
                throw RepoSkillError.unsupportedFiles
            }
            var prefix = ""
            for component in SkillFilePrimitives.pathComponents(file.path).dropLast() {
                prefix += prefix.isEmpty ? component : "/\(component)"
                directories[Data(prefix.utf8)] = prefix
            }
            guard size <= remaining, members.count + directories.count <= maximumEntries else {
                throw SkillFileTransactionError.budgetExceeded
            }
            remaining -= size
            files.append((file, size))
        }
        guard paths.contains(Data("SKILL.md".utf8)), paths.isDisjoint(with: directories.keys) else {
            throw RepoSkillError.unsupportedFiles
        }
        return (files, directories.values.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
    }

    /// 调用方为每个条目传入独立父目录，快照保留原目录名供评估器核对。
    private static func makeSnapshot(
        named name: String, displayName: String, under parent: URL, populate: (URL) async throws -> String
    ) async throws -> SkillEvaluationInput {
        guard isSafePath(name, maximumDepth: 1) else { throw RepoSkillError.unsupportedFiles }
        let root = parent.appendingPathComponent(name, isDirectory: true)
        try createDirectory(root)
        do {
            let version = try await populate(root)
            try Task.checkCancellation()
            return SkillEvaluationInput(root: root, version: version, name: displayName)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    /// 复用完整目录预算；按已经读取的清单逐项复核字节，防止把读取期间的修改
    /// 同指纹一起发布。openat 拒绝中间目录和文件链接，避免误读出界附件。
    @concurrent
    private static func copyLocal(_ source: URL, to destination: URL?) async throws -> SkillDirectoryFingerprint {
        let fingerprint = try await SkillFilePrimitives.fingerprint(
            source, maximumEntries: maximumEntries, maximumBytes: Int64(maximumBytes), maximumDepth: maximumDepth,
            requireUnlinkedFiles: true
        )
        guard fingerprint.members.contains(where: { $0.path == "SKILL.md" && $0.kind == .file }),
              fingerprint.members.allSatisfy({ isSafePath($0.path) }) else {
            throw RepoSkillError.unsupportedFiles
        }
        guard let destination else { return fingerprint }
        for member in fingerprint.members {
            try Task.checkCancellation()
            let output = destination.appendingPathComponent(member.path)
            if member.kind == .directory {
                try createDirectory(output)
            } else {
                try SkillFilePrimitives.copyRegularFile(in: source, member: member, to: output)
            }
        }
        return fingerprint
    }

    private static func isSafePath(_ path: String, maximumDepth: Int = SkillEvaluationSnapshotter.maximumDepth) -> Bool {
        let components = SkillFilePrimitives.pathComponents(path)
        return !components.isEmpty && components.count <= maximumDepth && !path.contains("\0")
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func createDirectory(_ url: URL) throws {
        guard mkdir(url.path, 0o700) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}
