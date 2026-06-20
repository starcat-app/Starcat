//
//  RepoHealthModels.swift
//  Starcat
//
//  Repo Health 评分 payload 与维度模型。
//
//  payload 会持久化到 repo_health_snapshots.payload_json，目的是让 UI 能解释
//  “为什么是这个分数”，而不是只展示一个无法追溯的数字。
//

import Foundation

/// Repo Health 四个固定维度。
enum RepoHealthDimension: String, Codable, CaseIterable, Sendable {
    case maintenance
    case popularity
    case quality
    case security
}

/// 单个维度的评分与证据。
struct RepoHealthDimensionScore: Codable, Equatable, Sendable {
    var dimension: RepoHealthDimension
    var score: Double
    var summaryKey: String
    var evidence: [String]
    var missing: [String]
}

/// Repo Health 持久化解释 payload。
struct RepoHealthPayload: Codable, Equatable, Sendable {
    var generatedAt: String
    var repoFullName: String
    var dimensions: [RepoHealthDimensionScore]
    var latestReleaseTag: String?
    var latestReleasePublishedAt: String?
    var openSSFScore: Double?
    var notes: [String]
}

