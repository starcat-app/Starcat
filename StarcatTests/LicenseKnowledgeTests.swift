//
//  LicenseKnowledgeTests.swift
//  StarcatTests
//
//  License 胶囊 / 说明卡的契约测试：
//  ① SPDX 解析与归类与 2026-11-01 值域普查对齐；② 归一口径与 RepoLicenseFilter 一致；
//  ③ 卡条目数量声明（cardSpecs）与 Localizable.xcstrings 中英文案一一对应——
//  这条是 xcstrings「仅按行插入」流程的安全网，缺 key / 漏语言会在这里红。
//

import Foundation
import Testing
@testable import Starcat

@Suite("LicenseKnowledge")
struct LicenseKnowledgeTests {

    // MARK: - 类别映射

    @Test("第一版卡集按义务类别正确归类")
    func categoryMapping() {
        let permissive = [
            "MIT", "mit license", "  MIT  ", "Apache-2.0", "apache license 2.0",
            "BSD-2-Clause", "BSD-3-Clause", "ISC", "CC0-1.0", "Unlicense",
            "The Unlicense", "0BSD", "WTFPL", "MIT-0", "Zlib", "BSL-1.0",
        ]
        for id in permissive {
            guard case .known(let entry) = LicenseKnowledge.resolve(id) else {
                Issue.record("expected known for \(id)")
                continue
            }
            #expect(entry.category == .permissive, "\(id) should be permissive")
        }
        for id in ["MPL-2.0", "LGPL-2.0", "LGPL-2.1", "LGPL-3.0"] {
            guard case .known(let entry) = LicenseKnowledge.resolve(id) else {
                Issue.record("expected known for \(id)")
                continue
            }
            #expect(entry.category == .weakCopyleft, "\(id) should be weak copyleft")
        }
        for id in ["GPL-2.0", "GPL-3.0"] {
            guard case .known(let entry) = LicenseKnowledge.resolve(id) else {
                Issue.record("expected known for \(id)")
                continue
            }
            #expect(entry.category == .strongCopyleft, "\(id) should be strong copyleft")
        }
        guard case .known(let entry) = LicenseKnowledge.resolve("AGPL-3.0") else {
            Issue.record("expected known for AGPL-3.0")
            return
        }
        #expect(entry.category == .networkCopyleft)
    }

    @Test("SPDX 变体归一：-only / -or-later 后缀、大小写与已知别名")
    func normalization() {
        // GitHub 用旧式 id，自建源可能带新式后缀，两者必须指向同一张卡。
        for variant in ["GPL-3.0-only", "gpl-3.0-or-later", "GPL-3.0"] {
            guard case .known(let entry) = LicenseKnowledge.resolve(variant) else {
                Issue.record("expected known for \(variant)")
                continue
            }
            #expect(entry.displayName == "GPL-3.0")
        }
        guard case .known(let lgpl) = LicenseKnowledge.resolve("LGPL-2.1-only") else {
            Issue.record("expected known for LGPL-2.1-only")
            return
        }
        #expect(lgpl.displayName == "LGPL-2.1")
        // 别名表与 RepoLicenseFilter 对齐；大小写无关。
        for variant in ["MIT License", "mit license", "MIT"] {
            guard case .known(let entry) = LicenseKnowledge.resolve(variant) else {
                Issue.record("expected known for \(variant)")
                continue
            }
            #expect(entry.displayName == "MIT")
        }
    }

    @Test("待确认兜底：缺失、NOASSERTION、Other 与未收录许可证")
    func unknownFallbacks() {
        for value: String? in [nil, "", "   ", "\t\n"] {
            guard case .unknown(let raw) = LicenseKnowledge.resolve(value) else {
                Issue.record("expected unknown for \(value ?? "nil")")
                continue
            }
            #expect(raw == nil, "empty input should keep raw nil")
        }
        for value in ["NOASSERTION", "noassertion", "Other", "LicenseRef-Custom", "EPL-2.0", "MulanPSL-2.0", "CC-BY-SA-4.0"] {
            guard case .unknown(let raw) = LicenseKnowledge.resolve(value) else {
                Issue.record("expected unknown for \(value)")
                continue
            }
            #expect(raw == value, "raw value should be preserved for display")
        }
    }

    @Test("多重许可表达式：OR / AND / WITH 不取单一类别")
    func multiLicenseExpressions() {
        for expression in [
            "MIT OR Apache-2.0",
            "MIT AND CC-BY-4.0",
            "GPL-2.0 WITH Classpath-exception-2.0",
            "(MIT OR Apache-2.0) AND (LGPL-2.1-or-later OR GPL-3.0-or-later)",
            "mit or apache-2.0",
        ] {
            guard case .multiLicense(let expression) = LicenseKnowledge.resolve(expression) else {
                Issue.record("expected multiLicense for \(expression)")
                continue
            }
        }
    }

