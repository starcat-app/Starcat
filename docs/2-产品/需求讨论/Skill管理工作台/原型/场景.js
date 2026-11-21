/* 设计稿的演示资料与交互状态。所有状态只在当前预览中生效，Pencil 使用同一组初始场景。 */
const SkillScenarios = (() => {
  const pages = [
    ["S01", "我的 Skill", "本机库", "辨认同名条目的来源，打开正文、文件、分配或版本。"],
    ["S02", "本机盘点", "本机库", "确认读取范围，区分实际文件、共享目录和上次观察。"],
    ["S03", "纳管外部条目", "本机库", "对照原位置和私有副本位置，再决定是否分配。"],
    ["S04", "分配预览", "本机库", "以物理目录为单位选择写入目标，核对共用入口的 Agent。"],
    ["S05", "逐项结果", "本机库", "区分本次创建、已满足和现场变化，仅重试需要处理的项。"],
    ["S06", "分配与暂停", "本机库", "按所有权暂停或恢复入口，保留已导入的内容。"],
    ["S07", "发现 Skill", "GitHub", "在 Stars 和外部目录中挑选仓内子目录，确认来源。"],
    ["S08", "阅读与安装", "GitHub", "切换原文与翻译，核对完整文件、固定提交和入库位置。"],
    ["S09", "订阅收件箱", "GitHub", "只查看所订阅子目录的内容变化，保留离线来源的上次结果。"],
    ["S10", "版本审核", "GitHub", "逐文件对照基线、本地、上游，为这一版选择保留、备份更新或回退。"],
    ["S11", "给 Agent 使用", "本机库", "分别取得任务说明、原文、固定版本请求或完整文件包。"],
    ["S12", "项目组合", "工作区", "比较项目期望版本与本机现场，再预览差异项。"],
    ["S13", "Skill 趋势", "GitHub", "按周、月、年切换仓库榜，查看来源和样本覆盖。"],
    ["S14", "发布草稿", "工作区", "选择将公开的文件并预览 GitHub 草稿。"],
    ["S15", "紧凑暗色", "本机库", "在 1040 × 640 的窗口完成阅读，并能找回导航。"],
    ["S16", "文件预览", "本机库", "按相对路径阅读说明、引用及脚本，并复制文件位置。"]
  ].map(([id, title, group, acceptance]) => ({ id, title, group, acceptance }));

  const skills = {
    release: { name: "release-notes", repo: "octoworks/dev-skills", path: "skills/release-notes", sha: "1a7c9e205154ac14ce725d84fe562a2e7f9316ba", glyph: "branch", owner: "受管", summary: "将合并的 PR 和提交整理为面向用户的发布说明。", example: "为下一个版本整理发布说明，按用户可见的变化分组。", english: "Write release notes from merged pull requests and commits." },
    external: { name: "release-notes", repo: "paperplane/release-kit", path: "agents/release-notes", sha: "e54109c40fe12bb3f0d823985230b9368acf09ac", glyph: "folder", owner: "外部", summary: "从 Git 标签整理发布草稿。这个版本来自另一套工具。", example: "读取最近两个标签之间的改动，生成中文草稿。", english: "Prepare a release draft from the changes between two Git tags." },
    notes: { name: "review-notes", repo: "本机 · Magpie Library", path: "library/skills/review-notes", sha: "", glyph: "file", owner: "外部", summary: "把代码评审中的决定和待办整理成一份记录。", example: "把这次评审中的决定和后续行动整理成笔记。", english: "Turn code review decisions and follow-ups into a short record." },
    docs: { name: "docs-audit", repo: "octoworks/dev-skills", path: "skills/docs-audit", sha: "b073c1d28512009150ae1be86f4531b347e14c4b", glyph: "book", owner: "受管", summary: "整理文档中需要作者确认的引用与过期示例。", example: "列出本次文档变更涉及的示例与引用。", english: "Inventory examples and links affected by documentation changes." },
    triage: { name: "issue-triage", repo: "orbit-lab/maintainer-kit", path: "skills/issue-triage", sha: "c421ef3fd529884914faaa2557f0d753bfefbf81", glyph: "inbox", owner: "受管", summary: "把新收到的 GitHub Issues 分组，列出需要维护者回复的条目。", example: "把本周新增的 Issues 按问题类型整理成清单。", english: "Group incoming issues and surface items that need a maintainer reply." },
    changelog: { name: "changelog-editor", repo: "orbit-lab/maintainer-kit", path: "skills/changelog-editor", sha: "c421ef3fd529884914faaa2557f0d753bfefbf81", glyph: "file", owner: "候选", summary: "将零散的更新说明编辑为可直接阅读的变更记录。", example: "把这些更新说明合并为一份面向用户的变更记录。", english: "Edit individual change notes into a readable changelog." }
  };
  const library = ["release", "external", "notes", "docs"];
  for (const key of ["external", "notes"]) skills[`${key}Copy`] = {...skills[key], owner:"受管", origin:key};
  const files = ["SKILL.md", "references/format.md", "scripts/format.sh"];
  const targets = [
    { id: "shared", title: "用户共享目录", sub: "Codex 和 Claude Code 指向同一物理根（示例）", path: "~/.agents/skills", state: "创建 1 个链接", tone: "blue" },
    { id: "project", title: "项目专用入口", sub: "项目 Docs Lab · Claude Code", path: "Docs Lab/.claude/skills", state: "创建 1 个链接", tone: "blue" },
    { id: "ok", title: "Kit Demo 项目入口", sub: "项目 Kit Demo · Codex", path: "Kit Demo/.agents/skills", tone: "blue" },
    { id: "foreign", title: "其他管理器的副本", sub: "Magpie Library · 由外部工具维护", path: "Magpie Library/skills", state: "只读", tone: "gray" }
  ];
  const ranks = {
    "周": [["octoworks/dev-skills", 146], ["orbit-lab/maintainer-kit", 92], ["paperplane/release-kit", 58]],
    "月": [["orbit-lab/maintainer-kit", 418], ["octoworks/dev-skills", 356], ["paperplane/release-kit", 167]],
    "年": []
  };

  /** 可从画板目录直接访问任一页，独立演示也有完整的上下文。 */
  function initial(page = "S01") {
    const state = {
      page, picked: page === "S03" ? "notes" : ["S07", "S08"].includes(page) ? "triage" : "release",
      owned: [...library.filter(key => skills[key].owner === "受管")], focus: "library",
      librarySelection: "release", source: "我的 Stars", translated: false, installed: [], subscriptions: ["release", "docs"],
      selectedTargets: ["shared", "project", "ok"], retried: false, receipts: null, receiptPage: 0, pending: "", scanned: false,
      links: {release:{shared:"active"},docs:{ok:"active",project:"active"}}, pauseTarget:"shared", planKind:"library", retryRows:[], scanDenied:false,
      checked: ["release"], batch: false, planEntries: [], filter: "全部", query: "", listOffset:0,
      file: 0, diffFile: 0, unread: true, updateDecision: "", versionBySkill: {},
      period: "周", repoRank: 0, draftFiles: [0, 1], draft: false, draftNote: "", draftRepo:"octoworks/skill-drafts", draftBranch:"",
      copyMode: 0, sidebar: false, readerOnly:false, flash: "", scanRoot: page==="S03"?1:0,
      selectedPack: "docs", packRows: ["release"], removed:[], repaired:false, returnPage:"S01"
    };
    if (page === "S05") {
      state.planEntries = [state.picked];
      state.receipts = results(state);
      for (const row of state.receipts) if (row.status === "已创建") rememberLink(state,row.key,row.target,"active");
    }
    return state;
  }
  function pageById(id) { return pages.find(page => page.id === id); }
  function jump(state, page) {
    if (!pageById(page)) return;
    state.page = page;
    state.pending = "";
    state.sidebar = false;
    state.readerOnly = false;
    state.flash = "";
  }
  function toggle(list, key) {
    return list.includes(key) ? list.filter(item => item !== key) : [...list, key];
  }
  function permittedTargets(state) {
    if (state.retried) return targets.filter(target => state.retryRows.some(row => row.target === target.id));
    if (state.planKind === "repair") return targets.filter(target => target.id === "project");
    if (state.planKind === "pack") return targets.filter(target => target.id === (state.selectedPack === "docs" ? "project" : "ok"));
    return targets;
  }
  function plan(state, entries, kind = "library", retry = false) {
    const allowed = [...new Set(entries)].filter(key => state.owned.includes(key) || (kind !== "library" && skills[key]?.sha));
    if (!allowed.length) { state.flash = "请先将外部条目复制到我的库"; return; }
    state.returnPage = state.page;
    state.planEntries = allowed;
    state.planKind = kind;
    state.retried = retry;
    state.selectedTargets = permittedTargets(state).filter(target => target.id !== "foreign").map(target => target.id);
    state.receiptPage = 0;
    if (!retry) { state.receipts = null; state.retryRows = []; }
    jump(state, "S04");
  }
  function rememberLink(state, key, target, value) {
    (state.links[key] ||= {})[target] = value;
  }
  function saveItem(state, key) {
    state.removed = state.removed.filter(value => value !== key);
    state.installed = [...new Set([...state.installed, key])];
    state.owned = [...new Set([...state.owned, key])];
    state.librarySelection = key;
  }
  function lastFocus(state) {
    if (state.librarySelection && !state.removed.includes(state.librarySelection)) return state.librarySelection;
    return [...library, ...state.installed].find(key => !state.removed.includes(key)) || "notes";
  }
  function results(state) {
    const entries = state.planEntries.length ? state.planEntries : [state.picked];
    return entries.flatMap(key => state.selectedTargets.filter(target => !state.retried || state.retryRows.some(row => row.key===key && row.target===target)).map(target => ({
      key, target, status: state.links[key]?.[target]==="active" ? "已满足" : target === "project" && !state.retried ? "需处理" : "已创建"
    })));
  }
  /** 预览只更新演示模型。分配结果保留逐项回执，第二次尝试仅替换上一次失败的目标。 */
  function act(state, action, value = "") {
    const [kind, arg] = action.split(":");
    state.flash = "";
    switch (kind) {
      case "go":
        if (arg==="S09" && !state.subscriptions.includes(state.picked)) state.picked = state.subscriptions[0] || state.picked;
        if (arg==="S07" && !["triage","changelog","release","docs"].includes(state.picked)) state.picked=state.source==="我的 Stars"?"triage":"changelog";
        if (arg==="S03" && skills[state.picked].origin) state.picked=skills[state.picked].origin;
        if (arg==="S14") { state.draftFiles=[0,1]; state.draft=false; state.draftNote=""; state.draftBranch=`skills/${skills[state.picked].name}`; }
        jump(state, arg); break;
      case "home": state.picked = lastFocus(state); jump(state, "S01"); break;
      case "library": state.librarySelection = state.picked = arg; state.file = 0; jump(state, "S01"); break;
      case "scan": state.scanned = true; state.scanDenied=true; state.flash = state.scanRoot===2 ? "仍待授权，保留昨天的结果" : "盘点完成，1 个根保留上次结果"; break;
      case "root": state.scanRoot = Number(arg); jump(state,"S02"); break;
      case "external": state.picked = "notes"; state.scanRoot=1; jump(state, "S03"); break;
      case "adopt": {
        const copy = skills[state.picked].origin ? state.picked : `${state.picked}Copy`;
        if (skills[copy]) { saveItem(state,copy); state.picked=copy; state.flash="已创建受管副本，外部原件保留"; }
        break;
      }
      case "plan": plan(state, [state.picked]); break;
      case "batchPlan": plan(state, state.checked); break;
      case "installedPlan": {
        const key = skills[state.picked].owner === "外部" ? `${state.picked}Copy` : state.picked;
        plan(state, [key]); break;
      }
      case "agentPlan": {
        if (!skills[state.picked].sha) break;
        const key = skills[state.picked].owner === "外部" ? `${state.picked}Copy` : state.picked;
        plan(state, [key], "agent"); break;
      }
      case "repair": plan(state, ["release"], "repair"); break;
      case "cancelPlan": jump(state,state.returnPage); break;
      case "target": if (arg !== "foreign" && permittedTargets(state).some(target=>target.id===arg)) state.selectedTargets = toggle(state.selectedTargets, arg); break;
      case "apply": {
        if (!state.selectedTargets.length) break;
        const newRows = results(state);
        if (state.planKind!=="library") for (const key of state.planEntries) if (!state.owned.includes(key)) saveItem(state,key);
        state.receipts = state.retried ? state.receipts.map(row => newRows.find(fresh=>fresh.key===row.key && fresh.target===row.target) || row) : newRows;
        for (const row of newRows) if (row.status!=="需处理") {
          rememberLink(state,row.key,row.target,"active");
          if (state.planKind==="repair" && row.key==="release" && row.target==="project") state.repaired=true;
        }
        state.picked = state.librarySelection = state.planEntries[0] || state.picked;
        state.receiptPage=0;
        jump(state, "S05"); break;
      }
      case "retry": {
        const failed = (state.receipts || results(state)).filter(row => row.status === "需处理");
        if (!state.receipts) state.receipts = results(state);
        if (failed.length) { state.retryRows=failed; plan(state, failed.map(row => row.key), state.planKind, true); }
        break;
      }
      case "receiptPage": state.receiptPage=Number(arg); break;
      case "pause":
        if (state.links[state.picked]?.[arg]) { state.pauseTarget=arg; state.pending=state.links[state.picked][arg]==="paused"?"恢复入口":"暂停入口"; }
        break;
      case "confirmPause": {
        const paused = state.pending==="暂停入口";
        rememberLink(state,state.picked,state.pauseTarget,paused?"paused":"active");
        state.pending=""; state.flash=paused?"入口已暂停，库内文件保留":"入口已恢复"; break;
      }
      case "remove": if (state.owned.includes(state.picked)) state.pending="移除受管副本"; break;
      case "confirmRemove": {
        if (!state.owned.includes(state.picked)) break;
        const original = skills[state.picked].origin;
        state.removed.push(state.picked); state.owned=state.owned.filter(key=>key!==state.picked);
        state.installed=state.installed.filter(key=>key!==state.picked);
        state.checked=state.checked.filter(key=>key!==state.picked); delete state.links[state.picked];
        state.picked=state.librarySelection=original || lastFocus(state); jump(state,"S01"); state.flash="已解除自有入口并将副本移入废纸篓（演示）"; break;
      }
      case "cancel": state.pending = ""; break;
      case "source": state.source = arg; state.picked = arg === "我的 Stars" ? "triage" : "changelog"; jump(state, "S07"); break;
      case "candidate": state.picked = arg; state.translated=false; jump(state,"S07"); break;
      case "lang": state.translated = arg === "中文"; break;
      case "install":
        if (state.picked==="external") state.picked="externalCopy";
        saveItem(state,state.picked); state.flash = "完整子目录已入库"; break;
      case "subscribe": {
        if (skills[state.picked].owner==="外部" && state.owned.includes(`${state.picked}Copy`)) state.picked=`${state.picked}Copy`;
        state.subscriptions = Array.from(new Set([...state.subscriptions, state.picked])); jump(state, "S09"); break;
      }
      case "unsubscribe":
        state.subscriptions=state.subscriptions.filter(key=>key!==state.picked);
        state.picked=state.subscriptions[0] || lastFocus(state);
        state.flash="已取消订阅，库内内容保留"; break;
      case "inbox": state.picked = arg; jump(state,"S09"); break;
      case "retrySource": state.flash="来源仍不可达，保留昨天的结果"; break;
      case "review": state.updateDecision = ""; state.diffFile = 0; jump(state, "S10"); break;
      case "diff": state.diffFile = Number(arg); break;
      case "change": state.pending = arg; break;
      case "resolve":
        state.updateDecision = state.pending; state.pending = ""; state.unread = false;
        state.versionBySkill[state.picked] = state.updateDecision;
        state.flash = state.updateDecision === "备份后更新" ? "已备份本地版本并采用上游" : state.updateDecision === "回退到基线" ? "已恢复基线版本" : "已保留本地版本"; break;
      case "mode": state.copyMode = Number(arg); break;
      case "copy": state.flash = "✓ 已复制（演示）"; break;
      case "export": state.flash = "完整包包含正文、引用和脚本（演示）"; break;
      case "pack": state.selectedPack = arg; state.packRows = arg === "docs" ? ["release"] : ["triage"]; break;
      case "packRow": state.packRows = toggle(state.packRows, arg); break;
      case "packPlan": if (state.packRows.length) { state.picked = state.packRows[0]; plan(state, state.packRows, "pack"); } break;
      case "period": state.period = arg; state.repoRank = 0; break;
      case "rank": state.repoRank = Number(arg); break;
      case "rankRead": {
        const repo = ranks[state.period][state.repoRank]?.[0];
        if (repo) { state.picked = Object.keys(skills).find(key => skills[key].repo === repo); jump(state, "S08"); } break;
      }
      case "draftFile": if (arg !== "0") state.draftFiles = toggle(state.draftFiles, Number(arg)); state.draft = false; break;
      case "draft": state.draft = true; state.flash = "本地草稿已生成"; break;
      case "editDraft": state.draftNote = value; state.flash = "已保存草稿文字（演示）"; break;
      case "editRepo": if (value.trim()) { state.draftRepo=value.trim(); state.draft=false; } break;
      case "editBranch": if (value.trim()) { state.draftBranch=value.trim(); state.draft=false; } break;
      case "file": state.file = Number(arg); break;
      case "sidebar": state.sidebar = !state.sidebar; break;
      case "reader": state.readerOnly = !state.readerOnly; state.sidebar=false; break;
      case "batch": state.batch = !state.batch; break;
      case "check": if (state.owned.includes(arg)) state.checked = toggle(state.checked, arg); break;
      case "listOffset": state.listOffset=Number(arg); break;
      case "filter": state.filter = arg; state.listOffset=0; break;
      case "search": state.query = value.trim(); state.listOffset=0; break;
      case "refresh": state.flash = "已刷新示例数据"; break;
    }
  }
  return { pages, skills, library, targets, files, ranks, initial, pageById, act, results, permittedTargets };
})();
if (typeof module !== "undefined") module.exports = SkillScenarios;
