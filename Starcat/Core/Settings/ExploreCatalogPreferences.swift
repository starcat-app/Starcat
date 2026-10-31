//
//  ExploreCatalogPreferences.swift
//  Starcat
//
//  探索内容的长期偏好。只保存隐藏项，后端新增分类或来源默认可见；
//  语言与 Awesome 子来源继续由各自已有配置负责。
//

import Foundation

/// 导航和周刊查询共用的配置，不能把“全部来源”误解成绕过用户偏好。
struct ExploreCatalogPreferences: Codable, Equatable, Sendable {
    /// `linuxDo` 是 UI 分组；内部路由仍复用 discover 的 LinuxDo source。
    /// `dailyRadar` 是文章工作区，不映射到任何仓库 ExploreMode。
    static let groupIDs = ["dailyRadar", "discover", "trending", "popular", "newReleases", "weekly", "linuxDo", "awesome"]

    var hiddenModes: Set<String> = []
    var hiddenDiscoverTopics: Set<String> = []
    var hiddenDiscoverPlatforms: Set<String> = []
    var hiddenWeeklySources: Set<String> = []
    var hiddenDailyRadarCategories: Set<String> = []

    /// 损坏或来自未来版本的设置也必须留一个可进入的分类。
    var visibleGroupIDs: [String] {
        let visible = Self.groupIDs.filter { !hiddenModes.contains($0) }
        return visible.isEmpty ? ["discover"] : visible
    }

    func isGroupEnabled(_ id: String) -> Bool {
        visibleGroupIDs.contains(id)
    }

    /// 日报分类来自服务端 catalog；偏好只保存隐藏项，后端新增分类默认可见。
    func visibleDailyRadarCategories(_ categories: [DailyRadarCatalog.Category]) -> [DailyRadarCatalog.Category] {
        categories.filter { !hiddenDailyRadarCategories.contains($0.id) }
    }

    /// 多来源仓库只要属于任一启用来源就保留；不能因同时出现在隐藏来源而被误删。
    func includesWeeklyItem(_ item: WeeklyFeedItem) -> Bool {
        hiddenWeeklySources.isEmpty || item.sourceTypes.contains { !hiddenWeeklySources.contains($0.rawValue) }
    }

    /// 远端 API 使用逗号分隔的来源白名单；nil 保持无偏好时的完整目录语义。
    func weeklyQuerySources(availableCodes: [String]) -> [String]? {
        guard !hiddenWeeklySources.isEmpty else { return nil }
        return availableCodes.filter { !hiddenWeeklySources.contains($0) }.sorted()
    }
}
