//
//  RepoFileMarkdownRenderer.swift
//  Starcat
//
//  文件预览复用现有 MarkdownUI → ReadmeWebView 管线。
//  HTML 准备在独立 actor 完成；原始文本仍由下载 VM 持有，不因切换模式重新请求。
//

import Foundation
import MarkdownUI

/// 文档身份包含仓库、树提交、路径和 blob，拒绝跨文件或跨版本的 WebKit 回调。
struct RepoFileMarkdownDocument: Equatable, Sendable {
    let id: String
    let html: String
    let baseURL: URL?
}

/// 一次只准备当前文件；取消后即使同步解析刚结束，也不能发布过时文档。
actor RepoFileMarkdownRenderer {
    static let shared = RepoFileMarkdownRenderer()

    static func supports(fileName: String) -> Bool {
        ["md", "markdown"].contains((fileName as NSString).pathExtension.lowercased())
    }

    func prepare(text: String, target: RepoFileBrowserTarget, commit: String,
                 path: String, blobSHA: String) throws -> RepoFileMarkdownDocument {
        try Task.checkCancellation()
        let html = ReadmeAssetURLRewriter.rewrite(
            in: MarkdownContent(text).renderHTML(), owner: target.owner, repo: target.name,
            ref: commit, filePath: path
        )
        try Task.checkCancellation()
        let baseURL = URL(string: "https://github.com/\(target.owner)/\(target.name)/blob/\(commit)/")?
            .appendingPathComponent(path)
        return RepoFileMarkdownDocument(
            id: "\(target.fullName):\(commit):\(path):\(blobSHA)", html: html, baseURL: baseURL
        )
    }
}
