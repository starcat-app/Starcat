//
//  AppStoreUpdateController.swift
//  Starcat
//
//  App Store 分发渠道的版本检测与提示状态协调器。
//

import Foundation
import Observation

/// App Store 上架版本的最小展示模型。
///
/// 更新安装必须继续交给 Mac App Store；客户端只保留版本号和商店跳转地址，
/// 不下载任何可执行文件，也不与 Direct 版的 Sparkle 更新链路交叉。
struct AppStoreListing: Equatable, Sendable {
    let version: String
    let storeURL: URL
}

/// App Store 版本号的数字比较模型。
///
/// `String` 的字典序会把 `1.10` 判定为小于 `1.9`，因此这里按点拆分后逐段比较。
/// 尾部的零会被收口，让 `1.2` 与 `1.2.0` 保持相等。
struct AppStoreVersion: Comparable, Sendable {
    private let components: [Int]

    init?(_ rawValue: String) {
        let rawComponents = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard rawComponents.isEmpty == false,
              rawComponents.allSatisfy({ component in
                  component.isEmpty == false
                      && component.allSatisfy(\.isNumber)
                      && Int(component) != nil
              })
        else {
            return nil
        }

        var normalized = rawComponents.compactMap { Int($0) }
        while normalized.count > 1, normalized.last == 0 {
            normalized.removeLast()
        }
        components = normalized
    }

    static func < (lhs: AppStoreVersion, rhs: AppStoreVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

protocol AppStoreUpdateFetching: Sendable {
    func fetchLatestVersion() async throws -> AppStoreListing
}

enum AppStoreUpdateError: Error, Equatable, LocalizedError {
    case invalidResponse
    case invalidVersion(String)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The App Store lookup response was invalid"
        case .invalidVersion(let version):
            return "The App Store returned an invalid version: \(version)"
        case .httpStatus(let statusCode):
            return "The App Store lookup request failed with HTTP \(statusCode)"
        }
    }
}

/// Apple Lookup API 客户端。
///
/// 固定使用 App Store Connect 分配的 numeric App ID，避免名称搜索误命中同名应用。
/// `country` 只决定 storefront 和返回链接，不参与版本比较。
struct URLSessionAppStoreUpdateClient: AppStoreUpdateFetching {
    static let starcatAppID = 6_788_809_803
    static let starcatBundleID = "com.starcat.app.store"

    private let session: URLSession
    private let countryCode: String

    init(
        session: URLSession = .shared,
        countryCode: String = Locale.current.region?.identifier.lowercased() ?? "us"
    ) {
        self.session = session
        self.countryCode = countryCode
    }

    func fetchLatestVersion() async throws -> AppStoreListing {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(Self.starcatAppID)),
            URLQueryItem(name: "country", value: countryCode)
        ]
        guard let url = components.url else {
            throw AppStoreUpdateError.invalidResponse
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppStoreUpdateError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AppStoreUpdateError.httpStatus(httpResponse.statusCode)
        }

        let payload = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard let result = payload.results.first(where: {
            $0.trackID == Self.starcatAppID && $0.bundleID == Self.starcatBundleID
        }) else {
            throw AppStoreUpdateError.invalidResponse
        }

        let version = result.version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AppStoreVersion(version) != nil else {
            throw AppStoreUpdateError.invalidVersion(result.version)
        }
        guard let storeURL = URL(
            string: "macappstore://itunes.apple.com/app/id\(result.trackID)"
        ) else {
            throw AppStoreUpdateError.invalidResponse
        }

        return AppStoreListing(version: version, storeURL: storeURL)
    }

    private struct LookupResponse: Decodable {
        let results: [LookupResult]
    }

    private struct LookupResult: Decodable {
        let trackID: Int
        let bundleID: String
        let version: String

        private enum CodingKeys: String, CodingKey {
            case trackID = "trackId"
            case bundleID = "bundleId"
            case version
        }
    }
}

/// 主窗口可展示的更新检测结果。
enum AppStoreUpdatePresentation: Equatable, Sendable {
    case updateAvailable(currentVersion: String, listing: AppStoreListing)
    case upToDate(currentVersion: String)
    case failed

    var title: String {
        switch self {
        case .updateAvailable:
            return String.l10n("app.update.available.title")
        case .upToDate:
            return String.l10n("app.update.current.title")
        case .failed:
            return String.l10n("app.update.failed.title")
        }
    }

