//
//  WidgetSharedConfiguration.swift
//  Starcat
//
//  App 与 Widget Extension 共用的 App Group 配置解析。
//

import Foundation

/// 共享容器配置错误。
enum WidgetSharedConfigurationError: Error, Equatable, LocalizedError {
    case missingAppGroupIdentifier
    case invalidAppGroupIdentifier(String)
    case containerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingAppGroupIdentifier:
            return "Missing STARCAT_WIDGET_APP_GROUP in Info.plist"
        case .invalidAppGroupIdentifier(let identifier):
            return "Invalid Widget App Group identifier: \(identifier)"
        case .containerUnavailable(let identifier):
            return "Widget App Group container is unavailable: \(identifier)"
        }
    }
}

/// 解析 target 注入的共享容器标识和固定文件布局。
///
/// Store / Direct 使用不同 Info.plist 值；禁止按 bundle id 拼接，避免渠道增加或
/// bundle id 调整后静默落到错误容器。
enum WidgetSharedConfiguration {
    static let appGroupInfoKey = "STARCAT_WIDGET_APP_GROUP"
    static let snapshotFileName = "widget-snapshot-v1.json"
    static let avatarsDirectoryName = "avatars"

    static func appGroupIdentifier(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) throws -> String {
        guard let rawValue = infoDictionary?[appGroupInfoKey] as? String,
              !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WidgetSharedConfigurationError.missingAppGroupIdentifier
        }

        let identifier = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.hasPrefix("group.com.starcat.app."),
              identifier.hasSuffix(".widgets") else {
            throw WidgetSharedConfigurationError.invalidAppGroupIdentifier(identifier)
        }
        return identifier
    }

    static func containerURL(
        groupIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let url = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        ) else {
            throw WidgetSharedConfigurationError.containerUnavailable(groupIdentifier)
        }
        return url
    }

    static func snapshotURL(containerURL: URL) -> URL {
        containerURL.appendingPathComponent(snapshotFileName, isDirectory: false)
    }

    static func avatarsDirectoryURL(containerURL: URL) -> URL {
        containerURL.appendingPathComponent(avatarsDirectoryName, isDirectory: true)
    }
}
