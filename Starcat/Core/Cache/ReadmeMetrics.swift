//
//  ReadmeMetrics.swift
//  Starcat
//
//  README 缓存指标计数器（HOM-201 P2-3，2026-06-14）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  动机
//  ────────────────────────────────────────────────────────────────────────────
//
//  P0 / P1 / P2 一路改下来后,README 缓存路径已经有"hover prefetch / inflight
//  dedupe / softTtl 短路 / promote / LRU / 压缩"等多层优化,但**实际命中率**
//  与**配额节省**的体感都来自人工 debug log 推断,没有量化数据。本类提供
//  零侵入的计数器,让后续优化判断有事实依据,而不是凭直觉。
//
//  ────────────────────────────────────────────────────────────────────────────
//  采集口径
//  ────────────────────────────────────────────────────────────────────────────
//
//  5 个核心计数器(对应 SWR 状态机的所有终态):
//   - `cachedHit`     ←  cachedReadme 命中本地缓存(含 trending → manage promote)
//   - `refresh200`    ←  GitHub 200 OK,refreshReadme 写新 HTML(`.updated`)
//   - `refresh304`    ←  GitHub 304 Not Modified,touch cached_at(`.notModified`)
//   - `refresh404`    ←  GitHub 404 Not Found,删本地行(`.notFound`)
//   - `refreshFailed` ←  transport / 5xx / 解析失败等(`.failed`)
//
//  manage 与 trending 路径用同一组计数器(不分两套):
//   - 想要按路径拆分时,行为已经分别在 `refreshReadme` / `refreshTrendingReadme`
//     里调 metrics.record,这里统计全局口径足以判断"整体缓存健康度";
//   - 真要拆分时再扩本类,避免一开始 over-engineer。
//
//  cachedHit 与 refresh* 是两类不同维度的指标:
//   - hit + miss(本地未命中)对比 → "缓存覆盖率"
//   - 200 / 304 比例 → "条件请求有效性"(304 占比高 = 304 大多省了 body 字节)
//   - 404 占比 → "404 短路价值"(配合 ReadmeAvailability 单例)
//   - failed 占比 → "刷新失败率"(配额耗尽 / 网络异常的体感来源)
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计取舍
//  ────────────────────────────────────────────────────────────────────────────
//
//  - **actor**:计数器是共享可变状态,跨 ViewModel / Task 调用,actor 保证原子;
//    Swift 6 默认 Sendable 检查能跨边界传递。
//  - **进程级,不持久化**:计数器只为后续优化决策提供事实证据,不需要跨重启留存。
//    冷启动重置即"本次 session 的 cache 行为"。
//  - **不接 metric backend / OpenTelemetry**:本地工具,通过 `Settings → 调试`
//    或 `AppLog.cache` 周期 flush 就够用。引入远程汇报需要用户隐私同意,
//    不在 P2 范围内。
//  - **快照 struct + Sendable**:`snapshot()` 返回不可变 `ReadmeMetricsSnapshot`,
//    UI 层(Settings 调试段)可以直接读不需要担心后台 record 改值。
//

import Foundation

/// 单次快照,跨 actor 边界传递安全(struct + Sendable 字段)。
struct ReadmeMetricsSnapshot: Sendable, Equatable {
    let cachedHit: Int
    let refresh200: Int
    let refresh304: Int
    let refresh404: Int
    let refreshFailed: Int

    /// 总请求数(refresh 调用总次数,不含 cachedHit)。用于算 304 / 200 / 404 / failed 占比。
    var totalRefresh: Int {
        refresh200 + refresh304 + refresh404 + refreshFailed
    }
}

/// README 缓存命中 / 刷新结果计数器。详见文件头注释。
actor ReadmeMetrics {

    private var cachedHit: Int = 0
    private var refresh200: Int = 0
    private var refresh304: Int = 0
    private var refresh404: Int = 0
    private var refreshFailed: Int = 0

    init() {}

    // MARK: - 记录

    /// 本地缓存命中(含 trending → manage promote)。
    func recordCachedHit() {
        cachedHit &+= 1
    }

    /// 网络刷新 200 OK → 写新 HTML。
    func recordRefresh200() {
        refresh200 &+= 1
    }

    /// 网络刷新 304 Not Modified → touch cached_at。
    func recordRefresh304() {
        refresh304 &+= 1
    }

    /// 网络刷新 404 Not Found → 删本地行。
    func recordRefresh404() {
        refresh404 &+= 1
    }

    /// 网络刷新失败(transport / 5xx / 解析失败等)。
    func recordRefreshFailed() {
        refreshFailed &+= 1
    }

    // MARK: - 读取

    /// 当前计数器快照。
    ///
    /// 返回 `Sendable` 结构体,UI 层可以直接读,不需要担心后台 record 改值。
    func snapshot() -> ReadmeMetricsSnapshot {
        ReadmeMetricsSnapshot(
            cachedHit: cachedHit,
            refresh200: refresh200,
            refresh304: refresh304,
            refresh404: refresh404,
            refreshFailed: refreshFailed
        )
    }

    /// 重置全部计数器(测试用)。
    func reset() {
        cachedHit = 0
        refresh200 = 0
        refresh304 = 0
        refresh404 = 0
        refreshFailed = 0
    }
}
