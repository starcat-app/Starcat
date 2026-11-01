//
//  AIOrganizationBannerTests.swift
//  StarcatTests
//
//  后台任务入口的状态语义与多语言窄宽布局；离屏测量，不创建窗口或操作桌面。
//

import SwiftUI
import Testing
@testable import Starcat

/// 文案长度、计数和阶段切换不能改变横幅高度，所有入口必须仍在可用宽度内。
@MainActor
@Suite("AI organization banner")
struct AIOrganizationBannerTests {
    private static let states: [AIOrganizationBannerState] = [
        .idle, .preparing, .analyzing(processed: 0, total: 1_496), .analyzing(processed: 1_495, total: 1_496),
        .applying(processed: 0, total: 0), .applying(processed: 0, total: 149), .applying(processed: 148, total: 149),
        .paused(processed: 500, total: 1_496), .review(count: 149), .review(count: 0), .failed(count: 3), .failed(count: 0)
    ]

    @Test("已有任务只提供重开入口，不能再次开始整理")
    func actionSemantics() {
        #expect(AIOrganizationBannerState.idle.actionKey == "batchAI.banner.start")
        for state in Self.states where state != .idle {
            #expect(state.actionKey != "batchAI.banner.start")
        }
        #expect(AIOrganizationBannerState.applying(processed: 53, total: 149).actionKey == "batchAI.banner.viewProgress")
        #expect(AIOrganizationBannerState.paused(processed: 53, total: 149).actionKey == "aiOrganization.banner.viewTask")
        #expect(AIOrganizationBannerState.review(count: 149).actionKey == "aiOrganization.banner.viewResults")
    }

    @Test("缺译时使用英语源文案，已有翻译不被覆盖")
    func missingTranslationUsesSource() {
        let key = "aiOrganization.banner.applyingGroups"
        #expect(AIOrganizationBannerText.resolve(key, for: key) == "Applying groups")
        #expect(AIOrganizationBannerText.resolve("Gruppen werden angewendet", for: key) == "Gruppen werden angewendet")
    }

    @Test("每个支持语言的编译资源都直接包含完整译文", arguments: AppLocale.allCases.filter { $0 != .system })
    func compiledTranslationsAreComplete(appLocale: AppLocale) throws {
        let source = try stringsTable(for: .english)
        let target = try stringsTable(for: appLocale)
        let keys = source.keys.filter { $0.hasPrefix("aiOrganization.banner.") }
        #expect(!keys.isEmpty)
        for key in keys {
            let translated = try #require(target[key], "\(appLocale.rawValue) 缺少 \(key)，不能靠英语回退通过检查")
            let original = try #require(source[key])
            #expect(!translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(translated != key)
            #expect(!translated.contains("\n") && !translated.contains("\r"))
            if appLocale != .english { #expect(translated != original) }
            #expect(try formatPlaceholders(in: translated) == formatPlaceholders(in: original))
        }
    }

    @Test("全部支持语言、宽窄中栏和计数变化仍保持单行固定高度", arguments: AppLocale.allCases.filter { $0 != .system }, [CGFloat(240), 320, 480, 840])
    func localizedLayoutStaysBounded(appLocale: AppLocale, width: CGFloat) throws {
        // String.l10n 读取持久化的应用语言，单独注入 SwiftUI locale 只会改变数字与布局方向。
        // 同步主线程测量期间设置并恢复原值，确保实际测量目标语言，且不遗留语言偏好。
        let defaults = UserDefaults.standard
        let previousLocale = defaults.string(forKey: "AppLocaleOverride")
        defaults.set(appLocale.rawValue, forKey: "AppLocaleOverride")
        defer {
            if let previousLocale {
                defaults.set(previousLocale, forKey: "AppLocaleOverride")
            } else {
                defaults.removeObject(forKey: "AppLocaleOverride")
            }
        }
        for scale in InterfaceScale.allCases {
            for kind in [AIOrganizationBanner.Kind.grouping, .tags] {
                let baseline = try measuredSize(kind: kind, state: .idle, appLocale: appLocale, scale: scale, width: width)
                for state in Self.states {
                    let size = try measuredSize(kind: kind, state: state, appLocale: appLocale, scale: scale, width: width)
                    #expect(size.width <= width)
                    #expect(size.height == baseline.height)
                }
            }
        }
    }

    /// 十位仓库数覆盖长数字；减少动态效果后只验证布局，不把动画帧当验收截图。
    private func measuredSize(kind: AIOrganizationBanner.Kind, state: AIOrganizationBannerState,
                              appLocale: AppLocale, scale: InterfaceScale, width: CGFloat) throws -> CGSize {
        let renderer = ImageRenderer(content: AIOrganizationBanner(
            kind: kind, repositoryCount: 2_000_000_000, state: state, canStart: false,
            onStart: {}, onShowPanel: {}
        ).environment(\.locale, appLocale.effectiveLocale)
            .environment(\.starcatInterfaceScale, scale)
            .environment(\.starcatReduceMotion, true))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try #require(renderer.nsImage).size
    }

    /// 直接读指定 lproj 的产物，不能用 Bundle 查表 API 自动回退英语来掩盖缺译。
    private func stringsTable(for appLocale: AppLocale) throws -> [String: String] {
        let resources = try #require(Bundle.main.resourceURL)
        let url = resources.appendingPathComponent("\(appLocale.rawValue).lproj/Localizable.strings")
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(value as? [String: String])
    }

    /// 本组文案仅含 %@；允许参数调整语序，但编号、类型与重复次数必须与源文案一致。
    private func formatPlaceholders(in value: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: #"%(?:\d+\$)?@"#)
        let string = value as NSString
        return expression.matches(in: value, range: NSRange(location: 0, length: string.length))
            .map { string.substring(with: $0.range) }.sorted()
    }
}
