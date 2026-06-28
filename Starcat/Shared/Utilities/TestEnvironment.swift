//
//  TestEnvironment.swift
//  Starcat
//
//  单一信息源：判断当前进程是否运行在 XCTest / Swift Testing 的测试 host 内。
//
//  存在意义：
//  Starcat 在 ad-hoc 签名 + App Sandbox 下，App 启动期任何 Keychain 调用都可能触发
//  macOS 系统授权对话框（ACL 不匹配）。测试 host 没有窗口接收用户点击，主线程会被
//  对话框死等，最终 testmanagerd 5.5min 超时报 "hung before establishing connection"。
//
//  解决：所有"App 启动期主动调 Keychain"的代码路径都用本工具门控，测试期 no-op。
//
//  使用约定：
//  - StarcatApp.bootstrap() 跳过 Keychain.ping
//  - AuthSession.restoreSessionIfAvailable() 跳过 loadGithubToken
//  - 后续任何"启动期 keychain / 网络 / 系统授权"调用都应在此门控下执行
//
//  ⚠️ 临时债：等 Apple ID Team 签名 + keychain-access-groups entitlement 切回正轨后，
//  本工具仍可保留（测试隔离是好实践），但 AuthSession 的守卫可以删掉。
//  详见 docs/4-工程进度/踩坑与故障记录/2026-05-30-Keychain-临时绕过方案.md
//

import Foundation

enum TestEnvironment {

    /// 当前是否运行在测试 host 进程中。
    ///
    /// 判定逻辑（任一命中即为真）：
    /// - `XCTestCase` ObjC 类已注入运行时（XCTest framework 加载后必有）
    /// - `XCTestConfigurationFilePath` 环境变量存在（xcodebuild test 必写）
    /// - `XCTestBundlePath` 环境变量存在（部分 Xcode 版本会写）
    static let isRunning: Bool = {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCInjectBundleInto"] != nil
    }()
}
