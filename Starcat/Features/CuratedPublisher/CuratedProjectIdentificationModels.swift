//
//  CuratedProjectIdentificationModels.swift
//  Starcat
//
//  精选发布台 AI 甄别流程的领域模型。
//
//  关键约束：AI 只负责理解线索和判断证据，最终可发布仓库必须来自 GitHub 的
//  canonical 核验结果；“未找到”是合法业务结论，不能为了凑结果替换成第三方实现。
//

import Foundation

/// AI 对单条项目线索给出的最终判断。
enum CuratedProjectIdentificationStatus: String, Codable, Equatable, Sendable {
    case confirmed
    case needsReview = "needs_review"
    case notFound = "not_found"
}

/// 支撑项目归属判断的外部证据。
struct CuratedProjectEvidence: Identifiable, Equatable, Sendable {
    var id: String { url.absoluteString }

    let title: String
    let url: URL
    let snippet: String?
}

/// 一条原始线索经过 AI 拆分、联网检索和 GitHub 核验后的结果。
struct CuratedProjectFinding: Identifiable, Equatable, Sendable {
    let id: Int
    let originalText: String
    let title: String
    let sourceURL: URL?
    let status: CuratedProjectIdentificationStatus
    let reason: String
    let repository: RepositoryCandidate?
    let candidates: [RepositoryCandidate]
    let evidence: [CuratedProjectEvidence]

    var isPublishable: Bool {
        status == .confirmed && repository != nil
    }
}

/// 一次识别运行的完整输出；模型名用于 UI 明确披露本次判断由哪个模型完成。
struct CuratedProjectIdentification: Equatable, Sendable {
    let findings: [CuratedProjectFinding]
    let modelName: String

    var confirmedFindings: [CuratedProjectFinding] {
        findings.filter(\.isPublishable)
    }
}

/// UI 可展示的识别阶段。阶段状态属于识别域，不与 Weekly 连接/发布状态共用。
enum CuratedProjectIdentificationPhase: Equatable, Sendable {
    case idle
    case understanding
    case searching(completed: Int, total: Int)
    case judging
}
