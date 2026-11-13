//
//  SearchContentPolicy.swift
//  Starcat
//
//  Search Center 专属的离线展示策略。规则不可变且只加载一次，不修改收藏数据，
//  也不把危险对象词本身当成禁止条件；所有命中都可以追溯到规则 ID。
//

import Foundation

/// 只接收搜索已经取得的公开元数据，不读取用户笔记或为了过滤额外抓取正文。
struct SearchContentDocument: Sendable {
    enum Field: String, Codable, Sendable {
        case query, title, description, topic
    }

    let id: String
    var repositoryFullName: String? = nil
    var repositoryID: Int64? = nil
    var urls: [URL] = []
    var fields: [Field: [String]] = [:]
}

/// 诊断只保留规则和类别，不保留命中的原文。
struct SearchContentMatch: Equatable, Hashable, Sendable {
    let ruleID: String
    let category: String
}

/// 身份集合使跨来源、分页和缓存重复评估不会重复增加统计。
struct SearchContentSummary: Equatable, Sendable {
    var checkedIDs: Set<String> = []
    var blockedIDs: Set<String> = []
    var ruleIDs: Set<String> = []
    var categories: Set<String> = []

    var checkedCount: Int { checkedIDs.count }
    var hiddenCount: Int { blockedIDs.count }
    var retainedCount: Int { checkedIDs.subtracting(blockedIDs).count }

    mutating func record(_ document: SearchContentDocument, match: SearchContentMatch?) {
        checkedIDs.insert(document.id)
        if let match {
            blockedIDs.insert(document.id)
            ruleIDs.insert(match.ruleID)
            categories.insert(match.category)
        }
    }

    mutating func formUnion(_ other: Self) {
        checkedIDs.formUnion(other.checkedIDs)
        blockedIDs.formUnion(other.blockedIDs)
        ruleIDs.formUnion(other.ruleIDs)
        categories.formUnion(other.categories)
    }
}

/// 纯值类型策略可由普通搜索与智能发现共享；正常路径没有网络、锁或逐结果编译。
struct SearchContentPolicy: Sendable {
    private struct IdentityRule: Decodable, Sendable {
        let id: String
        let category: String
        let fullName: String
        let githubID: Int64?
    }

    private struct DomainRule: Decodable, Sendable {
        let id: String
        let category: String
        let domain: String
    }

    private struct Rule: Decodable, Sendable {
        let id: String
        let category: String
        let fields: [SearchContentDocument.Field]
        var terms: [String]
        var actions: [String]
        var exceptions: [String]
    }

    private struct Ruleset: Decodable {
        let version: String
        let repositories: [IdentityRule]
        let domains: [DomainRule]
        let rules: [Rule]
    }

    /// 归一化后的纯 ASCII 文本不可能命中非 ASCII 词，加载时预选以减少热态探测。
    private struct PreparedRule: Sendable {
        let rule: Rule
        let asciiTerms: [String]
    }

    enum RulesetError: Error {
        case invalid
    }

    let version: String
    private let repositories: [String: SearchContentMatch]
    private let repositoryIDs: [Int64: SearchContentMatch]
    private let domains: [String: SearchContentMatch]
    private let rulesByField: [SearchContentDocument.Field: [PreparedRule]]
    private static let fieldOrder: [SearchContentDocument.Field] = [.query, .title, .description, .topic]
    private static let locale = Locale(identifier: "en_US_POSIX")
    private static let clauseSeparators = CharacterSet(charactersIn: ".。;；!?！？\n\r,，")

    /// 缺少或损坏随包规则属于构建错误；测试与双渠道资源检查必须在交付前发现。
    static let bundled: Self = {
        guard let url = Bundle.main.url(forResource: "SearchContentRules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let policy = try? Self(data: data) else {
            preconditionFailure("Bundled SearchContentRules.json is missing or invalid")
        }
        return policy
    }()

