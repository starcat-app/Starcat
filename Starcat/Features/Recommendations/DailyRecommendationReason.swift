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
