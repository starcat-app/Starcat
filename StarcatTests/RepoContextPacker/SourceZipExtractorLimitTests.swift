//
//  SourceZipExtractorLimitTests.swift
//  StarcatTests
//
//  验证 RepoContextPacker 的 ZIP 预检使用调用方运行期阈值，而不是固定 100 MiB。
//

import Foundation
import Testing
@testable import Starcat

@Suite("SourceZipExtractor runtime limit")
struct SourceZipExtractorLimitTests {

    @Test("低于文件大小的运行期阈值应先报 zipTooLarge")
    func customLimitRejectsBeforeExtraction() async throws {
        let fileURL = try makeTemporaryPayload(byteCount: 11)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let extractor = DefaultSourceZipExtractor(maximumArchiveBytes: 10)

        do {
            _ = try await extractor.extract(fileURL)
            Issue.record("超过运行期阈值时应抛 zipTooLarge")
        } catch RepoContextPackerError.zipTooLarge(let actual, let maximum) {
            #expect(actual == 11)
            #expect(maximum == 10)
        } catch {
            Issue.record("预期 zipTooLarge，实际为 \(error)")
        }
    }

    @Test("提高运行期阈值后不应再被历史 100MiB 常量拦截")
    func raisedLimitReachesExtraction() async throws {
        let fileURL = try makeSparseTemporaryPayload(byteCount: 101 * 1_024 * 1_024)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let extractor = DefaultSourceZipExtractor(maximumArchiveBytes: 200 * 1_000_000)

        do {
            _ = try await extractor.extract(fileURL)
            Issue.record("无效 ZIP 应在解压阶段失败")
        } catch RepoContextPackerError.zipExtractionFailed {
            // 预期：大小预检已放行，证明运行期阈值生效。
        } catch {
            Issue.record("预期进入解压阶段，实际为 \(error)")
        }
    }

    private func makeTemporaryPayload(byteCount: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-extractor-limit-\(UUID().uuidString).zip")
        try Data(count: byteCount).write(to: url)
        return url
    }

    /// 用 sparse file 验证 >100MiB 的边界，避免单测实际分配百兆内存。
    private func makeSparseTemporaryPayload(byteCount: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-extractor-limit-sparse-\(UUID().uuidString).zip")
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(byteCount))
        return url
    }
}
