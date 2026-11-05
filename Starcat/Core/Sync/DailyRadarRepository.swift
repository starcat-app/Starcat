//
//  DailyRadarRepository.swift
//  Starcat
//
//  公共日报的有界磁盘缓存。保存原始 envelope，避免重新编码造成 DTO 字段丢失；
//  文件命名仅含服务与凭据摘要，不保存 Key。账号私人状态不写入此缓存。
//

import Foundation

/// 读取值与成功校验时间一起返回，失败时不会把尝试时间当作同步成功时间。
struct DailyRadarCachedValue<Value: Sendable>: Sendable {
    let value: Value
    let validatedAt: Date
}

actor DailyRadarRepository {
    /// 完整首屏以一份原子文件保存，独立于各接口逐次推进的缓存版本
    struct HomeSnapshot: Sendable {
        let catalog: DailyRadarCatalog
        let dates: DailyRadarDates
        let page: DailyRadarPage
        let edition: String?
    }
    private struct HomeEntry: Codable {
        let catalog: Entry
        let dates: Entry
        let page: Entry
        let edition: String?
    }
    private struct Entry: Codable, Sendable {
        let data: Data
        let etag: String?
        var validatedAt: Date
    }
    private let api: DailyRadarAPI
    private let directory: URL
    private let capacity: Int
    private struct Request {
        let id: UUID
        let generation: UInt64
        let task: Task<Entry, Error>
    }
    private var inFlight: [String: Request] = [:]

    init(api: DailyRadarAPI, directory: URL? = nil, capacity: Int = 64 * 1024 * 1024) {
        self.api = api
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Starcat/DailyRadar", isDirectory: true)
        self.capacity = capacity
    }

    /// 用相同身份先取磁盘，再由视图决定何时重验证；不自动把失败变成空数据。
    func cached<Value: Decodable & Sendable>(
        _ type: Value.Type, path: String, parameters: [URLQueryItem]
    ) async -> DailyRadarCachedValue<Value>? {
        let config = await api.configuration()
        guard let entry = read(key: key(path, parameters, config)),
              (await api.configuration()).generation == config.generation else { return nil }
        return decode(type, entry: entry)
    }

    /// 使用当前凭据命名空间恢复最后一份完整首屏，不能跨服务或凭据查找旧内容
    func restoreHome(query: DailyRadarQuery) async -> HomeSnapshot? {
        let config = await api.configuration()
        guard let entry = read(key: homeKey(query, config)),
              let home = try? JSONDecoder().decode(HomeEntry.self, from: entry.data),
              let catalog = decode(DailyRadarCatalog.self, entry: home.catalog)?.value,
              let dates = decode(DailyRadarDates.self, entry: home.dates)?.value,
              let page = decode(DailyRadarPage.self, entry: home.page)?.value,
              catalog.catalogRevision == dates.catalogRevision,
              dates.catalogRevision == page.catalogRevision,
              (await api.configuration()).generation == config.generation else { return nil }
        return HomeSnapshot(catalog: catalog, dates: dates, page: page, edition: home.edition)
    }

    /// 只有三段读取全部成功且版本一致才替换快照；刷新中途失败不破坏上一份完整结果
    func saveHome(query: DailyRadarQuery, catalogRevision: String, edition: String?) async {
        let config = await api.configuration()
        let catalogParameters = query.catalogParameters
        var request = query
        request.catalogRevision = catalogRevision
        request.dateTo = nil
        guard let catalog = read(key: key("/api/v1/daily-radar/catalog", catalogParameters, config)),
              let dates = read(key: key("/api/v1/daily-radar/dates", request.parameters, config)) else { return }
        request.dateTo = edition
        guard let page = read(key: key("/api/v1/daily-radar/reports", request.parameters, config)),
              decode(DailyRadarCatalog.self, entry: catalog)?.value.catalogRevision == catalogRevision,
              decode(DailyRadarDates.self, entry: dates)?.value.catalogRevision == catalogRevision,
              decode(DailyRadarPage.self, entry: page)?.value.catalogRevision == catalogRevision,
              let data = try? JSONEncoder().encode(HomeEntry(catalog: catalog, dates: dates, page: page, edition: edition)),
              (await api.configuration()).generation == config.generation else { return }
        write(Entry(data: data, etag: nil, validatedAt: page.validatedAt), key: homeKey(query, config))
    }

    private func homeKey(_ query: DailyRadarQuery, _ config: DailyRadarAPI.Configuration) -> String {
        // 周期来自目录，冷启动时尚未恢复；同一分类的快照不能因默认 daily 而漏命中
        var filter = query
        filter.period = ""
        filter.catalogRevision = nil
        filter.cursor = nil
        return key("/daily-radar-home-v1", filter.parameters, config)
    }

    /// 同条件并发请求合并；304 仅更新成功校验时间，409 不允许用旧缓存伪装成功。
    func fetch<Value: Decodable & Sendable>(
        _ type: Value.Type, path: String, parameters: [URLQueryItem], force: Bool = false,
        ttl: TimeInterval = 600
    ) async throws -> DailyRadarCachedValue<Value> {
        let config = await api.configuration()
        let requestKey = key(path, parameters, config)
        let previous = read(key: requestKey)
        if !force, let previous, Date().timeIntervalSince(previous.validatedAt) < ttl,
           let decoded = decode(type, entry: previous) { return decoded }
        let request: Request
        if let existing = inFlight[requestKey], existing.generation == config.generation {
            request = existing
        } else {
            let task = Task {
                let response = try await api.request(path: path, parameters: parameters, etag: previous?.etag, configuration: config)
                if response.notModified {
                    guard var previous else { throw DailyRadarError.invalidResponse }
                    previous.validatedAt = Date()
                    return previous
                }
                return Entry(data: response.data, etag: response.etag, validatedAt: Date())
            }
            request = Request(id: UUID(), generation: config.generation, task: task)
            inFlight[requestKey] = request
        }
        do {
            let entry = try await request.task.value
            guard (await api.configuration()).generation == config.generation else { throw DailyRadarError.staleConfiguration }
            guard let decoded = decode(type, entry: entry) else { throw DailyRadarError.invalidResponse }
            write(entry, key: requestKey)
            finish(request, key: requestKey)
            return decoded
        } catch {
            finish(request, key: requestKey)
            throw error
        }
    }

    /// 服务/账户变化取消共享在途请求；已写公共缓存按命名空间隔离，下次可再次使用。
    func cancelRequests() {
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
    }
    private func finish(_ request: Request, key: String) {
        // cancel 后同 key 可能已有新任务；旧请求只能清理属于自己的登记。
        if inFlight[key]?.id == request.id { inFlight.removeValue(forKey: key) }
    }

    private func key(_ path: String, _ parameters: [URLQueryItem], _ config: DailyRadarAPI.Configuration) -> String {
        let query = parameters.sorted { $0.name < $1.name }.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        let namespace = DailyRadarAPI.isEvents(path: path, parameters: parameters) ? config.eventsNamespace : config.namespace
        return DailyRadarAPI.Configuration.digest("\(namespace)|\(path)|\(query)")
    }
    private func read(key: String) -> Entry? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }
    private func decode<Value: Decodable & Sendable>(_ type: Value.Type, entry: Entry) -> DailyRadarCachedValue<Value>? {
        guard let envelope = try? JSONDecoder().decode(StarcatEnvelope<Value>.self, from: entry.data),
              envelope.schemaVersion == 1 else { return nil }
        return .init(value: envelope.data, validatedAt: entry.validatedAt)
    }
    private func write(_ entry: Entry, key: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent(key), options: .atomic)
            // 文件级 LRU 上限只淘汰可再生公共内容；当前阅读持有独立值快照，不受删除影响。
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            let sizes = files.map { ($0, (try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]))) }
            var total = sizes.reduce(0) { $0 + ($1.1?.fileSize ?? 0) }
            for (url, values) in sizes.sorted(by: { ($0.1?.contentModificationDate ?? .distantPast) < ($1.1?.contentModificationDate ?? .distantPast) }) where total > capacity {
                try? FileManager.default.removeItem(at: url)
                total -= values?.fileSize ?? 0
            }
        } catch {
            // 磁盘缓存不可写不能把成功的在线读取降级为业务失败。
            AppLog.network.warning("DailyRadar cache persistence failed")
        }
    }
}
