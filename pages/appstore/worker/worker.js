// ============================================================================
// dong4j.app — 应用橱窗路由 Worker
//
// 架构:
//   dong4j.app/               → 内置应用橱窗首页 (列出所有 App)
//   dong4j.app/starcat/*      → 反向代理到 starcat-appstore.pages.dev
//   dong4j.app/<未来应用>/*    → 反向代理到对应 Pages 项目
//
// 添加新应用: 只需在 APPS 对象里加一行
//
// 部署: npx wrangler deploy
// 路由: npx wrangler routes add 'dong4j.app/*' --worker dong4j-app-router
// ============================================================================

// --- 应用路由表 ------------------------------------------------------------
// key: URL 子路径前缀 (如 "/starcat")
// val: { host: Cloudflare Pages .dev 域名, name: 应用展示名, desc: 简介 }
const APPS = {
    "/starcat": {
        host: "starcat-appstore.pages.dev",
        name: "Starcat for GitHub",
        desc: "Turn GitHub Stars into a searchable AI knowledge base. Native macOS app.",
        icon: "⭐",
    },
    // 未来应用示例:
    // "/another-app": {
    //     host: "another-app.pages.dev",
    //     name: "Another App",
    //     desc: "Description here.",
    //     icon: "🆕",
    // },
};

// --- 处理函数 --------------------------------------------------------------

/**
 * 首页 — dong4j.app 应用橱窗
 * 列出 APPS 表中的所有应用，每个应用一个卡片，点击进入对应子路径
 */
function serveIndex() {
    const appCards = Object.entries(APPS)
        .map(([path, app]) => {
            return `
            <a href="${path}" class="app-card">
                <div class="app-icon">${app.icon}</div>
                <div class="app-info">
                    <h2>${app.name}</h2>
                    <p>${app.desc}</p>
                </div>
                <div class="app-arrow">→</div>
            </a>`;
        })
        .join("\n");

    const html = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>dong4j.app — Apps</title>
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
        .app-icon { font-size: 32px; flex-shrink: 0; width: 48px; text-align: center; }
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
        <p>Independent apps for developers</p>
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
