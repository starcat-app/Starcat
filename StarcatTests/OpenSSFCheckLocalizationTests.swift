//
//  OpenSSFCheckLocalizationTests.swift
//  StarcatTests
//
//  用真实 OpenSSF 结论验证显示翻译、数字顺序和未知原文回退。
//  直接检查各语言编译后的 .strings，防止系统英语兜底掩盖缺失的翻译。
//

import Foundation
import Testing
@testable import Starcat

/// 查表函数读取指定语言资源，不修改 AppLocaleOverride，避免影响并行测试。
@Suite("OpenSSF 检查文案国际化")
struct OpenSSFCheckLocalizationTests {
    @Test("所有公开检查项都有中文显示名", arguments: [
        ("Binary-Artifacts", "二进制产物"),
        ("Branch-Protection", "分支保护"),
        ("CI-Tests", "持续集成测试"),
        ("CII-Best-Practices", "最佳实践"),
        ("Code-Review", "代码审查"),
        ("Contributors", "贡献者"),
        ("Dangerous-Workflow", "危险工作流"),
        ("Dependency-Update-Tool", "依赖更新"),
        ("Fuzzing", "模糊测试"),
        ("License", "许可证"),
        ("Maintained", "维护活跃度"),
        ("Packaging", "打包发布"),
        ("Pinned-Dependencies", "依赖版本锁定"),
        ("SAST", "静态安全分析"),
        ("SBOM", "软件物料清单"),
        ("Security-Policy", "安全政策"),
        ("Signed-Releases", "发布签名"),
        ("Token-Permissions", "令牌权限"),
        ("Vulnerabilities", "漏洞"),
        ("Webhooks", "Webhook 安全"),
    ])
    func knownCheckNames(identifier: String, expected: String) throws {
        let strings = try compiledStrings(locale: "zh-Hans")
        #expect(OpenSSFCheckLocalization.name(identifier, localize: { strings[$0] ?? $0 }) == expected)
    }

    @Test("openai/codex 实际检查结论完整翻译", arguments: [
        ("Found 0/30 approved changesets -- score normalized to 0", "已批准 0/30 个变更集；折算得分：0"),
        ("30 commit(s) and 0 issue activity found in the last 90 days -- score normalized to 10",
         "近 90 天有 30 次提交、0 次 Issue 活动；折算得分：10"),
        ("security policy file detected", "检测到安全政策文件"),
        ("no dangerous workflow patterns detected", "未检测到危险的工作流模式"),
        ("no effort to earn an OpenSSF best practices badge detected", "未检测到申请 OpenSSF 最佳实践徽章的活动"),
        ("detected GitHub workflow tokens with excessive permissions", "检测到权限过大的 GitHub 工作流令牌"),
        ("license file detected", "检测到许可证文件"),
        ("no binaries found in the repo", "仓库中未发现二进制文件"),
        ("packaging workflow detected", "检测到打包工作流"),
        ("dependency not pinned by hash detected -- score normalized to 9", "检测到未通过哈希锁定的依赖；折算得分：9"),
        ("project is not fuzzed", "项目未进行模糊测试"),
        ("SAST tool is not run on all commits -- score normalized to 0", "并非所有提交都运行静态安全分析；折算得分：0"),
        ("branch protection is not maximal on development and all release branches",
         "开发分支及所有发布分支的保护尚未达到最高级别"),
        ("5 out of the last 5 releases have a total of 5 signed artifacts.",
         "最近 5 个发布版本中，5 个版本共包含 5 个已签名产物"),
    ])
    func observedReasons(original: String, expected: String) throws {
        let strings = try compiledStrings(locale: "zh-Hans")
        #expect(OpenSSFCheckLocalization.reason(original, localize: { strings[$0] ?? $0 }) == expected)
    }

