/*
 * Starcat Companion shared utilities.
 *
 * The extension deliberately stores only the local port and Companion bearer
 * token. GitHub data, notes, health scores, and actions remain owned by the
 * Starcat app and are fetched through the loopback API.
 */

(function () {
  const STORAGE_KEYS = {
    port: "starcatCompanionPort",
    token: "starcatCompanionToken"
  };

  const DEFAULT_PORT = 5051;
  const REPO_SEGMENT_BLOCKLIST = new Set([
    "about",
    "apps",
    "codespaces",
    "collections",
    "customer-stories",
    "dashboard",
    "events",
    "explore",
    "features",
    "marketplace",
    "new",
    "notifications",
    "orgs",
    "pricing",
    "pulls",
    "search",
    "settings",
    "sponsors",
    "topics",
    "trending"
  ]);

  function normalizePort(value) {
    const parsed = Number.parseInt(String(value || ""), 10);
    if (Number.isInteger(parsed) && parsed >= 1024 && parsed <= 65535) {
      return parsed;
    }
    return DEFAULT_PORT;
  }

  function normalizeToken(value) {
    return String(value || "").trim();
  }

  async function loadConfig() {
    const stored = await chrome.storage.local.get([STORAGE_KEYS.port, STORAGE_KEYS.token]);
    return {
      port: normalizePort(stored[STORAGE_KEYS.port]),
      token: normalizeToken(stored[STORAGE_KEYS.token])
    };
  }

  async function saveConfig(config) {
    await chrome.storage.local.set({
      [STORAGE_KEYS.port]: normalizePort(config.port),
      [STORAGE_KEYS.token]: normalizeToken(config.token)
    });
  }

  function parseGitHubRepo(urlString) {
    let url;
    try {
      url = new URL(urlString);
    } catch {
      return null;
    }
    if (url.hostname !== "github.com") return null;

    const parts = url.pathname.split("/").filter(Boolean);
    if (parts.length < 2) return null;
    const [owner, repo] = parts;
    if (REPO_SEGMENT_BLOCKLIST.has(owner)) return null;
    if (!/^[A-Za-z0-9._-]+$/.test(owner) || !/^[A-Za-z0-9._-]+$/.test(repo)) return null;

    return {
      owner,
      repo,
      fullName: `${owner}/${repo}`
    };
  }

  function createClient(config) {
    const port = normalizePort(config.port);
    const token = normalizeToken(config.token);
    const baseURL = `http://127.0.0.1:${port}`;

    async function request(path, options = {}) {
      if (!token) {
        throw new Error("missing_token");
      }

      const response = await fetch(`${baseURL}${path}`, {
        ...options,
        headers: {
          "Authorization": `Bearer ${token}`,
          "Content-Type": "application/json",
          ...(options.headers || {})
        }
      });

      const text = await response.text();
      let body = null;
      if (text) {
        try {
          body = JSON.parse(text);
        } catch {
          body = { raw: text };
        }
      }

      if (!response.ok) {
        const error = new Error(body?.error || `http_${response.status}`);
        error.status = response.status;
        error.body = body;
        throw error;
      }
      return body;
    }

    return {
      ping() {
        return request("/local/v1/ping");
      },
      repoContext(repo) {
        const params = new URLSearchParams({ owner: repo.owner, repo: repo.repo });
        return request(`/local/v1/repo-context?${params.toString()}`);
      },
      saveNote(repo, content) {
        return request("/local/v1/notes", {
          method: "PATCH",
          body: JSON.stringify({ owner: repo.owner, repo: repo.repo, content })
        });
      },
      openAction(repo, action) {
        return request("/local/v1/actions/open", {
          method: "POST",
          body: JSON.stringify({ owner: repo.owner, repo: repo.repo, action })
        });
      }
    };
  }

  globalThis.StarcatCompanion = {
    DEFAULT_PORT,
    loadConfig,
    saveConfig,
    parseGitHubRepo,
    createClient
  };
})();
