//
//  RepoRecommendationItem+ViewData.swift
//  Starcat
//
//  把推荐接口的 DTO（`RepoRecommendationItem`）转换为 `UnifiedRepoRow` 需要的
//  `RepoCardViewData` + 语义匹配度 `SemanticSearchHit`。
//
//  目的：让推荐 popover 内的卡片与主 repo 列表用同一份骨架渲染（Q4 决策），
//  视觉 100% 还原。转换层只承担数据适配，不引入新的 UI 组件。
//

import Foundation

extension RepoRecommendationItem {

    /// 构造 `UnifiedRepoRow` 期望的 `RepoCardViewData`。
    ///
    /// 字段映射策略：
    /// - `owner` / `repo` 从 `fullName` 用 "/" 拆出（推荐接口只给完整名）
    /// - `isStarred` = false（推荐场景不查 starred registry，避免增加不必要的 DB 读）
    /// - 所有「场景独有徽章」字段传 nil —— 推荐列表不是 trending / weekly / activity
    /// - `avatarURL` = nil —— 推荐接口不返回 owner 头像，由 UnifiedRepoRow 用 owner login 拼
    /// - `openSSFScore` / `healthBadge` = nil —— 详情页才查，列表行不查
    func asCardData() -> RepoCardViewData {
        let (owner, repoName) = Self.splitFullName(fullName)
        return RepoCardViewData(
            ghRepoId: repoID,
            fullName: fullName,
            owner: owner,
            repo: repoName,
            avatarURL: nil,
            description: description,
            language: language,
            starsCount: stars,
            forksCount: forks,
            isArchived: archived,
            isFork: false,
            isPrivate: false,
            isStarred: false,
            badge: nil,
            weeklySources: [],
            weeklySourceLabel: nil,
            inlineMetadata: nil,
            readStatus: nil,
            openSSFScore: nil,
            healthBadge: nil
        )
    }

    /// 构造 `SemanticSearchHit`，用于在 UnifiedRepoRow 的右簇渲染 SemanticScoreBadge。
    ///
    /// 直接调用 `SemanticScoreBadge(score:reason:)` 的扩展 init 即可（它内部会合成 hit），
    /// 这里是中间步骤保留：如果未来推荐需要在卡片上直接拿 hit 做排序 / 过滤，扩展点更直观。
    func asSemanticSearchHit() -> SemanticSearchHit {
        let clampedScore = max(0, min(1, score))
        let tier: Int
        switch clampedScore {
        case 0.85...: tier = 4
        case 0.65..<0.85: tier = 3
        case 0.45..<0.65: tier = 2
        default: tier = 1
        }
        let placeholderRepo = Repo(
            id: 0, owner: "", name: "", fullName: "",
            description: nil, language: nil,
            starsCount: 0, forksCount: 0, watchersCount: 0,
            topics: nil, license: nil, homepage: nil,
            htmlUrl: "", cloneUrl: nil, sshUrl: nil,
            isPrivate: false, isFork: false, isArchived: false, isStarred: false,
            pushedAt: nil, createdAt: nil, updatedAt: nil, starredAt: nil, cachedAt: nil
        )
        return SemanticSearchHit(
            repo: placeholderRepo,
            score: score,
            displayScore: clampedScore,
            tier: tier,
            reason: reasonText
        )
    }

    /// hover tooltip 文案：取 reasons[0]（后端给的最强推荐理由），为空则用通用文案。
    var reasonText: String {
        if let first = reasons.first, !first.isEmpty { return first }
        return "repo.recommendations.open"
    }

    /// 拆分 `owner/repo` 格式的 fullName。
    /// 后端不保证 fullName 一定有 `/`（异常情况），容错：取整段作为 owner，repo 留空。
    private static func splitFullName(_ fullName: String) -> (owner: String, repo: String) {
        if let slashIndex = fullName.firstIndex(of: "/") {
            let owner = String(fullName[..<slashIndex])
            let repo = String(fullName[fullName.index(after: slashIndex)...])
            return (owner, repo)
        }
        return (fullName, "")
    }
}
