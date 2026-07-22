// ============================================================================
// dong4j.app — 个人项目导航 + 本域应用路由 Worker
//
// 架构:
//   dong4j.app/               → 内置导航首页 (LINKS 卡片列表)
//   dong4j.app/starcat/*      → 反向代理到 starcat-appstore.pages.dev
//   dong4j.app/<未来应用>/*    → 反向代理到对应 Pages 项目
//
// 添加首页卡片: 在 LINKS 数组里加一项
// 添加本域反代应用: 在 APPS 对象里加一行（并可选同步到 LINKS）
//
// 部署: 走 pages/appstore/deploy.sh（末尾 wrangler deploy）
// 单独部署: cd pages/appstore/worker && wrangler deploy
// ============================================================================

// --- 首页导航卡片 ------------------------------------------------------------
// 只负责首页展示；外链与本域路径都可挂。
// iconEmoji: 纯 emoji；iconUrl: 图片（与 emoji 二选一，优先 iconUrl）
// external: true 时新标签打开；false / 省略则同标签进本域路径。
const LINKS = [
    {
        name: "Home",
        desc: "Personal homepage",
        href: "https://home.dong4j.site/",
        iconEmoji: "🏠",
        external: true,
    },
    {
        name: "GitHub",
        desc: "Code & open source",
        href: "https://github.com/dong4j",
        // GitHub 官方头像快捷地址，随账号头像自动更新
        iconUrl: "https://github.com/dong4j.png?size=96",
        external: true,
    },
    {
        name: "Blog",
        desc: "Writing & notes",
        href: "https://blog.dong4j.site/",
        iconEmoji: "✍️",
        external: true,
    },
    {
        name: "Starcat for GitHub",
        desc: "Turn GitHub Stars into a searchable AI knowledge base. Native macOS app.",
        href: "/starcat",
        // 经本 Worker 反代，路径对应 Pages 里的应用图标
        iconUrl: "/starcat/starcat-logo.png",
        // 与其余卡片一致：新标签打开，避免盖掉导航首页
        external: true,
    },
    {
        name: "ZekaStack",
        desc: "Cloud-native infrastructure toolkit.",
        href: "https://zekastack.dong4j.site/",
        iconEmoji: "🧩",
        external: true,
    },
];

// --- 本域应用反代表 ------------------------------------------------------------
// key: URL 子路径前缀 (如 "/starcat")
// val: { host: Cloudflare Pages .dev 域名 }
// 首页卡片与反代解耦：外链只进 LINKS，不进这里。
const APPS = {
    "/starcat": {
        host: "starcat-appstore.pages.dev",
    },
    // 未来应用示例:
    // "/another-app": {
    //     host: "another-app.pages.dev",
    // },
};

// --- 处理函数 --------------------------------------------------------------

/**
 * 渲染单张导航卡片的图标区域。
 * 有 iconUrl 用图片（圆角），否则回退 emoji。
 */
function renderCardIcon(link) {
    if (link.iconUrl) {
        return `<img class="app-icon-img" src="${link.iconUrl}" alt="" width="48" height="48" loading="lazy">`;
    }
    return `<div class="app-icon">${link.iconEmoji || "🔗"}</div>`;
}

/**
 * 首页 — dong4j.app 个人项目导航
 * 按 LINKS 顺序输出卡片；外链新标签，本域路径同标签。
 */
