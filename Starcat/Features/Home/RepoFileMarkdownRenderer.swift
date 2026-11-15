//
//  RepoFileMarkdownRenderer.swift
//  Starcat
//
//  文件预览复用现有 MarkdownUI → ReadmeWebView 管线。
//  HTML 准备在独立 actor 完成；front matter 只改变预览，源码与下载仍保留原文。
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
            in: Self.renderHTML(text), owner: target.owner, repo: target.name,
            ref: commit, filePath: path
        )
        try Task.checkCancellation()
        let baseURL = URL(string: "https://github.com/\(target.owner)/\(target.name)/blob/\(commit)/")?
            .appendingPathComponent(path)
        return RepoFileMarkdownDocument(
            id: "\(target.fullName):\(commit):\(path):\(blobSHA)", html: html, baseURL: baseURL
        )
    }

    /// 只识别文件开头、在顶层闭合的元数据；正文中的分隔线与未闭合内容仍走原有 Markdown。
    private static func renderHTML(_ text: String) -> String {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.hasPrefix("\u{feff}") { normalized.removeFirst() }
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(where: {
                  let delimiter = $0.trimmingCharacters(in: .whitespaces)
                  return !$0.hasPrefix(" ") && !$0.hasPrefix("\t") && (delimiter == "---" || delimiter == "...")
              }),
              let metadata = metadataHTML(lines[1..<end])
        else { return MarkdownContent(text).renderHTML() }
        let body = lines.dropFirst(end + 1).joined(separator: "\n")
        return metadata + MarkdownContent(body).renderHTML()
    }

    /// 按顶层键分组，不将 YAML 当作 Markdown 或可执行对象；复杂值保留可读的缩进文本。
    private static func metadataHTML(_ lines: ArraySlice<String>) -> String? {
        var fields: [(key: String, lines: [String])] = []
        for line in lines {
            if line.hasPrefix("#") { continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !fields.isEmpty { fields[fields.count - 1].lines.append("") }
                continue
            }
            if line.hasPrefix(" ") || line.hasPrefix("\t") || line.hasPrefix("- ") {
                guard !fields.isEmpty else { return nil }
                fields[fields.count - 1].lines.append(line)
            } else if let colon = line.firstIndex(of: ":"),
                      colon != line.startIndex,
                      line.index(after: colon) == line.endIndex || line[line.index(after: colon)].isWhitespace {
                fields.append((String(line[..<colon]), [String(line[line.index(after: colon)...])]))
            } else {
                // 已确认是键值元数据但语法超出展示子集时，整体按 YAML 文本展示，不能丢字段。
                guard !fields.isEmpty else { return nil }
                return "<pre><code class=\"language-yaml\">\(escapeHTML(lines.joined(separator: "\n")))</code></pre>\n"
            }
        }
        guard !fields.isEmpty else { return "" }
        let rows = fields.map { field in
            """
            <tr><th scope="row" style="vertical-align: top; text-align: left;">\(escapeHTML(field.key))</th>\
            <td style="white-space: pre-wrap; overflow-wrap: anywhere;">\(escapeHTML(metadataValue(field.lines)))</td></tr>
            """
        }.joined(separator: "\n")
        // 复用阅读器的语义色表格样式，长描述允许换行，键值仍保留辅助功能的表头语义。
        return "<table class=\"starcat-front-matter\"><tbody>\(rows)</tbody></table>\n"
    }

    /// 仅解码常见字符串；折叠块保留段落与额外缩进，嵌套映射和列表不猜测为标量。
    private static func metadataValue(_ lines: [String]) -> String {
        let scalar = lines[0].trimmingCharacters(in: .whitespaces)
        let continuation = Array(lines.dropFirst())
        let indent = continuation.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
        let content = continuation.map { String($0.dropFirst(min(indent, $0.count))) }
        if (scalar.first == ">" || scalar.first == "|"),
           scalar.dropFirst().allSatisfy({ "+-123456789".contains($0) }) {
            var value = ""
            for (index, line) in content.enumerated() {
                if index > 0 {
                    let previous = content[index - 1]
                    let folds = scalar.first == ">" && !previous.isEmpty && !line.isEmpty
                        && !previous.hasPrefix(" ") && !line.hasPrefix(" ")
                    value += folds ? " " : "\n"
                }
                value += line
            }
            return value.trimmingCharacters(in: .newlines)
        }
        if scalar.isEmpty {
            return content.joined(separator: "\n").trimmingCharacters(in: .newlines)
        }
        let value = ([scalar] + content).map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), let data = value.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    /// 元数据来自仓库文件，只作为文本节点插入，不能变成标签或触发资源加载。
    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
