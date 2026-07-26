import { chromium } from "playwright";
import fs from "node:fs";
import path from "node:path";

const root = path.resolve("screenshots/2026-06-23-app-store");
function pngDataURL(relativePath) {
  const data = fs.readFileSync(path.join(root, relativePath)).toString("base64");
  return `data:image/png;base64,${data}`;
}

const shots = {
  library: pngDataURL("app-store/01-star-library-detail.png"),
  discovery: pngDataURL("app-store/02-trending-discovery.png"),
  activity: pngDataURL("app-store/03-weekly-activity.png"),
  collections: pngDataURL("app-store/04-smart-collections.png"),
  ai: pngDataURL("app-store/05-ai-assistant-entry.png"),
};

const pages = [
  {
    file: "landing/hero-library.png",
    title: "Your Stars, finally searchable.",
    subtitle: "Turn a flat GitHub star list into a native, searchable knowledge library.",
    image: shots.library,
    accent: "#0A84FF",
    chips: ["1,857 starred repos", "README rendered", "Tags, notes, status"],
  },
  {
    file: "landing/feature-discovery.png",
    title: "Discover what matters this week.",
    subtitle: "Track trending repos, weekly updates, releases, and signals in one macOS workspace.",
    image: shots.discovery,
    sideImage: shots.activity,
    accent: "#34C759",
    chips: ["Trending", "Weekly digest", "Release tracking"],
  },
  {
    file: "landing/feature-ai.png",
    title: "Ask AI about any repository.",
    subtitle: "Bring your own model key, summarize READMEs, and keep context attached to the repo.",
    image: shots.ai,
    sideImage: shots.collections,
    accent: "#8E5CFF",
    chips: ["BYOK AI", "Smart collections", "Repo context"],
  },
];

function htmlFor(page) {
  const chipMarkup = page.chips.map((chip) => `<span>${chip}</span>`).join("");
  const sideMarkup = page.sideImage
    ? `<img class="side-shot" src="${page.sideImage}" alt="">`
    : "";

  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    * { box-sizing: border-box; }
    body {
      margin: 0;
      width: 3200px;
      height: 1800px;
      overflow: hidden;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", Arial, sans-serif;
      color: #111827;
      background:
        radial-gradient(circle at 14% 18%, ${page.accent}26, transparent 24%),
        radial-gradient(circle at 86% 12%, #FFD60A24, transparent 19%),
        linear-gradient(135deg, #F8FBFF 0%, #FFFFFF 44%, #F7F8FB 100%);
    }
    .network {
      position: absolute;
      inset: 0;
      opacity: .35;
      background-image:
        linear-gradient(90deg, #94A3B826 1px, transparent 1px),
        linear-gradient(#94A3B826 1px, transparent 1px);
      background-size: 80px 80px;
      mask-image: radial-gradient(circle at 74% 28%, black, transparent 58%);
    }
    .wrap {
      position: relative;
      width: 100%;
      height: 100%;
      padding: 124px 150px 110px;
    }
    .brand {
      display: flex;
      align-items: center;
      gap: 22px;
      font-size: 42px;
      font-weight: 700;
      color: #172033;
    }
    .mark {
      width: 64px;
      height: 64px;
      border-radius: 18px;
      display: grid;
      place-items: center;
      color: white;
      background: linear-gradient(135deg, ${page.accent}, #1D1D1F);
      box-shadow: 0 18px 44px ${page.accent}3f;
    }
    h1 {
      margin: 88px 0 0;
      width: 1260px;
      font-size: 106px;
      line-height: 1.02;
      letter-spacing: 0;
    }
    p {
      margin: 36px 0 0;
      width: 1180px;
      font-size: 42px;
      line-height: 1.32;
      color: #475569;
    }
    .chips {
      display: flex;
      gap: 20px;
      margin-top: 56px;
      flex-wrap: wrap;
      max-width: 1280px;
    }
    .chips span {
      border: 1px solid #D6DEE9;
      border-radius: 999px;
      padding: 18px 28px;
      font-size: 28px;
      font-weight: 650;
      color: #243044;
      background: rgba(255,255,255,.72);
      box-shadow: 0 10px 30px rgba(15, 23, 42, .06);
    }
    .shot {
      position: absolute;
      right: 130px;
      bottom: 118px;
      width: 1850px;
      border-radius: 36px;
      box-shadow: 0 48px 140px rgba(15, 23, 42, .24);
      border: 1px solid rgba(148, 163, 184, .55);
    }
    .side-shot {
      position: absolute;
      right: 1520px;
      bottom: 128px;
      width: 940px;
      border-radius: 30px;
      box-shadow: 0 38px 105px rgba(15, 23, 42, .18);
      border: 1px solid rgba(148, 163, 184, .5);
      transform: rotate(-2deg);
    }
    .orb {
      position: absolute;
      right: 118px;
      top: 118px;
      width: 360px;
      height: 360px;
      border-radius: 999px;
      border: 1px solid ${page.accent}33;
      background: linear-gradient(135deg, ${page.accent}19, transparent);
    }
  </style>
</head>
<body>
  <div class="network"></div>
  <div class="wrap">
    <div class="orb"></div>
    <div class="brand"><div class="mark">★</div><div>Starcat</div></div>
    <h1>${page.title}</h1>
    <p>${page.subtitle}</p>
    <div class="chips">${chipMarkup}</div>
    ${sideMarkup}
    <img class="shot" src="${page.image}" alt="">
  </div>
</body>
</html>`;
}

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 3200, height: 1800 }, deviceScaleFactor: 1 });

for (const item of pages) {
  await page.setContent(htmlFor(item), { waitUntil: "load" });
  await page.waitForFunction(() => [...document.images].every((image) => image.complete && image.naturalWidth > 0));
  await page.screenshot({ path: path.join(root, item.file), fullPage: false });
}

await browser.close();
