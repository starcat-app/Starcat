//
//  LicenseKnowledge.swift
//  Starcat
//
//  SPDX 标识 → 许可义务类别 + 说明卡的本地静态映射与解析器。
//
//  为什么是静态表：说明卡内容必须人工核对许可证原文后固定下来，绝不能
//  运行时生成或现场"翻译"许可证；这里只做「值 → 类别 / 卡」的确定性解析。
//  数据来源是本地 DB 的 license 字符串（GitHub spdx_id，自建源 license_spdx，
//  可能 fallback 到 license name），值域普查见 2026-11-01 分类设计讨论。
//
//  分类按「义务在什么场景触发」而不是「能否商用」：
//  宽松 / 有限互惠 / 强互惠 / 网络互惠。常见互惠许可证都允许商业使用，
//  说明卡里必须继续写明这一点，避免把互惠档误读成"禁止商用"。
//
//  与 RepoLicenseFilter 的归一口径保持一致（trim / ASCII 小写 / 别名 /
//  NOASSERTION → 未知），两套逻辑不允许各自漂移。
//

import Foundation

/// 许可义务类别；`multiLicense` 是表达式兜底，`unknown` 是识别失败兜底。
enum LicenseCategory: Hashable, Sendable, CaseIterable {
    /// 宽松：MIT / Apache-2.0 / BSD / ISC 及公共领域家族。
    case permissive
    /// 有限互惠：义务只覆盖被许可文件本身或库（MPL / LGPL / EPL 档）。
    case weakCopyleft
    /// 强互惠：分发作品时需按条款提供对应源码（GPL 档）。
    case strongCopyleft
    /// 网络互惠：分发义务之外，网络交互也触发源码义务（AGPL 档）。
    case networkCopyleft
    /// 多重许可：含 OR / AND / WITH 表达式，不取"最严格"颜色，单独解释。
    case multiLicense
    /// 待确认：未识别、自定义、信息缺失。没有明确许可 ≠ 可以默认使用。
    case unknown
}

/// 一张已核对的许可证知识卡：展示标识 + 参考链接 + 义务类别。
struct LicenseKnowledgeEntry: Hashable, Sendable {
    /// SPDX 规范大小写的展示标识（"MIT"、"Apache-2.0"）。
    let displayName: String
    /// 说明卡文案的 key 命名空间（`license.card.<contentKey>.*`）。
    let contentKey: String
    /// choosealicense.com slug；nil 表示没有官方说明页（如 LGPL-2.0）。
    let referenceSlug: String?
    let category: LicenseCategory

    /// 「了解此许可证」的官方参考页。
    var referenceURL: URL? {
        guard let referenceSlug else { return nil }
        return URL(string: "https://choosealicense.com/licenses/\(referenceSlug)/")
    }
}

/// 解析结果：`known` 走彩色分类卡；`multiLicense` / `unknown` 走各自的兜底卡。
enum LicenseKnowledgeResolution: Hashable, Sendable {
    case known(LicenseKnowledgeEntry)
    case multiLicense(expression: String)
    case unknown(raw: String?)
}

enum LicenseKnowledge {

    // MARK: - 对外解析入口

