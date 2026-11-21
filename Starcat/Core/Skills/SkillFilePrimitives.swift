//
//  SkillFilePrimitives.swift
//  Starcat
//
//  仓库安装与本机管理共用的文件事务基础。这里只处理调用方明确提供的路径，
//  渠道、所有权、用户确认和持久 journal 由各业务入口负责，不能从路径存在推断授权。
//

import CryptoKit
import Darwin
import Foundation

/// 内容身份包含文件集合、类型和权限，不使用 mtime 代替内容校验。
struct SkillFileFingerprint: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case file, directory }
    let path: String
    let kind: Kind
    let digest: String?
    let byteCount: Int64
    let mode: Int
}

/// 排序后的完整目录快照用于预检、暂存复核和本地修改保护。
struct SkillDirectoryFingerprint: Codable, Equatable, Sendable {
    let digest: String
    let rootMode: Int
    let members: [SkillFileFingerprint]
    var byteCount: Int64 { members.reduce(0) { $0 + $1.byteCount } }
}

/// stage 和 backup 必须与最终目标同父目录；不能把系统 /tmp 当作同卷发布区。
struct SkillStagingPaths: Sendable {
    let parent: URL
    let operationID: UUID
    var stage: URL { parent.appendingPathComponent(".starcat-stage-\(operationID.uuidString)", isDirectory: true) }
    var payload: URL { stage.appendingPathComponent("payload", isDirectory: true) }
    var backup: URL { parent.appendingPathComponent(".starcat-backup-\(operationID.uuidString)", isDirectory: true) }

    init(parent: URL, operationID: UUID = UUID()) {
        self.parent = parent.standardizedFileURL
        self.operationID = operationID
    }
}

/// rollback 失败必须保留可恢复现场，不能把它压缩成普通下载失败后清理。
enum SkillFileTransactionError: LocalizedError {
    case invalidBoundary, budgetExceeded, recoveryRequired(URL)

    var errorDescription: String? {
        switch self {
        case .invalidBoundary: RepoSkillError.unsupportedFiles.localizedDescription
        case .budgetExceeded: RepoSkillError.incomplete.localizedDescription
        case .recoveryRequired(let backup): "\(RepoSkillError.verification.localizedDescription)\n\(backup.path)"
        }
    }
}