function serveIndex() {
    const appCards = LINKS.map((link) => {
        const externalAttrs = link.external
            ? ' target="_blank" rel="noopener noreferrer"'
            : "";
        return `
            <a href="${link.href}" class="app-card"${externalAttrs}>
                ${renderCardIcon(link)}
                <div class="app-info">
                    <h2>${link.name}</h2>
                    <p>${link.desc}</p>
                </div>
                <div class="app-arrow">→</div>
            </a>`;
    }).join("\n");

    const html = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>dong4j.app — Projects</title>
    <link rel="icon" type="image/png" href="https://github.com/dong4j.png?size=64">
    <link rel="apple-touch-icon" href="https://github.com/dong4j.png?size=180">
    <style>
        :root {
            --bg: #090B10;
            --card-bg: rgba(255,255,255,0.05);
            --border: rgba(255,255,255,0.10);
            --text: #F7F7F8;
            --text-secondary: #B8BDC7;
            --accent: #7DD3FC;
        }
        *, *::before, *::after { margin:0; padding:0; box-sizing:border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif;
            background: var(--bg); color: var(--text);
            min-height: 100vh; display: flex; flex-direction: column;
            align-items: center; justify-content: center;
            padding: 40px 24px;
            -webkit-font-smoothing: antialiased;
        }
        header { text-align: center; margin-bottom: 48px; }
        header h1 { font-size: 28px; font-weight: 700; letter-spacing: -0.02em; margin-bottom: 8px; }
        header p { color: var(--text-secondary); font-size: 16px; }
        .app-list { display: flex; flex-direction: column; gap: 16px; max-width: 520px; width: 100%; }
        .app-card {
            display: flex; align-items: center; gap: 20px;
            padding: 24px 28px;
            background: var(--card-bg); border: 1px solid var(--border);
            border-radius: 16px; text-decoration: none; color: inherit;
            transition: border-color .2s ease, background .2s ease, transform .2s ease;
        }
        .app-card:hover {
            border-color: rgba(255,255,255,0.22);
            background: rgba(255,255,255,0.08);
            transform: translateY(-1px);
        }
        .app-icon {
            font-size: 32px; flex-shrink: 0; width: 48px; height: 48px;
            display: flex; align-items: center; justify-content: center;
            text-align: center; line-height: 1;
        }
        .app-icon-img {
            flex-shrink: 0; width: 48px; height: 48px;
            border-radius: 12px; object-fit: cover;
            background: rgba(255,255,255,0.06);
        }
        .app-info { flex: 1; min-width: 0; }
        .app-info h2 { font-size: 18px; font-weight: 700; margin-bottom: 4px; }
        .app-info p { font-size: 14px; color: var(--text-secondary); line-height: 1.5; }
        .app-arrow { font-size: 20px; color: var(--text-secondary); flex-shrink: 0; }
        footer {
            margin-top: 48px; text-align: center;
            font-size: 13px; color: rgba(255,255,255,0.3);
        }
        footer a { color: var(--accent); text-decoration: none; }
        footer a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <header>
        <h1>dong4j.app</h1>
        <p>Projects &amp; links</p>
    </header>
    <main class="app-list">
        ${appCards}
    </main>
    <footer>
        <a href="mailto:dong4j@gmail.com">dong4j@gmail.com</a>
    </footer>
</body>
</html>`;

    return new Response(html, {
        status: 200,
        headers: { "Content-Type": "text/html; charset=utf-8" },
    });
}

/**
 * 根域 robots.txt。
 *
 * 搜索引擎只会读取域名根路径的 robots.txt；Starcat App Store 站点挂在
 * /starcat 子路径下，所以这里必须从 Worker 返回 sitemap 入口。
 */
function serveRobots() {
    return new Response(
        [
            "User-agent: *",
            "Allow: /",
            "Sitemap: https://dong4j.app/starcat/sitemap.xml",
            "",
        ].join("\n"),
        {
            status: 200,
            headers: { "Content-Type": "text/plain; charset=utf-8" },
        }
    );
}

/**
 * 子应用代理 — 将 /app-path/* 转发到对应 Pages 项目
 * 自动剥离子路径前缀、修正 Location 头和 HTML 中的域名
 */
async function proxyToPages(request, pathPrefix, pagesHost) {
    const url = new URL(request.url);

    // 剥离路径前缀
    //  /starcat           → /
    //  /starcat/support   → /support
    const targetPath = url.pathname.slice(pathPrefix.length) || "/";
    const targetUrl = `https://${pagesHost}${targetPath}${url.search}`;

    const modifiedRequest = new Request(targetUrl, {
        method: request.method,
        headers: request.headers,
        body: request.body,
        redirect: "manual",
    });
    modifiedRequest.headers.set("Host", pagesHost);

    let response = await fetch(modifiedRequest);

    // 修正重定向 Location 头
    if ([301, 302, 303, 307, 308].includes(response.status)) {
        const location = response.headers.get("Location");
        if (location) {
            let newLocation = location;
            // pages.dev 域名 → dong4j.app/app-path
            newLocation = newLocation.replace(
                `https://${pagesHost}`,
                `https://dong4j.app${pathPrefix}`
            );
            // 相对路径 /xxx → /app-path/xxx
            if (newLocation.startsWith("/") && !newLocation.startsWith(pathPrefix)) {
                newLocation = `${pathPrefix}${newLocation}`;
            }
            response = new Response(response.body, {
                status: response.status,
                headers: response.headers,
            });
            response.headers.set("Location", newLocation);
        }
    }

    // 修正 HTML 中的绝对 URL 引用
    const contentType = response.headers.get("Content-Type") || "";
    if (contentType.includes("text/html")) {
        let html = await response.text();
        html = html.replace(
            new RegExp(`https://${pagesHost.replace(/\./g, "\\.")}`, "g"),
            `https://dong4j.app${pathPrefix}`
        );
        response = new Response(html, {
            status: response.status,
            headers: response.headers,
        });
    }

    return response;
}

// --- 主路由 ----------------------------------------------------------------
export default {
    async fetch(request, env, ctx) {
        const url = new URL(request.url);
        const pathname = url.pathname;

        // 1. 首页 — dong4j.app/
        if (pathname === "/" || pathname === "") {
            return serveIndex();
        }

        // 2. 搜索引擎入口 — 必须位于域名根路径，而不是 /starcat/robots.txt
        if (pathname === "/robots.txt") {
            return serveRobots();
        }

        // 3. 遍历应用路由表，匹配子路径
        for (const [prefix, app] of Object.entries(APPS)) {
            // 精确匹配 /app-name（无结尾 /）→ 301 重定向到 /app-name/
            // 这样浏览器才能正确解析相对路径的图片/资源
            if (pathname === prefix) {
                return Response.redirect(
                    `https://dong4j.app${prefix}/${url.search}`,
                    301
                );
            }
            // /app-name/xxx → 代理到 Pages 项目
            if (pathname.startsWith(prefix + "/")) {
                return proxyToPages(request, prefix, app.host);
            }
        }

        // 4. 未匹配任何路由 — 返回 404
        return new Response("404 — Not Found", {
            status: 404,
            headers: { "Content-Type": "text/plain; charset=utf-8" },
        });
    },
};
