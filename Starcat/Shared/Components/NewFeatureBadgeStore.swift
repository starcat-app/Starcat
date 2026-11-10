//
//  NewFeatureBadgeStore.swift
//  Starcat
//
//  新功能首次点击状态的共享持久化容器。
//

import Foundation
import Observation

/// 记录“用户已首次点击过哪些新功能入口”。
///
/// 标识按功能版本独立存储：本版本未点击时展示，点击后立即隐藏并写入 UserDefaults。
/// 之后如果某个功能值得再次提醒，必须显式新增新的 feature rawValue，不能随 App 升级重置旧值。
@MainActor
@Observable
final class NewFeatureBadgeStore {

    enum Feature: String, CaseIterable {
        case followersGraph = "followers-graph.v1"
        case followingGraph = "following-graph.v1"
        case dailyRadar = "daily-radar.v1"
        case linuxDo = "linux-do.v1"
    }

    private let defaults: UserDefaults
    private var visitedFeatures: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 只读取已知 feature，避免历史残留 key 影响内存集合；未记录的 key 默认尚未点击。
        self.visitedFeatures = Set(
            Feature.allCases
                .filter { defaults.bool(forKey: Self.key(for: $0)) }
                .map(\.rawValue)
        )
    }

    func shouldShowBadge(for feature: Feature) -> Bool {
        !visitedFeatures.contains(feature.rawValue)
    }

    func markVisited(_ feature: Feature) {
        guard visitedFeatures.insert(feature.rawValue).inserted else { return }
        defaults.set(true, forKey: Self.key(for: feature))
    }

    private static func key(for feature: Feature) -> String {
        "NewFeatureBadge.visited.\(feature.rawValue)"
    }
}
