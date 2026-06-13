//
//  RepositorySearchAPI.swift
//  Starcat
//
//  GitHub Repository Search 端点与 query builder。
//
//  qualifier 由结构化字段生成，不接受 UI 直接拼接原始字符串，避免空格、冒号和日期
//  编码错误。GitHub 的 1000 条检索上限由 Provider/UI 显式展示，不在网络层静默截断。
//

import Foundation

struct GitHubRepositorySearchDTO: Decodable, Equatable {
    let totalCount: Int
    let incompleteResults: Bool
    let items: [GitHubRepoDTO]
}

struct GitHubRepositorySearchQuery: Equatable, Sendable {
    let text: String
    let filters: GitHubSearchFilters

    var encodedQuery: String {
        var components = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let language = normalized(filters.language) { components.append("language:\(language)") }
        if let topic = normalized(filters.topic) { components.append("topic:\(topic)") }
        if let stars = filters.minimumStars { components.append("stars:>=\(max(0, stars))") }
        if let date = filters.createdAfter { components.append("created:>=\(Self.dateFormatter.string(from: date))") }
        if let date = filters.pushedAfter { components.append("pushed:>=\(Self.dateFormatter.string(from: date))") }
        return components.filter { !$0.isEmpty }.joined(separator: " ")
    }

    var queryItems: [URLQueryItem] {
        var items = [
            URLQueryItem(name: "q", value: encodedQuery),
            URLQueryItem(name: "per_page", value: nil),
            URLQueryItem(name: "page", value: nil)
        ]
        if filters.sort != .bestMatch {
            items.append(URLQueryItem(name: "sort", value: filters.sort.rawValue))
            items.append(URLQueryItem(name: "order", value: filters.order.rawValue))
        }
        return items
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

extension GitHubAPIClient {
    func searchRepositories(
        query: GitHubRepositorySearchQuery,
        page: Int,
        perPage: Int
    ) async throws -> APIResponse<GitHubRepositorySearchDTO> {
        var items = query.queryItems.map { item -> URLQueryItem in
            switch item.name {
            case "page": return URLQueryItem(name: item.name, value: String(max(1, page)))
            case "per_page": return URLQueryItem(name: item.name, value: String(min(max(1, perPage), 100)))
            default: return item
            }
        }
        // GitHub 要求 q 非空；网络层保留防御，UI 仍负责不提交空查询。
        if query.encodedQuery.isEmpty {
            items[0] = URLQueryItem(name: "q", value: "stars:>=0")
        }
        return try await get(path: "/search/repositories", queryItems: items)
    }
}
