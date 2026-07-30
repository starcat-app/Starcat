/**
 * Starcat 1.2.0 App Store 截图渲染器。
 *
 * 使用 HTML/CSS 对真实应用截图做确定性排版，避免生成式图像工具改写界面文字
 * 或伪造产品能力。输出固定为 Mac App Store 接受的 2880 × 1800 PNG。
 */
import { chromium } from "playwright";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const screenshotsRoot = path.resolve(scriptDirectory, "../..");
const sourceRoot = path.join(screenshotsRoot, "2026-06-23-app-store", "landingpage");
const outputRoot = path.resolve(scriptDirectory, "../en-US");

const pages = [
  {
    file: "01-knowledge-library.png",
    source: "主窗口.png",
    title: "Turn GitHub Stars<br>into a <em>knowledge base.</em>",
    accent: "#0A84FF",
    glow: "#33A7FF",
  },
  {
    file: "02-global-search.png",
    source: "主窗口-全局搜索.png",
    title: "Find any saved project<br>in <em>seconds.</em>",
    accent: "#32D7FF",
    glow: "#0A84FF",
  },
  {
    file: "03-smart-collections.png",
    source: "主窗口-智能集合.png",
    title: "Let Smart Collections<br><em>organize for you.</em>",
    accent: "#8E5CFF",
    glow: "#BF5AF2",
  },
  {
    file: "04-discover-projects.png",
    source: "主窗口-探索栏目.png",
    title: "Discover projects<br><em>worth watching.</em>",
    accent: "#30D158",
    glow: "#64D2FF",
  },
  {
    file: "05-release-tracking.png",
    source: "主窗口-Release.png",
    title: "Never miss an<br><em>important release.</em>",
    accent: "#FF9F0A",
    glow: "#FF375F",
  },
  {
    file: "06-personal-notes.png",
    source: "主窗口-个人笔记.png",
    title: "Keep your insights<br><em>with every project.</em>",
    accent: "#FF375F",
    glow: "#BF5AF2",
  },
  {
    file: "07-ai-summary.png",
    source: "主窗口-AI摘要.png",
    title: "Let AI understand<br><em>any repository.</em>",
    accent: "#BF5AF2",
    glow: "#5E5CE6",
  },
  {
    file: "08-rag-knowledge-base.png",
    source: "RAG 工作台-知识库.png",
    title: "Connect repositories<br>into one <em>knowledge base.</em>",
    accent: "#64D2FF",
    glow: "#30D158",
  },
  {
    file: "09-rag-workspace.png",
    source: "RAG 工作台.png",
    title: "Ask your entire<br><em>knowledge base.</em>",
    accent: "#5E5CE6",
    glow: "#32D7FF",
  },
  {
    file: "10-grounded-answers.png",
    source: path.join("processed", "RAG 工作台-四面板-分层合成.png"),
    title: "Every answer comes<br><em>with evidence.</em>",
    accent: "#30D158",
    glow: "#0A84FF",
    imageFit: "cover",
    imagePosition: "center top",
  },
];

/**
 * 把真实截图嵌入页面，避免浏览器访问本地文件时受路径编码或权限影响。
 */
function pngDataURL(relativePath) {
  const sourcePath = path.join(sourceRoot, relativePath);
  const data = fs.readFileSync(sourcePath).toString("base64");
  return `data:image/png;base64,${data}`;
}

/**
 * 每张图共享同一构图，只通过强调色和标题形成节奏，保证商店列表连续浏览时
 * 看起来是一套设计，而不是十张互不相关的宣传图。
 */
function htmlFor(item) {
  const image = pngDataURL(item.source);
  const imageFit = item.imageFit ?? "cover";
  const imagePosition = item.imagePosition ?? "center top";

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <style>
    * { box-sizing: border-box; }
    html, body {
      margin: 0;
      width: 2880px;
      height: 1800px;
      overflow: hidden;
    }
    body {
      position: relative;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display",
        "Helvetica Neue", Arial, sans-serif;
      color: #fff;
      background:
        radial-gradient(circle at 8% 6%, ${item.accent}7a 0, transparent 31%),
        radial-gradient(circle at 88% 2%, ${item.glow}4f 0, transparent 30%),
        radial-gradient(circle at 50% 88%, ${item.accent}24 0, transparent 43%),
        linear-gradient(135deg, #153f73 0%, #0c2d59 46%, #061b3b 100%);
    }
    body::before {
      content: "";
      position: absolute;
      inset: 0;
      opacity: .19;
      background-image:
        linear-gradient(90deg, rgba(255,255,255,.12) 1px, transparent 1px),
        linear-gradient(rgba(255,255,255,.10) 1px, transparent 1px);
      background-size: 120px 120px;
      mask-image: radial-gradient(circle at 50% 62%, black, transparent 68%);
    }
    body::after {
      content: "";
      position: absolute;
      left: 280px;
      right: 280px;
      top: 525px;
      height: 520px;
      border-radius: 50%;
      background: ${item.accent};
      opacity: .16;
      filter: blur(150px);
    }
    .headline {
      position: absolute;
      z-index: 3;
      top: 110px;
      left: 145px;
      width: 2590px;
      margin: 0;
      text-align: center;
      font-size: 150px;
      font-weight: 780;
      line-height: .98;
      letter-spacing: -6px;
      text-wrap: balance;
      text-shadow: 0 12px 42px rgba(0, 0, 0, .22);
    }
    .headline em {
      font-family: inherit;
      font-weight: inherit;
      font-style: italic;
      letter-spacing: -6px;
    }
    .window-glow {
      position: absolute;
      z-index: 1;
      left: 190px;
      top: 675px;
      width: 2500px;
      height: 1030px;
      border-radius: 90px;
      background: linear-gradient(135deg, ${item.accent}80, ${item.glow}28);
      filter: blur(90px);
      opacity: .5;
    }
    .window {
      position: absolute;
      z-index: 2;
      left: 110px;
      top: 590px;
      width: 2660px;
      height: 1210px;
      overflow: hidden;
      border: 2px solid rgba(255, 255, 255, .28);
      border-radius: 48px 48px 0 0;
      background: #0d1018;
      box-shadow:
        0 64px 150px rgba(0, 0, 0, .55),
        0 20px 54px rgba(0, 0, 0, .36),
        inset 0 1px 0 rgba(255, 255, 255, .16);
    }
    .window img {
      width: 100%;
      height: 100%;
      display: block;
      object-fit: ${imageFit};
      object-position: ${imagePosition};
      background: #0d1018;
    }
    .window::after {
      content: "";
      position: absolute;
      inset: 0;
      pointer-events: none;
      background:
        linear-gradient(180deg, rgba(255,255,255,.035), transparent 12%),
        linear-gradient(90deg, rgba(255,255,255,.025), transparent 5%, transparent 95%, rgba(255,255,255,.025));
    }
  </style>
</head>
<body>
  <h1 class="headline">${item.title}</h1>
  <div class="window-glow"></div>
  <div class="window"><img src="${image}" alt=""></div>
</body>
</html>`;
}

fs.mkdirSync(outputRoot, { recursive: true });

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({
  viewport: { width: 2880, height: 1800 },
  deviceScaleFactor: 1,
});

for (const item of pages) {
  await page.setContent(htmlFor(item), { waitUntil: "load" });
  await page.waitForFunction(
    () => [...document.images].every((image) => image.complete && image.naturalWidth > 0),
  );
  await page.screenshot({
    path: path.join(outputRoot, item.file),
    fullPage: false,
    omitBackground: false,
  });
}

await browser.close();
