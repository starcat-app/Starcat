//
//  SkillImportPayloadCache.swift
//  Starcat
//
//  仅存活于一轮批量审核的已验证 blob 缓存。预览持有独立副本，
//  清理缓存不能使已批准计划失效，也不跨授权复用私有下载。
//

import Foundation

/// 批量准备按条目顺序调用；最多保留 64 MiB，结束准备后显式清理。
actor SkillImportPayloadCache {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("StarcatSkillBatch-\(UUID().uuidString)")
    private var files: [String: URL] = [:]
    private var retainedBytes = 0

    /// 每次复用仍校验 Git blob；复制完成才返回，调用方可安全结束缓存生命周期。
    func copy(
        file: GitHubGitTreeEntryDTO, selection: SkillGitHubSelection, authorizationID: String,
        downloader: any RepoFileDownloading, destination: URL
    ) async throws {
        try Task.checkCancellation()
        let key = [authorizationID, selection.locator, file.sha].joined(separator: "\u{0}")
        let directory = root.appendingPathComponent(UUID().uuidString)
        let downloaded: URL
        if let existing = files[key] { downloaded = existing }
        else {
            downloaded = try await downloader.download(
                owner: selection.owner, repo: selection.repository, sha: file.sha,
                relativePath: file.path, toRoot: directory
            )
            guard downloaded.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/")
            else { throw RepoSkillError.verification }
        }
        do {
            guard !SkillFilePrimitives.isSymbolicLink(downloaded),
                  try await downloader.verifyDownloadedFile(
                    owner: selection.owner, repo: selection.repository, sha: file.sha, fileURL: downloaded
                  ) else { throw RepoSkillError.verification }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: downloaded, to: destination)
            if files[key] == nil {
                let count = (try FileManager.default.attributesOfItem(atPath: downloaded.path)[.size] as? NSNumber)?.intValue ?? 0
                if retainedBytes + count <= 67_108_864 {
                    files[key] = downloaded
                    retainedBytes += count
                } else {
                    try FileManager.default.removeItem(at: directory)
                }
            }
        } catch {
            if files[key] == nil { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }

    func close() {
        try? FileManager.default.removeItem(at: root)
        files.removeAll()
        retainedBytes = 0
    }
}
