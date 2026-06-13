//
//  TierClassifierTests.swift
//  StarcatTests
//
//  验证 DefaultTierClassifier 的分级逻辑（§22.9 Q8 决议）：
//    - 精确名命中 Tier 0
//    - glob 命中 Tier 0 / Tier 1
//    - Tier 0 > 100KB 强制降级 Tier 2 + skippedFiles tier0FileTooLarge
//    - 默认 → Tier 2
//

import Testing
import Foundation
@testable import Starcat

@Suite("TierClassifier")
struct TierClassifierTests {

    private func makeFile(_ path: String, size: Int = 100) -> FilteredFile {
        FilteredFile(
            relativePath: path,
            absoluteURL: URL(fileURLWithPath: "/tmp/\(path)"),
            sizeBytes: size
        )
    }

    @Test("精确名命中 Tier 0")
    func exactNameTier0() throws {
        let classifier = try DefaultTierClassifier()
        let files = [
            makeFile("README.md"),
            makeFile("LICENSE"),
            makeFile("package.json"),
            makeFile("Dockerfile"),
        ]
        let result = classifier.classify(files: files)
        #expect(result.tieredFiles.allSatisfy { $0.tier == .zero })
        #expect(result.skippedFiles.isEmpty)
    }

    @Test("glob 命中 Tier 0")
    func globTier0() throws {
        let classifier = try DefaultTierClassifier()
        let files = [
            makeFile("MyProject.csproj"),
            makeFile(".github/workflows/ci.yml"),
        ]
        let result = classifier.classify(files: files)
        #expect(result.tieredFiles.allSatisfy { $0.tier == .zero })
    }

    @Test("glob 命中 Tier 1（入口文件）")
    func globTier1() throws {
        let classifier = try DefaultTierClassifier()
        let files = [
            makeFile("src/index.ts"),
            makeFile("src/main.rs"),
            makeFile("main.go"),
        ]
        let result = classifier.classify(files: files)
        #expect(result.tieredFiles.allSatisfy { $0.tier == .one })
    }

    @Test("默认 → Tier 2")
    func defaultTier2() throws {
        let classifier = try DefaultTierClassifier()
        let files = [
            makeFile("src/utils/helper.ts"),
            makeFile("tests/util.test.swift"),
        ]
        let result = classifier.classify(files: files)
        #expect(result.tieredFiles.allSatisfy { $0.tier == .two })
    }

    @Test("Tier 0 > 100KB → 降级 Tier 2 + skippedFiles tier0FileTooLarge")
    func tier0OverSizeDemotion() throws {
        let classifier = try DefaultTierClassifier()
        let bigReadme = makeFile("README.md", size: 200 * 1024)  // 200KB > 100KB
        let result = classifier.classify(files: [bigReadme])

        #expect(result.tieredFiles.count == 1)
        // 降级为 Tier 2
        #expect(result.tieredFiles[0].tier == .two)
        // matchReason 应含「demoted-from-tier0」
        #expect(result.tieredFiles[0].matchReason.contains("demoted-from-tier0"))

        // skippedFiles 含 1 条 tier0FileTooLarge 记录
        #expect(result.skippedFiles.count == 1)
        #expect(result.skippedFiles[0].path == "README.md")
        #expect(result.skippedFiles[0].reason == SkipReason.tier0FileTooLarge)
        #expect(result.skippedFiles[0].tier == 0)
        #expect(result.skippedFiles[0].fileSize == 200 * 1024)
    }

    @Test("Tier 0 < 100KB 不降级")
    func tier0UnderSizeOk() throws {
        let classifier = try DefaultTierClassifier()
        let normalReadme = makeFile("README.md", size: 50 * 1024)
        let result = classifier.classify(files: [normalReadme])
        #expect(result.tieredFiles[0].tier == .zero)
        #expect(result.skippedFiles.isEmpty)
    }
}
