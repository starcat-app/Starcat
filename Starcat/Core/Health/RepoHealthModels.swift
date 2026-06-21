//
//  RepoHealthModels.swift
//  Starcat
//
//  Repo Health 评分 payload 与维度模型。
//
//  payload 会持久化到 repo_health_snapshots.payload_json，目的是让 UI 能解释
//  “为什么是这个分数”，而不是只展示一个无法追溯的数字。
//
//  v2（2026-06-21）：`evidence` / `missing` 英文字符串改为结构化 `facts[]`,
//  每条 fact 走 i18n key + 参数,维度卡可直接展示「子项标签 + 当前值」。
//

import Foundation

/// Repo Health 四个固定维度。
enum RepoHealthDimension: String, Codable, CaseIterable, Sendable {
    case maintenance
    case popularity
    case quality
    case security
}

/// 单条 fact 的语义色调 —— UI 用其决定值的 foregroundStyle。
enum RepoHealthFactTone: String, Codable, Sendable {
    case good
    case neutral
    case bad
    case missing
}

/// 单个维度的可展示 fact（标签 + 本地化值 + 色调）。
struct RepoHealthFact: Codable, Equatable, Sendable {
    var key: String
    var labelKey: String
    var valueKey: String
    var valueArgs: [String]
    var tone: RepoHealthFactTone
    /// 非 nil 时 UI 把值渲染为可点击外链（如 Homepage）。
    var linkURL: String?
}

/// 单个维度的评分与证据。
struct RepoHealthDimensionScore: Codable, Equatable, Sendable {
    var dimension: RepoHealthDimension
    var score: Double
    var summaryKey: String
    var facts: [RepoHealthFact]
}

/// Repo Health 持久化解释 payload。
struct RepoHealthPayload: Codable, Equatable, Sendable {
    var generatedAt: String
    var repoFullName: String
    var dimensions: [RepoHealthDimensionScore]
    var latestReleaseTag: String?
    var latestReleasePublishedAt: String?
    /// 2026-06-21 dong4j 反馈:Release 行加可点击链接,跳到 GitHub release 页面。
    /// Release 缺失时为 nil;UI 层据此决定该行是否可点。
    var latestReleaseUrl: String?
    var openSSFScore: Double?
    var notes: [String]
}
