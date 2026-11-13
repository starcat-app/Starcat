//
//  RepoSkillReadingCache.swift
//  Starcat
//
//  Skill 正文和文件分组的后台准备。只返回 Sendable 值，解析器与临时语法树不跨 actor。
//

import Foundation
import MarkdownUI

/// 阅读缓存属于单个窗口，关闭窗口或切换账号后随会话释放，不共享私有仓库正文。
actor RepoSkillReadingCache {
    struct Folder: Identifiable, Sendable {
        let id: String
        let files: [RepoSkillFile]
    }

    struct Document: Sendable {
        let skillID: String
        let html: String
        let baseURL: URL?
        let rootFiles: [RepoSkillFile]
        let folders: [Folder]
    }

    private var documents: [String: Document] = [:]
    private var recent: [String] = []

    /// 保留最近几份正文；超大单文仍可阅读，但不在切换后长期占用缓存。
    func prepare(_ skill: RepoSkill, imageBaseURL: URL?, contentBaseURL: URL? = nil) throws -> Document {
        try Task.checkCancellation()
        if let cached = documents[skill.id] {
            recent.removeAll { $0 == skill.id }
            recent.append(skill.id)
            return cached
        }
        let html = Self.resolveImages(MarkdownContent(skill.manifest).renderHTML(), baseURL: imageBaseURL)
        try Task.checkCancellation()
        let grouped = Dictionary(grouping: skill.files, by: \.folder)
        let document = Document(
            skillID: skill.id, html: html, baseURL: contentBaseURL, rootFiles: grouped["", default: []],
            folders: grouped.keys.filter { !$0.isEmpty }.sorted().map {
                Folder(id: $0, files: grouped[$0, default: []])
            }
        )
        if html.utf8.count < 1_000_000 {
            documents[skill.id] = document
            recent.append(skill.id)
            while recent.count > 4 { documents[recent.removeFirst()] = nil }
        }
        return document
    }

    /// HTML 由 MarkdownUI 生成，图片相对地址使用固定提交的 raw 目录，链接仍交给 WebView 的 blob 基址。
    private static func resolveImages(_ html: String, baseURL: URL?) -> String {
        guard let baseURL, let pattern = try? NSRegularExpression(pattern: #"<img\b[^>]*\bsrc="([^"]*)""#) else { return html }
        let source = html as NSString
        var result = html
        for match in pattern.matches(in: html, range: NSRange(location: 0, length: source.length)).reversed() {
            let relative = source.substring(with: match.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: relative, relativeTo: baseURL)?.absoluteURL,
                  URL(string: relative)?.scheme == nil,
                  let range = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(range, with: url.absoluteString.replacingOccurrences(of: "&", with: "&amp;"))
        }
        return result
    }
}
