//
//  OpenSSFCheckLocalization.swift
//  Starcat
//
//  将 OpenSSF 的稳定检查标识和已知英文结论映射到显示文案。
//  原始 API 内容仍用于身份、缓存与评分；只翻译完整匹配的结论，避免误译安全事实。
//

import Foundation

/// Sheet 与雷达图共用的无状态显示映射；每次查表，语言切换不会复用旧译文。
enum OpenSSFCheckLocalization {
    /// 读取失败不能进入原文兜底；正常结论仍区分译文与可查证的上游原文。
    enum CheckReason: Equatable {
        case unavailable
        case localized(String)
        case original(String)
    }

    private static let nameKeys: [String: String] = [
        "Binary-Artifacts": "binaryArtifacts",
        "Branch-Protection": "branchProtection",
        "CI-Tests": "ciTests",
        "CII-Best-Practices": "bestPractices",
        "Code-Review": "codeReview",
        "Contributors": "contributors",
        "Dangerous-Workflow": "dangerousWorkflow",
        "Dependency-Update-Tool": "dependencyUpdate",
        "Fuzzing": "fuzzing",
        "License": "license",
        "Maintained": "maintained",
        "Packaging": "packaging",
        "Pinned-Dependencies": "pinnedDependencies",
        "SAST": "sast",
        "SBOM": "sbom",
        "Security-Policy": "securityPolicy",
        "Signed-Releases": "signedReleases",
        "Token-Permissions": "tokenPermissions",
        "Vulnerabilities": "vulnerabilities",
        "Webhooks": "webhooks",
    ]

    /// 固定句来自 ossf/scorecard 的 checks/evaluation；严格匹配，不按分数推断原因。
    private static let reasonKeys: [String: String] = [
        "no binaries found in the repo": "noBinaries",
        "binaries present in source code": "binariesPresent",
        "branch protection not enabled on development/release branches": "branchesUnprotected",
        "branch protection is fully enabled on development and all release branches": "branchesProtected",
        "branch protection is not maximal on development and all release branches": "branchesPartial",
        "unable to detect any development/release branches": "noBranches",
        "no pull request found": "noPullRequests",
        "no effort to earn an OpenSSF best practices badge detected": "noBadge",
        "badge detected: Gold": "badgeGold",
        "badge detected: Silver": "badgeSilver",
        "badge detected: Passing": "badgePassing",
        "badge detected: InProgress": "badgeInProgress",
        "all changesets reviewed": "allReviewed",
        "no changesets detected": "noChangesets",
        "dangerous workflow patterns detected": "dangerousWorkflows",
        "no dangerous workflow patterns detected": "noDangerousWorkflows",
        "no workflows found": "noWorkflows",
        "update tool detected": "updateTool",
        "no update tool detected": "noUpdateTool",
        "project is fuzzed": "fuzzed",
        "project is not fuzzed": "notFuzzed",
        "license file detected": "license",
        "license file not detected": "noLicense",
        "project is archived": "archived",
        "packaging workflow detected": "packaging",
        "packaging workflow not detected": "noPackaging",
        "all dependencies are pinned": "dependenciesPinned",
        "dependency not pinned by hash detected": "dependenciesUnpinned",
        "no dependencies found": "noDependencies",
        "SAST tool detected": "sastDetected",
        "SAST tool is run on all commits": "sastAllCommits",
        "SAST tool is not run on all commits": "sastPartial",
        "SAST tool detected but not run on all commits": "sastDetectedPartial",
        "SAST tool detected: CodeQL": "sastCodeQL",
        "no SAST tool detected": "noSast",
        "SBOM file not detected": "noSbom",
        "SBOM file found in release artifacts": "sbomRelease",
        "SBOM file found in project": "sbomProject",
        "security policy file detected": "securityPolicy",
        "security policy file not detected": "noSecurityPolicy",
        "no releases found": "noReleases",
        "Project has not signed or included provenance with any releases.": "unsignedReleases",
        "Token permissions are not available": "tokenPermissionsUnavailable",
        "No tokens found": "noTokens",
        "detected GitHub workflow tokens with excessive permissions": "excessivePermissions",
        "GitHub workflow tokens follow principle of least privilege": "leastPrivilege",
        "project does not have webhook": "noWebhooks",
        "no hook(s) have a secret configured": "noWebhookSecrets",
    ]

    /// 模板只捕获十进制数字，路径、URL 或新增语义不会被宽泛的通配符吞掉。
    /// 所有表达式均由本文件定义；初始化失败属于开发错误，不能静默漏译。
    private struct ReasonPattern: Sendable {
        let expression: NSRegularExpression
        let key: String

        init(_ pattern: String, key: String) {
            expression = try! NSRegularExpression(pattern: "\\A(?:\(pattern))\\z")
            self.key = key
        }

