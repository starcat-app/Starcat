//
//  AwesomeCustomSourceParseState.swift
//  Starcat
//
//  用户自定义 Awesome 来源的本地解析状态。
//
//  状态只存在当前账户数据库中，用于让来源卡片先出现、后台解析可恢复；它不会上传到
//  Discovery API，也不会混入远端精选来源的数据契约。
//

import Foundation

enum AwesomeCustomSourceParsePhase: String, Codable, Sendable {
    case queued
    case readingReadme = "reading_readme"
    case enrichingRepositories = "enriching_repositories"
    case completed
    case failed
}

struct AwesomeCustomSourceParseState: Equatable, Sendable {
    let sourceID: String
    let phase: AwesomeCustomSourceParsePhase
    let processedCount: Int
    let totalCount: Int?
    let errorMessage: String?
    let updatedAt: Date

    var isActive: Bool {
        switch phase {
        case .queued, .readingReadme, .enrichingRepositories:
            return true
        case .completed, .failed:
            return false
        }
    }

    var progress: Double? {
        guard phase == .enrichingRepositories,
              let totalCount,
              totalCount > 0
        else { return nil }
        return min(max(Double(processedCount) / Double(totalCount), 0), 1)
    }
}
