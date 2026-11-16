//
//  DailyRecommendationReason.swift
//  Starcat
//
//  将 ServingBundle 的已知理由转换为展示语义，避免泄露模型标识或虚构种子级关联。
//

import Foundation

/// 服务端只提供理由类型时，只解释该类型，不推断具体仓库、共同用户数或匹配百分比。
enum DailyRecommendationReason: Equatable {
    case coStar
    case collaborative
    case popularity
    case metadata
    case model
    case unspecified

    /// 当前服务会返回中文说明，历史缓存也可能带类型代码；未知内容不直接显示给用户。
    init(reasons: [String]) {
        self = .unspecified
        for reason in reasons {
            switch reason.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "costar", "time_decayed_costar", "基于公开 Star 共现关系":
                self = .coStar
            case "truncated_svd", "基于仓库协同相似度":
                self = .collaborative
            case "global_popularity", "基于公开 Star 热度":
                self = .popularity
            case "metadata_similarity":
                self = .metadata
            case "基于自研推荐模型":
                self = .model
            default:
                continue
            }
            return
        }
    }

    var localizationKey: String {
        switch self {
        case .coStar: "recommendations.daily.reasonCoStar"
        case .collaborative: "recommendations.daily.reasonCollaborative"
        case .popularity: "recommendations.daily.reasonPopularity"
        case .metadata: "recommendations.daily.reasonMetadata"
        case .model: "recommendations.daily.reasonModel"
        case .unspecified: "recommendations.daily.reason"
        }
    }

    /// 固定解释推荐机制，和项目简介分开，不把类型文案扩写成用户级推荐证据。
    var detailLocalizationKey: String {
        switch self {
        case .coStar: "recommendations.daily.reasonCoStarDetail"
        case .collaborative: "recommendations.daily.reasonCollaborativeDetail"
        case .popularity: "recommendations.daily.reasonPopularityDetail"
        case .metadata: "recommendations.daily.reasonMetadataDetail"
        case .model: "recommendations.daily.reasonModelDetail"
        case .unspecified: "recommendations.daily.reason"
        }
    }
}

extension RepoRecommendationItem {
    /// 基础依据只列真实来源；通用“模型筛选”没有个性化信息，不再当成详细理由。
    var basicRecommendationReason: String {
        let names = (matchedSeeds ?? []).map(\.fullName).filter { !$0.isEmpty }
        if !names.isEmpty {
            return String(format: String.l10n("recommendations.daily.basedOnStars"),
                          names.joined(separator: " · "))
        }
        let basis = DailyRecommendationReason(reasons: reasons)
        if basis == .model || basis == .unspecified {
            return String.l10n("recommendations.history.reasonUnavailable")
        }
        return String.l10n(basis.detailLocalizationKey)
    }
}

/// 将纯文本中的真实来源链接化；先转义 Markdown，不能让模型插入额外外链或远程图片。
enum RecommendationEvidenceMarkdown {
    static func make(text: String, sources: [RecommendationSeed]) -> String {
        let names = Array(Set(sources.map(\.fullName).filter {
            $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$"#,
                     options: .regularExpression) != nil
        })).sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
        guard !names.isEmpty else { return escape(text) }
        let pattern = #"(?<![A-Za-z0-9_./-])("#
            + names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            + #")(?![A-Za-z0-9_./-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return escape(text) }
        var result = ""
        var cursor = text.startIndex
        var mentioned = Set<String>()
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let name = String(text[range])
            result += escape(String(text[cursor..<range.lowerBound])) + link(name)
            mentioned.insert(name)
            cursor = range.upperBound
        }
        result += escape(String(text[cursor...]))
        // AI 未点名的来源仍可查看，但不再重复整句“基于你 Star 过的项目推荐”。
        let remaining = names.filter { !mentioned.contains($0) }
        if !remaining.isEmpty {
            result += "\n\n" + remaining.map(link).joined(separator: " · ")
        }
        return result
    }

    private static func link(_ name: String) -> String {
        "[\(name)](https://github.com/\(name))"
    }

    private static func escape(_ text: String) -> String {
        text.reduce(into: "") { result, character in
            if "\\`*_{}[]()#+-.!>|".contains(character) { result.append("\\") }
            result.append(character)
        }
    }
}