        /// 原样提取数字，不做数值转换，保留上游的精度与表示方式。
        func arguments(in source: String) -> [String]? {
            guard let match = expression.firstMatch(
                in: source,
                range: NSRange(source.startIndex..., in: source)
            ) else { return nil }
            return (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: source).map { String(source[$0]) }
            }
        }
    }

    private static let patterns: [ReasonPattern] = [
        ReasonPattern(
            #"([0-9]+) commit\(s\) and ([0-9]+) issue activity found in the last ([0-9]+) days"#,
            key: "activity"
        ),
        ReasonPattern(#"([0-9]+) commits found in the last ([0-9]+) days"#, key: "commits"),
        ReasonPattern(#"Found ([0-9]+)/([0-9]+) approved changesets"#, key: "reviewed"),
        ReasonPattern(
            #"project was created within the last ([0-9]+) days\. Please review its contents carefully"#,
            key: "recentProject"
        ),
        ReasonPattern(#"([0-9]+) out of ([0-9]+) merged PRs checked by a CI test"#, key: "ciTests"),
        ReasonPattern(#"project has ([0-9]+) contributing companies or organizations"#, key: "contributors"),
        ReasonPattern(#"([0-9]+) existing vulnerabilities detected"#, key: "vulnerabilities"),
        ReasonPattern(
            #"([0-9]+) out of the last ([0-9]+) releases have a total of ([0-9]+) signed artifacts\."#,
            key: "signedArtifacts"
        ),
        ReasonPattern(
            #"([0-9]+) out of the last ([0-9]+) releases have a total of ([0-9]+) signed artifacts and ([0-9]+) immutable releases\."#,
            key: "immutableReleases"
        ),
        ReasonPattern(
            #"All ([0-9]+) of the projects webhooks are configured with a secret"#,
            key: "webhookSecrets"
        ),
        ReasonPattern(
            #"([0-9]+) out of the projects ([0-9]+) webhooks are configured without a secret"#,
            key: "webhooksWithoutSecrets"
        ),
    ]

    private static let normalizedScore = ReasonPattern(#"([0-9]+)"#, key: "normalized")

    /// 未知标识原样显示，确保上游新增检查项仍可识别与查证。
    static func name(_ identifier: String, localize: (String) -> String = { String.l10n($0) }) -> String {
        guard let key = nameKeys[identifier] else { return identifier }
        return localize("openssf.checkName.\(key)")
    }

    /// 上游用负分同时表达运行失败和证据不足，不能把所有负分都当成错误。
    /// 保留已知的不适用说明；未评估且无法识别的结论只给友好提示，原始数据仍留在缓存。
    static func reason(
        for check: OpenSSFScoreCheck,
        localize: (String) -> String = { String.l10n($0) }
    ) -> CheckReason? {
        guard let source = check.reason,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return check.isEvaluated ? nil : .unavailable
        }
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("internal error:")
            || normalized == "runtime error"
            || normalized.hasPrefix("runtime error:") {
            return .unavailable
        }
        if let translated = reason(source, localize: localize) {
            return .localized(translated)
        }
        return check.isEvaluated ? .original(source) : .unavailable
    }

    /// 失败页不读取 lastError；success 到达此处代表缓存内容无法解码，也只能提示暂不可用。
    static func statusReason(
        _ status: OpenSSFScoreFetchStatus,
        localize: (String) -> String = { String.l10n($0) }
    ) -> String {
        localize(status == .notIndexed ? "openssf.status.notIndexedHint" : "openssf.status.readFailure")
    }

    /// 返回 nil 表示原文没有完整匹配，由调用方显示「上游原文」标签。
    /// 参数化句与归一化后缀必须同时匹配，禁止只翻译半句后丢掉剩余事实。
    /// 注入查表函数供测试直接读取各语言编译资源，无需改全局语言设置。
    static func reason(_ source: String, localize: (String) -> String = { String.l10n($0) }) -> String? {
        let parts = source.components(separatedBy: " -- score normalized to ")
        guard parts.count <= 2 else { return nil }
        let original = parts[0]
        let translated: String
        if let key = reasonKeys[original] {
            translated = localize("openssf.reason.\(key)")
        } else if let match = patterns.lazy.compactMap({ pattern -> (String, [String])? in
            pattern.arguments(in: original).map { (pattern.key, $0) }
        }).first {
            translated = String(
                format: localize("openssf.reason.\(match.0)"),
                arguments: match.1.map { $0 as CVarArg }
            )
        } else {
            return nil
        }
        guard parts.count == 2 else { return translated }
        guard let score = normalizedScore.arguments(in: parts[1])?.first else { return nil }
        return String(format: localize("openssf.reason.normalized"), translated, score)
    }
}
