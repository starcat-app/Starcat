/*
 * Local-only server for the Starcat admin panel.
 *
 * Why this exists:
 * Fly Machines API does not expose browser CORS headers, so the static admin
 * page cannot call https://api.machines.dev directly. This tiny local server
 * serves the panel and proxies /fly-api/* to Fly with the token from config.js.
 */
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const defaultPort = 8080;
const port = Number.parseInt(readArg("--port") || process.env.PORT || String(defaultPort), 10);

const mimeTypes = new Map([
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".svg", "image/svg+xml"],
  [".png", "image/png"],
  [".jpg", "image/jpeg"],
  [".jpeg", "image/jpeg"],
  [".ico", "image/x-icon"]
]);

createServer(async (req, res) => {
  try {
    const url = new URL(req.url || "/", `http://${req.headers.host || "127.0.0.1"}`);
    if (url.pathname === "/fly-api" || url.pathname.startsWith("/fly-api/")) {
      await proxyFlyRequest(req, res, url);
      return;
    }
    await serveStaticFile(res, url.pathname);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    writeJSON(res, 500, { error: message });
  }
}).listen(port, "127.0.0.1", () => {
  console.log(`Starcat local admin: http://127.0.0.1:${port}/`);
});

function readArg(name) {
  const index = process.argv.indexOf(name);
  if (index === -1) return "";
  return process.argv[index + 1] || "";
}

async function serveStaticFile(res, rawPathname) {
  const pathname = normalizeAdminPath(rawPathname);
  const relativePath = pathname === "/" ? "index.html" : pathname.slice(1);
  const filePath = path.resolve(__dirname, relativePath);
  if (!filePath.startsWith(`${__dirname}${path.sep}`) && filePath !== path.join(__dirname, "index.html")) {
    writeJSON(res, 403, { error: "forbidden" });
    return;
  }
  if (!existsSync(filePath)) {
    writeJSON(res, 404, { error: "not found" });
    return;
  }
  const ext = path.extname(filePath);
  const body = await readFile(filePath);
  res.writeHead(200, {
    "Content-Type": mimeTypes.get(ext) || "application/octet-stream",
    "Cache-Control": "no-store"
  });
  res.end(body);
}

function normalizeAdminPath(rawPathname) {
  const decoded = decodeURIComponent(rawPathname || "/");
  if (decoded === "/_local-admin" || decoded === "/_local-admin/") return "/";
  if (decoded.startsWith("/_local-admin/")) return decoded.slice("/_local-admin".length);
  return decoded;
}

async function proxyFlyRequest(req, res, localURL) {
  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET,POST,DELETE,OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
      "Access-Control-Max-Age": "600"
    });
    res.end();
    return;
  }

  const cfg = await loadConfig();
  const fly = cfg.fly || {};
  if (!fly.apiToken) {
    writeJSON(res, 500, { error: "missing fly.apiToken in config.js" });
    return;
  }

  const apiBaseURL = String(fly.apiBaseURL || "https://api.machines.dev/v1").replace(/\/+$/, "");
  const flyPath = localURL.pathname.replace(/^\/fly-api/, "") || "/";
  const targetURL = new URL(`${apiBaseURL}${flyPath}`);
  targetURL.search = localURL.search;

  const response = await fetch(targetURL, {
    method: req.method,
    headers: {
      Authorization: `Bearer ${fly.apiToken}`,
      Accept: "application/json",
      ...(req.headers["content-type"] ? { "Content-Type": req.headers["content-type"] } : {})
    },
    body: hasRequestBody(req.method) ? await readRequestBody(req) : undefined
  });

  const body = Buffer.from(await response.arrayBuffer());
  res.writeHead(response.status, {
    "Content-Type": response.headers.get("content-type") || "application/json; charset=utf-8",
    "Cache-Control": "no-store"
  });
  res.end(body);
  console.log(`${req.method} ${localURL.pathname}${localURL.search} -> ${response.status}`);
}

async function loadConfig() {
  const configPath = path.join(__dirname, "config.js");
  const source = await readFile(configPath, "utf8");
  const sandbox = { window: {} };
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox, { filename: configPath });
  return sandbox.window.STARCAT_ADMIN_CONFIG || {};
}

function hasRequestBody(method) {
  return !["GET", "HEAD", "OPTIONS"].includes(String(method || "GET").toUpperCase());
}

async function readRequestBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks);
}

function writeJSON(res, status, payload) {
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store"
  });
  res.end(JSON.stringify(payload));
}
