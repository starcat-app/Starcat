//
//  WeeklySourcePresentation.swift
//  Starcat
//
//  Weekly 来源的展示解析器。wire model 只保存稳定 source_code；文案、asset 和
//  SF Symbol fallback 统一在这里解析，避免每增加一个来源就污染网络 DTO。
//

import Foundation

/// Weekly 来源的本地展示信息。
struct WeeklySourcePresentation: Sendable {
    let source: WeeklySource

    var displayName: String {
        switch source.rawValue {
        case WeeklySource.weekly.rawValue: return String.l10n("weekly.source.ruanyf")
        case WeeklySource.zread.rawValue: return "ZRead"
        case WeeklySource.discovery.rawValue: return "Hacker News"
        case WeeklySource.helloGitHub.rawValue: return "HelloGitHub"
        case WeeklySource.aiIntelligence.rawValue: return String.l10n("weekly.source.aiIntelligence")
        default: return source.rawValue
        }
    }

    /// 有许可来源使用本地 asset；HelloGitHub / AI 情报首版使用 SF Symbol，
    /// 避免在未核实品牌素材许可前复制远程图片。
    var assetName: String? {
        switch source.rawValue {
        case WeeklySource.weekly.rawValue: return "WeeklySources/ruanyf"
        case WeeklySource.zread.rawValue: return "WeeklySources/weekly-zread"
        case WeeklySource.discovery.rawValue: return "WeeklySources/hackernews"
        default: return nil
        }
    }

    var systemImage: String {
        switch source.rawValue {
        case WeeklySource.helloGitHub.rawValue: return "shippingbox.fill"
        case WeeklySource.aiIntelligence.rawValue: return "sparkles"
        default: return "questionmark.circle.fill"
        }
    }

    /// 服务端目录同时返回中英文文案；按 Starcat 应用语言选择，不能使用只代表
    /// 系统语言的 Locale.current，否则设置页强制语言后筛选项不会同步切换。
    static func localizedServerTitle(chinese: String, english: String) -> String {
        switch UserDefaults.standard.string(forKey: "AppLocaleOverride") ?? "system" {
        case "zh-Hans": return chinese
        case "en": return english
        default:
            return Locale.autoupdatingCurrent.language.languageCode?.identifier == "zh" ? chinese : english
        }
    }
}

extension WeeklySource {
    var presentation: WeeklySourcePresentation {
        WeeklySourcePresentation(source: self)
    }
}

extension WeeklySourceDescriptor {
    var localizedTitle: String {
        WeeklySourcePresentation.localizedServerTitle(chinese: displayNameZH, english: displayNameEN)
    }
}
