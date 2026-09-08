//
//  ReadmeStarHistoryDOM.swift
//  Starcat
//
//  README 历史卡片的主题样式与有界交互。脚本只由 App 的 WKUserScript 注入；
//  ResizeObserver 只响应图表、标签和时间线尺寸变化，滚动不重建图表。卸载时释放 observer。
//

import Foundation

/// 与固定 HTML renderer 配套的私有 DOM 协议，所有选择器局限于 Starcat 拥有的卡片。
enum ReadmeStarHistoryDOM {
    static let css = """
    #starcat-readme-star-history[hidden] { display: none; }
    .starcat-star-history {
        --history-line: #08bd59;
        --history-foreground: #101725;
        --history-secondary: #677791;
        --history-panel: #ffffff;
        --history-inner: #ffffff;
        --history-border: #e5eaf2;
        --history-grid: #dde5ef;
        --history-chip: #eef1f6;
        --history-shadow: rgba(37, 52, 76, .07);
        --history-green: #12bc75;
        --history-purple: #8453ff;
        --history-pink: #f44895;
        --history-gold: #f4bb21;
        --history-brand: #9a6b00;
        --history-accent: #2580ff;
        --history-growth: #e96b4d;
        container-type: inline-size;
        container-name: star-history;
        /* 正文左右已有 24px；各补 28px 后保持对称，并在 34pt 工具条 + 10pt 贴边距离之外留 8px。 */
        margin: 28px 28px 8px;
        font-size: calc(var(--readme-body-font-size, 16px) * .875);
        color: var(--history-foreground);
        line-height: 1.4;
    }
    body.dark .starcat-star-history {
        --history-line: #30d875;
        --history-foreground: #f2f4f8;
        --history-secondary: #adb8ca;
        /* 半透明面板随真实系统窗底抬升，避免把深色卡片锁成黑色或蓝色块。 */
        --history-panel: rgba(255,255,255,.065);
        --history-inner: rgba(255,255,255,.045);
        --history-border: rgba(221,230,246,.12);
        --history-grid: rgba(209,221,244,.12);
        --history-chip: rgba(226,234,251,.085);
        --history-shadow: rgba(0,0,0,.16);
        --history-green: #35d990;
        --history-purple: #b293ff;
        --history-pink: #ff77b6;
        --history-gold: #ffd34d;
        --history-brand: #ffd34d;
        --history-accent: #6ba7ff;
        --history-growth: #ff927a;
    }
    .starcat-star-history *, .starcat-star-history *::before, .starcat-star-history *::after { box-sizing: border-box; }
    .starcat-star-history-card {
        padding: 24px 24px 18px;
        border: 1px solid var(--history-border);
        border-radius: 18px;
        background: var(--history-panel);
        box-shadow: 0 8px 28px var(--history-shadow);
    }
    /* 骨架沿用正式卡片的外框和响应式高度，替换为真实内容时不会突然改变滚动范围。 */
    .starcat-star-history-skeleton { overflow: hidden; }
    .starcat-star-history-skeleton-block {
        display: block;
        border-radius: 9px;
        background: var(--history-chip);
        animation: starcat-star-history-skeleton-pulse 1.35s ease-in-out infinite;
    }
    .starcat-star-history-skeleton-header {
        display: grid;
        grid-template-columns: 76px minmax(0, 1fr) 112px;
        align-items: start;
        gap: 18px;
    }
    .starcat-star-history-skeleton-avatar { width: 76px; height: 76px; border-radius: 18px; }
    .starcat-star-history-skeleton-copy { min-width: 0; padding-top: 2px; }
    .starcat-star-history-skeleton-copy .starcat-star-history-skeleton-block + .starcat-star-history-skeleton-block { margin-top: 9px; }
    .starcat-star-history-skeleton-kicker { width: min(180px, 48%); height: 14px; }
    .starcat-star-history-skeleton-title { width: min(320px, 76%); height: 24px; }
    .starcat-star-history-skeleton-description { width: min(520px, 94%); height: 13px; }
    .starcat-star-history-skeleton-tag { width: min(210px, 42%); height: 22px; border-radius: 999px; }
    .starcat-star-history-skeleton-total { width: 112px; height: 54px; justify-self: end; }
    .starcat-star-history-skeleton-chart { height: 310px; margin-top: 14px; border-radius: 12px; }
    .starcat-star-history-skeleton-metrics {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 10px;
        margin-top: 18px;
    }
    .starcat-star-history-skeleton-metrics .starcat-star-history-skeleton-block { min-height: 56px; border-radius: 13px; }
    .starcat-star-history-skeleton-journey { height: 76px; margin-top: 20px; border-radius: 12px; }
    .starcat-star-history-skeleton-footer { display: flex; justify-content: space-between; gap: 20px; margin-top: 20px; }
    .starcat-star-history-skeleton-footer .starcat-star-history-skeleton-block { width: 128px; height: 12px; }
    @keyframes starcat-star-history-skeleton-pulse {
        0%, 100% { opacity: .48; }
        50% { opacity: .86; }
    }
    .starcat-star-history-card-header { display: flex; justify-content: space-between; align-items: flex-start; gap: 24px; }
    .starcat-star-history-repository { display: flex; flex: 1; min-width: 0; align-items: flex-start; gap: 18px; }
    .starcat-star-history-avatar {
        position: relative; display: grid; place-items: center; width: 76px; height: 76px; flex: 0 0 76px;
        padding: 7px; border-radius: 18px; background: var(--history-chip); color: var(--history-secondary); font-size: 1.8em;
    }
    .starcat-star-history-avatar img { position: absolute; inset: 7px; width: calc(100% - 14px); height: calc(100% - 14px); border-radius: 12px; object-fit: cover; }
    .starcat-star-history-card-copy { min-width: 0; flex: 1; }
    .starcat-star-history-card-kicker { display: flex; align-items: center; gap: 9px; color: var(--history-secondary); font-weight: 500; font-size: .95em; }
    .starcat-star-history-card-kicker .starcat-star-history-icon { width: 20px; height: 20px; }
    .starcat-star-history-card h3 { margin: 5px 0 6px; padding: 0; border: 0; font-size: 1.55em; line-height: 1.2; letter-spacing: -.02em; color: var(--history-foreground); overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
    .starcat-star-history-card .starcat-star-history-description { margin: 0; color: var(--history-secondary); font-size: 1em; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
    .starcat-star-history-tags { display: flex; gap: 7px; flex-wrap: nowrap; min-width: 0; overflow: hidden; margin-top: 12px; }
    .starcat-star-history-tag { display: inline-flex; flex: 0 0 auto; align-items: center; gap: 7px; max-width: 180px; min-width: 0; padding: 4px 10px; border-radius: 999px; background: var(--history-chip); color: var(--history-secondary); font-size: .82em; line-height: 1.3; }
    .starcat-star-history-tag[hidden] { display: none; }
    .starcat-star-history-tag-language { max-width: min(180px, 100%); }
    .starcat-star-history-tag > span { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .starcat-star-history-tag i { display: block; width: 8px; height: 8px; flex: 0 0 8px; border-radius: 50%; }
    .starcat-star-history-dot-purple { background: var(--history-purple); }
    .starcat-star-history-dot-pink { background: var(--history-pink); }
    .starcat-star-history-dot-green { background: var(--history-green); }
    .starcat-star-history-current { flex: 0 0 auto; text-align: right; padding-top: 3px; }
    .starcat-star-history-current-value { display: flex; align-items: center; justify-content: flex-end; gap: 11px; }
    .starcat-star-history-current-value strong { color: var(--history-foreground); font-size: 2.25em; font-weight: 700; letter-spacing: -.035em; line-height: 1.1; font-variant-numeric: tabular-nums; }
    .starcat-star-history-current-star { color: var(--history-gold); display: flex; }
    .starcat-star-history-current-star .starcat-star-history-icon { width: 32px; height: 32px; }
    .starcat-star-history-current-label { display: block; color: var(--history-secondary); margin-top: 9px; font-size: .9em; }
    .starcat-star-history-icon { display: inline-block; width: 18px; height: 18px; flex: 0 0 auto; background: currentColor; -webkit-mask-size: contain; -webkit-mask-repeat: no-repeat; -webkit-mask-position: center; }
    .starcat-star-history-chart { position: relative; height: 310px; min-width: 0; margin-top: 14px; outline: none; }
    .starcat-star-history-chart:focus-visible { border-radius: 8px; outline: 2px solid var(--history-secondary); outline-offset: 3px; }
    .starcat-star-history-chart svg { display: block; width: 100%; height: 100%; overflow: visible; }
    .starcat-star-history-grid { stroke: var(--history-grid); stroke-width: 1; stroke-dasharray: 3 4; }
    .starcat-star-history-axis { fill: var(--history-secondary); font: 12px -apple-system, BlinkMacSystemFont, sans-serif; font-variant-numeric: tabular-nums; }
    .starcat-star-history-area { fill: url(#starcat-history-fill); stroke: none; }
    .starcat-star-history-gradient-top { stop-color: var(--history-line); stop-opacity: .27; }
    .starcat-star-history-gradient-bottom { stop-color: var(--history-line); stop-opacity: .035; }
    .starcat-star-history-line { fill: none; stroke: var(--history-line); stroke-width: 2.8; stroke-linejoin: round; stroke-linecap: round; }
    .starcat-star-history-endpoint, .starcat-star-history-hover-point { fill: var(--history-line); stroke: #fff; stroke-width: 2.5; }
    body.dark .starcat-star-history-endpoint, body.dark .starcat-star-history-hover-point { stroke: #30353c; }
    .starcat-star-history-marker-milestone, .starcat-star-history-marker-current { fill: var(--history-accent); }
    .starcat-star-history-marker-firstRecorded { fill: var(--history-green); }
    .starcat-star-history-marker-spike { fill: var(--history-growth); }
    .starcat-star-history-endpoint-ring { fill: none; stroke: var(--history-accent); stroke-width: 1.5; }
    .starcat-star-history-crosshair { stroke: var(--history-secondary); stroke-width: 1; stroke-dasharray: 3 4; opacity: .5; }
    .starcat-star-history-callout, .starcat-star-history-tooltip {
        position: absolute; padding: 7px 10px; width: max-content; min-width: 94px; max-width: 180px; border: 1px solid var(--history-border);
        border-radius: 9px; background: #fff; box-shadow: 0 4px 12px var(--history-shadow); pointer-events: none; white-space: nowrap; z-index: 1;
    }
    body.dark .starcat-star-history-callout, body.dark .starcat-star-history-tooltip { background: #353940; }
    .starcat-star-history-callout::after, .starcat-star-history-tooltip::after {
        content: ''; position: absolute; top: 100%; left: var(--tip-x, 50%); width: 8px; height: 8px;
        transform: translate(-50%, -4px) rotate(45deg); background: inherit; border-right: 1px solid var(--history-border); border-bottom: 1px solid var(--history-border);
    }
    .starcat-star-history-callout strong, .starcat-star-history-tooltip strong { display: block; color: var(--history-foreground); font-size: .9em; font-weight: 650; }
    .starcat-star-history-callout small, .starcat-star-history-tooltip small { display: block; color: var(--history-secondary); font-size: .8em; }
    .starcat-star-history-callout-subtitle { display: block; color: var(--history-secondary); font-size: .8em; }
    .starcat-star-history-callout > * { overflow: hidden; text-overflow: ellipsis; }
    .starcat-star-history-callout-spike strong { color: var(--history-growth); }
    .starcat-star-history-callout-current strong { font-weight: 700; }
    /* max-content 按内容收紧，上限只依赖图表宽度；不使用受 left 剩余空间影响的 auto 宽度。 */
    .starcat-star-history-tooltip { width: max-content; min-width: 0; max-width: min(260px, calc(100% - 8px)); white-space: normal; z-index: 2; }
    .starcat-star-history-tooltip > strong { white-space: nowrap; }
    .starcat-star-history-tooltip .starcat-star-history-tooltip-fields { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 5px 8px; margin: 6px 0 0; padding: 6px 0 0; border-top: 1px solid var(--history-border); font-size: .8em; line-height: 1.4; }
    .starcat-star-history-tooltip-fields dt, .starcat-star-history-tooltip-fields dd { margin: 0; padding: 0; font-size: inherit; font-weight: 400; }
    .starcat-star-history-tooltip-fields dt { max-width: 6.5em; color: var(--history-secondary); overflow-wrap: anywhere; }
    .starcat-star-history-tooltip-fields dd { color: var(--history-foreground); overflow-wrap: anywhere; }
    .starcat-star-history-tooltip-fields dd small { margin-top: 2px; font-size: 1em; }
    .starcat-star-history-tooltip[hidden] { display: none; }
    .starcat-star-history-metrics { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; margin-top: 18px; }
    /* 收紧纵向留白来减薄卡片；保留最小高度，让放大字号时仍能由两行文字自然撑开。 */
    .starcat-star-history-metric { container: star-history-metric / inline-size; display: flex; align-items: center; gap: 10px; min-width: 0; min-height: 56px; padding: 5px 12px; border: 1px solid var(--history-border); border-radius: 13px; background: var(--history-inner); box-shadow: 0 3px 10px var(--history-shadow); }
    .starcat-star-history-metric-icon { display: grid; place-items: center; width: 32px; height: 32px; flex: 0 0 32px; border-radius: 9px; }
    .starcat-star-history-metric-icon .starcat-star-history-icon { width: 23px; height: 23px; }
    .starcat-star-history-green { color: var(--history-green); background: rgba(18,188,117,.095); }
    .starcat-star-history-purple { color: var(--history-purple); background: rgba(132,83,255,.09); }
    .starcat-star-history-gold { color: var(--history-gold); background: rgba(244,187,33,.10); }
    .starcat-star-history-pink { color: var(--history-pink); background: rgba(244,72,149,.09); }
    .starcat-star-history-metric-copy { min-width: 0; flex: 1; }
    .starcat-star-history-metric-copy strong, .starcat-star-history-metric-copy > span { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .starcat-star-history-metric-copy strong { font-size: 1.3em; font-weight: 650; font-variant-numeric: tabular-nums; }
    .starcat-star-history-metric-copy > span { margin-top: 2px; font-size: max(11px, .82em); color: var(--history-secondary); }
    .starcat-star-history-miniature { display: none; width: clamp(56px, 28cqw, 112px); height: 36px; flex: 0 0 auto; fill: currentColor; stroke: currentColor; stroke-width: 1.7; stroke-linecap: round; stroke-linejoin: round; }
    .starcat-star-history-miniature-green { color: var(--history-green); }
    .starcat-star-history-miniature-purple { color: var(--history-purple); }
    .starcat-star-history-miniature-gold { color: var(--history-gold); }
    .starcat-star-history-miniature-pink { color: var(--history-pink); }
    @container star-history-metric (min-width: 240px) {
        .starcat-star-history-miniature { display: block; }
    }
    /* 与原型一致的开放时间线：弱连接线、类型色圆点、日期/标题/补充三层，不再套一层卡片。 */
    .starcat-star-journey { margin-top: 18px; }
    .starcat-star-journey h4 { margin: 0 0 8px; padding: 0; border: 0; color: var(--history-secondary); font-size: .85em; font-weight: 600; }
    /* 历史事件各占一列，文字在圆点右下方；最后 10px 专属于真实 Current，只画圆环。 */
    .starcat-star-journey .starcat-star-journey-track { position: relative; display: grid; grid-template-columns: repeat(var(--journey-columns), minmax(0, 1fr)) 10px; list-style: none; margin: 0; padding: 0; }
    .starcat-star-journey-track::before { content: ''; position: absolute; top: 5px; left: 5px; right: 5px; height: 1px; background: var(--history-grid); }
    .starcat-star-journey-track > .starcat-star-journey-node { --journey-color: var(--history-accent); position: relative; min-width: 0; margin: 0; padding: 12px 12px 0; list-style: none; text-align: left; }
    .starcat-star-journey-node[hidden] { display: none; }
    .starcat-star-journey-track > .starcat-star-journey-created { --journey-color: var(--history-secondary); }
    .starcat-star-journey-track > .starcat-star-journey-firstRecorded { --journey-color: var(--history-green); }
    .starcat-star-journey-track > .starcat-star-journey-spike,
    .starcat-star-journey-track > .starcat-star-journey-bestDay,
    .starcat-star-journey-track > .starcat-star-journey-bestWeek { --journey-color: var(--history-growth); }
    .starcat-star-journey-track > .starcat-star-journey-current { grid-column: -2 / -1; padding: 0; min-height: 10px; }
    .starcat-star-journey-dot { position: absolute; top: 0; left: 0; width: 10px; height: 10px; border: 2px solid #fff; border-radius: 50%; background: var(--journey-color); }
    body.dark .starcat-star-journey-dot { border-color: #353940; }
    .starcat-star-journey-current .starcat-star-journey-dot { box-shadow: 0 0 0 1.5px var(--history-accent); }
    /* 日期紧跟 10px 圆点下方；虚线依附文字区，随两行/三行内容伸缩，不额外撑出留白。 */
    .starcat-star-journey-copy { position: relative; margin: 0; padding: 0; }
    .starcat-star-journey-copy::before { content: ''; position: absolute; top: 0; bottom: 2px; left: -8px; border-left: 1px dashed var(--journey-color); }
    .starcat-star-journey-copy > * { display: block; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; line-height: 1.45; }
    .starcat-star-journey-copy time, .starcat-star-journey-copy > span { font-size: .78em; color: var(--history-secondary); }
    .starcat-star-journey-copy strong { color: var(--history-foreground); font-size: .82em; font-weight: 500; }
    .starcat-star-history-footer { display: flex; justify-content: space-between; flex-wrap: wrap; align-items: center; gap: 10px 20px; margin-top: 20px; color: var(--history-secondary); font-size: .78em; }
    .starcat-star-history-source, .starcat-star-history-footer-actions, .starcat-star-history-attribution { display: flex; align-items: center; gap: 7px; }
    .starcat-star-history-source { flex-wrap: wrap; }
    .starcat-star-history-footer-actions { margin-left: auto; flex: 0 0 auto; gap: 10px; }
    /* 小字号署名采用更深的金色以保证白底可读，深色主题再提亮，色相仍呼应星形。 */
    .starcat-star-history-attribution strong { font-weight: 600; color: var(--history-brand); }
    @container star-history (max-width: 799px) {
        .starcat-star-history-card { padding: 20px 18px 16px; }
        .starcat-star-history-card-header { gap: 16px; }
        .starcat-star-history-avatar { width: 64px; height: 64px; flex-basis: 64px; }
        .starcat-star-history-repository { gap: 12px; }
        .starcat-star-history-card .starcat-star-history-description { display: block; white-space: nowrap; text-overflow: ellipsis; }
        .starcat-star-history-current-value strong { font-size: 1.9em; }
        .starcat-star-history-current-star .starcat-star-history-icon { width: 27px; height: 27px; }
        .starcat-star-history-metrics { gap: 8px; }
        .starcat-star-history-metric { gap: 8px; padding: 4px 10px; min-height: 52px; }
        .starcat-star-history-metric-icon { width: 28px; height: 28px; flex-basis: 28px; border-radius: 8px; }
        .starcat-star-history-metric-icon .starcat-star-history-icon { width: 20px; height: 20px; }
        .starcat-star-history-metric-copy strong { font-size: 1.15em; }
        .starcat-star-history-chart { height: 280px; }
        .starcat-star-history-skeleton-header { grid-template-columns: 64px minmax(0, 1fr) 96px; gap: 16px; }
        .starcat-star-history-skeleton-avatar { width: 64px; height: 64px; }
        .starcat-star-history-skeleton-total { width: 96px; height: 48px; }
        .starcat-star-history-skeleton-chart { height: 280px; }
        .starcat-star-history-skeleton-metrics { gap: 8px; }
        .starcat-star-history-skeleton-metrics .starcat-star-history-skeleton-block { min-height: 52px; }
    }
    /* 窄栏仍保留四列和语义图标；缩小底座、间距与行高，避免隐藏图标后留下空卡片。 */
    @container star-history (max-width: 639px) {
        .starcat-star-history-metrics { gap: 6px; }
        .starcat-star-history-metric { gap: 6px; min-height: 44px; padding: 3px 6px; border-radius: 11px; }
        .starcat-star-history-metric-icon { width: 24px; height: 24px; flex-basis: 24px; border-radius: 7px; }
        .starcat-star-history-metric-icon .starcat-star-history-icon { width: 18px; height: 18px; }
        .starcat-star-history-metric-copy strong { line-height: 1.2; }
        .starcat-star-history-metric-copy > span { line-height: 1.3; }
        .starcat-star-history-skeleton-metrics { gap: 6px; }
        .starcat-star-history-skeleton-metrics .starcat-star-history-skeleton-block { min-height: 44px; }
    }
    @container star-history (max-width: 519px) {
        .starcat-star-history-card { padding: 16px 12px; }
        .starcat-star-history-card-header { flex-direction: column; }
        .starcat-star-history-repository { width: 100%; }
        .starcat-star-history-current { display: flex; align-items: center; gap: 12px; padding-left: 76px; }
        .starcat-star-history-current-label { margin: 0; }
        .starcat-star-history-card h3 { font-size: 1.35em; }
        .starcat-star-history-chart { height: 250px; margin-top: 2px; }
        .starcat-star-history-tooltip { max-width: min(220px, calc(100% - 8px)); padding: 6px 8px; }
        .starcat-star-history-skeleton-header { grid-template-columns: 64px minmax(0, 1fr); }
        .starcat-star-history-skeleton-total { grid-column: 2; width: min(120px, 50%); justify-self: start; }
        .starcat-star-history-skeleton-chart { height: 250px; margin-top: 2px; }
    }
    @container star-history (max-width: 339px) {
        .starcat-star-history-card { padding-inline: 8px; }
        .starcat-star-history-metrics { gap: 4px; }
        .starcat-star-history-metric { gap: 4px; padding-inline: 3px; }
        .starcat-star-history-metric-icon { width: 20px; height: 20px; flex-basis: 20px; border-radius: 6px; }
        .starcat-star-history-metric-icon .starcat-star-history-icon { width: 14px; height: 14px; }
        .starcat-star-history-current { padding-left: 0; }
    }
    @media (prefers-reduced-motion: reduce) {
        .starcat-star-history-skeleton-block { animation: none; opacity: .68; }
    }
    """