    var message: String {
        switch self {
        case .updateAvailable(let currentVersion, let listing):
            return String(
                format: String.l10n("app.update.available.messageFormat"),
                listing.version,
                currentVersion
            )
        case .upToDate(let currentVersion):
            return String(
                format: String.l10n("app.update.current.messageFormat"),
                currentVersion
            )
        case .failed:
            return String.l10n("app.update.failed.message")
        }
    }

    var storeURL: URL? {
        guard case .updateAvailable(_, let listing) = self else { return nil }
        return listing.storeURL
    }
}

/// App Store 版更新检测协调器。
///
/// 自动检查失败必须静默，不能让网络波动阻塞启动；用户主动检查时才展示失败结果。
/// 自动检查按 24 小时节流，并对同一个远端版本最多自动提示一次。手动检查不受这两个
/// 限制，用户始终可以从“操作”菜单再次确认当前版本。
@MainActor
@Observable
final class AppStoreUpdateController {
    private enum CheckMode: Equatable {
        case automatic
        case manual
    }

    private enum DefaultsKey {
        static let lastAutomaticCheckAt = "AppStoreUpdate.lastAutomaticCheckAt"
        static let lastPresentedVersion = "AppStoreUpdate.lastPresentedVersion"
    }

    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    let isAppStoreBuild: Bool
    private(set) var isChecking = false
    private(set) var presentation: AppStoreUpdatePresentation?

    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let parsedCurrentVersion: AppStoreVersion?
    @ObservationIgnored private let client: any AppStoreUpdateFetching
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let allowsAutomaticChecks: Bool

    init(
        bundle: Bundle = .main,
        client: any AppStoreUpdateFetching = URLSessionAppStoreUpdateClient(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        allowsAutomaticChecks: Bool = !TestEnvironment.isRunning
    ) {
        isAppStoreBuild = DistributionChannel.resolve(from: bundle).isAppStore
        currentVersion = (
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        parsedCurrentVersion = AppStoreVersion(currentVersion)
        self.client = client
        self.defaults = defaults
        self.now = now
        self.allowsAutomaticChecks = allowsAutomaticChecks
    }

    var canCheckForUpdates: Bool {
        isAppStoreBuild && parsedCurrentVersion != nil && !isChecking
    }

    /// 启动或重新激活时的后台检查入口。
    ///
    /// 先写入检查时间再发请求，避免断网时每次窗口激活都重复请求；用户仍可通过菜单
    /// 立即手动重试。测试 host 默认关闭本路径，避免测试启动期产生外部网络流量。
    func checkAutomaticallyIfNeeded() async {
        guard allowsAutomaticChecks, canCheckForUpdates else { return }
        let currentDate = now()
        if let lastCheck = defaults.object(forKey: DefaultsKey.lastAutomaticCheckAt) as? Date,
           currentDate.timeIntervalSince(lastCheck) < Self.automaticCheckInterval {
            return
        }

        defaults.set(currentDate, forKey: DefaultsKey.lastAutomaticCheckAt)
        await performCheck(mode: .automatic)
    }

    /// 用户从菜单主动触发的检查入口，不受 24 小时节流或已提示版本限制。
    func checkManually() async {
        await performCheck(mode: .manual)
    }

    func dismissPresentation() {
        presentation = nil
    }

    private func performCheck(mode: CheckMode) async {
        guard canCheckForUpdates, let parsedCurrentVersion else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            let listing = try await client.fetchLatestVersion()
            guard let latestVersion = AppStoreVersion(listing.version) else {
                throw AppStoreUpdateError.invalidVersion(listing.version)
            }

            if latestVersion > parsedCurrentVersion {
                let lastPresentedVersion = defaults.string(
                    forKey: DefaultsKey.lastPresentedVersion
                )
                guard mode == .manual || lastPresentedVersion != listing.version else {
                    return
                }
                defaults.set(listing.version, forKey: DefaultsKey.lastPresentedVersion)
                presentation = .updateAvailable(
                    currentVersion: currentVersion,
                    listing: listing
                )
            } else if mode == .manual {
                presentation = .upToDate(currentVersion: currentVersion)
            }
        } catch {
            AppLog.general.warning(
                "App Store update check failed: \(error.localizedDescription, privacy: .public)"
            )
            if mode == .manual {
                presentation = .failed
            }
        }
    }
}
