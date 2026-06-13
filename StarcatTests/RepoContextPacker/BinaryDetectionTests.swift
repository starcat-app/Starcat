//
//  BinaryDetectionTests.swift
//  StarcatTests
//
//  验证 BinaryDetection.isLikelyBinary 的 NUL 字节探测（§22.7 Q6 决议）：
//    - 含 NUL byte (0x00) → true（binary）
//    - 不含 NUL → false（text）
//    - 空文件 → false（text，让 caller 处理空内容）
//    - 读不开 → true（保守策略 = binary 跳过）
//

import Testing
import Foundation
@testable import Starcat

@Suite("BinaryDetection")
struct BinaryDetectionTests {

    private func writeTempFile(_ data: Data, ext: String = "bin") throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BinaryDetectionTests", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent(UUID().uuidString + ".\(ext)", isDirectory: false)
        try data.write(to: url)
        return url
    }

    @Test("纯 ASCII 文本 → text")
    func plainTextIsNotBinary() throws {
        let url = try writeTempFile(Data("hello world\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(BinaryDetection.isLikelyBinary(at: url) == false)
    }

    @Test("含 NUL byte → binary")
    func nulByteIsBinary() throws {
        var data = Data("text before".utf8)
        data.append(0x00)
        data.append("text after".data(using: .utf8)!)
        let url = try writeTempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(BinaryDetection.isLikelyBinary(at: url) == true)
    }

    @Test("空文件 → text（让 caller 处理）")
    func emptyFileIsText() throws {
        let url = try writeTempFile(Data())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(BinaryDetection.isLikelyBinary(at: url) == false)
    }

    @Test("UTF-8 中文文本 → text（不含 0x00）")
    func chineseTextIsNotBinary() throws {
        let url = try writeTempFile(Data("你好世界 hello world".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(BinaryDetection.isLikelyBinary(at: url) == false)
    }

    @Test("不存在的文件 → binary（保守策略）")
    func nonexistentIsBinary() {
        let url = URL(fileURLWithPath: "/tmp/this-does-not-exist-\(UUID()).bin")
        #expect(BinaryDetection.isLikelyBinary(at: url) == true)
    }

    @Test("8KB 之后的 NUL byte 不会被探测（采样窗口限制）")
    func nulOutsideSampleWindow() throws {
        // 前 8KB 全 ASCII，第 8200 byte 才是 NUL
        var data = Data(count: 9000)
        for i in 0..<9000 {
            data[i] = i == 8200 ? 0x00 : UInt8(ascii: "a")
        }
        let url = try writeTempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }
        // 注：业界标准 8KB 窗口已经能挡 99% 的 binary 文件；
        // 极少数 binary 在 8KB 之后才有 NUL（如某些压缩文件头是纯 ASCII magic）会漏检
        #expect(BinaryDetection.isLikelyBinary(at: url) == false)
    }
}
