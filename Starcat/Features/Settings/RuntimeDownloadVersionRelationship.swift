//
//  RuntimeDownloadVersionRelationship.swift
//  Starcat
//
//  比较真实 CLI 版本与固定下载版本，供三项 Runtime 共用更新标识和重复安装确认
//

import Foundation

/// 无法识别的版本不能冒充有更新；调用方应提示确认后再安装固定版本
enum RuntimeDownloadVersionRelationship: Equatable {
    case unknown
    case updateAvailable
    case current
    case newer

    /// 检测成功后的版本反馈与更新胶囊使用同一比较结果
    var detectionMessageKey: String {
        "settings.integration.runtimeDetection.\(self)"
    }

    init(installedVersion: String, availableVersion: String) {
        guard let installed = Self.components(in: installedVersion),
              let available = Self.components(in: availableVersion) else {
            self = .unknown
            return
        }
        if installed == available {
            self = .current
        } else {
            self = installed.lexicographicallyPrecedes(available) ? .updateAvailable : .newer
        }
    }

    /// CLI 输出可含产品名前缀；同时接受 PyPI rc2 与 SemVer -rc.2
    /// 按数值比较版本段，正式版排在同版本的预发布版之后，build metadata 不参与排序
    private static func components(in output: String) -> [Int]? {
        let pattern = #"(?:^|\s)v?([0-9]+)\.([0-9]+)\.([0-9]+)(?:-?(alpha|beta|rc)[.-]?([0-9]+))?(?:\+[0-9A-Za-z.-]+)?(?=\s|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) else {
            return nil
        }
        func capture(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: output) else { return nil }
            return String(output[range])
        }
        guard let major = capture(1).flatMap(Int.init),
              let minor = capture(2).flatMap(Int.init),
              let patch = capture(3).flatMap(Int.init) else { return nil }
        let stage: Int
        switch capture(4) {
        case "alpha": stage = 0
        case "beta": stage = 1
        case "rc": stage = 2
        default: stage = 3
        }
        return [major, minor, patch, stage, capture(5).flatMap(Int.init) ?? 0]
    }
}
