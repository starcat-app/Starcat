//
//  AIComposerModels.swift
//  Starcat
//
//  RAG 与 Agent Composer 可以共同使用的中性输入模型。
//

import Foundation

/// 用户显式仓库与查询结果之间的关系。
enum AIComposerExplicitRepoMode: String, Codable, CaseIterable, Hashable, Sendable {
    case only
    case prefer
    case exclude
}

/// Composer 只持有展示和快照需要的轻量仓库引用，不绑定 RAG 或 Agent ViewModel。
struct AIComposerRepoReference: Codable, Identifiable, Hashable, Sendable {
    var id: Int64
    var owner: String
    var name: String
    var fullName: String
    var language: String?
    var starsCount: Int
}

/// 从用户输入中识别出的 GitHub 仓库链接。
struct AIComposerGitHubLink: Codable, Identifiable, Hashable, Sendable {
    var id: String { url.absoluteString }
    var url: URL
    var owner: String
    var repository: String
}

enum AIComposerGitHubLinkDetector {
    /// 只识别 github.com/{owner}/{repo}，其它 GitHub 页面仍作为普通文本交给模型。
    static func links(in text: String) -> [AIComposerGitHubLink] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        return detector.matches(in: text, range: range).compactMap { result in
            guard let url = result.url,
                  url.host?.lowercased() == "github.com" else { return nil }
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.count >= 2 else { return nil }
            let owner = components[0]
            let repository = components[1].replacingOccurrences(of: ".git", with: "")
            let key = "\(owner.lowercased())/\(repository.lowercased())"
            guard seen.insert(key).inserted else { return nil }
            return AIComposerGitHubLink(url: url, owner: owner, repository: repository)
        }
    }
}
