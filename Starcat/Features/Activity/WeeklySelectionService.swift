//
//  WeeklySelectionService.swift
//  Starcat
//
//  Activity 页 weekly 分类与外围视图（Sidebar / HomeView detail pane）之间共享的
//  小型 UI 状态总线。
//
//  为什么不走 binding 链路：
//  - sidebar 上需要展示"周刊"分类右侧的项目总数（仿 manage Languages 计数徽章），
//    总数只有 WeeklyContentViewModel 跑完 API 才知道；
//  - HomeView 的右侧详情页需要根据当前 weekly 选中项渲染 WeeklyDetailView。
//  这两条信息都跨越了 SidebarView / RepoListView / ActivityView / HomeView 多层视图，
//  逐层 binding 改动面太大；改成单个 @Observable 服务，谁需要就 @Environment 取。
//
//  关键约束：
//  - 仅承载 UI 临时状态，不做持久化、不做网络请求；
//  - 主线程隔离（`@MainActor`），所有写入都来自 SwiftUI 视图层；
//  - 切换分类 / 退出 Activity 页时由调用方主动 `clearSelection()`，避免详情页停留陈旧数据。
//

import Foundation
import Observation

/// 周刊 UI 共享状态。
///
/// 字段说明见各 `private(set)` 的注释；写入入口故意限定在 `apply...` /
/// `clearSelection` 几个明确方法上，避免外部直接覆写造成"谁都能写"的失控。
@MainActor
@Observable
final class WeeklySelectionService {

    /// 周刊已 enrich 完成的项目总数；后端 API 的 `total` 字段。
    ///
    /// `nil` 表示"尚未拉取过"，sidebar 据此决定是否显示计数徽章。
    private(set) var total: Int?

    /// Activity 页 weekly 分类中当前选中的项目。
    ///
    /// nil → 详情页显示空态；非 nil → HomeView 详情区路由到 `WeeklyDetailView`。
    /// 用户切换非 weekly 分类、切走 Activity 页时，由调用方主动 `clearSelection`。
    private(set) var selectedProject: WeeklyProject?

    /// WeeklyContentViewModel 拉到分页结果后写一次 total。
    ///
    /// 不要在 sidebar 自己再发请求拉 total —— 详情列表既然要拉，复用即可，
    /// 一来省一次 API 调用，二来保证 sidebar 与列表数据口径一致。
    func applyTotal(_ value: Int) {
        total = value
    }

    /// 选中项目（点击行触发）。
    func select(_ project: WeeklyProject?) {
        selectedProject = project
    }

    /// 清空选中（切换分类、切走 Activity 页时调用）。
    func clearSelection() {
        selectedProject = nil
    }
}
