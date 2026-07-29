//
//  GitHubAppConfigurationTests.swift
//  StarcatTests
//
//  验证 GitHub App 公共 slug 只能生成受控的官方安装入口。
//

import Foundation
import Testing
@testable import Starcat

@Suite("GitHub App 公共配置")
struct GitHubAppConfigurationTests {
    @Test("合法 slug 生成官方安装入口")
    func validSlugBuildsInstallationURL() {
        let url = AppConstants.makeGitHubAppInstallationURL(
            slug: "  starcat-project-access  "
        )

        #expect(
            url?.absoluteString
                == "https://github.com/apps/starcat-project-access/installations/new"
        )
    }

    @Test("空值和路径字符不会生成安装入口", arguments: [
        "",
        "   ",
        "starcat/project-access",
        "starcat?target=other",
        "starcat_project_access"
    ])
    func invalidSlugIsRejected(_ slug: String) {
        #expect(AppConstants.makeGitHubAppInstallationURL(slug: slug) == nil)
    }

    @Test("项目权限 callback 与主登录 callback 精确隔离")
    func projectAccessCallbackRouteIsExact() {
        #expect(
            AppConstants.isGitHubAppCallback(
                URL(string: "starcat://github-app/callback?code=project&state=one")!
            )
        )
        #expect(
            !AppConstants.isGitHubAppCallback(
                URL(string: "starcat://callback?code=login&state=two")!
            )
        )
        #expect(
            !AppConstants.isGitHubAppCallback(
                URL(string: "starcat://github-app/other?code=project&state=one")!
            )
        )
    }
}