    @Test("本地值域普查样本全部有归类（含按设计落入待确认的值）")
    func valueDomainCoverage() {
        // 2026-11-01 对本地 5 张表的普查结果：每个值都必须落到三类之一，
        // 不允许解析失败或崩溃。
        let samples = [
            "MIT", "Apache-2.0", "NOASSERTION", "GPL-3.0", "AGPL-3.0", "GPL-2.0",
            "BSD-3-Clause", "CC0-1.0", "LGPL-3.0", "BSD-2-Clause", "CC-BY-SA-4.0",
            "MPL-2.0", "WTFPL", "Unlicense", "LGPL-2.1", "CC-BY-4.0", "ISC",
            "MulanPSL-2.0", "EPL-2.0", "EPL-1.0", "Artistic-2.0", "OFL-1.1",
            "0BSD", "EUPL-1.2", "Zlib", "PostgreSQL", "MIT-0", "CERN-OHL-P-2.0",
            "BlueOak-1.0.0", "BSL-1.0",
        ]
        for sample in samples {
            let resolution = LicenseKnowledge.resolve(sample)
            switch resolution {
            case .known, .multiLicense, .unknown:
                continue // 归到哪一类由上面的专项测试保证；这里保证"有归类"。
            }
        }
    }

    @Test("choosealicense 参考链接：除 LGPL-2.0 外全部可用")
    func referenceURLs() {
        let knownIds = [
            "MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC",
            "CC0-1.0", "Unlicense", "0BSD", "WTFPL", "MIT-0", "Zlib", "BSL-1.0",
            "MPL-2.0", "LGPL-2.0", "LGPL-2.1", "LGPL-3.0",
            "GPL-2.0", "GPL-3.0", "AGPL-3.0",
        ]
        for id in knownIds {
            guard case .known(let entry) = LicenseKnowledge.resolve(id) else {
                Issue.record("expected known for \(id)")
                continue
            }
            if id == "LGPL-2.0" {
                // choosealicense.com 没有 LGPL-2.0 页面，链接必须为 nil。
                #expect(entry.referenceURL == nil)
                continue
            }
            guard let url = entry.referenceURL else {
                Issue.record("missing referenceURL for \(id)")
                continue
            }
            #expect(url.host == "choosealicense.com")
            // 用 absoluteString 而不是 path：新版 Foundation 的 url.path 会丢尾部斜杠，
            // 而尾部斜杠对 choosealicense 的真实请求语义有意义。
            #expect(url.absoluteString == "https://choosealicense.com/licenses/\(id.lowercased())/")
        }
    }

    // MARK: - 卡文案与 spec 的一致性

    /// 从 App bundle 的指定语言 lproj 里查 key；查不到时返回 sentinel。
    private func lookup(_ bundle: Bundle?, key: String) -> String {
        bundle?.localizedString(forKey: key, value: "##missing##", table: nil) ?? "##missing##"
    }

    @Test("cardSpecs 声明的每个 key 在中英文 Catalog 中都存在")
    func cardSpecLocalizationCoverage() {
        let appBundle = Bundle.main
        let en = appBundle.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
        let zhHans = appBundle.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:))
        #expect(en != nil, "en.lproj should exist in app bundle")
        #expect(zhHans != nil, "zh-Hans.lproj should exist in app bundle")

        for (contentKey, spec) in LicenseKnowledgePopoverContent.cardSpecs {
            var keys: [String] = ["license.card.\(contentKey).conclusion"]
            // multi / unknown 的标题来自原始数据，没有 title key。
            if contentKey != "multi" && contentKey != "unknown" {
                keys.append("license.card.\(contentKey).title")
            }
            for i in 0..<spec[.can]! { keys.append("license.card.\(contentKey).can.\(i)") }
            for i in 0..<spec[.must]! { keys.append("license.card.\(contentKey).must.\(i)") }
            for i in 0..<spec[.watch]! { keys.append("license.card.\(contentKey).watch.\(i)") }

            for key in keys {
                #expect(lookup(en, key: key) != "##missing##", "missing en value: \(key)")
                #expect(lookup(zhHans, key: key) != "##missing##", "missing zh-Hans value: \(key)")
            }
        }
    }

    @Test("类别标签与兜底文案在中英文 Catalog 中都存在")
    func infraLocalizationCoverage() {
        let appBundle = Bundle.main
        let en = appBundle.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
        let zhHans = appBundle.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:))
        let keys = [
            "license.capsule.help",
            "license.generic.name",
            "license.card.action.viewLicense",
            "license.card.action.learnMore",
            "license.card.section.can",
            "license.card.section.must",
            "license.card.section.watch",
            "license.category.permissive",
            "license.category.weakCopyleft",
            "license.category.strongCopyleft",
            "license.category.networkCopyleft",
            "license.category.multiLicense",
            "license.category.unknown",
            "license.category.full.permissive",
            "license.category.full.weakCopyleft",
            "license.category.full.strongCopyleft",
            "license.category.full.networkCopyleft",
            "license.category.full.multiLicense",
            "license.category.full.unknown",
        ]
        for key in keys {
            #expect(lookup(en, key: key) != "##missing##", "missing en value: \(key)")
            #expect(lookup(zhHans, key: key) != "##missing##", "missing zh-Hans value: \(key)")
        }
    }
}