    /// 初始化时校验并归一化规则，查询时只做确定性匹配。
    init(data: Data) throws {
        let decoded = try JSONDecoder().decode(Ruleset.self, from: data)
        let ids = decoded.repositories.map(\.id) + decoded.domains.map(\.id) + decoded.rules.map(\.id)
        guard !decoded.version.isEmpty, ids.allSatisfy({ !$0.isEmpty }),
              Set(ids).count == ids.count,
              decoded.rules.allSatisfy({ !$0.terms.isEmpty && !$0.fields.isEmpty
                  && ($0.terms + $0.actions + $0.exceptions).allSatisfy({ !$0.isEmpty }) }),
              Set(decoded.repositories.map { $0.fullName.lowercased() }).count == decoded.repositories.count,
              Set(decoded.repositories.compactMap(\.githubID)).count == decoded.repositories.compactMap(\.githubID).count,
              Set(decoded.domains.map { $0.domain.lowercased() }).count == decoded.domains.count else {
            throw RulesetError.invalid
        }
        version = decoded.version
        repositories = Dictionary(uniqueKeysWithValues: decoded.repositories.map {
            ($0.fullName.lowercased(), SearchContentMatch(ruleID: $0.id, category: $0.category))
        })
        repositoryIDs = Dictionary(uniqueKeysWithValues: decoded.repositories.compactMap { rule in
            rule.githubID.map { ($0, SearchContentMatch(ruleID: rule.id, category: rule.category)) }
        })
        domains = Dictionary(uniqueKeysWithValues: decoded.domains.map {
            ($0.domain.lowercased(), SearchContentMatch(ruleID: $0.id, category: $0.category))
        })
        let preparedRules = decoded.rules.map { original in
            var rule = original
            rule.terms = original.terms.map(Self.normalized)
            rule.actions = original.actions.map(Self.normalized)
            rule.exceptions = original.exceptions.map(Self.normalized)
            return PreparedRule(rule: rule, asciiTerms: rule.terms.filter {
                $0.utf8.allSatisfy({ $0 < 128 })
            })
        }
        rulesByField = Dictionary(uniqueKeysWithValues: Self.fieldOrder.map { field in
            (field, preparedRules.filter { $0.rule.fields.contains(field) })
        })
    }

    func match(query: String) -> SearchContentMatch? {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = value.hasPrefix("repo:") ? String(value.dropFirst(5)) : value
        return match(SearchContentDocument(
            id: "query",
            repositoryFullName: name,
            urls: URL(string: value).map { [$0] } ?? [],
            fields: [.query: [value]]
        ))
    }

    /// 精确对象优先。文本按字段独立评估，禁止把标题与描述拼出不存在的交易意图。
    func match(_ document: SearchContentDocument) -> SearchContentMatch? {
        if let id = document.repositoryID, let match = repositoryIDs[id] { return match }
        if let name = document.repositoryFullName?.lowercased(), let match = repositories[name] { return match }
        for url in document.urls {
            if let name = Self.repositoryName(from: url), let match = repositories[name] { return match }
            if let host = url.host?.lowercased() {
                for (domain, match) in domains where host == domain || host.hasSuffix("." + domain) {
                    return match
                }
            }
        }
        // 固定字段优先级令命中解释可复现；适用规则在加载时分组，避免每条重复分配。
        for field in Self.fieldOrder {
            guard let values = document.fields[field], let applicable = rulesByField[field] else { continue }
            for value in values {
                // 描述通常只有数百字符；异常巨量文本不应占住输入响应线程。
                // 仅取连续前缀，不能将头尾拼接后制造原文不存在的命中。
                let text = Self.normalized(String(value.prefix(4_096)))
                let searchable = text as NSString
                let isASCII = text.utf8.allSatisfy({ $0 < 128 })
                for prepared in applicable {
                    let rule = prepared.rule
                    let terms = isASCII ? prepared.asciiTerms : rule.terms
                    // 两边已经做过相同的 Unicode 归一化。逐词重复进行规范等价搜索
                    // 会放大整批耗时；literal 保留归一化后的语义并避开重复转换。
                    guard terms.contains(where: {
                        searchable.range(of: $0, options: .literal).location != NSNotFound
                    }) else { continue }
                    let fragments = rule.actions.isEmpty
                        ? [text] : text.components(separatedBy: Self.clauseSeparators)
                    if fragments.contains(where: { Self.matches(rule, in: $0) }) {
                        return SearchContentMatch(ruleID: rule.id, category: rule.category)
                    }
                }
            }
        }
        return nil
    }

