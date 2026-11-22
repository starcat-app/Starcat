//
//  CacheJSONCodec.swift
//  Starcat
//
//  本地 JSON 缓存共用的无损压缩格式。保留原路径和业务 Schema，
//  读取时靠格式头区分 zlib 数据和旧 JSON。
//

import Foundation

enum CacheJSONCodec {
    private static let header = Data("SCZ1".utf8)

    /// 小条目或压缩后更大的条目继续写原字节，避免增加实际占用。
    static func pack(_ json: Data) throws -> Data {
        guard json.count > header.count else { return json }
        let compressed = try (json as NSData).compressed(using: .zlib) as Data
        guard compressed.count + header.count < json.count else { return json }
        return header + compressed
    }

    /// 旧格式直接交给原有业务解码器；带格式头的损坏数据走调用方的恢复流程。
    static func unpack(_ stored: Data) throws -> Data {
        guard isCompressed(stored) else { return stored }
        return try (Data(stored.dropFirst(header.count)) as NSData).decompressed(using: .zlib) as Data
    }

    static func isCompressed(_ stored: Data) -> Bool {
        stored.starts(with: header)
    }

    /// 调用方先校验业务数据。成功时返回节省量，失败则保留旧文件，供下次读取重试。
    @discardableResult
    static func migrateFileIfSmaller(_ stored: Data, at url: URL) -> Int64? {
        guard let packed = upgradeIfSmaller(stored) else { return nil }
        do {
            try packed.write(to: url, options: .atomic)
            return Int64(stored.count - packed.count)
        } catch {
            return nil
        }
    }

    static func upgradeIfSmaller(_ stored: Data) -> Data? {
        guard !isCompressed(stored), let packed = try? pack(stored), isCompressed(packed) else { return nil }
        return packed
    }
}
