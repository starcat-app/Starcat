//
//  ShareModels.swift
//  Starcat
//
//  分享相关的 DTO 模型。
//

import Foundation

struct ShareRepoRequest: Codable, Sendable {
    let repo: ShareRepoDTO
    let aiSummary: ShareAISummaryDTO
}

struct ShareRepoDTO: Codable, Sendable {
    let fullName: String
    let description: String?
    let language: String?
    let starsCount: Int
    let forksCount: Int
    let topics: [String]
    let homepage: String?
    let url: String
}

struct ShareTagDTO: Codable, Sendable {
    let name: String
    let confidence: Double?
}

struct ShareAISummaryDTO: Codable, Sendable {
    let oneLiner: String
    let summary: String
    let platforms: [String]
    let suitableFor: [String]
    let strengths: [String]
    let risks: [String]
    let suggestedTags: [ShareTagDTO]
}

struct ShareResponseDTO: Codable, Sendable {
    let shareUrl: String
    let expiresAt: String
}
