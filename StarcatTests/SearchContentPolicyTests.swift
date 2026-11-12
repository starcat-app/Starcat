//
//  SearchContentPolicyTests.swift
//  StarcatTests
//
//  规则正反样本与热态批量基准；防治、研发和正常软件必须与危险交易区分。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Search Content Policy")
struct SearchContentPolicyTests {
    @Test("精确仓库匹配不扩大到作者或同名项目", arguments: [
        "https://github.com/cirosantilli/china-dictatorship",
        "https://GITHUB.COM/CIROSANTILLI/CHINA-DICTATORSHIP/issues/1",
        "https://github.com/cirosantilli/china-dictatorship.git"
    ])
    func blockedRepositoryURLs(_ value: String) {
        #expect(SearchContentPolicy.bundled.match(query: value)?.ruleID == "repository.explicit.001")
    }

    @Test("相似身份和域名不得误杀", arguments: [
        "cirosantilli/hello-world", "another-owner/china-dictatorship",
        "cirosantilli/china-dictatorship-tools",
        "https://github.com.example.org/cirosantilli/china-dictatorship",
        "https://example.org/cirosantilli/china-dictatorship",
        "https://github.com/search?q=cirosantilli/china-dictatorship"
    ])
    func unrelatedIdentities(_ value: String) {
        #expect(SearchContentPolicy.bundled.match(query: value) == nil)
    }

    @Test("主题与明确交易规则命中", arguments: [
        "法轮功", "法輪功", "法\u{200B}轮功", "法 轮 功", "ＦＡＬＵＮ　ＧＯＮＧ",
        "Falun-Gong", "falungong", "反中共政治宣传库",
        "购买枪支", "出售毒品", "販賣人口", "出售人体器官", "sell human organs",
        "buy cocaine", "buy guns", "恐怖组织招募", "出售被盗账号",
        "sell stolen credentials", "赌博平台招募", "online casino signup bonus"
    ])
    func blockedQueries(_ value: String) {
        #expect(SearchContentPolicy.bundled.match(query: value) != nil)
    }

    @Test("正常技术和防治项目保留", arguments: [
        "帮我查一下 github 最近比较火的 linux 发行版，我搞忘叫什么名字了",
        "管理 github star 的开源项目", "basecamp/omarchy",
        "gunicorn", "kill-process", "drug discovery toolkit", "药物研发",
        "枪声检测", "购买毒品检测设备", "研究毒品交易", "毒品交易检测",
        "反人口贩卖公益项目", "打击贩卖人口", "人體器官移植研究",
        "human organ transplantation", "buy a pipe organ", "anti-human-trafficking",
        "cocaine trafficking detection", "密码管理和隐私保护", "反诈骗检测",
        "政治历史研究", "宗教文献整理", "反共识算法", "Falungongish software"
    ])
    func safeQueries(_ value: String) {
        #expect(SearchContentPolicy.bundled.match(query: value) == nil)
    }

    @Test("字段、句子与相距过远的词不能组合误杀")
    func independentFragments() {
        let policy = SearchContentPolicy.bundled
        let separatedFields = SearchContentDocument(
            id: "safe", fields: [.title: ["枪支检测"], .description: ["购买软件许可证"]]
        )
        #expect(policy.match(separatedFields) == nil)
        #expect(policy.match(query: "枪支检测。购买软件许可证") == nil)
        #expect(policy.match(query: "枪支检测，购买软件许可证") == nil)
        #expect(policy.match(query: "gun detection " + String(repeating: "normal software ", count: 10) + "buy license") == nil)
    }

    @Test("局部例外不覆盖同一结果里的另一次交易或精确身份")
    func exceptionsAreLocal() {
        let policy = SearchContentPolicy.bundled
        #expect(policy.match(query: "研究毒品交易。出售毒品") != nil)
        #expect(policy.match(query: "毒品交易检测，同时出售毒品") != nil)
        #expect(policy.match(SearchContentDocument(
            id: "blocked", repositoryFullName: "cirosantilli/china-dictatorship",
            fields: [.description: ["研究毒品交易"]]
        ))?.ruleID == "repository.explicit.001")
    }

    @Test("统计按身份去重且隐藏优先")
    func summaryDeduplicates() {
        let document = SearchContentDocument(id: "repo:example/project")
        var summary = SearchContentSummary()
        summary.record(document, match: nil)
        var incoming = SearchContentSummary()
        incoming.record(document, match: SearchContentMatch(ruleID: "example", category: "test"))
        summary.formUnion(incoming)
        summary.formUnion(incoming)
        #expect(summary.checkedCount == 1)
        #expect(summary.hiddenCount == 1)
        #expect(summary.retainedCount == 0)
    }

    @Test("域名按标签边界匹配，数字仓库身份独立于改名")
    func exactDomainAndNumericIdentity() throws {
        let data = Data("""
        {"version":"test","repositories":[{"id":"repo","category":"test","fullName":"old/name","githubID":42}],
         "domains":[{"id":"domain","category":"test","domain":"blocked.example"}],"rules":[]}
        """.utf8)
        let policy = try SearchContentPolicy(data: data)
        #expect(policy.match(SearchContentDocument(id: "renamed", repositoryID: 42))?.ruleID == "repo")
        #expect(policy.match(query: "https://sub.blocked.example/path")?.ruleID == "domain")
        #expect(policy.match(query: "https://notblocked.example/path") == nil)
        #expect(policy.match(query: "https://blocked.example.safe.org/path") == nil)
    }

    @Test("无效规则不能静默启用")
    func invalidRuleset() {
        let data = Data("""
        {"version":"test","repositories":[],"domains":[],"rules":[
        {"id":"same","category":"test","fields":["query"],"terms":[""],"actions":[],"exceptions":[]}]}
        """.utf8)
        #expect(throws: SearchContentPolicy.RulesetError.self) { try SearchContentPolicy(data: data) }
    }

    @Test("批量热态基准与异常长文本有界")
    func warmBatchBenchmark() {
        let policy = SearchContentPolicy.bundled
        let documents = (0..<100).map { index in
            SearchContentDocument(
                id: "repo:example/project-\(index)",
                repositoryFullName: "example/project-\(index)",
                fields: [.title: ["example/project-\(index)"], .description: [
                    index.isMultiple(of: 4) ? "药物研发与枪声检测，反人口贩卖公益项目" :
                        "A fast GitHub stars manager with semantic search, tags and release tracking."
                ]]
            )
        }
        var samples: [Double] = []
        for _ in 0..<40 {
            let start = ContinuousClock.now
            let matches = documents.compactMap { policy.match($0) }
            samples.append(Self.milliseconds(start.duration(to: .now)))
            #expect(matches.isEmpty)
        }
        let sorted = samples.sorted()
        print("SearchContentPolicy benchmark: 100 candidates, Debug, P50=\(sorted[20])ms P95=\(sorted[38])ms")
        let longValue = String(repeating: "normal software ", count: 100_000)
        #expect(policy.match(query: longValue) == nil)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
