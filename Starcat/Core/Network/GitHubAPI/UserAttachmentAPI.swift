//
//  UserAttachmentAPI.swift
//  Starcat
//
//  GitHub Issue / PR 评论粘贴图片：把剪贴板 PNG 传到 uploads.github.com，
//  拿回 `https://github.com/user-attachments/assets/<uuid>`。
//
//  关键约束：
//  - 官方 REST 没有这个端点；本实现按 2026-08 社区验证过的 Bearer token 通道来。
//  - 必须带 `repository_id`。公开仓现有 `public_repo` 已实测 201；私仓没 `repo` 会 404。
//  - 评论发出去仍走 `createNotificationIssueComment`，这里只负责换 URL。
//

import Foundation

extension GitHubAPIClient {
    func uploadUserAttachment(
        fileName: String,
        contentType: String,
        repositoryID: Int64,
        data: Data
    ) async throws -> URL {
        guard !data.isEmpty else { throw GitHubUserAttachmentError.emptyImage }
        guard data.count <= GitHubUserAttachment.maxBytes else {
            throw GitHubUserAttachmentError.imageTooLarge
        }
        guard let url = GitHubUserAttachment.makeUploadURL(
            fileName: fileName,
            contentType: contentType,
            repositoryID: repositoryID
        ) else {
            throw NetworkError.invalidURL
        }
        let response = try await postBytes(
            to: url,
            accept: "application/json",
            contentType: "application/octet-stream",
            body: data
        )
        return try GitHubUserAttachment.parseAssetURL(from: response.data)
    }
}