    /// 在 README 文档自己的闭包中声明，避免暴露给远端内容新的 native bridge。
    static let script = """
    function configureStarHistory(host) {
        var tags = host.querySelector('.starcat-star-history-tags');
        var languageChip = tags && tags.querySelector('.starcat-star-history-tag-language');
        var topicChips = tags ? Array.from(tags.querySelectorAll('.starcat-star-history-tag-topic')) : [];
        var moreChip = tags && tags.querySelector('.starcat-star-history-tag-more');
        var topicNames = tags ? JSON.parse(tags.dataset.topics) : [];
        var journey = host.querySelector('.starcat-star-journey-track');
        var journeyNodes = journey ? Array.from(journey.children) : [];
        // 先预留语言与 +N，再依次减少 Topic；每次从完整候选集开始，放宽窗口才能恢复标签。
        function layoutTags() {
            if (!tags || !moreChip || tags.clientWidth <= 0) { return; }
            if (languageChip) { languageChip.style.maxWidth = ''; }
            topicChips.forEach(function(chip) { chip.hidden = false; });
            var available = tags.clientWidth, gap = parseFloat(getComputedStyle(tags).columnGap) || 0;
            var languageWidth = languageChip ? languageChip.getBoundingClientRect().width : 0;
            var topicWidths = topicChips.map(function(chip) { return chip.getBoundingClientRect().width; });
            var shown = topicChips.length, moreWidth = 0;
            for (; shown >= 0; shown--) {
                var hidden = topicNames.length - shown;
                moreChip.hidden = hidden === 0;
                moreChip.textContent = '+' + hidden;
                moreWidth = hidden ? moreChip.getBoundingClientRect().width : 0;
                var chipCount = (languageChip ? 1 : 0) + shown + (hidden ? 1 : 0);
                var needed = languageWidth + moreWidth + topicWidths.slice(0, shown).reduce(function(sum, value) { return sum + value; }, 0)
                    + gap * Math.max(0, chipCount - 1);
                if (needed <= available || shown === 0) { break; }
            }
            topicChips.forEach(function(chip, index) { chip.hidden = index >= shown; });
            moreChip.title = topicNames.slice(shown).join(', ');
            if (languageChip && shown === 0) {
                languageChip.style.maxWidth = Math.max(0, Math.min(languageWidth, available - moreWidth - (moreWidth ? gap : 0))) + 'px';
            }
        }
        // 每次根据容器宽度重新取排名前 N 个；保留创建/当前，放宽后恢复被隐藏的成长节点。
        // 字号参与预算，放大 README 文字时减少节点，不缩字或把时间线折成两行。
        function layoutJourney() {
            if (!journey || journey.clientWidth <= 0) { return; }
            var minimumWidth = Math.max(118, parseFloat(getComputedStyle(journey).fontSize) * 10);
            // Current 仍计入事件名额；只改变其显示内容，避免改变前面历史节点的筛选结果。
            var slots = Math.max(2, Math.min(6, Math.floor((journey.clientWidth - 10) / minimumWidth)));
            journeyNodes.forEach(function(node) { node.hidden = Number(node.dataset.rank) >= slots; });
            var visible = journeyNodes.filter(function(node) { return !node.hidden; });
            journey.style.setProperty('--journey-columns', Math.max(1, visible.length - 1));
        }
        function layoutMetadata() { layoutTags(); layoutJourney(); }
        var chart = host.querySelector('.starcat-star-history-chart');
        var points = chart ? JSON.parse(chart.dataset.points) : [];
        var rendered = chart ? JSON.parse(chart.dataset.rendered) : [];
        // 加载骨架没有图表数据；仍保留通用 metadata observer 清理协议，方便原地替换。
        if (!chart || points.length < 2 || rendered.length < 2) {
            var metadataObserver = new ResizeObserver(layoutMetadata);
            if (tags) { metadataObserver.observe(tags); }
            if (journey) { metadataObserver.observe(journey); }
            host.starcatHistoryCleanup = function() { metadataObserver.disconnect(); };
            layoutMetadata();
            return;
        }
        var annotations = JSON.parse(chart.dataset.annotations || '[]');
        var svg = chart.querySelector('svg');
        var callouts = chart.querySelector('.starcat-star-history-callouts');
        var tooltip = chart.querySelector('.starcat-star-history-tooltip');
        var markerGroup = svg.querySelector('.starcat-star-history-markers');
        var crosshair = svg.querySelector('.starcat-star-history-crosshair');
        var hoverPoint = svg.querySelector('.starcat-star-history-hover-point');
        var maximum = Number(chart.dataset.maximum), step = Number(chart.dataset.step);
        var locale = chart.dataset.locale;
        var number = new Intl.NumberFormat(locale, { maximumFractionDigits: 0 });
        var shortNumber = new Intl.NumberFormat(locale, { maximumFractionDigits: 1 });
        var fullDate = new Intl.DateTimeFormat(locale, { year: 'numeric', month: 'short', day: 'numeric', timeZone: 'UTC' });
        var start = points[0][0], end = points[points.length - 1][0], duration = Math.max(1, end - start);
        var width = 0, height = 0, left = 44, right = 12, top = 64, bottom = 30;
        var selected = points.length - 1, tooltipIndex = -1, interacting = false;
        function compact(value) {
            var magnitude = Math.abs(value);
            if (magnitude >= 999500) { return shortNumber.format(value / 1000000) + 'M'; }
            if (magnitude >= 1000) { return shortNumber.format(value / 1000) + 'K'; }
            return number.format(value);
        }
        function x(point) { return left + (point[0] - start) / duration * (width - left - right); }
        function y(point) { return top + (1 - point[1] / maximum) * (height - top - bottom); }
        function element(tag, attributes, text) {
            var node = document.createElementNS('http://www.w3.org/2000/svg', tag);
            Object.keys(attributes).forEach(function(key) { node.setAttribute(key, attributes[key]); });
            if (text !== undefined) { node.textContent = text; }
            return node;
        }
        // 全序列二分查找，mousemove 不扫描数千个日期，也不触发 SwiftUI 重算。
        function nearest(time) {
            var low = 0, high = points.length - 1;
            while (low < high) {
                var middle = (low + high) >> 1;
                if (points[middle][0] < time) { low = middle + 1; } else { high = middle; }
            }
            return low > 0 && time - points[low - 1][0] < points[low][0] - time ? low - 1 : low;
        }
        function fillLabel(label, point, full) {
            var value = document.createElement('strong');
            value.textContent = full ? number.format(point[1]) : compact(point[1]);
            var date = document.createElement('small');
            date.textContent = fullDate.format(point[0]);
            label.replaceChildren(value, date);
        }
        function positionLabel(label, point) {
            var labelWidth = label.offsetWidth, labelHeight = label.offsetHeight;
            var labelX = Math.max(2, Math.min(width - labelWidth - 2, x(point) - labelWidth / 2));
            var labelY = Math.max(2, y(point) - labelHeight - 14);
            label.style.left = labelX + 'px'; label.style.top = labelY + 'px';
            label.style.setProperty('--tip-x', Math.max(10, Math.min(labelWidth - 10, x(point) - labelX)) + 'px');
            return { x: labelX, y: labelY, width: labelWidth, height: labelHeight };
        }
        function showSelection() {
            var point = points[selected];
            var annotation = annotations.find(function(item) { return item.index === selected; });
            var rows = annotation ? (annotation.rows || []) : [];
            tooltip.hidden = false;
            // 相同历史点复用 DOM；容器缩放只重新定位，垂直移动光标不会改变内容或换行。
            if (tooltipIndex !== selected) {
                tooltipIndex = selected;
                fillLabel(tooltip, point, true);
                if (rows.length) {
                    var fields = document.createElement('dl');
                    fields.className = 'starcat-star-history-tooltip-fields';
                    rows.forEach(function(row) {
                        var label = document.createElement('dt'), value = document.createElement('dd');
                        label.textContent = row.label;
                        value.textContent = row.value;
                        if (row.note) {
                            var note = document.createElement('small');
                            note.textContent = row.note;
                            value.appendChild(note);
                        }
                        fields.appendChild(label); fields.appendChild(value);
                    });
                    tooltip.appendChild(fields);
                }
            }
            positionLabel(tooltip, point);
            callouts.style.visibility = 'hidden';
            crosshair.style.display = ''; hoverPoint.style.display = '';
            crosshair.setAttribute('x1', x(point)); crosshair.setAttribute('x2', x(point));
            crosshair.setAttribute('y1', top); crosshair.setAttribute('y2', height - bottom);
            hoverPoint.setAttribute('cx', x(point)); hoverPoint.setAttribute('cy', y(point));
            chart.setAttribute('aria-valuenow', selected);
            var details = rows.map(function(row) { return row.label + ': ' + row.value + (row.note ? ', ' + row.note : ''); });
            chart.setAttribute('aria-valuetext', [number.format(point[1]), fullDate.format(point[0])].concat(details).join(', '));
        }
        function hideSelection() {
            interacting = false;
            tooltip.hidden = true; callouts.style.visibility = '';
            crosshair.style.display = 'none'; hoverPoint.style.display = 'none';
        }
        function layout() {
            if (!chart.isConnected) { return; }
            layoutMetadata();
            width = chart.clientWidth; height = chart.clientHeight;
            if (width < 100) { return; }
            svg.setAttribute('viewBox', '0 0 ' + width + ' ' + height);
            var coordinates = rendered.map(function(point) { return x(point) + ',' + y(point); }).join(' ');
            svg.querySelector('.starcat-star-history-line').setAttribute('points', coordinates);
            svg.querySelector('.starcat-star-history-area').setAttribute('points', x(rendered[0]) + ',' + (height - bottom) + ' ' + coordinates + ' ' + x(rendered[rendered.length - 1]) + ',' + (height - bottom));
            var yTicks = svg.querySelector('.starcat-star-history-y-ticks'); yTicks.replaceChildren();
            for (var index = 0; index <= 4; index++) {
                var value = step * index, tickY = y([0, value]);
                yTicks.appendChild(element('line', { class: 'starcat-star-history-grid starcat-star-history-grid-horizontal', x1: left, x2: width - right, y1: tickY, y2: tickY }));
                yTicks.appendChild(element('text', { class: 'starcat-star-history-axis starcat-star-history-axis-y', x: left - 10, y: tickY, 'text-anchor': 'end', 'dominant-baseline': 'middle' }, compact(value)));
            }
            var tickCount = width >= 800 ? 6 : (width >= 500 ? 4 : 3);
            var days = duration / 86400000;
            var dateFormat = new Intl.DateTimeFormat(locale, days <= 180 ? { month: 'short', day: 'numeric', timeZone: 'UTC' } : { year: 'numeric', month: 'short', timeZone: 'UTC' });
            var xTicks = svg.querySelector('.starcat-star-history-x-ticks'); xTicks.replaceChildren();
            for (var tick = 0; tick < tickCount; tick++) {
                var time = start + duration * tick / (tickCount - 1), tickX = x([time, 0]);
                xTicks.appendChild(element('line', { class: 'starcat-star-history-grid', x1: tickX, x2: tickX, y1: top, y2: height - bottom }));
                xTicks.appendChild(element('text', { class: 'starcat-star-history-axis starcat-star-history-axis-x', x: tickX, y: height - 8, 'text-anchor': tick === 0 ? 'start' : (tick === tickCount - 1 ? 'end' : 'middle') }, dateFormat.format(time)));
            }
            callouts.replaceChildren(); markerGroup.replaceChildren();
            var limit = width >= 800 ? 4 : (width >= 480 ? 3 : (width >= 300 ? 2 : 1));
            var occupied = [], used = new Set();
            // 只使用完整历史选出的语义事件；Current 排第一，余下按价值与碰撞情况决定是否显示。
            annotations.forEach(function(annotation) {
                if (occupied.length >= limit) { return; }
                var candidate = annotation.index;
                if (used.has(candidate)) { return; } used.add(candidate);
                var point = points[candidate], label = document.createElement('div');
                label.className = 'starcat-star-history-callout starcat-star-history-callout-' + annotation.kind;
                fillLabel(label, point, false);
                label.querySelector('strong').textContent = annotation.title;
                if (annotation.subtitle) {
                    var subtitle = document.createElement('span');
                    subtitle.className = 'starcat-star-history-callout-subtitle';
                    subtitle.textContent = annotation.subtitle;
                    label.insertBefore(subtitle, label.querySelector('small'));
                }
                callouts.appendChild(label);
                var box = positionLabel(label, point);
                var overlaps = occupied.some(function(other) { return box.x < other.x + other.width + 12 && box.x + box.width + 12 > other.x && box.y < other.y + other.height + 8 && box.y + box.height + 8 > other.y; });
                if (overlaps) { label.remove(); return; } occupied.push(box);
                if (annotation.kind === 'current') {
                    markerGroup.appendChild(element('circle', { class: 'starcat-star-history-endpoint-ring', cx: x(point), cy: y(point), r: 7.5 }));
                }
                markerGroup.appendChild(element('circle', { class: 'starcat-star-history-endpoint starcat-star-history-marker-' + annotation.kind, cx: x(point), cy: y(point), r: 5.5 }));
            });
            if (interacting) { showSelection(); } else { hideSelection(); }
        }
        chart.addEventListener('pointermove', function(event) {
            var box = chart.getBoundingClientRect();
            var progress = Math.max(0, Math.min(1, (event.clientX - box.left - left) / (width - left - right)));
            var next = nearest(start + duration * progress);
            if (interacting && next === selected) { return; }
            selected = next; interacting = true; showSelection();
        });
        chart.addEventListener('pointerleave', function() { if (document.activeElement !== chart) { hideSelection(); } });
        chart.addEventListener('focus', function() { interacting = true; showSelection(); });
        chart.addEventListener('blur', hideSelection);
        chart.addEventListener('keydown', function(event) {
            if (event.key === 'ArrowLeft') { selected = Math.max(0, selected - 1); }
            else if (event.key === 'ArrowRight') { selected = Math.min(points.length - 1, selected + 1); }
            else if (event.key === 'Home') { selected = 0; }
            else if (event.key === 'End') { selected = points.length - 1; }
            else if (event.key === 'Escape') { chart.blur(); return; }
            else { return; }
            event.preventDefault(); interacting = true; showSelection();
        });
        // ResizeObserver 已按布局批次通知；再次等待动画帧会在离屏 WebView 中停滞，留下旧坐标。
        // SVG 和绝对定位标注不改变容器尺寸，因此可以直接重排，不产生尺寸反馈循环。
        var observer = new ResizeObserver(layout);
        observer.observe(chart);
        if (tags) { observer.observe(tags); }
        if (journey) { observer.observe(journey); }
        host.starcatHistoryCleanup = function() { observer.disconnect(); };
        layout();
    }
    """
}
