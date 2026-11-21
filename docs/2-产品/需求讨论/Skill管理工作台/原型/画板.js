/* 共用矢量画布。几何、文字、图标、操作热区均为独立图层，浏览器预览和 Pencil 绘制取同一棵树。 */
const SkillBoards = (() => {
  const data = typeof require === "function" ? require("./场景.js") : SkillScenarios;
  const detail = typeof require === "function" ? require("./详情.js") : SkillDetails;
  const light = { text:"#1D1D1F", sub:"#60646C", paper:"#FFFFFF", side:"#F5F5F7", bar:"#FAFAFC", line:"#D8DADF", stripe:"#F8F9FB", select:"#EAF3FF", blue:"#075DBD", accent:"#0969CB", green:"#13734E", mint:"#E6F5EB", amber:"#86520D", cream:"#FFF3DB", icon:"#E9ECF1", ink:"#FFFFFF" };
  const dark = { text:"#F5F5F7", sub:"#B1B5BE", paper:"#202124", side:"#191A1D", bar:"#25262A", line:"#404248", stripe:"#282A2E", select:"#173957", blue:"#82BCFF", accent:"#226AC2", green:"#7FD3A3", mint:"#16382E", amber:"#F3C57F", cream:"#392F21", icon:"#34373D", ink:"#FFFFFF" };
  const icons = {
    library:"M3 5h4v15H3z M10 5h4v15h-4z M16 6l3-1 4 14-3 1z",
    search:"M16 10a6 6 0 1 1-12 0 6 6 0 0 1 12 0z M15 15l6 6",
    scan:"M8 3H4v4 M16 3h4v4 M4 16v4h4 M20 16v4h-4 M3 12h18",
    star:"M12 3l2.8 5.8 6.4.9-4.6 4.5 1.1 6.4-5.7-3-5.7 3 1.1-6.4-4.6-4.5 6.4-.9z",
    globe:"M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0z M3 12h18 M12 3c5 5 5 13 0 18-5-5-5-13 0-18z",
    inbox:"M5 5h14l3 12v3H2v-3z M3 15h5l2 3h4l2-3h5",
    chart:"M3 20h18 M5 16l5-6 4 3 6-8 M16 5h4v4",
    pack:"M3 8l9-5 9 5-9 5z M3 12l9 5 9-5 M3 16l9 5 9-5",
    branch:"M9 6a2 2 0 1 1-4 0 2 2 0 0 1 4 0z M9 18a2 2 0 1 1-4 0 2 2 0 0 1 4 0z M20 6a2 2 0 1 1-4 0 2 2 0 0 1 4 0z M7 8v8 M18 8c0 6-10 3-11 8",
    folder:"M3 7V5h6l2 3h10v11H3z",
    file:"M5 3h9l5 5v13H5z M14 3v6h5 M8 13h8 M8 16h6",
    book:"M2 5c4-1 7-1 10 1 3-2 6-2 10-1v14c-4-1-7-1-10 1-3-2-6-2-10-1z M12 6v14",
    sync:"M20 10a8 8 0 0 0-14-4L3 9 M3 5v4h4 M4 14a8 8 0 0 0 14 4l3-3 M21 19v-4h-4",
    panel:"M3 4h18v16H3z M9 4v16", link:"M9 15l6-6 M8 12l-2 2a3 3 0 1 0 4 4l2-2 M16 12l2-2a3 3 0 1 0-4-4l-2 2",
    check:"M4 12l5 5L20 6", plus:"M12 4v16 M4 12h16",
    mac:"M3 4h18v13H3z M9 21h6 M12 17v4", copy:"M8 8h12v13H8z M16 5V3H4v13h2",
    clock:"M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0z M12 6v6l4 2",
    code:"M8 7l-5 5 5 5 M16 7l5 5-5 5 M14 4l-4 16", chevron:"M9 5l7 7-7 7",
    info:"M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0z M12 11v6 M12 7v1",
    lock:"M5 10h14v11H5z M8 10V7a4 4 0 0 1 8 0v3", close:"M5 5l14 14 M19 5L5 19",
    expand:"M4 9V4h5 M4 4l6 6 M15 20h5v-5 M20 20l-6-6"
  };
  const nav = [
    ["资料库",[["library","我的 Skill","home"],["scan","本机盘点","go:S02"]]],
    ["GitHub",[["star","我的 Stars","source:我的 Stars"],["globe","外部目录","source:外部目录"],["inbox","订阅更新","go:S09"],["chart","趋势","go:S13"]]],
    ["工作区",[["pack","项目组合","go:S12"]]]
  ];
  const textWidth = (value, size = 13, mono = false) => Array.from(value).reduce((total, letter) =>
    total + (/[\u2e80-\uffff]/u.test(letter) ? size : /[MW@%]/.test(letter) ? size * .85 : /[il.,:| ]/.test(letter) && !mono ? size * .32 : size * .59), 0);
  const clipText = (value, limit, size = 13, mono = false) => {
    if (textWidth(value, size, mono) <= limit) return value;
    let clipped = "";
    for (const letter of value) {
      if (textWidth(clipped + letter + "…", size, mono) > limit) break;
      clipped += letter;
    }
    return clipped + "…";
  };
  function node(parent, type, name, x, y, width, height, props = {}) {
    const item = { type, name, x, y, width, height, ...props };
    if (parent) parent.children.push(item);
    return item;
  }
  function frame(parent, name, x, y, width, height, props = {}) {
    return node(parent, "frame", name, x, y, width, height, { layout:"none", children:[], ...props });
  }
  function hit(item, action, label = item.name) {
    if (action) item.metadata = {type:"starcat-action", action, label};
    return item;
  }
  function paint(colors) {
    const rect = (parent, name, x, y, width, height, fill, radius = 0) => node(parent, "rectangle", name, x, y, width, height, {fill, cornerRadius:radius});
    const text = (parent, name, x, y, width, content, size = 13, weight = 400, fill = colors.text, mono = false, align = "left") => {
      const height = Math.ceil(size * 1.55);
      return node(parent,"text",name,x,y,width,height,{content:clipText(content,width-1,size,mono),fontFamily:mono ? "IBM Plex Mono" : "Noto Sans SC",fontSize:size,fontWeight:String(weight),textGrowth:"fixed-width-height",textAlign:align,textAlignVertical:"middle",fill});
    };
    const icon = (parent, key, x, y, size = 17, color = colors.sub) => node(parent,"path",`图标 · ${key}`,x,y,size,size,{viewBox:[0,0,24,24],geometry:icons[key],stroke:color,strokeWidth:1.65,strokeLinecap:"round",strokeLinejoin:"round"});
    const line = (parent, x, y, width) => rect(parent, "分隔线", x, y, width, 1, colors.line);
    const tone = key => key === "blue" ? [colors.blue,colors.select] : key === "green" ? [colors.green,colors.mint] : key === "amber" ? [colors.amber,colors.cream] : [colors.sub,colors.icon];
    const chip = (parent, x, y, label, tint = "gray") => {
      const width = Math.ceil(textWidth(label, 11) + 18);
      const [ink, fill] = tone(tint);
      rect(parent, `标签底 · ${label}`, x,y,width,22,fill,6);
      text(parent,label,x,y+2,width,label,11,600,ink,false,"center");
      return width;
    };
    const button = (parent, x, y, label, action, style = "quiet", width = Math.ceil(textWidth(label,13) + 28)) => {
      const group = hit(frame(parent,label,x,y,width,30),action);
      const active = !!action;
      const copied = style === "copied";
      const fill = copied ? colors.mint : style === "primary" && active ? colors.accent : colors.icon;
      const ink = copied ? colors.green : style === "primary" && active ? colors.ink : active ? colors.text : colors.sub;
      rect(group,"按钮背景",0,0,width,30,fill,7);
      text(group,label,0,4,width,copied ? "✓ 已复制" : label,13,600,ink,false,"center");
      return width;
    };
    const iconButton = (parent, key, x, y, label, action) => {
      const group = hit(frame(parent,label,x,y,30,30),action);
      icon(group,key,6,6,18);
    };
    return {rect,text,icon,line,chip,button,iconButton,frame,hit,tone,colors,textWidth};
  }
  function destination(state) {
    if (["S02","S03"].includes(state.page)) return "本机盘点";
    if (["S07","S08"].includes(state.page)) return state.source;
    return ({S09:"订阅更新",S10:"订阅更新",S12:"项目组合",S13:"趋势"})[state.page] || "我的 Skill";
  }
  function sidebar(parent, state, ui, height) {
    const {rect,text,icon,line,colors} = ui;
    const side = frame(parent,"导航",0,0,220,height,{fill:colors.side});
    for (const [index, fill] of ["#FF6058","#FFBD2E","#28C840"].entries())
      node(side,"ellipse","窗口控制",19+index*20,23,12,12,{fill});
    ui.iconButton(side,"panel",181,13,"折叠侧栏","sidebar");
    const brand = frame(side,"Starcat 工作台",14,71,192,49);
    rect(brand,"工具图标底",0,5,35,35,colors.select,9); icon(brand,"library",8,13,20,colors.blue);
    text(brand,"工作台名称",45,0,145,"Skill 管理",17,600);
    text(brand,"来源",45,27,140,"Starcat Direct",12,400,colors.sub);
    let y = 145;
    for (const [section, rows] of nav) {
      text(side,section,20,y,170,section,12,600,colors.sub); y += 26;
      for (const [glyph,label,action] of rows) {
        const selected = label === destination(state);
        const row = hit(frame(side,label,10,y,200,33),action);
        if (selected) rect(row,"选中背景",0,0,200,33,colors.select,7);
        icon(row,glyph,11,8,17,selected ? colors.blue : colors.sub);
        text(row,label,39,5,148,label,14,selected ? 600 : 450,selected ? colors.blue : colors.text);
        y += 36;
      }
      y += 20;
    }
    line(side,16,height-59,188);
    icon(side,"mac",22,height-40,18);
    text(side,"数据范围",50,height-43,145,"这台 Mac",13,500);
    rect(side,"右边界",219,0,1,height,colors.line);
  }
  function listRow(parent, ui, y, width, options) {
    const {text,rect,icon,chip,colors} = ui;
    const {label,sub,tag,glyph,sel,action,checkbox,checked,batchAction,index=0} = options;
    const group = hit(frame(parent,label,8,y,width-16,61),action);
    rect(group,"列表行",0,0,width-16,60,sel ? colors.select : index % 2 ? colors.stripe : colors.paper,7);
    let offset = 12;
    if (checkbox) {
      const box = hit(frame(group,`选择 ${label}`,3,12,30,32),batchAction);
      rect(box,"勾选框",5,7,17,17,checked ? colors.accent : colors.icon,4);
      if (checked) icon(box,"check",7,9,13,colors.ink);
      offset = 37;
    }
    rect(group,"条目图标底",offset,13,32,32,sel ? colors.paper : colors.icon,7);
    icon(group,glyph,offset+7,20,18,sel ? colors.blue : colors.sub);
    const labelX = offset + 43;
    const badge = tag ? Math.ceil(textWidth(tag,11)+18) : 0;
    text(group,"名称",labelX,6,width-34-labelX-badge,label,15,600);
    text(group,"来源 / 路径",labelX,33,width-labelX-34,sub,12,400,colors.sub);
    if (tag) chip(group,width-28-badge,9,tag,options.tone || "gray");
  }
  function middle(parent, state, ui, x, width, height) {
    const {rect,text,line,icon,button,iconButton,colors} = ui;
    const pane = frame(parent,"对象列表",x,0,width,height,{fill:colors.paper});
    const scope = destination(state);
    const browse = ["我的 Stars","外部目录"].includes(scope);
    const title = browse ? "发现 Skill" : scope;
    if (x === 0) iconButton(pane,"panel",8,13,"显示侧栏","sidebar");
    text(pane,"列表标题",x === 0 ? 43 : 19,12,width-96,title,19,600);
    iconButton(pane,"sync",width-42,12,"刷新","refresh");
    line(pane,0,53,width);
    let rows = [];
    let caption = "", rowY = 104;
    if (scope === "我的 Skill") {
      const input = hit(frame(pane,"搜索名称或来源",16,69,width-32,32),"askSearch");
      rect(input,"搜索框",0,0,width-32,32,colors.side,7); icon(input,"search",10,7,16);
      text(input,"搜索",33,5,width-73,state.query || "搜索名称或来源",13,400,state.query ? colors.text : colors.sub);
      let pos = 16;
      for (const label of ["全部","受管","外部"]) {
        const tab = hit(frame(pane,label,pos,114,48,26),`filter:${label}`);
        if (state.filter === label) rect(tab,"范围背景",0,0,48,26,colors.select,6);
        text(tab,label,0,3,48,label,12,500,state.filter === label ? colors.blue : colors.sub,false,"center");
        pos += 53;
      }
      button(pane,width-77,111,state.batch ? "完成" : "多选","batch","quiet",61);
      rows = [...new Set([...data.library,...state.installed])].filter(key => {
        const item = data.skills[key];
        const tag = state.owned.includes(key) ? "受管" : "外部";
        return !state.removed.includes(key) && (state.filter === "全部" || state.filter === tag) && `${item.name} ${item.repo}`.toLowerCase().includes(state.query.toLowerCase());
      }).map(key => ({label:data.skills[key].name, sub:data.skills[key].repo, glyph:data.skills[key].glyph, tag:state.owned.includes(key) ? "受管" : "外部",tone:state.owned.includes(key) ? "blue" : "gray",sel:key===state.picked,action:`library:${key}`,checkbox:state.batch && state.owned.includes(key),checked:state.checked.includes(key),batchAction:`check:${key}`}));
      caption = `本机条目 · ${rows.length}`; rowY = 187;
    } else if (scope === "本机盘点") {
      caption = "读取范围 · 3 个根目录";
      rows = [["共享目录","~/.agents/skills","link","可读取"],["外部资料库","Magpie Library/skills","folder","只读"],["项目目录","Docs Lab/.claude/skills","pack","待授权"]]
        .map(([label,sub,glyph,tag],index) => ({label,sub,glyph,tag,sel:index===state.scanRoot,action:`root:${index}`}));
    } else if (browse) {
      caption = state.source === "我的 Stars" ? "已收藏仓库中的 Skill" : "第三方目录 · 缓存样本";
      rows = (state.source === "我的 Stars" ? ["triage","changelog","release","docs"] : ["changelog","triage","docs"]).map(key => ({label:data.skills[key].name,sub:data.skills[key].repo,tag:key==="triage"?"推荐":"",glyph:data.skills[key].glyph,sel:state.picked===key,action:`candidate:${key}`}));
    } else if (scope === "订阅更新") {
      caption = "按 Skill 子目录订阅";
      rows = state.subscriptions.map(key => ({label:data.skills[key].name,sub:data.skills[key].repo,glyph:"inbox",tag:state.versionBySkill[key] ? "已处理" : key==="docs" ? "离线" : "待审核",tone:key==="docs"?"amber":"blue",sel:key===state.picked,action:`inbox:${key}`}));
    } else if (scope === "项目组合") {
      caption = "此 Mac 上的项目";
      rows = [["docs","Starcat Docs","Docs Lab · 2 个固定版本"],["kit","Maintainer Kit","Kit Demo · 2 个固定版本"]].map(([key,label,sub])=>({label,sub,glyph:"pack",sel:key===state.selectedPack,action:`pack:${key}`}));
    } else {
      caption = "GitHub 仓库榜 · 示例";
      rows = data.ranks[state.period].map(([label,score],index)=>({label,sub:`新增 ${score} Stars`,glyph:"chart",tag:`#${index+1}`,sel:state.repoRank===index,action:`rank:${index}`}));
    }
    text(pane,"列表分组",18,rowY-29,width-36,caption,12,600,colors.sub);
    const capacity = Math.max(1,Math.floor((height-54-rowY)/66));
    const paged = scope==="我的 Skill" && rows.length>capacity;
    const offset = paged ? Math.min(state.listOffset,Math.floor((rows.length-1)/capacity)*capacity) : 0;
    rows.slice(offset,offset+capacity).forEach((row,index) => listRow(pane,ui,rowY+index*66,width,{...row,index}));
    if (!rows.length) text(pane,"空状态",18,rowY+18,width-36,state.period==="年" && scope==="趋势" ? "尚未积累完整年度样本" : "没有匹配的条目",14,500,colors.sub);
    line(pane,0,height-48,width);
    if (state.batch && scope === "我的 Skill") {
      text(pane,"勾选汇总",16,height-35,width-142,`已勾选 ${state.checked.length} 项`,12,500,colors.sub);
      button(pane,width-120,height-39,"分配所选项",state.checked.length?"batchPlan":"","primary",105);
    } else {
      text(pane,"列表计数",17,height-34,width-48,`共 ${rows.length} 项`,12,400,colors.sub);
    }
    if (paged) button(pane,state.batch?width-183:width-85,height-39,offset?"上页":"下页",`listOffset:${offset?0:capacity}`,"quiet",54);
    rect(pane,"分隔条",width-1,0,1,height,colors.line);
  }
  function board(state) {
    const compact = state.page === "S15";
    const width = compact ? 1040 : 1440, height = compact ? 640 : 860;
    const colors = compact ? dark : light, ui = paint(colors);
    const page = data.pageById(state.page);
    const root = frame(null,`${page.id} · ${page.title}`,0,0,width,height,{fill:colors.paper,clip:true,context:page.acceptance});
    const side = compact || state.sidebar || state.readerOnly ? 0 : 220;
    const mid = state.readerOnly ? 0 : compact ? 300 : 400;
    if (side) sidebar(root,state,ui,height);
    if (mid) middle(root,state,ui,side,mid,height);
    const reader = frame(root,"阅读与操作",side+mid,0,width-side-mid,height,{fill:colors.paper});
    detail.render(reader,state,ui,data);
    if (compact && state.sidebar) sidebar(root,state,ui,height);
    return root;
  }
  return { board };
})();
if (typeof module !== "undefined") module.exports = SkillBoards;
