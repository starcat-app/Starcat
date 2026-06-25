//
//  ActivityCategoryCountService.swift
//  Starcat
//
//  Activity 分类与 Sidebar 之间共享的轻量计数状态。
//
//  设计约束：
//  - 本服务只保存其它对象已经拿到的计数结果，不主动读库、不发网络请求，避免
//    侧边栏徽章反过来拖慢 Activity 首屏。
//  - `.weekly` 的数据源仍是 Weekly API / bulk meta；这里仅接收最终 total，并把
//    它与本地分类计数合并成一个对 Sidebar 可见的快照，避免“周刊数字先跳出来”。
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

    /// Weekly total 虽然来自独立数据源，但 Sidebar 要求它和本地分类同批出现。
    private var weeklyTotal: Int?

    /// 首次进入 Activity 时，如果 weekly total 正在加载，就先不对外暴露本地 counts。
    ///
    /// 这个门闩只用于首批显示：避免 weekly 请求更快时先显示“周刊 2984”，也避免
    /// 本地聚合更快时先显示其它分类。请求成功或失败后都会放开；失败时本地分类照常
    /// 显示，weekly 行保持空白，不能让一个远端数字拖住整个 Sidebar。
    private var isWaitingForInitialWeeklyTotal = false

    /// 指定本地分类的计数。
    ///
    /// 未加载时返回 nil，已加载但该分类为空时返回 0。这样 UI 可以区分
    /// “还没算过”与“确实没有结果”，避免首次进入前显示一排误导性的 0。
    func count(for category: ActivityCategory) -> Int? {
        guard let localCounts else { return nil }
        guard !isWaitingForInitialWeeklyTotal else { return nil }
        if category == .weekly {
            return weeklyTotal
        }
        return localCounts[category] ?? 0
    }

    /// ActivityViewModel 发布新的 `allItems` 后写入完整分类计数。
    func applyLocalCounts(_ counts: [ActivityCategory: Int]) {
        localCounts = counts
    }

    /// ActivityView 开始拉取 weekly total 时调用。
    func beginWeeklyTotalLoad() {
        guard weeklyTotal == nil else { return }
        // 本地 counts 已经展示后，后台重试 weekly 不应把已有数字再清空造成闪烁。
        if localCounts == nil {
            isWaitingForInitialWeeklyTotal = true
        }
    }

    /// ActivityView / WeeklyContentView 拿到 weekly total 后调用。
    func applyWeeklyTotal(_ total: Int) {
        weeklyTotal = total
        isWaitingForInitialWeeklyTotal = false
    }

    /// Weekly total 拉取失败时放开本地分类显示，weekly 行继续保持空白。
    func finishWeeklyTotalLoadWithoutValue() {
        isWaitingForInitialWeeklyTotal = false
    }
}
