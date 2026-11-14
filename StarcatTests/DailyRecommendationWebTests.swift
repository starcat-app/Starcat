//
//  DailyRecommendationWebTests.swift
//  StarcatTests
//
//  检查网页与原生的展示边界，不创建窗口或执行 GUI 自动化。
//  覆盖跨批次点击、未推荐 ID、Int64 精度、缺失字段与打包后的页面资源。
//

import Foundation
import Testing
@testable import Starcat

@Suite("每日发现网页契约")
@MainActor
struct DailyRecommendationWebTests {
    @Test("当前候选可以触发原生操作", arguments: ["presented", "star", "details", "dismiss"])
    func acceptsCurrentItem(type: String) {
        let action = DailyRecommendationWebAction(
            body: ["type": type, "context": "account/batch", "id": "42"],
            context: "account/batch", allowedIDs: [42]
        )
        #expect(action != nil)
    }

    @Test("旧账号或旧批次操作被拒绝", arguments: ["presented", "star", "details", "dismiss", "nextBatch", "autoShow"])
    func rejectsStaleContext(type: String) {
        let action = DailyRecommendationWebAction(
            body: ["type": type, "context": "old-account", "id": "42", "value": true],
            context: "new-account", allowedIDs: [42]
        )
        #expect(action == nil)
    }

    @Test("网页不能指定非候选仓库或不精确的数字 ID", arguments: [
        ["type": "star", "context": "c", "id": "999"],
        ["type": "details", "context": "c", "id": "<script>"],
        ["type": "dismiss", "context": "c", "fullName": "other/repo"],
        ["type": "fetch", "context": "c", "id": "42"]
    ])
    func rejectsUntrustedItem(body: [String: String]) {
        #expect(DailyRecommendationWebAction(body: body, context: "c", allowedIDs: [42]) == nil)
    }

    @Test("数字 ID 不经 Double 转换，非法开关值不被当成确认")
    func rejectsInvalidPayloadTypes() {
        #expect(DailyRecommendationWebAction(
            body: ["type": "star", "context": "c", "id": 42], context: "c", allowedIDs: [42]
        ) == nil)
        #expect(DailyRecommendationWebAction(
            body: ["type": "autoShow", "context": "c", "value": "false"], context: "c", allowedIDs: []
        ) == nil)
        #expect(DailyRecommendationWebAction(
            body: ["type": "autoShow", "context": "c", "value": false], context: "c", allowedIDs: []
        ) == .setAutoShow(false))
    }

    @Test("Int64 ID、原始描述和统计在序列化后完整保留")
    func preservesDataWithoutGeneratedClaims() throws {
        let id: Int64 = 9_007_199_254_740_993
        let description = #"<img src=x onerror="alert(1)"> "quoted" \ text"#
        let item = candidate(id: id, description: description)
        let payload = DailyRecommendationWebSnapshot.Item(item, revealed: true)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        #expect(object["id"] as? String == String(id))
        #expect(object["description"] as? String == description)
        #expect(object["stars"] as? Int == 123)
        #expect(object["forks"] as? Int == 7)
        #expect(object["score"] == nil)
        #expect(object["source"] == nil)
        #expect(object["signals"] == nil)
        #expect(object["summary"] == nil)
        #expect(DailyRecommendationWebAction(
            body: ["type": "star", "context": "c", "id": String(id)], context: "c", allowedIDs: [id]
        ) == .star(id))
    }

    @Test("空简介与未知理由不补写个性化证据")
    func missingMetadata() {
        let item = DailyRecommendationWebSnapshot.Item(
            candidate(description: nil, reasons: ["unknown <script>"]), revealed: false
        )
        #expect(item.description.isEmpty)
        #expect(item.language == nil)
        #expect(item.reason == String.l10n("recommendations.daily.reason"))
        #expect(item.reasonDetail == item.reason)
        #expect(item.compactReason)
        #expect(!item.revealed)
    }

    @Test("已知理由提供固定机制解释，不透传未知字符串")
    func explainsKnownReason() {
        let item = DailyRecommendationWebSnapshot.Item(
            candidate(reasons: ["unknown", "time_decayed_costar"]), revealed: false
        )
        #expect(item.reason == String.l10n("recommendations.daily.reasonCoStar"))
        #expect(item.reasonDetail == String.l10n("recommendations.daily.reasonCoStarDetail"))
        #expect(item.reason != item.reasonDetail)
        #expect(!item.compactReason)
    }

    @Test("通用模型说明与未知理由不伪装成详细依据", arguments: [
        ["基于自研推荐模型"], ["unknown"]
    ])
    func generalReasonUsesCompactPresentation(reasons: [String]) {
        let item = DailyRecommendationWebSnapshot.Item(candidate(reasons: reasons), revealed: false)
        #expect(item.compactReason)
        #expect(!item.reasonDetail.isEmpty)
    }

    @Test("账号、数据库和新批次分别改变网页身份")
    func contextTracksAccountAndBatch() {
        var state = DailyRecommendationState()
        state.day = "2026-11-14"
        state.generatedAt = Date(timeIntervalSince1970: 100)
        let original = DailyRecommendationWebSnapshot.context(accountID: 1, revision: 1, state: state)
        #expect(original != DailyRecommendationWebSnapshot.context(accountID: 2, revision: 1, state: state))
        #expect(original != DailyRecommendationWebSnapshot.context(accountID: 1, revision: 2, state: state))
        state.generatedAt = Date(timeIntervalSince1970: 101)
        #expect(original != DailyRecommendationWebSnapshot.context(accountID: 1, revision: 1, state: state))
    }

    @Test("实际应用包包含透明本地页面，没有设计样例或网络入口")
    func bundledRenderer() throws {
        let url = try #require(Bundle.main.url(forResource: "daily-discovery", withExtension: "html"))
        let html = try String(contentsOf: url, encoding: .utf8)
        #expect(html.contains("window.starcatDiscovery"))
        #expect(html.contains("border-radius: 16px"))
        #expect(html.contains("--sd-luster: .55"))
        #expect(html.contains("background: transparent"))
        #expect(html.contains("connect-src 'none'"))
        #expect(!html.contains("astral-sh"))
        #expect(!html.contains("window.openai"))
        #expect(!html.contains("localStorage"))
        #expect(!html.contains("fetch("))
    }

    private func candidate(id: Int64 = 42, description: String? = nil, reasons: [String] = []) -> RepoRecommendationItem {
        RepoRecommendationItem(
            repoID: id, fullName: "owner/project", description: description, language: nil,
            stars: 123, forks: 7, archived: false, score: 0.9, source: "starcat_trained", reasons: reasons
        )
    }
}
