//
//  GitHubAchievementsParserTests.swift
//  StarcatTests
//
//  使用官方页面形状的最小 fixture 检查真实勋章、等级、去重与网页结构变化降级。
//

import Testing
@testable import Starcat

struct GitHubAchievementsParserTests {
    /// 同时存在侧栏头像与主卡片时只读取一次；不把其它页面图片当成勋章。
    @Test("解析真实成就卡片和等级")
    func parsesCardsAndTiers() throws {
        let html = """
        <meta name="route-controller" content="profiles_achievements">
        <img class="achievement-badge-sidebar" alt="Achievement: Fake sidebar">
        <turbo-frame id="user-profile-frame">
          <details class="js-achievement-card-details" data-achievement-slug="pull-shark">
            <summary class="achievement-card">
              <img src="https://github.githubassets.com/assets/pull-shark-silver.png" alt="Achievement: Pull Shark">
              <span class="Label achievement-tier-label achievement-tier-label--silver">x3</span>
            </summary>
          </details>
          <details data-achievement-slug='yolo'><summary>
            <img alt='Achievement: YOLO &amp; Friends' src='https://github.githubassets.com/assets/yolo.png'>
          </summary></details>
        </turbo-frame>
        """
        let result = try GitHubAchievementsParser.parse(html)
        #expect(result.map(\.id) == ["pull-shark", "yolo"])
        #expect(result.map(\.name) == ["Pull Shark", "YOLO & Friends"])
        #expect(result.first?.tier == "x3")
        #expect(result.last?.tier == nil)
    }

    @Test("结构变化和登录页面不能覆盖旧缓存", arguments: [
        "<html><title>Sign in · GitHub</title></html>",
        "profiles_achievements user-profile-frame <img class='achievement-badge-card'>",
        """
        profiles_achievements user-profile-frame
        <details data-achievement-slug="yolo"><summary>
          <img src="https://example.com/fake.png" alt="Achievement: YOLO">
        </summary></details>
        """
    ])
    func rejectsUnexpectedPages(html: String) {
        #expect(throws: (any Error).self) {
            try GitHubAchievementsParser.parse(html)
        }
    }

    @Test("真实空页面允许清除旧勋章")
    func acceptsEmptyAchievements() throws {
        let result = try GitHubAchievementsParser.parse("profiles_achievements <turbo-frame id='user-profile-frame'></turbo-frame>")
        #expect(result.isEmpty)
    }
}
