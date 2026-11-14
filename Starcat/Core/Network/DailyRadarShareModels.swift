//
//  DailyRadarShareModels.swift
//  Starcat
//
//  每日热点公开快照的上传白名单。只从固定 revision 的报告 DTO 取值，
//  不读取本地 Repo、Stars 状态、笔记、账号或任何凭据。
//

import Foundation

/// 与 sharing-api 独立日报端点对应；显式 CodingKeys 保持既有 snake_case 契约。
struct DailyRadarShareRequest: Encodable, Sendable {
    struct Report: Encodable, Sendable {
        let id: String
        let date: String
        let categoryID: String
        let language: String
        let revision: String
        let title: String
        let subtitle: String
        let summary: String
        let readingMinutes: Int
        let markdown: String
        let sources: [Source]

        enum CodingKeys: String, CodingKey {
            case id, date, language, revision, title, subtitle, summary, markdown, sources
            case categoryID = "category_id", readingMinutes = "reading_minutes"
        }
    }

    struct Source: Encodable, Sendable {
        let title: String
        let url: String
    }

    struct Project: Encodable, Sendable {
        let owner: String
        let repo: String
        let name: String
        let description: String
        let language: String
        let stars: Int
        let avatarURL: String

        enum CodingKeys: String, CodingKey {
            case owner, repo, name, description, language, stars
            case avatarURL = "avatar_url"
        }
    }

    let report: Report
    let projects: [Project]

    /// 正文与 metadata 必须来自同一个详情响应；禁止用列表摘要拼出可公开的半份报告。
    init(detail: DailyRadarReport) throws {
        guard let markdown = detail.presentationMarkdown,
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !detail.id.isEmpty, !detail.revision.isEmpty, !detail.contentLanguage.isEmpty,
              !detail.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw DailyRadarShareError.reportUnavailable }
        guard markdown.utf8.count <= 1_048_576 else { throw DailyRadarShareError.tooLarge }
        let article = DailyRadarArticle.parse(markdown)
        report = Report(
            id: detail.id, date: detail.editionDate, categoryID: detail.category,
            language: detail.contentLanguage, revision: detail.revision,
            title: article?.title ?? detail.title, subtitle: "",
            summary: article?.summary ?? detail.summary,
            readingMinutes: article?.readingMinutes ?? detail.readingMinutes,
            markdown: article?.body ?? markdown,
            sources: detail.source.map { [Source(title: $0.name, url: $0.url.absoluteString)] } ?? []
        )
        // 分享只携带报告自身的公开仓库快照；私有 DTO 即使异常出现在报告里也不会上传。
        projects = (detail.relatedProjects ?? []).filter { !$0.repo.isPrivate }.map {
            Project(
                owner: $0.repo.owner, repo: $0.repo.repo, name: $0.repo.repo,
                description: $0.repo.description ?? "", language: $0.repo.language ?? "",
                stars: $0.repo.stars, avatarURL: $0.repo.ownerAvatar?.absoluteString ?? ""
            )
        }
    }
}

/// 只缓存公开 URL 与创建时间；不把报告正文或凭据写入分享缓存。
struct DailyRadarShareResponse: Codable, Sendable, Equatable {
    let shareID: String
    let shareURL: URL
    let alreadyExists: Bool
    let heroWebPURL: URL
    let heroPNGURL: URL
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case shareID = "share_id", shareURL = "share_url", alreadyExists = "already_exists"
        case heroWebPURL = "hero_webp_url", heroPNGURL = "hero_png_url", createdAt = "created_at"
    }

    /// 自托管允许 HTTP；系统分享与浏览器入口始终拒绝非网页 scheme 和嵌入凭据。
    func validated() throws -> Self {
        guard !shareID.isEmpty, [shareURL, heroWebPURL, heroPNGURL].allSatisfy({
            ["http", "https"].contains($0.scheme?.lowercased() ?? "") &&
                $0.host?.isEmpty == false && $0.user == nil && $0.password == nil
        }) else { throw DailyRadarShareError.unavailable }
        return self
    }
}

/// UI 只展示可恢复的本地化错误，不把服务端 message、传输细节或本机路径给读者。
enum DailyRadarShareError: Error, Equatable {
    case reportUnavailable
    case coverFailed
    case configuration
    case conflict
    case tooLarge
    case rateLimited
    case unavailable

    var localizationKey: String {
        switch self {
        case .reportUnavailable: "dailyRadar.share.unavailable"
        case .coverFailed: "dailyRadar.share.error.cover"
        case .configuration: "dailyRadar.share.error.configuration"
        case .conflict: "dailyRadar.share.error.conflict"
        case .tooLarge: "dailyRadar.share.error.size"
        case .rateLimited: "dailyRadar.share.error.rateLimit"
        case .unavailable: "dailyRadar.share.error.unavailable"
        }
    }

    /// 映射稳定 HTTP 状态；底层错误的描述有可能携带服务地址、operation ID 或凭据。
    static func from(_ error: Error) -> Self {
        if let known = error as? Self { return known }
        guard let network = error as? StarcatEnvelopeNetworkError,
              case .serverError(let status, _, _) = network else { return .unavailable }
        switch status {
        case 401, 403: return .configuration
        case 409: return .conflict
        case 413: return .tooLarge
        case 429: return .rateLimited
        default: return .unavailable
        }
    }
}
