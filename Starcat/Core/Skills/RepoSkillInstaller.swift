//
//  RepoSkillInstaller.swift
//  Starcat
//
//  复用 blob 下载器，在目标卷暂存完整目录后一次发布。失败不暴露半成品、不执行内容。
//

import CryptoKit
import Foundation

/// 本机 receipt 与实际文件逐项核对；跨目标工具和路径独立，文件被修改后恢复为冲突。
actor RepoSkillInstaller {
    enum Existing: Equatable, Sendable { case missing, installed, conflict }

    private struct Receipt: Codable {
        let repositoryID: Int64
        let directory: String
        let commitSHA: String
        let files: [String: String]
    }

    private static let receiptName = ".starcat-install.json"
    private let downloader: any RepoFileDownloading

    init(downloader: any RepoFileDownloading) { self.downloader = downloader }

    /// “已安装”必须包含相同来源、提交和文件内容，不能只判断同名文件夹是否存在。
    func existing(_ skill: RepoSkill, destination: RepoSkillDestination) throws -> Existing {
        let folder = destination.url.appendingPathComponent(skill.name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) || isSymbolicLink(folder) else { return .missing }
        guard !isSymbolicLink(folder),
              let data = try? Data(contentsOf: folder.appendingPathComponent(Self.receiptName)),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.repositoryID == skill.repositoryID, receipt.directory == skill.directory,
              receipt.commitSHA == skill.commitSHA,
              Set(receipt.files.keys) == Set(skill.files.map(\.path)),
              try verifyFiles(at: folder, hashes: receipt.files, skill: skill)
        else { return .conflict }
        return .installed
    }

    /// 同名替换只在显式确认后发生，发布失败回滚旧目录。取消点只在事务发布之前。
    func install(
        _ skill: RepoSkill, repo: Repo, destination: RepoSkillDestination, replacing: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard skill.installationIssue == nil, !skill.files.isEmpty,
              SkillFrontmatter.isValidName(skill.name),
              skill.files.contains(where: { $0.path == "SKILL.md" }),
              skill.files.allSatisfy({ RepoFileTreeBuilder.isSafeRelativePath($0.path) && $0.path != Self.receiptName })
        else { throw RepoSkillError.unsupportedFiles }
        try Task.checkCancellation()
        let fm = FileManager.default
        let root = destination.url
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // 目标根目录允许工具自身使用软链接；真正发布位置以解析后的目录为准。
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let destination = resolvedRoot.appendingPathComponent(skill.name, isDirectory: true)
        let stage = resolvedRoot.appendingPathComponent(".starcat-stage-\(UUID().uuidString)", isDirectory: true)
        let backup = resolvedRoot.appendingPathComponent(".starcat-backup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let downloadRoot = stage.appendingPathComponent("download", isDirectory: true)
        let payload = stage.appendingPathComponent("payload", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        var hashes: [String: String] = [:]
        for (index, file) in skill.files.enumerated() {
            try Task.checkCancellation()
            let count = Double(skill.files.count)
            let url = try await downloader.download(
                owner: repo.owner, repo: repo.name, sha: file.sha, relativePath: file.path,
                toRoot: downloadRoot, onProgress: { fraction in
                    onProgress((Double(index) + fraction) / count)
                }
            )
            try Task.checkCancellation()
            let installedFile = payload.appendingPathComponent(file.path)
            try fm.createDirectory(at: installedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: url, to: installedFile)
            try fm.setAttributes([.posixPermissions: file.mode == "100755" ? 0o755 : 0o644], ofItemAtPath: installedFile.path)
            let bytes = try Data(contentsOf: installedFile, options: .mappedIfSafe)
            guard try await downloader.verifyDownloadedFile(
                owner: repo.owner, repo: repo.name, sha: file.sha, fileURL: installedFile
            ) else { throw RepoSkillError.verification }
            hashes[file.path] = Self.digest(bytes)
            onProgress(Double(index + 1) / count)
        }
        let receipt = Receipt(
            repositoryID: skill.repositoryID, directory: skill.directory, commitSHA: skill.commitSHA, files: hashes
        )
        try JSONEncoder().encode(receipt).write(to: payload.appendingPathComponent(Self.receiptName), options: .atomic)
        guard try verifyFiles(at: payload, hashes: hashes, skill: skill) else { throw RepoSkillError.verification }
        try Task.checkCancellation()
        let exists = fm.fileExists(atPath: destination.path) || isSymbolicLink(destination)
        guard !exists || replacing else { throw RepoSkillError.conflict }
        if exists { try fm.moveItem(at: destination, to: backup) }
        do {
            // 同卷 rename 发布；无 await，取消不能把已提交的目录误报为失败。
            try fm.moveItem(at: payload, to: destination)
        } catch {
            if exists { try fm.moveItem(at: backup, to: destination) }
            throw error
        }
        if exists { try? fm.removeItem(at: backup) }
    }

    private func verifyFiles(at directory: URL, hashes: [String: String], skill: RepoSkill) throws -> Bool {
        let fm = FileManager.default
        var enumerationFailed = false
        guard let enumerator = fm.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, _ in enumerationFailed = true; return false }
        ) else {
            return false
        }
        var actual: Set<String> = []
        let basePath = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { return false }
            if values.isRegularFile == true {
                // macOS 枚举 /tmp 时可能返回 /private/tmp；两端同样规范化后才能截相对路径。
                let absolutePath = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard absolutePath.hasPrefix(basePath) else { return false }
                let path = String(absolutePath.dropFirst(basePath.count))
                if path != Self.receiptName { actual.insert(path) }
            }
        }
        guard !enumerationFailed, actual == Set(hashes.keys) else { return false }
        for file in skill.files {
            let url = directory.appendingPathComponent(file.path)
            guard Self.digest(try Data(contentsOf: url, options: .mappedIfSafe)) == hashes[file.path] else { return false }
            let mode = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            if file.mode == "100755", (mode?.intValue ?? 0) & 0o111 == 0 { return false }
        }
        return true
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