    @Test("动态参数按译文语序显示且保留原始值", arguments: [
        ("187 commit(s) and 004 issue activity found in the last 91 days -- score normalized to 7",
         "近 91 天有 187 次提交、004 次 Issue 活动；折算得分：7"),
        ("30 commits found in the last 90 days", "近 90 天有 30 次提交"),
        ("3 out of 17 merged PRs checked by a CI test -- score normalized to 1",
         "已合并的拉取请求中，3/17 个经过 CI 测试；折算得分：1"),
        ("project has 12 contributing companies or organizations", "有 12 家公司或组织参与贡献"),
        ("8 existing vulnerabilities detected", "检测到 8 个现有漏洞"),
        ("project was created within the last 90 days. Please review its contents carefully",
         "项目创建于近 90 天内，请仔细审查其内容"),
        ("2 out of the last 5 releases have a total of 13 signed artifacts and 1 immutable releases.",
         "最近 5 个发布版本中，2 个版本共包含 13 个已签名产物；不可变发布版本有 1 个"),
        ("All 4 of the projects webhooks are configured with a secret", "全部 4 个 Webhook 均已配置密钥"),
        ("2 out of the projects 7 webhooks are configured without a secret -- score normalized to 7",
         "2/7 个 Webhook 未配置密钥；折算得分：7"),
    ])
    func dynamicArguments(original: String, expected: String) throws {
        let strings = try compiledStrings(locale: "zh-Hans")
        #expect(OpenSSFCheckLocalization.reason(original, localize: { strings[$0] ?? $0 }) == expected)
    }

    @Test("未知或仅部分匹配的结论交回原文路径", arguments: [
        "",
        "license file detected; but its contents could not be verified",
        "license file detected\n",
        "security policy file detected -- score normalized to unknown",
        "project is archived -- score normalized to 0 -- score normalized to 1",
        "Found 3/5 approved changesets; exceptions: .github/工作流.yml",
        "new rule failed: https://example.com/a?token=100%25 — 文件.swift",
    ])
    func unknownReasonsAreNotPartiallyTranslated(original: String) {
        #expect(OpenSSFCheckLocalization.reason(original, localize: { $0 }) == nil)
        #expect(OpenSSFCheckLocalization.name("Future-Check", localize: { $0 }) == "Future-Check")
    }

    @Test("缺少评估与未检测到证据不被改写为安全结论")
    func unavailableReasonsPreserveMeaning() throws {
        let strings = try compiledStrings(locale: "zh-Hans")
        let localize: (String) -> String = { strings[$0] ?? $0 }
        #expect(OpenSSFCheckLocalization.reason("no releases found", localize: localize) == "未发现发布版本")
        #expect(OpenSSFCheckLocalization.reason("Token permissions are not available", localize: localize) == "无法获取令牌权限")
        #expect(OpenSSFCheckLocalization.reason("no workflows found", localize: localize) == "未发现工作流")
        #expect(OpenSSFCheckLocalization.reason("dangerous workflow patterns detected", localize: localize) == "检测到危险的工作流模式")
    }

    @Test("读取失败不再进入上游原文展示", arguments: [
        "internal error: error during branchesHandler setup: internal error: some github tokens can't read classic branch protection rules: https://github.com/ossf/scorecard-action/blob/main/docs/authentication/fine-grained-auth-token.md",
        "runtime error",
        "internal error: request failed: https://example.com/diagnostics",
        "upstream request timed out while reading branch protection",
    ])
    func failedChecksHideTechnicalDetails(original: String) throws {
        let strings = try compiledStrings(locale: "zh-Hans")
        let check = makeCheck(score: -1, reason: original)
        #expect(OpenSSFCheckLocalization.reason(for: check, localize: { strings[$0] ?? $0 }) == .unavailable)
        #expect(check.reason == original)
    }

    @Test("未评估且没有有效说明时使用友好提示", arguments: [nil, "", " \n "] as [String?])
    func missingReasonsAreUnavailable(original: String?) {
        #expect(OpenSSFCheckLocalization.reason(for: makeCheck(score: -1, reason: original)) == .unavailable)
        #expect(OpenSSFCheckLocalization.reason(for: makeCheck(score: 10, reason: original)) == nil)
    }

    @Test("明确的运行错误优先于分数字段", arguments: [0.0, 10.0])
    func explicitErrorsAreNotShownAsScores(score: Double) {
        let check = makeCheck(score: score, reason: " \nINTERNAL ERROR: failed to read branch protection")
        #expect(OpenSSFCheckLocalization.reason(for: check) == .unavailable)
    }

