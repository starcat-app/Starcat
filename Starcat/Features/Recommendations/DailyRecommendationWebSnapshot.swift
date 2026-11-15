//
//  DailyRecommendationWebSnapshot.swift
//  Starcat
//
//  每日发现的单向展示契约。只传递卡面需要的值，网页不持有账户凭据或候选池，
//  也不能用自行构造的仓库对象发起 Star、详情或屏蔽操作。
//

import Foundation

/// 完整快照适合最多十张卡；比较快照后再发送，避免本地保存触发重复网页更新。
struct DailyRecommendationWebSnapshot: Encodable, Equatable {
    struct Item: Encodable, Equatable {
        let id: String
        let fullName: String
        let description: String
        let language: String?
        let stars: Int
        let forks: Int
        let reason: String
        let reasonDetail: String
        let compactReason: Bool
        let revealed: Bool

        /// GitHub ID 按字符串过桥，避免 JavaScript Number 丢失 Int64 精度。
        init(_ item: RepoRecommendationItem, revealed: Bool, explanation: String? = nil) {
            id = String(item.repoID)
            fullName = item.fullName
            description = item.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            language = item.language?.trimmingCharacters(in: .whitespacesAndNewlines)
            stars = item.stars
            forks = item.forks
            let basis = DailyRecommendationReason(reasons: item.reasons)
            reason = explanation != nil ? String.l10n("recommendations.daily.aiReasonTitle")
                : String.l10n(basis.localizationKey)
            reasonDetail = explanation ?? item.basicRecommendationReason
            // 模型兜底和未知类型只有通用说明，不应占用暗示“详细个性化理由”的重型分区。
            compactReason = explanation == nil && (basis == .model || basis == .unspecified)
            self.revealed = revealed
        }
    }

    let context: String
    let items: [Item]
    let labels: [String: String]
    let date: String
    let locale: String
    let dark: Bool
    let reduceMotion: Bool
    let scale: Double
    let loading: Bool
    let busy: Bool
    let message: String?
    let emptyMessage: String
    let canRetry: Bool
    let canChangeBatch: Bool
    let canSetAutoShow: Bool
    let showsOnLaunch: Bool

    /// 账号、数据库或冻结批次改变后，旧页面的延迟点击不能作用于新批次。
    static func context(accountID: Int64?, revision: UInt64, state: DailyRecommendationState) -> String {
        "\(accountID ?? 0)|\(revision)|\(state.day)|\(state.generatedAt?.timeIntervalSince1970 ?? 0)|\(state.modelVersion)"
    }

    /// 文案在原生层查 Catalog；网页始终跟随应用语言，而非 WebKit 的系统语言。
    static var localizedLabels: [String: String] {
        let keys = [
            "title": "recommendations.daily.title",
            "subtitle": "recommendations.daily.reason",
            "reasonTitle": "recommendations.daily.reasonTitle",
            "noDescription": "recommendations.daily.noDescription",
            "star": "recommendations.daily.star",
            "details": "recommendations.daily.details",
            "dismiss": "recommendations.daily.dismiss",
            "next": "recommendations.daily.browseNext",
            "previous": "recommendations.daily.browsePrevious",
            "nextBatch": "recommendations.daily.nextBatch",
            "revealAll": "recommendations.daily.openAll",
            "done": "recommendations.daily.done",
            "loading": "recommendations.daily.loading",
            "retry": "recommendations.daily.retry",
            "autoShow": "recommendations.daily.autoShow"
        ]
        return keys.mapValues { String.l10n($0) }
    }
}

/// 网页只能引用当前原生快照中的 ID，不能提交任意仓库或直接访问网络服务。
enum DailyRecommendationWebAction: Equatable {
    case presented(Int64)
    case star(Int64)
    case details(Int64)
    case dismiss(Int64)
    case revealAll
    case nextBatch
    case retry
    case setAutoShow(Bool)
    case close

    init?(body: Any, context: String, allowedIDs: Set<Int64>) {
        guard let body = body as? [String: Any],
              body["context"] as? String == context,
              let type = body["type"] as? String else { return nil }
        switch type {
        case "presented", "star", "details", "dismiss":
            guard let rawID = body["id"] as? String,
                  let id = Int64(rawID), allowedIDs.contains(id) else { return nil }
            switch type {
            case "presented": self = .presented(id)
            case "star": self = .star(id)
            case "details": self = .details(id)
            default: self = .dismiss(id)
            }
        case "revealAll": self = .revealAll
        case "nextBatch": self = .nextBatch
        case "retry": self = .retry
        case "autoShow":
            guard let value = body["value"] as? Bool else { return nil }
            self = .setAutoShow(value)
        case "close": self = .close
        default: return nil
        }
    }
}
