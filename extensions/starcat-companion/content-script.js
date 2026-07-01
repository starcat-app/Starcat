/*
 * GitHub repository page integration.
 *
 * GitHub uses client-side navigation, so this script treats URL/DOM changes as
 * hints and always debounces before reading the page. Network calls are also
 * deduplicated per repo to avoid amplifying Starcat local requests during DOM
 * churn.
 */

(function () {
  const PANEL_ID = "starcat-companion-panel";
  const DEBOUNCE_MS = 500;
  const CACHE_TTL_MS = 60 * 1000;
  const MISSING_CONFIG_COOLDOWN_MS = 60 * 1000;

  let scheduledTimer = null;
  let lastURL = location.href;
  let missingConfigUntil = 0;
  const contextCache = new Map();
  const inFlight = new Map();

  function scheduleRefresh(reason, options = {}) {
    window.clearTimeout(scheduledTimer);
    scheduledTimer = window.setTimeout(() => {
      refreshPanel(reason, options).catch(() => {
        removePanel();
      });
    }, DEBOUNCE_MS);
  }

  async function refreshPanel(_reason, options = {}) {
    const repo = StarcatCompanion.parseGitHubRepo(location.href);
    if (!repo) {
      removePanel();
      return;
    }

    const target = findInsertionTarget();
    if (!target) return;

    if (Date.now() < missingConfigUntil) {
      removePanel();
      return;
    }

    const config = await StarcatCompanion.loadConfig();
    if (!config.token) {
      if (Date.now() > missingConfigUntil) {
        missingConfigUntil = Date.now() + MISSING_CONFIG_COOLDOWN_MS;
      }
      removePanel();
      return;
    }

    const client = StarcatCompanion.createClient(config);
    const context = await loadContext(client, repo, options.force === true);
    if (!hasRenderableContent(context)) {
      removePanel();
      return;
    }
    insertOrReplacePanel(target, renderPanel(context, repo, client));
  }

  async function loadContext(client, repo, force) {
    const key = repo.fullName.toLowerCase();
    const cached = contextCache.get(key);
    if (!force && cached && Date.now() - cached.loadedAt < CACHE_TTL_MS) {
      return cached.value;
    }
    if (inFlight.has(key)) {
      return inFlight.get(key);
    }

    const request = client.repoContext(repo)
      .then((value) => {
        contextCache.set(key, { value, loadedAt: Date.now() });
        return value;
      })
      .finally(() => {
        inFlight.delete(key);
      });
    inFlight.set(key, request);
    return request;
  }

  function findInsertionTarget() {
    return document.querySelector("#readme")
      || document.querySelector("div[data-testid='readme']")
      || document.querySelector("article.markdown-body")?.parentElement
      || document.querySelector(".Layout-sidebar")
      || document.querySelector("main");
  }

  function insertOrReplacePanel(target, panel) {
    removePanel();
    if (target.id === "readme" || target.matches("div[data-testid='readme']")) {
      target.parentElement?.insertBefore(panel, target);
      return;
    }
    target.prepend(panel);
  }

  function removePanel() {
    document.getElementById(PANEL_ID)?.remove();
  }

  function hasRenderableContent(context) {
    return Boolean(
      context?.recommendations?.length
        || context?.wiki_links?.length
        || context?.note?.editable
        || context?.health
        || context?.openssf
        || context?.actions?.open_in_starcat
        || context?.actions?.codeflow
        || context?.actions?.codebase
    );
  }

  function renderPanel(context, repo, client) {
    const panel = element("section", "starcat-panel");
    panel.id = PANEL_ID;

    const header = element("div", "starcat-panel__header");
    header.append(
      element("div", "starcat-panel__brand", "Starcat"),
      element("div", "starcat-panel__repo", context.repo?.full_name || repo.fullName)
    );
    panel.append(header);

    if (context.recommendations?.length) {
      panel.append(renderRecommendations(context.recommendations));
    }
    if (context.wiki_links?.length) {
      panel.append(renderWikiLinks(context.wiki_links));
    }
    if (context.note?.editable) {
      panel.append(renderNote(context.note, repo, client));
    }
    if (context.health || context.openssf) {
      panel.append(renderSignals(context));
    }
    if (context.actions && hasAction(context.actions)) {
      panel.append(renderActions(context.actions, repo, client));
    }

    return panel;
  }

  function renderRecommendations(items) {
    const section = panelSection("Similar");
    const list = element("div", "starcat-list");
    for (const item of items.slice(0, 5)) {
      const row = element("a", "starcat-list__item");
      row.href = `https://github.com/${item.full_name}`;
      row.target = "_blank";
      row.rel = "noreferrer";
      row.append(
        element("span", "starcat-list__title", item.full_name),
        element("span", "starcat-list__meta", recommendationMeta(item))
      );
      list.append(row);
    }
    section.append(list);
    return section;
  }

  function recommendationMeta(item) {
    const parts = [];
    if (item.language) parts.push(item.language);
    if (Number.isFinite(item.stars)) parts.push(`${item.stars.toLocaleString()} stars`);
    if (typeof item.score === "number") parts.push(`score ${item.score.toFixed(2)}`);
    return parts.join(" · ");
  }

  function renderWikiLinks(links) {
    const section = panelSection("Wiki");
    const group = element("div", "starcat-button-row");
    for (const link of links) {
      const anchor = element("a", "starcat-button", link.title || link.source);
      anchor.href = link.url;
      anchor.target = "_blank";
      anchor.rel = "noreferrer";
      group.append(anchor);
    }
    section.append(group);
    return section;
  }

  function renderNote(note, repo, client) {
    const section = panelSection("Notes");
    const textarea = element("textarea", "starcat-note");
    textarea.value = note.content || "";
    textarea.rows = 4;
    textarea.maxLength = 20000;
    textarea.placeholder = "Private note";

    const footer = element("div", "starcat-note__footer");
    const status = element("span", "starcat-note__status");
    const button = element("button", "starcat-button starcat-button--primary", "Save");
    button.type = "button";
    button.addEventListener("click", async () => {
      button.disabled = true;
      status.textContent = "Saving...";
      try {
        await client.saveNote(repo, textarea.value);
        status.textContent = "Saved";
        contextCache.delete(repo.fullName.toLowerCase());
        window.setTimeout(() => {
          if (status.textContent === "Saved") status.textContent = "";
        }, 2000);
      } catch {
        status.textContent = "Save failed";
      } finally {
        button.disabled = false;
      }
    });
    footer.append(status, button);
    section.append(textarea, footer);
    return section;
  }

  function renderSignals(context) {
    const section = panelSection("Signals");
    const grid = element("div", "starcat-signal-grid");
    if (context.health) {
      grid.append(signal("Health", `${formatScore(context.health.score)} ${context.health.grade || ""}`.trim()));
    }
    if (context.openssf) {
      grid.append(signal("OpenSSF", formatScore(context.openssf.score)));
    }
    section.append(grid);
    return section;
  }

  function signal(label, value) {
    const item = element("div", "starcat-signal");
    item.append(
      element("span", "starcat-signal__label", label),
      element("span", "starcat-signal__value", value)
    );
    return item;
  }

  function formatScore(value) {
    return typeof value === "number" ? value.toFixed(1) : "N/A";
  }

  function renderActions(actions, repo, client) {
    const section = panelSection("Actions");
    const row = element("div", "starcat-button-row");
    const actionMap = [
      ["open_in_starcat", "open-repo", "Open on GitHub"],
      ["codeflow", "codeflow", "CodeFlow"],
      ["codebase", "codebase", "Codebase"]
    ];

    for (const [flag, action, title] of actionMap) {
      if (!actions[flag]) continue;
      const button = element("button", "starcat-button", title);
      button.type = "button";
      button.addEventListener("click", async () => {
        button.disabled = true;
        try {
          await client.openAction(repo, action);
        } finally {
          button.disabled = false;
        }
      });
      row.append(button);
    }
    section.append(row);
    return section;
  }

  function hasAction(actions) {
    return actions.open_in_starcat || actions.codeflow || actions.codebase;
  }

  function panelSection(title) {
    const section = element("section", "starcat-section");
    section.append(element("h2", "starcat-section__title", title));
    return section;
  }

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  const observer = new MutationObserver(() => {
    if (location.href !== lastURL) {
      lastURL = location.href;
      contextCache.clear();
    }
    scheduleRefresh("mutation");
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });

  window.addEventListener("popstate", () => scheduleRefresh("popstate", { force: true }));
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && (changes.starcatCompanionPort || changes.starcatCompanionToken)) {
      contextCache.clear();
      missingConfigUntil = 0;
      scheduleRefresh("config", { force: true });
    }
  });

  scheduleRefresh("initial");
})();
