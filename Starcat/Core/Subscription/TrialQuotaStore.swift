//
//  TrialQuotaStore.swift
//  Starcat
//
//  免费试用配额本地存储。
//

import Foundation

/// AI 试用配额类型。
///
/// v1 只给单仓 AI 摘要与 AI 标签推荐各 3 次试用；其它高成本能力直接 Pro only。
/// 按 GitHub User ID 分命名空间，是为了避免同一台 Mac 上多账号之间互相消耗配额。
enum TrialQuotaKind: String, CaseIterable, Sendable {
    case aiSummary
    case aiTags

    var limit: Int { 3 }
}

/// 本机免费试用配额存储。
///
/// 这不是防作弊系统，只是产品体验层的本地计数。v1 不引入服务端账号系统，因此不能
/// 阻止重装绕过；该决策已记录在 `docs/StoreKit订阅实施决策记录.md`。
struct TrialQuotaStore {
    private let defaults: UserDefaults
    private let keyPrefix = "subscription.trialQuota"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func usedCount(kind: TrialQuotaKind, userID: Int64?) -> Int {
        defaults.integer(forKey: key(kind: kind, userID: userID))
    }

    func remaining(kind: TrialQuotaKind, userID: Int64?) -> Int {
        max(0, kind.limit - usedCount(kind: kind, userID: userID))
    }

    /// 消耗一次试用配额。
    ///
    /// 返回 false 表示配额已耗尽；调用方负责弹付费墙或展示错误。
    @discardableResult
    func consume(kind: TrialQuotaKind, userID: Int64?) -> Bool {
        let current = usedCount(kind: kind, userID: userID)
        guard current < kind.limit else { return false }
        defaults.set(current + 1, forKey: key(kind: kind, userID: userID))
        return true
    }

    private func key(kind: TrialQuotaKind, userID: Int64?) -> String {
        let namespace = userID.map(String.init) ?? "_anonymous"
        return "\(keyPrefix).\(namespace).\(kind.rawValue)"
    }
}
