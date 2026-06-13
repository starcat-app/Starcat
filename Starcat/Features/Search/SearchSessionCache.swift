//
//  SearchSessionCache.swift
//  Starcat
//
//  搜索会话内短期缓存。只驻留内存，不跨启动持久化，避免把第三方搜索结果误当成本地
//  知识库；actor 保证 Local/GitHub/Web 并发访问时字典状态一致。
//

import Foundation

actor SearchSessionCache<Value: Sendable> {
    private struct Entry: Sendable {
        let value: Value
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func value(for key: String, now: Date = Date()) -> Value? {
        guard let entry = entries[key] else { return nil }
        guard entry.expiresAt > now else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    func insert(_ value: Value, for key: String, now: Date = Date()) {
        entries[key] = Entry(value: value, expiresAt: now.addingTimeInterval(ttl))
    }

    func removeAll() {
        entries.removeAll()
    }
}
