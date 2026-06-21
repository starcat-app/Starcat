//
//  SmartCollectionTagMatchMode.swift
//  Starcat
//
//  用户智能集合标签匹配模式：任一 / 全部。
//

import Foundation

/// 规则内多标签匹配方式（仅作用于 `selectedTagIDs`）。
enum SmartCollectionTagMatchMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case any
    case all

    var id: String { rawValue }

    var summaryKey: String {
        switch self {
        case .any: return "smartCollections.rule.tagsAnyFormat"
        case .all: return "smartCollections.rule.tagsAllFormat"
        }
    }
}
