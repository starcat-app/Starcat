//
//  RepoSkillPageBudget.swift
//  Starcat
//
//  空命中页补取预算跨 SwiftUI task 重建保留，防止每来一页就重新获得无限预算。
//

import Foundation

struct RepoSkillPageBudget {
    private var scope = ""
    private(set) var consumed = 0

    /// 来源或筛选变化重置，当前范围最多主动补 20 页；正常滚动分页仍由原策略承担。
    mutating func claim(scope newScope: String) -> Bool {
        if scope != newScope { scope = newScope; consumed = 0 }
        guard consumed < 20 else { return false }
        consumed += 1
        return true
    }
}
