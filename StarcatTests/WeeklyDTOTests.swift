//
//  WeeklyDTOTests.swift
//  StarcatTests
//
//  R-05 后：验证 envelope 化的三源聚合 weekly 响应能正确解码到
//  `WeeklyFeedRepoDTO + WeeklyFeedItem`。
//
//  关键约束：
//  - 后端响应顶层走 `StarcatEnvelope<[StarcatRepoCardDTO]>`（schema_version + data + meta）
//  - 周刊场景独有字段（`first_issue` / `issue_url`）放在 `weekly` 扩展段下
//  - description / language / weekly 段都可缺；缺字段时默认值要落到 UI 友好的回退值
//

import Testing
import Foundation
@testable import Starcat

@Suite("Weekly Envelope 解码")
struct WeeklyDTOTests {

    private var decoder: JSONDecoder { JSONDecoder() }

    @Test("完整 envelope 响应解码到 WeeklyFeedItem")
    func decodeFullEnvelope() throws {
        let json = #"""
        {
          "schema_version": 1,
          "data": [
            {
              "gh_repo_id": 100001,
              "full_name": "alice/awesome-tool",
              "owner": "alice",
              "repo": "awesome-tool",
              "description": "An awesome tool",
              "language": "Go",
              "stars": 1234,
              "forks": 100,
              "watchers": 1234,
              "subscribers": 50,
              "topics": [],
              "is_archived": false,
              "is_fork": false,
              "is_private": false,
              "open_issues": 5,
              "html_url": "https://github.com/alice/awesome-tool",
              "is_available": true,
              "source_types": ["weekly", "zread", "hellogithub", "ai_intelligence", "future"],
              "first_event_at": "2024-05-02T00:00:00Z",
              "latest_event_at": "2026-05-02T00:00:00Z",
              "weekly": {
                "issue_number": 399,
                "issue_url": "https://github.com/ruanyf/weekly/blob/master/docs/issue-399.md"
              },
              "zread": {
                "week_start": "2026-05-01",
                "week_end": "2026-05-07",
                "week_label": "Week 18",
                "rank_in_week": 2
              },
              "source_entries": [
                {
                  "source_code": "ai_intelligence",
                  "occurred_at": "2026-07-16T00:00:00Z",
                  "source_url": "https://example.com/ai-news",
                  "title": "AI 情报项目",
                  "summary": "来自一段新闻文本"
                }
              ],
              "is_pinned": true,
              "pin_position": 2
            }
          ],
          "meta": {
            "page": 1,
            "page_size": 20,
            "total": 1,
            "next_page": 2
          }
        }
        """#

        let data = try #require(json.data(using: .utf8))
        let envelope = try decoder.decode(StarcatEnvelope<[WeeklyFeedRepoDTO]>.self, from: data)

        #expect(envelope.schemaVersion == 1)
        #expect(envelope.isSupported == true)
        #expect(envelope.data.count == 1)
        #expect(envelope.meta?.total == 1)
        #expect(envelope.meta?.page == 1)
        #expect(envelope.meta?.pageSize == 20)
        #expect(envelope.meta?.nextPage == 2)

        let item = WeeklyFeedItem(dto: envelope.data[0])
        #expect(item.id == 100001)
        #expect(item.owner == "alice")
        #expect(item.name == "awesome-tool")
        #expect(item.fullName == "alice/awesome-tool")
        #expect(item.stars == 1234)
        #expect(item.language == "Go")
        #expect(item.weekly?.issueNumber == 399)
        #expect(item.zread?.weekLabel == "Week 18")
        #expect(item.sourceTypes == [.weekly, .zread, .helloGitHub, .aiIntelligence, .unknown("future")])
        #expect(item.sourceEntries.first?.source == .aiIntelligence)
        #expect(item.sourceEntries.first?.title == "AI 情报项目")
        #expect(item.isPinned == true)
        #expect(item.pinPosition == 2)
        #expect(item.shortSourceLabel == "399")
        #expect(item.url.absoluteString == "https://github.com/alice/awesome-tool")
    }

    @Test("description / language / weekly 缺失时使用回退")
    func decodeWithMissingOptionalFields() throws {
        // weekly 扩展段缺失（弱关联场景：项目暂未在周刊收录但仍在卡片列表里出现，
        // 后端返回时会省略 weekly 段；前端应能优雅退化）。
        let json = #"""
        {
          "schema_version": 1,
          "data": [
            {
              "gh_repo_id": 100002,
              "full_name": "bob/tiny",
              "owner": "bob",
              "repo": "tiny",
              "stars": 0,
              "forks": 0,
              "watchers": 0,
              "subscribers": 0,
              "topics": [],
              "is_archived": false,
              "is_fork": false,
              "is_private": false,
              "open_issues": 0,
              "source_types": ["discovery"],
              "first_event_at": "2026-05-02T00:00:00Z",
              "latest_event_at": "2026-05-02T00:00:00Z",
              "discovery": {
                "hn_id": 123,
                "title": "Show HN: Tiny",
                "score": 5,
                "comments": 2,
                "published_at": "2026-05-02T00:00:00Z"
              }
            }
          ],
          "meta": {
            "page": 1,
            "page_size": 20,
            "total": 1
          }
        }
        """#

        let data = try #require(json.data(using: .utf8))
        let envelope = try decoder.decode(StarcatEnvelope<[WeeklyFeedRepoDTO]>.self, from: data)
        let item = WeeklyFeedItem(dto: envelope.data[0])

        #expect(item.description == nil)
        #expect(item.language == nil)
        #expect(item.weekly == nil)
        #expect(item.discovery?.hnID == 123)
        #expect(item.shortSourceLabel == "5.2")
    }

    @Test("空 data 数组不报错")
    func decodeEmptyEnvelope() throws {
        let json = #"""
        {
          "schema_version": 1,
          "data": [],
          "meta": { "page": 1, "page_size": 20, "total": 0 }
        }
        """#
        let data = try #require(json.data(using: .utf8))
        let envelope = try decoder.decode(StarcatEnvelope<[WeeklyFeedRepoDTO]>.self, from: data)
        #expect(envelope.data.isEmpty)
        #expect(envelope.meta?.total == 0)
    }

    @Test("详情事件解码通用来源字段")
    func decodeGenericSourceEvent() throws {
        let json = #"""
        {
          "id": "hellogithub:42",
          "source": "hellogithub",
          "source_code": "hellogithub",
          "occurred_at": "2026-07-16T00:00:00Z",
          "source_url": "https://hellogithub.com/periodical/volume/123",
          "title": "一个开源项目",
          "summary": "HelloGitHub 月刊推荐",
          "rank": 4
        }
        """#
        let event = try decoder.decode(WeeklySourceEvent.self, from: #require(json.data(using: .utf8)))
        #expect(event.source == .helloGitHub)
        #expect(event.sourceURL?.absoluteString == "https://hellogithub.com/periodical/volume/123")
        #expect(event.summary == "HelloGitHub 月刊推荐")
        #expect(event.rank == 4)
        #expect(event.presentationTitle == "一个开源项目")
        #expect(event.presentationDate == "2026-07-16")
    }
}

@Suite("Weekly 动态来源")
struct WeeklyDynamicSourceTests {
    @Test("未知来源可从 bulk 目录生成筛选项")
    func unknownSourceBuildsFilter() {
        let descriptor = WeeklySourceDescriptor(
            code: "future_channel",
            displayNameZH: "未来渠道",
            displayNameEN: "Future Channel",
            iconKey: "future",
            sortOrder: 90,
            count: 3
        )
        let filter = WeeklySourceFilter(descriptor: descriptor)
        #expect(filter.queryValue == "future_channel")
        #expect(filter.id == "future_channel")
        #expect(filter.count == 3)
        #expect(WeeklySource(rawValue: "future_channel").presentation.systemImage == "questionmark.circle.fill")
    }
}

@Suite("Weekly 来源展示语言", .serialized)
struct WeeklySourcePresentationTests {
    @Test("动态来源标题跟随应用语言而不是系统语言")
    func descriptorUsesAppLocaleOverride() {
        let key = "AppLocaleOverride"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let descriptor = WeeklySourceDescriptor(
            code: "future", displayNameZH: "未来渠道", displayNameEN: "Future Channel",
            iconKey: "future", sortOrder: 90, count: 1
        )

        UserDefaults.standard.set("en", forKey: key)
        #expect(descriptor.localizedTitle == "Future Channel")
        UserDefaults.standard.set("zh-Hans", forKey: key)
        #expect(descriptor.localizedTitle == "未来渠道")
    }
}

@Suite("WeeklyFeedListResult.hasMore")
struct WeeklyFeedListResultTests {

    @Test("nextPage 存在时 hasMore = true")
    func hasMoreWhenNextPageExists() {
        let result = WeeklyFeedListResult(items: [], total: 100, page: 1, pageSize: 20, nextPage: 2)
        #expect(result.hasMore == true)
    }

    @Test("nextPage 缺失时 hasMore = false")
    func noMoreWithoutNextPage() {
        let result = WeeklyFeedListResult(items: [], total: 100, page: 5, pageSize: 20, nextPage: nil)
        #expect(result.hasMore == false)
    }
}

@Suite("WeeklyAPI source filter", .serialized)
struct WeeklyAPISourceFilterTests {

    @Test("fetchRepos: 非全部来源时发送 source query")
    func fetchReposSendsSourceQuery() async throws {
        URLProtocolStub.reset()
        let api = WeeklyAPI(
            baseURL: URL(string: "https://weekly.test.invalid")!,
            session: URLProtocolStub.ephemeralSession()
        )
        URLProtocolStub.requestHandler = { request in
            (
                weeklyHTTPResponse(200, request.url!),
                Self.listFixtureBody()
            )
        }

        _ = try await api.fetchRepos(query: WeeklyFeedQuery(
            source: .zread,
            language: "Swift",
            sort: .starsDesc,
            page: 2,
            pageSize: 10
        ))

        let request = try #require(URLProtocolStub.receivedRequests.first)
        let query = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .compactMap { item in item.value.map { (item.name, $0) } }
        )
        #expect(query["source"] == "zread")
        #expect(query["lang"] == "Swift")
        #expect(query["sort"] == "stars")
        #expect(query["order"] == "desc")
        #expect(query["page"] == "2")
        #expect(query["page_size"] == "10")
    }

    @Test("fetchRepos: 全部来源不发送 source query")
    func fetchReposOmitsSourceForAll() async throws {
        URLProtocolStub.reset()
        let api = WeeklyAPI(
            baseURL: URL(string: "https://weekly.test.invalid")!,
            session: URLProtocolStub.ephemeralSession()
        )
        URLProtocolStub.requestHandler = { request in
            (
                weeklyHTTPResponse(200, request.url!),
                Self.listFixtureBody()
            )
        }

        _ = try await api.fetchRepos(query: WeeklyFeedQuery(source: .all))

        let request = try #require(URLProtocolStub.receivedRequests.first)
        let names = Set(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        #expect(!names.contains("source"))
    }

    private static func listFixtureBody() -> Data {
        #"""
        {
          "schema_version": 1,
          "data": [
            {
              "gh_repo_id": 100001,
              "full_name": "alice/awesome-tool",
              "owner": "alice",
              "repo": "awesome-tool",
              "stars": 1234,
              "forks": 100,
              "watchers": 1234,
              "subscribers": 50,
              "topics": [],
              "is_archived": false,
              "is_fork": false,
              "is_private": false,
              "open_issues": 5,
              "html_url": "https://github.com/alice/awesome-tool",
              "is_available": true,
              "source_types": ["zread"],
              "first_event_at": "2024-05-02T00:00:00Z",
              "latest_event_at": "2026-05-02T00:00:00Z",
              "zread": {
                "week_start": "2026-05-01",
                "week_end": "2026-05-07",
                "week_label": "Week 18",
                "rank_in_week": 2
              }
            }
          ],
          "meta": {
            "page": 1,
            "page_size": 20,
            "total": 1
          }
        }
        """#.data(using: .utf8)!
    }
}

private func weeklyHTTPResponse(
    _ statusCode: Int,
    _ url: URL,
    _ headers: [String: String] = [:]
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
}
