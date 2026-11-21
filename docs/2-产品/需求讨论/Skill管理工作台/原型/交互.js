/* 离线评审入口。窗口内的操作共享本轮样例，画板目录和重置按钮可以重新载入单个场景。 */
(() => {
  const byId = id => document.getElementById(id);
  const stage = byId("stage");
  const chooser = byId("chooser");
  const editor = byId("editor");
  const form = byId("edit-form");
  const field = byId("value");
  const header = document.querySelector("main > header");
  const pages = SkillScenarios.pages;
  const pageInUrl = () => SkillScenarios.pageById(location.hash.slice(1))?.id || "S01";
  let state = SkillScenarios.initial(pageInUrl());
  let renderedPage = "";
  let editorAction = "";
  let editorTrigger = "";
  let confirmTrigger = "";
  let copyTimer;

  const fields = {
    askSearch: ["搜索名称或来源", "search", () => state.query],
    askDraft: ["编辑草稿说明", "editDraft", () => state.draftNote || `Add ${SkillScenarios.skills[state.picked].name}`],
    askRepo: ["草稿的目标仓库", "editRepo", () => state.draftRepo],
    askBranch: ["草稿的目标分支", "editBranch", () => state.draftBranch || `skills/${SkillScenarios.skills[state.picked].name}`]
  };

  /** 临时写入浏览历史，让“返回”恢复上一屏选择。file: 页限制 History API 时仍可按画板编号定位。 */
  function remember(push = false) {
    const hash = `#${state.page}`;
    try {
      history[push ? "pushState" : "replaceState"]({skillDemo: state}, "", hash);
    } catch {
      if (location.hash !== hash) location.hash = hash;
    }
  }

  function focusAction(action) {
    const buttons = Array.from(stage.querySelectorAll("[data-action]"));
    const target = buttons.find(button => button.dataset.action === action);
    (target || stage).focus({preventScroll: true});
  }

  /** 只替换画板；键盘在同一屏切换选项时仍回到原控件，确认层优先聚焦取消。 */
  function render(focus = null) {
    const previous = document.activeElement?.closest("[data-action]")?.dataset.action;
    const page = SkillScenarios.pageById(state.page);
    const changed = renderedPage !== page.id;
    stage.classList.toggle("compact", page.id === "S15");
    stage.classList.toggle("page-changed", changed);
    stage.innerHTML = SkillVector.svg(SkillBoards.board(state), Boolean(state.pending));
    stage.setAttribute("aria-label", `${page.title} · Skill 管理工作台`);
    header.inert = Boolean(state.pending);
    byId("current").textContent = `${page.id} · ${page.title}`;
    byId("purpose").textContent = page.acceptance;
    byId("status").textContent = state.flash || (state.pending ? `等待确认 · ${state.pending}` : "演示数据 · 仅在此页生效");
    for (const button of byId("page-list").querySelectorAll("button")) {
      if (button.dataset.page === page.id) button.setAttribute("aria-current", "page");
      else button.removeAttribute("aria-current");
    }
    renderedPage = page.id;
    if (state.pending) focusAction("cancel");
    else if (focus !== null || previous) focusAction(focus ?? (changed ? "" : previous));
  }

  function startPage(id) {
    clearTimeout(copyTimer);
    confirmTrigger = "";
    const changed = state.page !== id;
    state = SkillScenarios.initial(id);
    remember(changed);
    render("");
  }

  function openField(action) {
    const [label, command, value] = fields[action];
    editorAction = command;
    editorTrigger = action;
    byId("edit-title").textContent = label;
    field.value = value();
    field.rows = action === "askDraft" ? 4 : 2;
    editor.showModal();
    field.focus();
    field.select();
  }

  /** 所有演示操作都由同一场景模型解释。复制反馈只在本轮操作按钮上显示 1.5 秒。 */
  function run(action, value = "", focus = null) {
    if (fields[action]) {
      openField(action);
      return;
    }
    clearTimeout(copyTimer);
    const oldPage = state.page;
    const wasPending = Boolean(state.pending);
    SkillScenarios.act(state, action, value);
    if (!wasPending && state.pending) confirmTrigger = action;
    if (wasPending && !state.pending && state.page === oldPage) focus = confirmTrigger;
    remember(state.page !== oldPage);
    render(focus);
    if (action === "copy") {
      copyTimer = setTimeout(() => {
        state.flash = "";
        remember();
        render();
      }, 1500);
    }
  }

  for (const page of pages) {
    const row = document.createElement("li");
    const button = document.createElement("button");
    const number = document.createElement("small");
    button.type = "button";
    button.dataset.page = page.id;
    number.textContent = page.id;
    button.append(number, document.createTextNode(page.title));
    row.append(button);
    byId("page-list").append(row);
  }
  byId("boards").addEventListener("click", () => {
    chooser.showModal();
    chooser.querySelector('[aria-current="page"]')?.focus();
  });
  byId("page-list").addEventListener("click", event => {
    const button = event.target.closest("[data-page]");
    if (button) {
      chooser.close();
      startPage(button.dataset.page);
    }
  });
  for (const button of document.querySelectorAll("[data-close]")) {
    button.addEventListener("click", () => button.closest("dialog").close());
  }
  form.addEventListener("submit", event => {
    event.preventDefault();
    editor.close();
    run(editorAction, field.value, editorTrigger);
  });
  byId("reset").addEventListener("click", () => startPage(state.page));
  stage.tabIndex = -1;
  stage.addEventListener("click", event => {
    const target = event.target.closest("[data-action]");
    if (target) run(target.dataset.action);
  });
  stage.addEventListener("keydown", event => {
    const target = event.target.closest("[data-action]");
    if (target && ["Enter", " "].includes(event.key)) {
      event.preventDefault();
      run(target.dataset.action);
    } else if (state.pending && event.key === "Escape") {
      event.preventDefault();
      run("cancel");
    } else if (state.pending && event.key === "Tab") {
      const buttons = Array.from(stage.querySelectorAll("[data-action]"));
      const offset = event.shiftKey ? -1 : 1;
      event.preventDefault();
      buttons[(buttons.indexOf(target) + offset + buttons.length) % buttons.length]?.focus();
    }
  });
  window.addEventListener("popstate", event => {
    clearTimeout(copyTimer);
    const restored = event.state?.skillDemo;
    state = restored?.page === pageInUrl() ? restored : SkillScenarios.initial(pageInUrl());
    if (state.flash.startsWith("✓")) state.flash = "";
    render("");
  });
  window.addEventListener("hashchange", () => {
    if (state.page !== pageInUrl()) startPage(pageInUrl());
  });
  remember();
  render();
})();
