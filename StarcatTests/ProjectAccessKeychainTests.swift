//
//  ProjectAccessKeychainTests.swift
//  StarcatTests
//
//  验证 GitHub App 项目凭据与现有 OAuth token 使用独立安全存储 account。
//

import Testing
@testable import Starcat

@Suite("ProjectAccessKeychain")
struct ProjectAccessKeychainTests {
    @Test("删除项目凭据不影响 OAuth token")
    func projectCredentialIsIndependent() throws {
        let keychain = InMemoryKeychain()
        try keychain.storeGithubToken("oauth-token")
        try keychain.storeProjectAccessCredential(#"{"access_token":"ghu_project"}"#)

        #expect(try keychain.loadGithubToken() == "oauth-token")
        #expect(try keychain.loadProjectAccessCredential()?.contains("ghu_project") == true)

        try keychain.deleteProjectAccessCredential()

        #expect(try keychain.loadProjectAccessCredential() == nil)
        #expect(try keychain.loadGithubToken() == "oauth-token")
    }
}
