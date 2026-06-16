//
//  GitHubBlogRSSAPI.swift
//  Starcat
//
//  Activity 公告与关注 PR-3（2026-06-17）：GitHub 官方博客 RSS feed 客户端。
//
//  端点：`GET https://github.blog/feed/`（WordPress RSS 2.0，不走 api.github.com）。
//
//  设计要点：
//  - 独立 `GitHubBlogRSSAPIProtocol` + `GitHubBlogRSSClient` actor，不塞进
//    `GitHubAPIClient`（host / 鉴权 / Accept 头语义都不同，硬塞会污染 REST client）。
//  - ETag / If-None-Match / `NetworkError.notModified` 与 GitHub REST 端点同款契约，
//    让 ActivityViewModel 可以复用 events 那套 SWR 分支逻辑。
//  - RSS 解析走 Foundation `XMLParser` + delegate（不引第三方 XML 库）；
//    `content:encoded` / `dc:creator` 等命名空间字段按 localName 匹配。
//  - 解析失败抛 `NetworkError.invalidResponse`（整 feed 失败，不部分解码）。
//

import Foundation

// MARK: - Protocol

/// GitHub Blog RSS 客户端协议（测试可注入 mock）。
protocol GitHubBlogRSSAPIProtocol: Sendable {
    /// 拉取 GitHub 官方博客 RSS feed。
    ///
    /// - Parameter ifNoneMatch: 上次响应 ETag；304 时抛 `NetworkError.notModified(etag:)`。
    func fetchFeed(ifNoneMatch: String?) async throws -> APIResponse<[GitHubBlogRSSItemDTO]>
}

// MARK: - Client

/// 生产实现：`URLSession` + `XMLParser`。
actor GitHubBlogRSSClient: GitHubBlogRSSAPIProtocol {

    private let session: URLSession
    private let feedURL: URL

    init(session: URLSession = URLSession(configuration: .ephemeral), feedURL: URL = AppEndpoints.GitHubBlog.feedURL) {
        self.session = session
        self.feedURL = feedURL
    }

    func fetchFeed(ifNoneMatch: String?) async throws -> APIResponse<[GitHubBlogRSSItemDTO]> {
        var request = URLRequest(url: feedURL)
        request.httpMethod = "GET"
        request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
        if let etag = ifNoneMatch, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw NetworkError.cancelled
        } catch {
            if (error as NSError).code == NSURLErrorCancelled {
                throw NetworkError.cancelled
            }
            throw NetworkError.transport(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        let etag = http.value(forHTTPHeaderField: "ETag")

        if http.statusCode == 304 {
            throw NetworkError.notModified(etag: etag)
        }

        guard (200...299).contains(http.statusCode) else {
            if http.statusCode >= 500 {
                throw NetworkError.serverError(statusCode: http.statusCode)
            }
            throw NetworkError.clientError(statusCode: http.statusCode, message: nil)
        }

        let items = try Self.parseRSS(data: data)

        return APIResponse(
            value: items,
            linkHeader: LinkHeader(nextPage: nil, lastPage: nil),
            rateLimit: RateLimitInfo(limit: nil, remaining: nil, reset: nil),
            statusCode: http.statusCode,
            etag: etag
        )
    }

    // MARK: - RSS 解析

    nonisolated private static func parseRSS(data: Data) throws -> [GitHubBlogRSSItemDTO] {
        let parser = XMLParser(data: data)
        let delegate = RSSParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw NetworkError.invalidResponse
        }
        return delegate.items
    }
}

// MARK: - XMLParser delegate

/// WordPress RSS 2.0 解析器（专用于 github.blog/feed/）。
///
/// 关键约束：
/// - `dc:creator` / `content:encoded` 在 `didEndElement` 里 localName 分别是
///   `creator` / `encoded`（前缀被 Foundation 剥掉），按 localName 匹配即可。
/// - 单条 item 缺 title / link / guid 之一 → 整条丢弃（不阻塞其它 item）。
private final class RSSParserDelegate: NSObject, XMLParserDelegate {

    private(set) var items: [GitHubBlogRSSItemDTO] = []

    private var isInItem = false
    private var title: String?
    private var link: String?
    private var guid: String?
    private var author: String?
    private var pubDate: String?
    private var categories: [String] = []
    private var descriptionHTML: String?
    private var contentHTML: String?
    private var currentText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentText = ""
        if elementName == "item" {
            isInItem = true
            resetItemBuffers()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATAData: Data) {
        if let chunk = String(data: CDATAData, encoding: .utf8) {
            currentText += chunk
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = (qName ?? elementName).lowercased()
        guard isInItem else { return }

        switch tag {
        case "title":
            title = text
        case "link":
            link = text
        case "guid":
            guid = text
        case "dc:creator", "creator":
            author = text.isEmpty ? nil : text
        case "pubdate":
            pubDate = text
        case "category":
            if !text.isEmpty { categories.append(text) }
        case "description":
            descriptionHTML = text.isEmpty ? nil : text
        case "content:encoded", "encoded":
            contentHTML = text.isEmpty ? nil : text
        case "item":
            if let item = makeItem() {
                items.append(item)
            }
            isInItem = false
        default:
            break
        }
        currentText = ""
    }

    private func resetItemBuffers() {
        title = nil
        link = nil
        guid = nil
        author = nil
        pubDate = nil
        categories = []
        descriptionHTML = nil
        contentHTML = nil
    }

    private func makeItem() -> GitHubBlogRSSItemDTO? {
        guard let title, let link else { return nil }
        let resolvedGuid = guid ?? link
        guard !resolvedGuid.isEmpty else { return nil }
        return GitHubBlogRSSItemDTO(
            guid: resolvedGuid,
            title: title,
            link: link,
            author: author,
            pubDate: pubDate ?? "",
            categories: categories,
            descriptionHTML: descriptionHTML,
            contentHTML: contentHTML
        )
    }
}