/// 同步基础函数由安装 actor 或后台 worker 调用；publish 的短提交区间没有 await 和取消点。
enum SkillFilePrimitives {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || isSymbolicLink(url)
    }

    /// 文件系统按 `/` 字节分段，Swift 的 Character 会把附在斜杠后的组合字符视为同一字素。
    static func pathComponents(_ path: String) -> [String] {
        path.utf8.split(separator: 0x2F, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    }

    /// 共享根可能被其他工具同时写入；存在性预检不能替代内核的禁止覆盖语义。
    /// 不支持排他 rename 的卷直接失败，不能回退为会替换目标的普通 rename。
    static func moveExclusively(_ source: URL, to destination: URL) throws {
        guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    /// 有界流式 hash，不把大附件一次性映射进内存；空目录与执行位也参与整体指纹。
    @concurrent
    static func fingerprint(
        _ directory: URL, maximumEntries: Int = 5_000,
        maximumBytes: Int64 = 67_108_864, maximumDepth: Int = 16, requireUnlinkedFiles: Bool = false
    ) async throws -> SkillDirectoryFingerprint {
        try fingerprintSynchronously(
            directory, maximumEntries: maximumEntries,
            maximumBytes: maximumBytes, maximumDepth: maximumDepth, requireUnlinkedFiles: requireUnlinkedFiles
        )
    }

    /// NSFastEnumeration 的迭代器只能用于同步上下文，整个循环由上层后台入口调度。
    private static func fingerprintSynchronously(
        _ directory: URL, maximumEntries: Int, maximumBytes: Int64, maximumDepth: Int, requireUnlinkedFiles: Bool
    ) throws -> SkillDirectoryFingerprint {
        try Task.checkCancellation()
        let manager = FileManager.default
        let rootValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw RepoSkillError.unsupportedFiles
        }
        // 评估的来源已经验证为物理路径。再次解析可能跟随其后被替换的父目录。
        let root = requireUnlinkedFiles ? directory.standardizedFileURL : directory.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path + "/"
        let rootMode = try mode(at: root)
        var enumerationError: (any Error)?
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw RepoSkillError.incomplete }
        var members: [SkillFileFingerprint] = []
        var totalBytes: Int64 = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let absolutePath = url.standardizedFileURL.path
            guard absolutePath.utf8.starts(with: prefix.utf8) else { throw SkillFileTransactionError.invalidBoundary }
            let path = String(decoding: absolutePath.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
            guard members.count < maximumEntries, pathComponents(path).count <= maximumDepth else {
                throw SkillFileTransactionError.budgetExceeded
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw RepoSkillError.unsupportedFiles }
            let permissions = try mode(at: url)
            if values.isDirectory == true {
                members.append(.init(path: path, kind: .directory, digest: nil, byteCount: 0, mode: permissions))
            } else {
                guard values.isRegularFile == true else { throw RepoSkillError.unsupportedFiles }
                let handle = try requireUnlinkedFiles ? openRegularFile(in: root, relativePath: path) : FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let (count, digest) = try hashFile(handle, maximumBytes: maximumBytes - totalBytes)
                totalBytes += count
                members.append(.init(path: path, kind: .file, digest: digest, byteCount: count, mode: permissions))
            }
        }
        if let enumerationError { throw enumerationError }
        members.sort { $0.path < $1.path }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifest = try encoder.encode(members)
        let digest = digest(Data("\(rootMode)\n".utf8) + manifest)
        return SkillDirectoryFingerprint(digest: digest, rootMode: rootMode, members: members)
    }

    /// 评估会跨过进程和模型边界，因此每一段都由内核拒绝跟随链接。
    /// O_NONBLOCK 防止扫描后被替换为 FIFO 的文件卡住整个任务。
    private static func openRegularFile(in root: URL, relativePath: String) throws -> FileHandle {
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        guard root.path.hasPrefix("/") else { throw RepoSkillError.unsupportedFiles }
        var descriptor = open("/", flags | O_DIRECTORY)
        guard descriptor >= 0 else { throw RepoSkillError.unsupportedFiles }
        defer { close(descriptor) }
        let parts = pathComponents(root.path).dropFirst() + pathComponents(relativePath)
        guard !relativePath.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") })
        else { throw RepoSkillError.unsupportedFiles }
        for (index, part) in parts.enumerated() {
            let next = openat(descriptor, part, flags | (index == parts.count - 1 ? 0 : O_DIRECTORY))
            guard next >= 0 else { throw RepoSkillError.unsupportedFiles }
            close(descriptor)
            descriptor = next
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG, status.st_nlink == 1 else {
            throw RepoSkillError.unsupportedFiles
        }
        let copied = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard copied >= 0 else { throw RepoSkillError.unsupportedFiles }
        return FileHandle(fileDescriptor: copied, closeOnDealloc: true)
    }

    /// 快照文件排他创建，沿用静态检查所需的读写权限，去除 Git 或本机文件的执行位。
    static func createPrivateFile(at url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// 复制流的字节数和摘要必须匹配预检，防止把变化后的附件记在旧版本下。
    static func copyRegularFile(in root: URL, member: SkillFileFingerprint, to destination: URL) throws {
        let input = try openRegularFile(in: root, relativePath: member.path)
        defer { try? input.close() }
        let output = try createPrivateFile(at: destination)
        defer { try? output.close() }
        do {
            let (count, digest) = try hashFile(input, maximumBytes: member.byteCount, output: output)
            guard count == member.byteCount, digest == member.digest else { throw RepoSkillError.verification }
        } catch SkillFileTransactionError.budgetExceeded {
            throw RepoSkillError.verification
        }
    }

    /// 指纹与复制共用固定大小的缓冲区，达到预算后最多再读一字节以区分 EOF 和增长。
    private static func hashFile(
        _ input: FileHandle, maximumBytes: Int64, output: FileHandle? = nil
    ) throws -> (Int64, String) {
        guard maximumBytes >= 0 else { throw SkillFileTransactionError.budgetExceeded }
        var hash = SHA256()
        var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let remaining = maximumBytes - count
            let limit = Int(min(65_535, remaining)) + 1
            guard let chunk = try input.read(upToCount: limit), !chunk.isEmpty else { break }
            guard chunk.count <= remaining else { throw SkillFileTransactionError.budgetExceeded }
            count += Int64(chunk.count)
            hash.update(data: chunk)
            try output?.write(contentsOf: chunk)
        }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// copyItem 保留原目录，复制后按批准的完整指纹复核；变化或取消都停在发布之前。
    @concurrent
    static func stageCopy(
        from source: URL, expected: SkillDirectoryFingerprint, paths: SkillStagingPaths
    ) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: paths.stage, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: source, to: paths.payload)
        let actual = try await fingerprint(paths.payload)
        guard actual == expected else { throw RepoSkillError.verification }
        try Task.checkCancellation()
    }

    /// 返回是否产生旧版本备份。清理或保留 backup 由业务 journal 决定，此处不擅自删除。
    @discardableResult
    static func publish(
        paths: SkillStagingPaths, destination: URL, replacing: Bool,
        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws -> Bool {
        guard destination.deletingLastPathComponent().standardizedFileURL.path == paths.parent.path,
              !isSymbolicLink(paths.stage), !exists(paths.backup) else {
            throw SkillFileTransactionError.invalidBoundary
        }
        let hadPrevious = exists(destination)
        guard !hadPrevious || replacing else { throw RepoSkillError.conflict }
        if hadPrevious { try move(destination, paths.backup) }
        do {
            try move(paths.payload, destination)
        } catch {
            if hadPrevious {
                do { try move(paths.backup, destination) }
                catch { throw SkillFileTransactionError.recoveryRequired(paths.backup) }
            }
            throw error
        }
        return hadPrevious
    }

    private static func mode(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let mode = attributes[.posixPermissions] as? NSNumber else { throw RepoSkillError.incomplete }
        return mode.intValue & 0o777
    }
}
