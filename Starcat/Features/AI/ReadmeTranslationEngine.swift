//
//  ReadmeTranslationEngine.swift
//  Starcat
//
//  README 运行时翻译引擎（与「在哪里配置」解耦）。
//
//  为什么独立枚举：
//  - 详情页菜单要聚合「系统 / AI」等当前可用引擎，切换写回设置；
//  - AI 的 Provider/Prompt 仍在 AI 设置；系统与外接 MT 在「翻译服务」设置；
//  - 磁盘缓存必须按引擎隔离，避免 AI 译文与系统译文互相覆盖。
//

import Foundation

/// README（及复用同一套缓存协议的通知翻译）选用的翻译引擎。
enum ReadmeTranslationEngine: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Apple Translation 框架（本机）。
    case system
    /// 现有 AI 翻译任务（配置在 AI 设置）。
    case ai
    // 二期：google / aliyun / baidu

    var id: String { rawValue }

    /// 设置 / 菜单显示用本地化 key。
    var displayNameKey: String {
        switch self {
        case .system: return "readme.translate.engine.system"
        case .ai: return "readme.translate.engine.ai"
        }
    }

    /// 菜单 SF Symbol。
    var systemImage: String {
        switch self {
        case .system: return "laptopcomputer"
        case .ai: return "sparkles"
        }
    }

    /// 写入 `ReadmeTranslation.model` 的稳定前缀，便于日志与缓存排查。
    var cacheModelToken: String {
        switch self {
        case .system: return "system"
        case .ai: return "ai"
        }
    }

    /// 磁盘文件名附加段。AI 保持历史无后缀，避免已有缓存全部失效。
    var cacheFileInfix: String {
        switch self {
        case .ai: return ""
        case .system: return ".system"
        }
    }
}
