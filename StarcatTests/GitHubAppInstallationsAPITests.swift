//
//  GitHubAppInstallationsAPITests.swift
//  StarcatTests
//
//  验证 GitHub App 安装列表的请求契约、slug 匹配与分页行为。
//

import Foundation
import Testing
@testable import Starcat

@Suite("GitHub App 安装状态 API", .serialized)
struct GitHubAppInstallationsAPITests {
    private func makeClient() -> GitHubAPIClient {
        GitHubAPIClient(
            baseURL: URL(string: "https://api.test.invalid")!,
            session: URLProtocolStub.ephemeralSession(),
            tokenProvider: StubTokenProvider(token: "ghu-project")
        )
    }

    @Test("匹配安装时携带 user token 并返回 true")
    func installedAppIsDetected() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            #expect(request.url?.path == "/user/installations")
            #expect(request.url?.query?.contains("per_page=100") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu-project")
            let body = """
                {
                  "total_count": 1,
                  "installations": [
                    { "id": 42, "app_slug": "starcat-project-access" }
                  ]
                }
                """.data(using: .utf8)!
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                body
            )
        }

        let installed = try await makeClient().hasAccessibleGitHubAppInstallation(
            appSlug: "Starcat-Project-Access"
        )

        #expect(installed)
    }

    @Test("无匹配安装时返回 false")
    func missingAppReturnsFalse() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let body = """
                {
                  "total_count": 1,
                  "installations": [
                    { "id": 7, "app_slug": "another-app" }
                  ]
                }
                """.data(using: .utf8)!
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                body
            )
        }

        let installed = try await makeClient().hasAccessibleGitHubAppInstallation(
            appSlug: "starcat-project-access"
        )

        #expect(!installed)
    }

    @Test("安装列表分页时继续查找下一页")
    func followsPagination() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "page" })?
                .value
            let found = page == "2"
            let body = """
                {
                  "total_count": 2,
                  "installations": [
                    { "id": \(found ? 2 : 1), "app_slug": "\(found ? "starcat-project-access" : "another-app")" }
                  ]
                }
                """.data(using: .utf8)!
            let headers = found ? nil : [
                "Link": "<https://api.test.invalid/user/installations?page=2&per_page=100>; rel=\"next\""
            ]
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: headers
                )!,
                body
            )
        }

        let installed = try await makeClient().hasAccessibleGitHubAppInstallation(
            appSlug: "starcat-project-access"
        )

        #expect(installed)
        #expect(URLProtocolStub.receivedRequests.count == 2)
    }
}
