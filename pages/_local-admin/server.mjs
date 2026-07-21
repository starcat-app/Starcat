/*
 * Local-only server for the Starcat admin panel.
 *
 * Why this exists:
 * Fly Machines API does not expose browser CORS headers, so the static admin
 * page cannot call https://api.machines.dev directly. This tiny local server
 * serves the panel, reads local service .env files, and applies selected
 * variables to Fly secrets using the token from config.js.
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
const repoRoot = path.resolve(__dirname, "..", "..");

const serviceEnvPaths = {
  sharing: "supports/starcat-sharing-api/.env",
  trending: "supports/starcat-trending-api/.env",
  weekly: "supports/starcat-weekly-api/.env",
  wiki: "supports/starcat-wiki-api/.env",
  recommend: "supports/starcat-recommend-api/.env",
  discovery: "supports/starcat-discovery-api/.env"
};

const defaultFlyApps = {
  sharing: "starcat-sharing-api",
  trending: "starcat-trending-api",
  weekly: "starcat-weekly-api",
  wiki: "starcat-wiki-api",
  recommend: "starcat-recommend-api",
  discovery: "starcat-discovery-api"
};

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
    if (url.pathname === "/local-env") {
      await readLocalEnv(req, res, url);
      return;
    }
    if (url.pathname === "/fly-env/apply") {
      await applyFlyEnv(req, res);
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
  // Local Admin 复用公开站点的官方 Logo，避免在多个目录复制出容易漂移的品牌资源。
  if (pathname === "/starcat-logo.png") {
    await writeStaticFile(res, path.join(repoRoot, "pages", "direct", "starcat-logo.png"));
    return;
  }
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
  await writeStaticFile(res, filePath);
}

async function writeStaticFile(res, filePath) {
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

async function readLocalEnv(req, res, localURL) {
  if (req.method !== "GET") {
    writeJSON(res, 405, { error: "method not allowed" });
    return;
  }
  const service = localURL.searchParams.get("service") || "";
  const envPath = serviceEnvPaths[service];
  if (!envPath) {
    writeJSON(res, 400, { error: `unknown service: ${service}` });
    return;
  }

  const absolutePath = path.resolve(repoRoot, envPath);
  if (!absolutePath.startsWith(`${repoRoot}${path.sep}`)) {
    writeJSON(res, 403, { error: "forbidden env path" });
    return;
  }
  if (!existsSync(absolutePath)) {
    writeJSON(res, 404, { service, envPath, variables: [], error: ".env not found" });
    return;
  }

  const source = await readFile(absolutePath, "utf8");
  writeJSON(res, 200, {
    service,
    envPath,
    variables: parseEnv(source)
  });
}

async function applyFlyEnv(req, res) {
  if (req.method === "OPTIONS") {
    writeJSON(res, 204, {});
    return;
  }
  if (req.method !== "POST") {
    writeJSON(res, 405, { error: "method not allowed" });
    return;
  }

  const payload = JSON.parse((await readRequestBody(req)).toString("utf8") || "{}");
  const service = String(payload.service || "");
  const appName = String(payload.app || flyAppForService((await loadConfig()).fly || {}, service));
  const variables = Array.isArray(payload.variables) ? payload.variables : [];
  if (!serviceEnvPaths[service]) {
    writeJSON(res, 400, { error: `unknown service: ${service}` });
    return;
  }
  if (!appName) {
    writeJSON(res, 400, { error: `missing fly app for service: ${service}` });
    return;
  }
  if (!variables.length) {
    writeJSON(res, 400, { error: "no variables selected" });
    return;
  }

  const cfg = await loadConfig();
  const fly = cfg.fly || {};
  if (!fly.apiToken) {
    writeJSON(res, 500, { error: "missing fly.apiToken in config.js" });
    return;
  }

  const apiBaseURL = String(fly.apiBaseURL || "https://api.machines.dev/v1").replace(/\/+$/, "");
  const results = [];
  for (const item of variables) {
    const name = String(item.name || "").trim();
    const value = item.value == null ? "" : String(item.value);
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) {
      results.push({ name, ok: false, error: "invalid env name" });
      continue;
    }

    const targetURL = `${apiBaseURL}/apps/${encodeURIComponent(appName)}/secrets/${encodeURIComponent(name)}`;
    try {
      const response = await fetch(targetURL, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${fly.apiToken}`,
          Accept: "application/json",
          "Content-Type": "application/json"
        },
        body: JSON.stringify({ value })
      });
      const text = await response.text();
      let body = text;
      try {
        body = text ? JSON.parse(text) : null;
      } catch {
        body = text;
      }
      results.push({ name, ok: response.ok, status: response.status, body: response.ok ? body : undefined, error: response.ok ? undefined : body });
    } catch (error) {
      results.push({ name, ok: false, error: error instanceof Error ? error.message : String(error) });
    }
  }

  const ok = results.every((item) => item.ok);
  writeJSON(res, ok ? 200 : 207, { service, app: appName, results });
}

function parseEnv(source) {
  const variables = [];
  for (const rawLine of source.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const normalized = line.startsWith("export ") ? line.slice(7).trim() : line;
    const separator = normalized.indexOf("=");
    if (separator <= 0) continue;
    const name = normalized.slice(0, separator).trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) continue;
    variables.push({
      name,
      value: unquoteEnvValue(normalized.slice(separator + 1).trim())
    });
  }
  return variables;
}

function unquoteEnvValue(value) {
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    return value.slice(1, -1).replace(/\\n/g, "\n").replace(/\\"/g, '"').replace(/\\\\/g, "\\");
  }
  if (value.length >= 2 && value.startsWith("'") && value.endsWith("'")) {
    return value.slice(1, -1);
  }
  return value;
}

function flyAppForService(fly, service) {
  const apps = fly.apps || {};
  if (Array.isArray(apps)) {
    return apps.find((app) => app === defaultFlyApps[service] || String(app).includes(`-${service}-`)) || defaultFlyApps[service] || "";
  }
  return apps[service] || defaultFlyApps[service] || "";
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
