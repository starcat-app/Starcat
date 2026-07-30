//
//  CodebaseMemoryExtractorLimitTests.swift
//  StarcatTests
//
//  验证 CodebaseMemory 的持久解压阶段不会绕过用户配置的仓库 ZIP 上限。
//

import CryptoKit
import Foundation
import Testing
@testable import Starcat

@Suite("CodebaseMemory Extractor Limit")
struct CodebaseMemoryExtractorLimitTests {
    @Test("持久解压使用调用方传入的 ZIP 上限")
    func rejectsArchiveAboveConfiguredLimit() async throws {
        let fileManager = FileManager.default
        let zipURL = fileManager.temporaryDirectory
            .appendingPathComponent("codebase-memory-limit-\(UUID().uuidString).zip")
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("codebase-memory-output-\(UUID().uuidString)", isDirectory: true)
        try Data("oversized".utf8).write(to: zipURL)
        defer {
            try? fileManager.removeItem(at: zipURL)
            try? fileManager.removeItem(at: outputURL)
        }

        do {
            _ = try await CodebaseMemoryExtractor().extractIfNeeded(
                zipURL: zipURL,
                outputDirectory: outputURL,
                maximumArchiveBytes: 4
            )
            Issue.record("Expected configured archive limit to reject extraction")
        } catch CodebaseMemoryError.archiveTooLarge(let actualBytes) {
            #expect(actualBytes == 9)
        }
    }

    @Test("调低上限后重新校验历史解压缓存")
    func cachedExtractionRespectsConfiguredLimit() async throws {
        let fileManager = FileManager.default
        let zipURL = fileManager.temporaryDirectory
            .appendingPathComponent("codebase-memory-cached-limit-\(UUID().uuidString).zip")
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("codebase-memory-cached-output-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = outputURL.appendingPathComponent("source", isDirectory: true)
        let zipData = Data("zip".utf8)
        try zipData.write(to: zipURL)
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 21).write(to: sourceURL.appendingPathComponent("source.swift"))
        let zipSHA = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        try zipSHA.write(
            to: outputURL.appendingPathComponent(".zip.sha256"),
            atomically: true,
            encoding: .utf8
        )
        defer {
            try? fileManager.removeItem(at: zipURL)
            try? fileManager.removeItem(at: outputURL)
        }

        do {
            _ = try await CodebaseMemoryExtractor().extractIfNeeded(
                zipURL: zipURL,
                outputDirectory: outputURL,
                maximumArchiveBytes: 4
            )
            Issue.record("Expected cached extracted source to respect the new 5× limit")
        } catch CodebaseMemoryError.extractedTooLarge(let actualBytes) {
            #expect(actualBytes == 21)
        }
    }
}
