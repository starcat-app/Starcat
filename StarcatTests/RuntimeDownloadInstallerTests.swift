//
//  RuntimeDownloadInstallerTests.swift
//  StarcatTests
//
//  安装失败、渠道边界与进程回收回归。真实二进制测试只使用显式提供的隔离下载目录，
//  不读写用户 Runtime、凭据或图谱缓存。
//

import CryptoKit
import Foundation
import Testing
@testable import Starcat

struct RuntimeDownloadInstallerTests {
    @Test("DeepSeek 镜像失败后回退官方源并保留两个来源的诊断")
    func deepSeekFallsBackToOfficialSource() async {
        let attempts = RuntimeDownloadAttemptRecorder()
        let installer = RuntimeDownloadInstaller(download: { request, _ in
            await attempts.record(request.url!)
            throw URLError(.cannotConnectToHost)
        })
        do {
            _ = try await installer.downloadArchive(.deepSeek) { _ in }
            Issue.record("Both unavailable sources must fail")
        } catch {
            #expect(error.localizedDescription.contains("pypi.tuna.tsinghua.edu.cn"))
            #expect(error.localizedDescription.contains("files.pythonhosted.org"))
        }
        #expect(await attempts.urls == DownloadableRuntime.deepSeek.downloadURLs)
        #expect(DownloadableRuntime.deepSeek.downloadURLs.last == DownloadableRuntime.deepSeek.asset.url)
    }

    @Test("主动取消下载不会继续请求备用源")
    func cancelledDownloadDoesNotFallBack() async {
        let attempts = RuntimeDownloadAttemptRecorder()
        let installer = RuntimeDownloadInstaller(download: { request, _ in
            await attempts.record(request.url!)
            throw URLError(.cancelled)
        })
        await #expect(throws: CancellationError.self) {
            _ = try await installer.downloadArchive(.deepSeek) { _ in }
        }
        #expect(await attempts.urls.count == 1)
    }

    @Test("镜像与官方源的损坏归档均须校验并清理")
    func corruptMirrorCannotBypassChecksum() async throws {
        let attempts = RuntimeDownloadAttemptRecorder()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = RuntimeDownloadInstaller(download: { request, _ in
            await attempts.record(request.url!)
            let archive = root.appendingPathComponent(UUID().uuidString)
            try Data("invalid mirror payload".utf8).write(to: archive)
            return (archive, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: (any Error).self) {
            _ = try await installer.downloadArchive(.deepSeek) { _ in }
        }
        #expect(await attempts.urls == DownloadableRuntime.deepSeek.downloadURLs)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("三项 Runtime 的同版本不能显示更新徽标")
    func installedRuntimeVersionsAreCurrent() {
        for (installed, available) in [
            ("codex-app-server 0.167.0", "0.167.0"),
            ("codex-cli 0.167.0\n", "0.167.0"),
            ("codebase-memory-mcp 0.12.1", "0.12.1"),
            ("0.2.1-rc.2", "0.2.1rc2"),
            ("v0.12.1+local", "0.12.1"),
        ] {
            #expect(RuntimeDownloadVersionRelationship(
                installedVersion: installed, availableVersion: available
            ) == .current)
        }
    }

    @Test("较旧 Runtime 按数值比较版本并显示可用更新")
    func olderRuntimeVersionsHaveUpdates() {
        for (installed, available) in [
            ("codebase-memory-mcp 0.9.8", "0.12.1"),
            ("codex-app-server 0.162.1", "0.167.0"),
            ("0.1.1rc1", "0.2.1-rc.2"),
            ("0.2.1-rc.1", "0.2.1rc2"),
            ("0.2.1-beta.9", "0.2.1-rc.2"),
            ("0.2.1-rc.2", "0.2.1"),
        ] {
            #expect(RuntimeDownloadVersionRelationship(
                installedVersion: installed, availableVersion: available
            ) == .updateAvailable)
        }
    }

    @Test("较高版本与正式版不能被误报为需要升级到较低版本")
    func newerRuntimeVersionsRequireDowngradeConfirmation() {
        for (installed, available) in [
            ("codebase-memory-mcp 0.13.0", "0.12.1"),
            ("codex-app-server 0.168.0", "0.167.0"),
            ("0.2.1", "0.2.1rc2"),
            ("0.2.1-rc.10", "0.2.1-rc.2"),
        ] {
            #expect(RuntimeDownloadVersionRelationship(
                installedVersion: installed, availableVersion: available
            ) == .newer)
        }
    }

    @Test("缺失与无法识别的版本不伪装成可用更新")
    func unknownRuntimeVersionsAreNotUpdates() {
        for installed in ["", "unknown", "failed to read version", "0.12", "0.12.1-dev.1"] {
            #expect(RuntimeDownloadVersionRelationship(
                installedVersion: installed, availableVersion: "0.12.1"
            ) == .unknown)
        }
    }

    @Test("归档哈希不匹配时拒绝安装")
    func checksumMismatch() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("fixture".utf8).write(to: file)
        let digest = SHA256.hash(data: Data("fixture".utf8)).map { String(format: "%02x", $0) }.joined()
        try RuntimeDownloadInstaller.verifyChecksum(at: file, expected: digest)
        #expect(throws: (any Error).self) {
            try RuntimeDownloadInstaller.verifyChecksum(at: file, expected: String(repeating: "0", count: 64))
        }
    }

    @Test("App Store 不下载也不创建安装目录")
    func appStoreCannotInstall() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let installer = RuntimeDownloadInstaller(download: { _, _ in
            Issue.record("App Store must not download")
            throw CancellationError()
        })
        await #expect(throws: (any Error).self) {
            _ = try await installer.install(.codex, channel: .appStore, root: root) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("损坏下载清理暂存目录并保留原安装")
    func failedDownloadPreservesExistingInstallation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("existing")
        try Data("keep".utf8).write(to: old)
        let installer = RuntimeDownloadInstaller(download: { request, _ in
            let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("damaged archive".utf8).write(to: archive)
            return (archive, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: (any Error).self) {
            _ = try await installer.install(.codex, channel: .direct, root: root) { _ in }
        }
        #expect(try String(contentsOf: old, encoding: .utf8) == "keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["existing"])
    }

    @Test("版本探测超时会回收进程")
    func processTimeout() async {
        let start = Date()
        await #expect(throws: (any Error).self) {
            _ = try await RuntimeDownloadInstaller.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 0.1)
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test("取消版本探测会及时回收进程")
    func processCancellation() async throws {
        let task = Task {
            try await RuntimeDownloadInstaller.run(URL(fileURLWithPath: "/bin/sleep"), ["30"])
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("DeepSeek 新启动参数使用独立 profile home 与无 Shell 补丁")
    func deepSeekSafePatch() {
        for id in ["subprocess", "pty", "terminal-bash", "persistent-bash", "tool-fs", "tool-working-directory"] {
            #expect(DeepSeekHarnessRuntime.configurationPatch.contains("- id: \(id)\n  disabled: true"))
        }
    }

}

/// 下载闭包可以跨执行器调用，用 actor 记录真实尝试次序而不共享可变数组
private actor RuntimeDownloadAttemptRecorder {
    private(set) var urls: [URL] = []

    func record(_ url: URL) {
        urls.append(url)
    }
}
