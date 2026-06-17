//
//  EndToEndIntegrationTests.swift
//  StarcatTests
//
//  Y7（2026-06-13）：RepoContextPacker E2E 集成测试骨架。
//
//  设计目标：用一个**真实 GitHub ZIP fixture**端到端跑全 pipeline（解压 → 过滤 →
//  分级 → 预算 → 目录树 → XML 拼装 → 写盘），断言 4 件事：
//    1. context.xml 文件被生成且可解析为字符串
//    2. metadata.json 文件被生成且能反序列化为 PackMetadata
//    3. PackMetadata 关键字段非空（owner / repo / commitSha 与输入对齐）
//    4. tier 三段计数与 stats 自洽（tier 0+1+2 = totalFiles - skipped）
//
//  关键设计选择：
//    - **fixture 不内嵌仓库**：fixture ZIP 放在 `StarcatTests/Fixtures/repo-context/`
//      下，按需手动制备（典型来源：`curl -L .../zipball/<sha> -o starcat-sample.zip`）。
//      CI 不强制——fixture 不存在时 `withKnownIssue` 跳过整个 case，绿色通过。
//    - **不 mock 任何 Packer 内部组件**：与单元测试完全互补——单元测试覆盖单组件契约，
//      E2E 测试覆盖"6 步串起来在真实数据上跑得通"。
//    - **不验证 XML 内容细节**：xml 字符串太大，比对会脆弱；只验证文件存在 + UTF-8 可读 +
//      含 `<repository>` 根标签。细节由 XmlOutputBuilder 单元测试覆盖。
//
//  如何准备 fixture（不是 CI 必需）：
//    1. 选一个**小型公开仓库**作为 fixture（建议 < 1MB ZIP，避免拖慢 CI 即便启用了 fixture）。
//       推荐：`braedonsaunders/codeflow`（已在 CodeFlowRunnerTests 用过）；
//    2. `curl -L "https://api.github.com/repos/braedonsaunders/codeflow/zipball/<sha>" \\
//          -o StarcatTests/Fixtures/repo-context/starcat-sample.zip`
//    3. 把对应 commit SHA 填到 `Self.fixtureCommitSha`。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RepoContextPacker.EndToEndIntegration")
struct EndToEndIntegrationTests {

    // MARK: - fixture 元信息（可调整）

    /// Fixture ZIP 路径——相对于源码仓库根目录的 `StarcatTests/Fixtures/repo-context/`。
    ///
    /// **不放仓库**：仓库根 .gitignore 应该忽略 `StarcatTests/Fixtures/repo-context/*.zip`。
    /// CI 不需要 fixture 就能跑（withKnownIssue skip）。
    private static let fixtureRelativePath = "StarcatTests/Fixtures/repo-context/starcat-sample.zip"

    /// 与 fixture ZIP 对齐的 commit SHA（fixture 不存在时此字段也无意义）。
    private static let fixtureCommitSha = "0000000000000000000000000000000000000000"

    private static let fixtureOwner = "braedonsaunders"
    private static let fixtureRepo = "codeflow"

    // MARK: - 主 case

    @Test("E2E: fixture ZIP → context.xml + metadata.json + 三段 tier 计数自洽")
    func endToEndFixturePipeline() async throws {
        guard let zipURL = locateFixture() else {
            // fixture 不存在：作为 known issue 标记并立刻返回。
            // 等本地或 CI 真的提供了 fixture，这条记录会自动转为"unexpectedly passed"。
            withKnownIssue("Fixture ZIP 未提供，跳过 E2E：放置 \(Self.fixtureRelativePath) 后此测试自动跑起来") {
                Issue.record("fixture absent")
            }
            return
        }

        // 输出根目录（每次跑用 UUID 隔离）
        let outputBaseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-e2e-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputBaseDir) }

        let input = PackInput(
            zipURL: zipURL,
            owner: Self.fixtureOwner,
            repo: Self.fixtureRepo,
            ref: "main",
            commitSha: Self.fixtureCommitSha,
            outputBaseDir: outputBaseDir,
            tokenBudget: 8000,
            tier1MaxLines: 80
        )

        let packer = try RepoContextPacker()
        let output = try await packer.pack(input)

        // ① context.xml 文件存在且可读，含 `<repository>` 根标签
        let xmlString = try String(contentsOf: output.contextURL, encoding: .utf8)
        #expect(xmlString.contains("<repository"))
        #expect(xmlString.hasSuffix("</repository>\n") || xmlString.hasSuffix("</repository>"))

        // ② metadata.json 存在且能反序列化
        // HOM-203：PackMetadata.generatedAt 已改为 Date 类型，必须用
        // PackMetadataCoder.decoder（带 lenient ISO-8601 策略）解码，否则默认
        // JSONDecoder 不会解析 String → Date 转换，导致测试在 Date 字段处抛错。
        let metadataData = try Data(contentsOf: output.metadataURL)
        let decoded = try PackMetadataCoder.decoder.decode(PackMetadata.self, from: metadataData)
        #expect(decoded.owner == Self.fixtureOwner)
        #expect(decoded.repo == Self.fixtureRepo)
        #expect(decoded.commitSha == Self.fixtureCommitSha)
        #expect(decoded.tokenBudget == 8000)

        // ③ stats 三段计数自洽：tier0 + tier1 + tier2 ≤ totalFiles（差额是 skipped）
        //    具体值会随 fixture 变化，只验证不变量（非负 / 和不超过 total）
        let stats = decoded.stats
        #expect(stats.tier0Count >= 0)
        #expect(stats.tier1Count >= 0)
        #expect(stats.tier2Count >= 0)
        #expect(stats.totalFiles >= stats.tier0Count + stats.tier1Count + stats.tier2Count,
                "totalFiles 必须 >= 三段 tier 之和（差额是 skipped）")
        #expect(stats.contextXmlBytes > 0, "context.xml 字节数应回填")

        // ④ Y2 新增字段非空（W7 + Y2 路径联调）
        #expect(decoded.tier1MaxLines == 80, "Y2: tier1MaxLines 应被 W7 透传")
        // generationCount 走 storage 路径才有；E2E 用 outputBaseDir 直写，预期 nil
        #expect(decoded.generationCount == nil, "未走 storage 路径，generationCount 应为 nil")
    }

    // MARK: - 辅助

    /// 定位 fixture ZIP；不存在返回 nil（让上层走 skip 分支）。
    ///
    /// 解析策略：从 `#file`（当前测试文件绝对路径）向上找到 `StarcatTests/` 目录，
    /// 再 join `Fixtures/repo-context/starcat-sample.zip`。
    private func locateFixture() -> URL? {
        let testFileURL = URL(fileURLWithPath: #file)
        // #file 是 `<workspace>/StarcatTests/EndToEndIntegrationTests.swift`
        // 父目录就是 `StarcatTests/`
        let testsRoot = testFileURL.deletingLastPathComponent()
        let fixtureURL = testsRoot
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("repo-context", isDirectory: true)
            .appendingPathComponent("starcat-sample.zip", isDirectory: false)
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            return nil
        }
        return fixtureURL
    }
}