    @Test("正常结论与确实不适用的说明继续显示")
    func validResultsPreserveTheirExplanation() throws {
        let strings = try compiledStrings(locale: "zh-Hans")
        let localize: (String) -> String = { strings[$0] ?? $0 }
        #expect(OpenSSFCheckLocalization.reason(
            for: makeCheck(score: -1, reason: "no pull request found"), localize: localize
        ) == .localized("未发现拉取请求"))
        #expect(OpenSSFCheckLocalization.reason(
            for: makeCheck(score: 0, reason: "dangerous workflow patterns detected"), localize: localize
        ) == .localized("检测到危险的工作流模式"))
        #expect(OpenSSFCheckLocalization.reason(
            for: makeCheck(score: 5, reason: "New check evidence: https://example.com/result"), localize: localize
        ) == .original("New check evidence: https://example.com/result"))
    }

    @Test("整页加载失败与尚未收录各自提供友好说明")
    func fetchFailuresUseFriendlyMessages() throws {
        let strings = try compiledStrings(locale: "zh-Hans")
        let localize: (String) -> String = { strings[$0] ?? $0 }
        for status in OpenSSFScoreFetchStatus.allCases {
            let expected = status == .notIndexed
                ? "OpenSSF 尚未收录此仓库，稍后可再次查看。"
                : "未能读取 OpenSSF 评分，请稍后刷新重试。"
            #expect(OpenSSFCheckLocalization.statusReason(status, localize: localize) == expected)
        }
    }

    @Test("重新查表跟随语言变化，不缓存已翻译的字符串")
    func languageChangesUseFreshLookup() throws {
        let english = try compiledStrings(locale: "en")
        let chinese = try compiledStrings(locale: "zh-Hans")
        let traditional = try compiledStrings(locale: "zh-Hant")
        #expect(OpenSSFCheckLocalization.name("Code-Review", localize: { english[$0] ?? $0 }) == "Code review")
        #expect(OpenSSFCheckLocalization.name("Code-Review", localize: { chinese[$0] ?? $0 }) == "代码审查")
        #expect(OpenSSFCheckLocalization.name("Code-Review", localize: { traditional[$0] ?? $0 }) == "程式碼審查")
        #expect(OpenSSFCheckLocalization.reason("license file detected", localize: { english[$0] ?? $0 }) == "License file detected")
    }

    @Test("全部运行时语言直接包含本次译文及相同占位符")
    func allRuntimeLocalesContainCompiledTranslations() throws {
        let english = try compiledStrings(locale: "en")
        let additionalKeys: Set<String> = [
            "openssf.check.temporarilyUnavailable",
            "openssf.sheet.securityTitle",
            "openssf.status.notIndexedHint",
            "openssf.status.readFailure",
            "openssf.status.unavailable",
        ]
        let keys = english.keys.filter {
            $0.hasPrefix("openssf.checkName.") || $0.hasPrefix("openssf.reason.") || additionalKeys.contains($0)
        }
        #expect(keys.count == 87)
        for appLocale in AppLocale.allCases where appLocale != .system {
            let strings = try compiledStrings(locale: appLocale.rawValue)
            for key in keys {
                let value = try #require(strings[key], "\(appLocale.rawValue) 缺少 \(key)")
                let source = try #require(english[key])
                #expect(!value.isEmpty)
                #expect(value != key)
                #expect(try placeholders(value) == placeholders(source), "\(appLocale.rawValue): \(key)")
                if appLocale != .english {
                    #expect(value != source, "\(appLocale.rawValue) 不能复制英语兜底：\(key)")
                }
            }
        }
    }

    /// 与 API 解码模型一致地构造检查项，不更改生产数据模型或评分规则。
    private func makeCheck(score: Double, reason: String?) -> OpenSSFScoreCheck {
        OpenSSFScoreCheck(name: "Branch-Protection", score: score, reason: reason, details: nil, documentation: nil)
    }

    /// 直接访问指定 .lproj 文件，不调用会自动回退到英语的 Bundle 查表接口。
    private func compiledStrings(locale: String) throws -> [String: String] {
        let resources = try #require(Bundle.main.resourceURL)
        let url = resources.appendingPathComponent("\(locale).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        )
    }

    /// 参数编号决定各语言语序；比较完整占位符，禁止丢参、重复或改类型。
    private func placeholders(_ value: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: #"%[0-9]+\$@"#)
        return expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }.sorted()
    }
}
