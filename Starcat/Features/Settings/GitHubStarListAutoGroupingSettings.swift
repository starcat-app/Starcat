//
//  GitHubStarListAutoGroupingSettings.swift
//  Starcat
//
//  GitHub Lists 后台自动分组的独立偏好。
//
//  关键约束：仓库分组会写 GitHub 远端，而标签整理只写 Starcat 本地数据；两者不能
//  共用总开关、阈值或运行统计。老版本曾把这两个字段塞进 AutoTidySettings，本类型
//  只在首次读取新 key 时迁移一次，之后完全使用独立 UserDefaults JSON。
//

import Foundation

struct GitHubStarListAutoGroupingSettings: Codable, Equatable, Sendable {
    /// 后台自动分组全局开关；还必须同时满足 List 级授权和置信度阈值才会写 GitHub。
    var enabled: Bool
    /// 自动写入 GitHub Lists 的最低置信度。
    var confidenceThreshold: Double
    /// 下一轮后台扫描的仓库偏移。它是内部进度，不在设置 UI 暴露。
    ///
    /// 持久化后，应用重启也不会永远重复最近 50 个仓库；走完整库后调度器归零，
    /// 以便新建规则、规则修改和新 Star 在后续轮次重新获得判断机会。
    var nextCandidateOffset: Int

    static let `default` = GitHubStarListAutoGroupingSettings(
        enabled: false,
        confidenceThreshold: 0.90,
        nextCandidateOffset: 0
    )

    private enum CodingKeys: String, CodingKey {
        case enabled
        case confidenceThreshold
        case nextCandidateOffset
    }

    init(enabled: Bool, confidenceThreshold: Double, nextCandidateOffset: Int = 0) {
        self.enabled = enabled
        self.confidenceThreshold = Self.clamp(confidenceThreshold)
        self.nextCandidateOffset = max(0, nextCandidateOffset)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? false
        self.confidenceThreshold = Self.clamp(
            (try? container.decode(Double.self, forKey: .confidenceThreshold)) ?? 0.90
        )
        self.nextCandidateOffset = max(
            0,
            (try? container.decode(Int.self, forKey: .nextCandidateOffset)) ?? 0
        )
    }

    /// 从仍保存在旧 AutoTidy JSON 中的两个字段迁移；新 key 已存在时调用方不会走这里。
    static func migratedFromLegacyAutoTidyJSON(_ raw: String?) -> Self? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        struct Legacy: Decodable {
            let generateGitHubListGrouping: Bool?
            let githubListGroupingConfidenceThreshold: Double?
        }
        guard let legacy = try? JSONDecoder().decode(Legacy.self, from: data),
              legacy.generateGitHubListGrouping != nil
                || legacy.githubListGroupingConfidenceThreshold != nil
        else { return nil }
        return Self(
            enabled: legacy.generateGitHubListGrouping ?? false,
            confidenceThreshold: legacy.githubListGroupingConfidenceThreshold ?? 0.90
        )
    }

    static func clamp(_ value: Double) -> Double {
        min(max(value, 0.5), 1.0)
    }
}
