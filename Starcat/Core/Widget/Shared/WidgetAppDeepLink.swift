//
//  WidgetAppDeepLink.swift
//  Starcat
//
//  Widget 空态回到主应用的版本化内部路由。
//
//  仓库和 Release 行仍分别使用 RepositoryDeepLink / RepositoryReleaseDeepLink；
//  本文件只处理没有具体数据实体时的“打开主窗口”和“打开 Release 时间线”。
//

import Foundation

enum WidgetAppDestination: String, Equatable, Sendable {
    case main = "open"
    case releaseTimeline = "releases"
    case insights
}

/// 受控的 Widget → Host App 跳转协议。
///
/// 路由严格限制为 `starcat://app/{destination}?v=1`，避免裸 `starcat://` 落入
/// OAuth callback 的兜底解析，也不接受任意外部 URL。
struct WidgetAppDeepLink: Equatable, Sendable {
    let destination: WidgetAppDestination

    init(destination: WidgetAppDestination) {
        self.destination = destination
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "starcat",
              components.host?.lowercased() == "app"
        else { return nil }

        let path = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .compactMap { String($0).removingPercentEncoding }
        guard path.count == 1,
              let destination = WidgetAppDestination(rawValue: path[0])
        else { return nil }

        let queryItems = components.queryItems ?? []
        guard queryItems.count == 1,
              queryItems[0].name == "v",
              queryItems[0].value == "1" else {
            return nil
        }
        self.destination = destination
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "starcat"
        components.host = "app"
        components.path = "/\(destination.rawValue)"
        components.queryItems = [URLQueryItem(name: "v", value: "1")]
        return components.url!
    }
}
