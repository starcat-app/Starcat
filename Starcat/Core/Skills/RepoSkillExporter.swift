//
//  RepoSkillExporter.swift
//  Starcat
//
//  仓库 Skill 导出共用 blob 下载与内容校验，不写安装 receipt，也不执行文件。
//

import Foundation

/// GUI 保存与公共接口共用临时产物；调用方取得成功结果后负责释放文件。
actor RepoSkillExporter {
    private let downloader: any RepoFileDownloading
    private let temporaryRoot: URL

    init(downloader: any RepoFileDownloading, temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.downloader = downloader
        self.temporaryRoot = temporaryRoot
    }

    /// 只接受扫描证据中的文件，按 blob SHA 下载，避免分支变化后保存另一版本。
    func export(
        file: RepoSkillFile, skill: RepoSkill, repo: Repo,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard skill.repositoryID == repo.id, skill.files.contains(file),
              RepoFileTreeBuilder.isSafeRelativePath(file.path),
              ["100644", "100755"].contains(file.mode) else { throw RepoSkillError.unsupportedFiles }
        try Task.checkCancellation()
        let manager = FileManager.default
        let stage = temporaryRoot.appendingPathComponent("starcat-skill-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: stage) }
        let downloaded = try await downloader.download(
            owner: repo.owner, repo: repo.name, sha: file.sha, relativePath: file.path,
            toRoot: stage, onProgress: onProgress
        )
        guard try await downloader.verifyDownloadedFile(
            owner: repo.owner, repo: repo.name, sha: file.sha, fileURL: downloaded
        ) else { throw RepoSkillError.verification }
        try Task.checkCancellation()
        try manager.setAttributes(
            [.posixPermissions: file.mode == "100755" ? 0o755 : 0o644], ofItemAtPath: downloaded.path
        )
        let artifact = temporaryRoot.appendingPathComponent("starcat-export-\(UUID())-\(file.name)")
        try manager.moveItem(at: downloaded, to: artifact)
        return artifact
    }

    /// 先在目标卷暂存，确认未取消后一次发布；覆盖失败保留原文件。
    func save(_ artifact: URL, to destination: URL) throws {
        let manager = FileManager.default
        let paths = SkillStagingPaths(parent: destination.deletingLastPathComponent())
        try manager.createDirectory(at: paths.stage, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: paths.stage) }
        try manager.copyItem(at: artifact, to: paths.payload)
        try Task.checkCancellation()
        let hadPrevious = try SkillFilePrimitives.publish(paths: paths, destination: destination, replacing: true)
        if hadPrevious { try? manager.removeItem(at: paths.backup) }
    }
}
