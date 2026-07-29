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

    @Test("匹配全部仓库安装时携带 user token 并返回完整范围")
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
                    {
                      "id": 42,
                      "app_slug": "starcat-project-access",
                      "repository_selection": "all"
                    }
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

        let access = try await makeClient().githubAppInstallationAccess(
            appSlug: "Starcat-Project-Access"
        )

        #expect(access == .allRepositories)
    }

    @Test("无匹配安装时返回未安装")
    func missingAppReturnsFalse() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let body = """
                {
                  "total_count": 1,
                  "installations": [
                    {
                      "id": 7,
                      "app_slug": "another-app",
                      "repository_selection": "all"
                    }
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

        let access = try await makeClient().githubAppInstallationAccess(
            appSlug: "starcat-project-access"
        )

        #expect(access == .notInstalled)
    }

    @Test("安装列表分页时识别指定仓库范围")
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
                    {
                      "id": \(found ? 2 : 1),
                      "app_slug": "\(found ? "starcat-project-access" : "another-app")",
                      "repository_selection": "\(found ? "selected" : "all")"
                    }
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

        let access = try await makeClient().githubAppInstallationAccess(
            appSlug: "starcat-project-access"
        )

        #expect(access == .selectedRepositories)
        #expect(URLProtocolStub.receivedRequests.count == 2)
    }

    @Test("任一匹配安装选择指定仓库时整体返回部分范围")
    func selectedInstallationDominatesAllRepositoriesInstallation() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let body = """
                {
                  "total_count": 2,
                  "installations": [
                    {
                      "id": 1,
                      "app_slug": "starcat-for-github",
                      "repository_selection": "all"
                    },
                    {
                      "id": 2,
                      "app_slug": "starcat-for-github",
                      "repository_selection": "selected"
                    }
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

        let access = try await makeClient().githubAppInstallationAccess(
            appSlug: "starcat-for-github"
        )

        #expect(access == .selectedRepositories)
    }
}