    /// 把数据库里的 license 裸字符串解析成胶囊 / 说明卡需要的一切。
    /// 纯函数、无 IO，方便单测覆盖值域普查出的全部真实样本。
    static func resolve(_ raw: String?) -> LicenseKnowledgeResolution {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return .unknown(raw: nil)
        }
        if trimmed.caseInsensitiveCompare("NOASSERTION") == .orderedSame {
            return .unknown(raw: trimmed)
        }
        if containsLicenseExpression(trimmed) {
            return .multiLicense(expression: trimmed)
        }
        guard let entry = entries[normalizedKey(trimmed)] else {
            return .unknown(raw: trimmed)
        }
        return .known(entry)
    }

    // MARK: - 归一化

    /// ASCII 小写 + 别名 + SPDX 后缀归一；与 RepoLicenseFilter.key 同一口径。
    static func normalizedKey(_ license: String) -> String {
        let trimmed = license.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = String(decoding: trimmed.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
        if lowered.isEmpty || lowered == "noassertion" { return "" }
        return Self.aliases[lowered] ?? stripSPDXSuffixes(lowered)
    }

    /// SPDX 2008 之后的 `-only` / `-or-later` 后缀归一到基础标识：
    /// GitHub 用旧式 "GPL-3.0"，自建源可能带新式后缀，两者指向同一张卡。
    private static func stripSPDXSuffixes(_ key: String) -> String {
        if key.hasSuffix("-or-later") {
            return String(key.dropLast("-or-later".count))
        }
        if key.hasSuffix("-only") {
            return String(key.dropLast("-only".count))
        }
        return key
    }

    /// SPDX 表达式的 OR / AND / WITH 必须是大写操作符（规范要求），
    /// 但为防御自建源写入小写，这里按整词大小写不敏感匹配。
    private static func containsLicenseExpression(_ raw: String) -> Bool {
        let tokens = raw
            .split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" })
            .map { $0.lowercased() }
        return tokens.contains("or") || tokens.contains("and") || tokens.contains("with")
    }

    /// 只收录明确同义的展示名；不猜测 "gpl3" 之类的写法，宁可落到"待确认"。
    private static let aliases: [String: String] = [
        "mit license": "mit",
        "apache license 2.0": "apache-2.0",
        "apache 2.0": "apache-2.0",
        "apache2": "apache-2.0",
        "bsd 2-clause \"simplified\" license": "bsd-2-clause",
        "bsd 3-clause \"new\" or \"revised\" license": "bsd-3-clause",
        "mozilla public license 2.0": "mpl-2.0",
        "the unlicense": "unlicense",
    ]

    // MARK: - 已核对卡集（2026-11-01 与 dong4j 对齐的第一版范围）

    /// 第一版卡集：8 个许可证家族 + 宽松家族扩展（CC0 / Unlicense / 0BSD /
    /// WTFPL / MIT-0 / Zlib / BSL-1.0，值域普查合计 100+ 次出现）。
    /// 之外的已识别许可证（EPL / OSL / EUPL / MulanPSL 等）按设计落入
    /// "待确认"灰色胶囊并保留原文入口，等后续版本补卡。
    private static let entries: [String: LicenseKnowledgeEntry] = [
        // 宽松
        "mit": .init(displayName: "MIT", contentKey: "mit", referenceSlug: "mit", category: .permissive),
        "apache-2.0": .init(displayName: "Apache-2.0", contentKey: "apache-2.0", referenceSlug: "apache-2.0", category: .permissive),
        "bsd-2-clause": .init(displayName: "BSD-2-Clause", contentKey: "bsd-2-clause", referenceSlug: "bsd-2-clause", category: .permissive),
        "bsd-3-clause": .init(displayName: "BSD-3-Clause", contentKey: "bsd-3-clause", referenceSlug: "bsd-3-clause", category: .permissive),
        "isc": .init(displayName: "ISC", contentKey: "isc", referenceSlug: "isc", category: .permissive),
        "cc0-1.0": .init(displayName: "CC0-1.0", contentKey: "cc0-1.0", referenceSlug: "cc0-1.0", category: .permissive),
        "unlicense": .init(displayName: "Unlicense", contentKey: "unlicense", referenceSlug: "unlicense", category: .permissive),
        "0bsd": .init(displayName: "0BSD", contentKey: "0bsd", referenceSlug: "0bsd", category: .permissive),
        "wtfpl": .init(displayName: "WTFPL", contentKey: "wtfpl", referenceSlug: "wtfpl", category: .permissive),
        "mit-0": .init(displayName: "MIT-0", contentKey: "mit-0", referenceSlug: "mit-0", category: .permissive),
        "zlib": .init(displayName: "Zlib", contentKey: "zlib", referenceSlug: "zlib", category: .permissive),
        "bsl-1.0": .init(displayName: "BSL-1.0", contentKey: "bsl-1.0", referenceSlug: "bsl-1.0", category: .permissive),
        // 有限互惠
        "mpl-2.0": .init(displayName: "MPL-2.0", contentKey: "mpl-2.0", referenceSlug: "mpl-2.0", category: .weakCopyleft),
        "lgpl-2.0": .init(displayName: "LGPL-2.0", contentKey: "lgpl-2.0", referenceSlug: nil, category: .weakCopyleft),
        "lgpl-2.1": .init(displayName: "LGPL-2.1", contentKey: "lgpl-2.1", referenceSlug: "lgpl-2.1", category: .weakCopyleft),
        "lgpl-3.0": .init(displayName: "LGPL-3.0", contentKey: "lgpl-3.0", referenceSlug: "lgpl-3.0", category: .weakCopyleft),
        // 强互惠
        "gpl-2.0": .init(displayName: "GPL-2.0", contentKey: "gpl-2.0", referenceSlug: "gpl-2.0", category: .strongCopyleft),
        "gpl-3.0": .init(displayName: "GPL-3.0", contentKey: "gpl-3.0", referenceSlug: "gpl-3.0", category: .strongCopyleft),
        // 网络互惠
        "agpl-3.0": .init(displayName: "AGPL-3.0", contentKey: "agpl-3.0", referenceSlug: "agpl-3.0", category: .networkCopyleft),
    ]
}
