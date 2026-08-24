//
//  AwesomeReadmeParser.swift
//  Starcat
//
//  使用 Apple swift-markdown 的 CommonMark/GFM AST 解析 Awesome README。
//
//  解析器只识别列表项中的公开 GitHub 仓库形态，保留当时的标题层级、原始描述和顺序；
//  外部链接只计数，不尝试猜测其背后的 GitHub 项目。Repo 是否真实公开由后续 GitHub API
//  核验，解析器本身不把 URL 文本当成可信元数据。
//

import Foundation
import Markdown

struct AwesomeRepositoryAddress: Hashable, Sendable {
    let owner: String
    let repo: String

    var fullName: String { "\(owner)/\(repo)" }
    var canonicalURL: URL { URL(string: "https://github.com/\(owner)/\(repo)")! }
}

enum AwesomeSourceInput {
    /// 接受 `owner/repo` 或 canonical GitHub 仓库 URL；子页面、非 HTTPS 和非 GitHub 域名拒绝。
    static func parse(_ raw: String) -> AwesomeRepositoryAddress? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            return address(pathComponents: trimmed.split(separator: "/").map(String.init))
        }
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? "")
        else { return nil }
        return address(pathComponents: url.path.split(separator: "/").map(String.init))
    }

    private static func address(pathComponents: [String]) -> AwesomeRepositoryAddress? {
        guard pathComponents.count == 2 else { return nil }
        let owner = pathComponents[0]
        let repo = pathComponents[1].hasSuffix(".git")
            ? String(pathComponents[1].dropLast(4))
            : pathComponents[1]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !owner.isEmpty, !repo.isEmpty,
              owner.unicodeScalars.allSatisfy(allowed.contains),
              repo.unicodeScalars.allSatisfy(allowed.contains),
              owner != ".", owner != "..", repo != ".", repo != ".."
        else { return nil }
        return AwesomeRepositoryAddress(owner: owner, repo: repo)
    }
}

struct ParsedAwesomeLink: Hashable, Sendable {
    let address: AwesomeRepositoryAddress
    let title: String
    let description: String?
    let sectionPath: [String]
    let order: Int
    let sourceAnchorURL: URL
}

struct AwesomeReadmeParseResult: Equatable, Sendable {
    let githubLinks: [ParsedAwesomeLink]
    let externalLinkCount: Int
}

enum AwesomeReadmeParser {
    static let maximumMarkdownBytes = 5 * 1024 * 1024
    static let maximumEntries = 2_000

    static func parse(
        markdown: String,
        source: AwesomeRepositoryAddress,
        defaultBranch: String,
        readmePath: String = "README.md"
    ) throws -> AwesomeReadmeParseResult {
        guard markdown.utf8.count <= maximumMarkdownBytes else {
            throw AwesomeCustomSourceError.readmeTooLarge
        }
        let document = Document(parsing: markdown, options: [.parseBlockDirectives])
        var walker = AwesomeWalker(
            source: source,
            defaultBranch: defaultBranch,
            readmePath: readmePath
        )
        walker.visit(document)
        return AwesomeReadmeParseResult(
            githubLinks: Array(walker.links.prefix(maximumEntries)),
            externalLinkCount: walker.externalLinkCount
        )
    }
}

private struct AwesomeWalker: MarkupWalker {
    let source: AwesomeRepositoryAddress
    let defaultBranch: String
    let readmePath: String
    var headings: [Int: String] = [:]
    var links: [ParsedAwesomeLink] = []
    var externalLinkCount = 0

    mutating func visitHeading(_ heading: Heading) {
        headings = headings.filter { $0.key < heading.level }
        let title = heading.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { headings[heading.level] = title }
        descendInto(heading)
    }

    mutating func visitListItem(_ listItem: ListItem) {
        let content = OwnListItemContent.collect(from: listItem)
        let sectionPath = headings.keys.sorted().compactMap { headings[$0] }
        var recordedGitHubLink = false

        for link in content.links {
            guard let destination = link.destination,
                  let url = URL(string: destination)
            else { continue }
            guard let address = AwesomeSourceInput.parse(url.absoluteString) else {
                if url.scheme == "https" || url.scheme == "http" { externalLinkCount += 1 }
                continue
            }
            // 一个 Awesome 列表项只代表一个项目。其余链接通常是文档、Demo 或重复镜像。
            guard !recordedGitHubLink else { continue }
            recordedGitHubLink = true
            let title = link.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = title.isEmpty ? address.fullName : title
            let description = Self.description(from: content.text, removing: displayTitle)
            links.append(
                ParsedAwesomeLink(
                    address: address,
                    title: displayTitle,
                    description: description,
                    sectionPath: sectionPath,
                    order: links.count,
                    sourceAnchorURL: sourceAnchorURL(sectionPath: sectionPath)
                )
            )
        }
        // 继续向下访问嵌套 ListItem；OwnListItemContent 会跳过它们，避免父项重复提取子项链接。
        descendInto(listItem)
    }

    private func sourceAnchorURL(sectionPath: [String]) -> URL {
        let base = "https://github.com/\(source.fullName)/blob/\(defaultBranch)/\(readmePath)"
        guard let heading = sectionPath.last else { return URL(string: base)! }
        return URL(string: "\(base)#\(Self.githubAnchor(heading))") ?? URL(string: base)!
    }

    private static func description(from text: String, removing title: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix(title.lowercased()) {
            value.removeFirst(min(title.count, value.count))
        }
        value = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "-–—:：")))
        return value.isEmpty ? nil : value
    }

    private static func githubAnchor(_ heading: String) -> String {
        var result = ""
        var previousWasHyphen = false
        for scalar in heading.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar.value > 127 {
                result.unicodeScalars.append(scalar)
                previousWasHyphen = false
            } else if scalar == " " || scalar == "-" {
                if !previousWasHyphen, !result.isEmpty { result.append("-") }
                previousWasHyphen = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

private struct OwnListItemContent {
    var links: [Link] = []
    var textParts: [String] = []

    var text: String { textParts.joined(separator: " ") }

    static func collect(from item: ListItem) -> OwnListItemContent {
        var result = OwnListItemContent()
        for child in item.children {
            collect(markup: child, into: &result, isRoot: false)
        }
        return result
    }

    private static func collect(markup: Markup, into result: inout OwnListItemContent, isRoot: Bool) {
        if !isRoot, markup is ListItem { return }
        if let link = markup as? Link {
            result.links.append(link)
        }
        if markup.childCount == 0,
           let plain = markup as? PlainTextConvertibleMarkup {
            let value = plain.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.textParts.append(value) }
        }
        for child in markup.children {
            collect(markup: child, into: &result, isRoot: false)
        }
    }
}
