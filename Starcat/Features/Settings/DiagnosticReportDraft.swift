//
//  DiagnosticReportDraft.swift
//  Starcat
//
//  诊断报告的临时线索与时间精度；草稿只随用户主动导出进入本机诊断包。
//

import Foundation

/// 日期线索不改变原有日志选取范围；“今天”保留日精度，不能伪造成午夜发生。
struct DiagnosticReportDraft: Equatable {
    enum TimeChoice: String, CaseIterable, Identifiable {
        case justNow, today, custom
        var id: Self { self }
        var titleKey: String { "diagnostics.report.time.\(rawValue)" }
    }

    /// 分类只表达用户报告的功能，不能作为后台连接测试或业务刷新指令。
    enum Module: String, CaseIterable, Identifiable {
        case unspecified, general, search, ai, translation, rag, agent, browser, mcp, storage, license
        var id: Self { self }

        var titleKey: String {
            switch self {
            case .unspecified: "diagnostics.report.modulePlaceholder"
            case .general: "settings.general.title"
            case .search: "settings.navigation.item.searchIndex"
            case .ai: "settings.models.title"
            case .translation: "settings.navigation.item.translation"
            case .rag: "workspace.rag.title"
            case .agent: "agent.workspace.window.title"
            case .browser: "settings.navigation.item.browserExtensions"
            case .mcp: "settings.mcp.title"
            case .storage: "settings.navigation.item.dataStorage"
            case .license: "settings.navigation.item.proLicense"
            }
        }
    }

    static let descriptionLimit = 2000
    var description = ""
    var module: Module = .unspecified
    var timeChoice: TimeChoice = .justNow
    var customTime = Date()

    /// 时间在点击导出时捕获，“今天”用本机时区的公历日期保存，不提供虚假的时分秒。
    func exportOptions(now: Date = Date(), timeZone: TimeZone = .current) -> DiagnosticExportOptions {
        var options = DiagnosticExportOptions(
            description: String(description.prefix(Self.descriptionLimit)),
            module: module == .unspecified ? "" : module.rawValue
        )
        switch timeChoice {
        case .justNow: options.occurredAt = now
        case .custom: options.occurredAt = customTime
        case .today:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            options.occurredOn = formatter.string(from: now)
        }
        return options
    }
}
