//
//  ActivityCategoryCountService.swift
//  Starcat
//
//  Activity 分类与 Sidebar 之间共享的轻量计数状态。
//
//  设计约束：
//  - 本服务只保存其它对象已经拿到的计数结果，不主动读库、不发网络请求，避免
//    侧边栏徽章反过来拖慢 Activity 首屏。
//  - Weekly 已迁移到 Explore,本服务只负责 Activity 本地聚合分类。
//

import Foundation
import Observation

/// Activity 分类计数总线。
///
/// Sidebar 与 ActivityViewModel 不是父子直接绑定关系；如果逐层传 binding，会把
/// HomeView / RepoListView / ActivityView 的入参继续扩大。这里沿用
/// `WeeklySelectionService` 的同款做法，把跨视图的临时 UI 状态收进一个
/// `@Observable` 服务，由 ViewModel / ActivityView 在已有结果发布时回写。
@MainActor
@Observable
final class ActivityCategoryCountService {

    /// nil 表示本地 Activity 聚合还没有完成过加载；sidebar 此时不显示占位 0。
    private(set) var localCounts: [ActivityCategory: Int]?

    /// 指定本地分类的计数。
    ///
    /// 未加载时返回 nil，已加载但该分类为空时返回 0。这样 UI 可以区分
    /// “还没算过”与“确实没有结果”，避免首次进入前显示一排误导性的 0。
    func count(for category: ActivityCategory) -> Int? {
        guard let localCounts else { return nil }
        return localCounts[category] ?? 0
    }

    /// ActivityViewModel 发布新的 `allItems` 后写入完整分类计数。
    func applyLocalCounts(_ counts: [ActivityCategory: Int]) {
        localCounts = counts
    }
}
