//
//  GitHubBlogRSSAPITests.swift
//  StarcatTests
//
//  Activity 公告与关注 PR-3（2026-06-17）：GitHubBlogRSSClient 单测。
//

import Testing
import Foundation
@testable import Starcat

@Suite("GitHubBlogRSSAPI.fetchFeed", .serialized)
struct GitHubBlogRSSAPITests {

    private let feedURL = URL(string: "https://github.blog.test.invalid/feed/")!

    private var sampleRSS: Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0"
                 xmlns:content="http://purl.org/rss/1.0/modules/content/"
                 xmlns:dc="http://purl.org/dc/elements/1.1/">
              <channel>
                <title>GitHub Blog</title>
                <item>
                  <title>Copilot CLI for Beginners</title>
                  <link>https://github.blog/ai-and-ml/copilot-cli/</link>
                  <guid isPermaLink="false">?p=96773</guid>
                  <pubDate>Mon, 16 Jun 2026 12:00:00 +0000</pubDate>
                  <dc:creator>GitHub Staff</dc:creator>
                  <category>AI &amp; ML</category>
                  <category>GitHub Copilot</category>
                  <description><![CDATA[<p>Short summary</p>]]></description>
                  <content:encoded><![CDATA[<p>Full <strong>HTML</strong> body</p>]]></content:encoded>
                </item>
              </channel>
            </rss>
            """.utf8
        )
    }

    private func makeClient() -> GitHubBlogRSSClient {
        URLProtocolStub.reset()
        return GitHubBlogRSSClient(
            session: URLProtocolStub.ephemeralSession(),
            feedURL: feedURL
        )
    }

    @Test("200: 解析 RSS item + ETag")
    func parseFeed200() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["ETag": "\"rss-etag\""]
            )!
            return (response, self.sampleRSS)
        }

        let resp = try await client.fetchFeed(ifNoneMatch: nil)

        #expect(resp.value.count == 1)
        #expect(resp.etag == "\"rss-etag\"")
        let item = try #require(resp.value.first)
        #expect(item.guid == "?p=96773")
        #expect(item.title == "Copilot CLI for Beginners")
        #expect(item.author == "GitHub Staff")
        #expect(item.categories == ["AI & ML", "GitHub Copilot"])
        #expect(item.contentHTML?.contains("<strong>HTML</strong>") == true)
    }

    @Test("If-None-Match 头透传")
    func ifNoneMatchHeader() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (response, Data("<?xml version=\"1.0\"?><rss><channel></channel></rss>".utf8))
        }
        _ = try await client.fetchFeed(ifNoneMatch: "\"old-etag\"")

        let req = try #require(URLProtocolStub.receivedRequests.first)
        #expect(req.value(forHTTPHeaderField: "If-None-Match") == "\"old-etag\"")
    }

    @Test("304: 抛 NetworkError.notModified")
    func notModified304() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 304,
                httpVersion: "HTTP/1.1",
                headerFields: ["ETag": "\"rss-etag\""]
            )!
            return (response, Data())
        }

        do {
            _ = try await client.fetchFeed(ifNoneMatch: "\"rss-etag\"")
            Issue.record("期望 notModified")
        } catch NetworkError.notModified(let etag) {
            #expect(etag == "\"rss-etag\"")
        } catch {
            Issue.record("期望 notModified，实际 \(error)")
        }
    }

    @Test("malformed XML: 抛 invalidResponse")
    func malformedXML() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (response, Data("not xml".utf8))
        }

        do {
            _ = try await client.fetchFeed(ifNoneMatch: nil)
            Issue.record("期望 invalidResponse")
        } catch NetworkError.invalidResponse {
            // pass
        } catch {
            Issue.record("期望 invalidResponse，实际 \(error)")
        }
    }
}
