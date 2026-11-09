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