    static func repositoryKey(_ fullName: String) -> String {
        "repo:" + fullName.lowercased()
    }

    static func referenceKey(_ url: URL) -> String {
        repositoryName(from: url).map(repositoryKey) ?? "url:" + url.absoluteString
    }

    /// 仅解析真实 GitHub 主机；网页中的 github.com 字样、相似域名都不能冒充仓库。
    static func repositoryName(from url: URL) -> String? {
        guard let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let reserved: Set<String> = ["search", "topics", "collections", "orgs", "users", "settings", "login"]
        guard !reserved.contains(parts[0].lowercased()) else { return nil }
        var name = String(parts[1]).lowercased()
        if name.hasSuffix(".git") { name.removeLast(4) }
        return "\(parts[0].lowercased())/\(name)"
    }

    /// 局部例外必须覆盖这一次命中的完整范围；其他位置的“研究/公益”不能全局放行。
    private static func matches(_ rule: Rule, in text: String) -> Bool {
        let exceptions = rule.exceptions.flatMap { occurrences(of: $0, in: text) }
        let subjects = rule.terms.flatMap { occurrences(of: $0, in: text) }
        let actions = rule.actions.flatMap { occurrences(of: $0, in: text) }
        for subject in subjects {
            let ranges = rule.actions.isEmpty ? [subject] : actions.compactMap { action -> NSRange? in
                let union = NSUnionRange(subject, action)
                // 限制两个词的距离，避免同一长段里无关的对象与动作相互污染。
                return union.length - subject.length - action.length <= 48 ? union : nil
            }
            if ranges.contains(where: { range in
                !exceptions.contains { NSIntersectionRange($0, range) == range }
            }) { return true }
        }
        return false
    }

    private static func occurrences(of term: String, in text: String) -> [NSRange] {
        var result: [NSRange] = []
        var start = text.startIndex
        let needsBoundary = term.unicodeScalars.contains(where: isASCIIWord)
        while start < text.endIndex,
              let range = text.range(of: term, options: .literal, range: start..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)].asciiValue
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound].asciiValue
            if !needsBoundary || (!isASCIIWord(before) && !isASCIIWord(after)) {
                result.append(NSRange(range, in: text))
            }
            start = range.upperBound
        }
        return result
    }

    private static func isASCIIWord(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIWord(UInt8(exactly: scalar.value))
    }

    private static func isASCIIWord(_ value: UInt8?) -> Bool {
        guard let value else { return false }
        return (97...122).contains(value) || (65...90).contains(value) || (48...57).contains(value)
    }

    /// ASCII 快速路径避免正常英文仓库描述触发 ICU 全文转换。
    /// 零宽字符可移除；空格/横线只在两侧均为汉字时折叠，英文边界始终保留。
    private static func normalized(_ input: String) -> String {
        if input.utf8.allSatisfy({ $0 < 128 }) {
            // ASCII 不需要逐字符查询 Unicode 属性，但仍须保留原有的大小写与
            // 分隔符归一化，不能用“直接返回”破坏 Falun-Gong 等变体的匹配。
            var bytes: [UInt8] = []
            bytes.reserveCapacity(input.utf8.count)
            var pendingSpace = false
            for byte in input.utf8 {
                if byte == 32 || byte == 9 || byte == 45 || byte == 95 {
                    pendingSpace = !bytes.isEmpty
                    continue
                }
                if pendingSpace { bytes.append(32) }
                pendingSpace = false
                bytes.append((65...90).contains(byte) ? byte + 32 : byte)
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        let value = input.precomposedStringWithCompatibilityMapping.lowercased(with: locale)
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        var previousWasHan = false
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF: continue
            default: break
            }
            if scalar == " " || scalar == "\t" || scalar == "_" || scalar == "-" || scalar == "·" {
                pendingSpace = !result.isEmpty
                continue
            }
            let isHan = scalar.properties.isIdeographic
            if pendingSpace && !(previousWasHan && isHan) { result.append(" ") }
            pendingSpace = false
            result.append(scalar)
            previousWasHan = isHan
        }
        return String(result)
    }
}
