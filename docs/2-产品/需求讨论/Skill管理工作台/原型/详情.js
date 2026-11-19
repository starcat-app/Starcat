/* 十六个评审场景的阅读区。底部操作始终与左侧所选对象、分配计划或收件箱记录对应。 */
const SkillDetails = (() => {
  function render(pane, state, ui, data) {
    const {rect,text,icon,line,chip,button,iconButton,frame,hit,colors,textWidth} = ui;
    const {width,height} = pane, margin = 30, area = width - margin * 2;
    const compact = state.page === "S15", item = data.skills[state.picked];
    const managed = state.owned.includes(state.picked);
    const page = data.pageById(state.page);
    const version = data.skills[state.picked].sha.slice(0,7) || "本地快照";
    const incoming = "89c04ad", main = [state.picked], selected = state.planEntries.length ? state.planEntries : main;
    const name = item.name, shortRoot = `…/managed/<id>/content/${name}/`;
    const entries = state.links[state.picked] || {};
    const activeCount = Object.values(entries).filter(value=>value==="active").length;
    const pausedCount = Object.values(entries).filter(value=>value==="paused").length;
    const reading = ["S01","S08","S15","S16"].includes(state.page);
    const topLabel = `${page.group}   /   ${page.title}`;
    text(pane,"导航路径",24,17,width-115,topLabel,13,500,colors.sub);
    if (reading) {
      if (state.page!=="S16")
        button(pane,width-178,12,state.translated?"看原文":"翻译",state.translated?"lang:原文":"lang:中文","quiet",62);
      iconButton(pane,"expand",width-98,12,state.readerOnly?"恢复栏位":"展开阅读区","reader");
    }
    iconButton(pane,"sync",width-48,12,"刷新详情","refresh");
    line(pane,0,53,width);

    function header(group, title, subtitle, options = {}) {
      const y = compact ? 68 : 77;
      if (options.glyph) {
        rect(pane,"条目图标底",margin,y,44,44,colors.select,10);
        icon(pane,options.glyph,margin+11,y+11,22,colors.blue);
      }
      const x = margin + (options.glyph ? 58 : 0);
      text(pane,"详情类别",x,y-2,width-x-margin,group,12,550,colors.sub);
      text(pane,"详情标题",x,y+18,width-x-margin,title,compact ? 21 : 25,650);
      text(pane,"详情摘要",margin,y+60,area,subtitle,14,400,colors.sub);
      line(pane,margin,y+95,area);
    }
    function section(y, title, aside = "") {
      text(pane,title,margin,y,area,title,16,600);
      if (aside) text(pane,aside,width-margin-218,y+3,218,aside,12,400,colors.sub,false,"right");
    }
    function paragraph(y, value, secondary = false) {
      text(pane,"说明",margin,y,area,value,14,400,secondary ? colors.sub : colors.text);
    }
    function fact(y, label, value, mono = false) {
      text(pane,label,margin,y,112,label,13,500,colors.sub);
      text(pane,`${label} 的值`,margin+118,y,area-119,value,13,500,colors.text,mono);
      line(pane,margin,y+28,area);
    }
    function message(y, title, sub, tint = "blue") {
      const [ink, fill] = ui.tone(tint);
      rect(pane,"提示背景",margin,y,area,57,fill,7);
      icon(pane,"info",margin+13,y+11,17,ink);
      text(pane,title,margin+40,y+6,area-52,title,13,600,ink);
      text(pane,sub,margin+40,y+30,area-52,sub,12,400,colors.sub);
    }
    function tabs(y, entries) {
      let x = margin;
      entries.forEach(([label,action,sel])=>{
        const size = Math.max(54, Math.ceil(textWidth(label,13)+24));
        const tab = hit(frame(pane,label,x,y,size,32),action);
        if (sel) rect(tab,"选中标签",0,29,size,2,colors.accent,1);
        text(tab,label,0,2,size,label,13,sel?600:450,sel ? colors.blue : colors.sub,false,"center");
        x += size+7;
      });
      line(pane,margin,y+32,area);
    }
    function skillTabs(active) {
      tabs(compact ? 167 : 183,[["说明","go:S01",active==="说明"],["文件","go:S16",active==="文件"],["分配","go:S06",active==="分配"],["版本","review",active==="版本"]]);
    }
    function code(y, title, lines) {
      const boxHeight = 36 + lines.length * 24 + 9;
      rect(pane,"文件背景",margin,y,area,boxHeight,colors.stripe,8);
      text(pane,title,margin+14,y+7,area-28,title,11,600,colors.sub,true);
      line(pane,margin+14,y+30,area-28);
      lines.forEach((entry,index)=>{
        const [value,tint] = Array.isArray(entry) ? entry : [entry];
        const color = tint ? ui.tone(tint)[0] : colors.text;
        text(pane,`行 ${index+1}`,margin+16,y+40+index*24,area-34,value,13,450,color,true);
      });
      return y + boxHeight;
    }
    function cardRow(y, glyph, title, sub, badge, tone = "gray", action = "", checked) {
      const row = hit(frame(pane,title,margin,y,area,57),action);
      rect(row,"行底",0,0,area,56,colors.stripe,6);
      const isCheck = typeof checked === "boolean";
      if (isCheck) {
        rect(row,"目标选择",12,18,19,19,checked ? colors.accent : colors.icon,4);
        if (checked) icon(row,"check",14,20,15,colors.ink);
      } else icon(row,glyph,13,17,19,tone === "amber" ? colors.amber : colors.sub);
      const badgeWidth = badge ? textWidth(badge,11)+20 : 0;
      text(row,title,44,5,area-60-badgeWidth,title,14,600);
      text(row,sub,44,30,area-56,sub,12,400,colors.sub);
      if (badge) chip(row,area-badgeWidth-10,7,badge,tone);
    }
    function footer(note, actions) {
      rect(pane,"操作栏",0,height-63,width,63,colors.bar);
      line(pane,0,height-63,width);
      let x = width - 21;
      for (const [label,action,style] of [...actions].reverse()) {
        const size = Math.ceil(textWidth(label,13)+27);
        x -= size;
        const copied = action === "copy" && state.flash === "✓ 已复制（演示）";
        button(pane,x,height-46,label,action,copied ? "copied" : style,size);
        x -= 8;
      }
      const label = state.flash || note;
      if (x>46) text(pane,"操作反馈",21,height-42,x-30,label,12,500,state.flash ? colors.green : colors.sub);
    }
    function showConfirm() {
      const remove = state.pending === "移除受管副本";
      const pause = state.pending === "暂停入口" || state.pending === "恢复入口";
      const sheetWidth = Math.min(480,area-30), sheetHeight = 179;
      const layer = frame(pane,"确认操作",0,0,width,height);
      rect(layer,"遮罩",0,0,width,height,compact ? "#00000070" : "#1D243338");
      const sheet = frame(layer,"确认面板",(width-sheetWidth)/2,Math.round((height-sheetHeight)/2),sheetWidth,sheetHeight,{fill:colors.paper,cornerRadius:12});
      text(sheet,"操作名称",21,19,sheetWidth-58,state.pending,19,600);
      iconButton(sheet,"close",sheetWidth-41,11,"关闭","cancel");
      const target = data.targets.find(value=>value.id===state.pauseTarget);
      const explain = remove ? `解除 ${activeCount} 个自有入口，将受管副本移入废纸篓。外部原件保留。` :
        pause ? state.pauseTarget==="shared" ? "Codex、Claude Code 共用这个入口，会同时受到影响。" : `影响范围为 ${target.sub}。其他项目可继续使用。` :
        state.pending === "备份后更新" ? "先备份本地修改，再写入所选上游版本。" : state.pending === "回退到基线" ? "恢复已记录的基线，并保留当前内容的备份。" : "保留本机文件，将本次上游变更标记为已处理。";
      text(sheet,"影响",21,58,sheetWidth-42,explain,14);
      text(sheet,"范围",21,87,sheetWidth-42,`当前条目  ${name}`,12,450,colors.sub);
      button(sheet,sheetWidth-191,126,"取消","cancel","quiet",62);
      button(sheet,sheetWidth-120,126,"确认（演示）",remove ? "confirmRemove" : pause ? "confirmPause" : "resolve","primary",101);
    }
    function libraryPage() {
      header(managed ? "我的库   /   受管条目" : "本机盘点   /   外部条目",name,item.summary,{glyph:item.glyph});
      skillTabs("说明");
      const y = compact ? 219 : 239;
      section(y,"SKILL.md",state.translated?"README 翻译 · 中文":"Markdown · 原文");
      paragraph(y+36,state.translated?item.summary:item.english);
      section(y+82,"如何使用");
      paragraph(y+115,item.example);
      code(y+151,"来源与版本",[item.repo,`${item.path}   @ ${version}`]);
      if (!compact) {
        section(531,"本机位置");
        fact(570,"内容归属",managed ? "Starcat 私有库" : "外部工具维护 · 只读");
        const location = entries.shared==="active" ? " · Codex、Claude Code 共用一个入口" : "";
        fact(608,"分配现场",managed ? `${activeCount} 个活跃入口，${pausedCount} 个暂停${location}` : "由外部工具维护");
        const x = margin + button(pane,margin,658,"查看分配","go:S06") + 8;
        if (managed) {
          const next = x + button(pane,x,658,"发布到 GitHub…","go:S14") + 8;
          button(pane,next,658,"移除受管副本…","remove");
        } else if (state.owned.includes(`${state.picked}Copy`)) button(pane,x,658,"查看对应受管副本",`library:${state.picked}Copy`);
      }
      footer(compact ? "这台 Mac" : "内容来自本机",[
        [compact?"标准窗口":"查看文件",compact?"go:S01":"go:S16"],["给 Agent 使用","go:S11"],
        [managed?"分配到 Agent":"查看纳管位置",managed?"plan":"go:S03","primary"]
      ]);
    }
    function inventory() {
      header("本机库","本机盘点","选择读取范围，先看清这台 Mac 上已有的文件和入口。",{glyph:"scan"});
      section(198,"本次扫描范围");
      const roots = [["~/.agents/skills","用户共享目录","可读取"],["Magpie Library/skills","配置的外部资料库","只读"],["Docs Lab/.claude/skills","上次成功读取 · 昨天 17:40",state.scanDenied?"重新读取仍待授权":"待授权"]];
      const root = roots[state.scanRoot];
      message(237,root[0],`${root[1]} · ${root[2]}`,state.scanRoot===2?"amber":"blue");
      if (state.scanRoot===2) button(pane,margin,305,"重试读取","scan");
      section(357,state.scanned ? "本次盘点结果" : "上次盘点结果","示例 Mac");
      if (state.scanRoot===0) {
        const active = state.links.release?.shared==="active";
        if (active) cardRow(399,"link","release-notes","共享目录中的符号链接指向 Starcat 私有库","受管入口","blue","library:release");
        else paragraph(407,"此目录上次分配的 release-notes 入口现已解除。",true);
      } else if (state.scanRoot===1) {
        cardRow(399,"folder","review-notes","Magpie Library/skills/review-notes","外部只读","gray","external");
      } else cardRow(399,"clock","docs-audit","上次观察在 Docs Lab 的项目入口 · 昨天 17:40","待刷新","amber");
      paragraph(508,state.scanRoot===2?"授权后可重新确认当前项目的入口。":"可以从中栏选择另一个目录，对照条目的来源和位置。",true);
      footer(state.scanned?"盘点完成 · 1 个根保留上次结果":"读取所列目录",[["重新盘点","scan"],["查看外部条目","external","primary"]]);
    }
    function adoption() {
      header("本机库   /   纳管预览",name,"保留外部管理器的原件，创建由 Starcat 维护的完整副本。",{glyph:"folder"});
      section(201,"两个位置");
      const source = item.origin || state.picked;
      const copy = `${source}Copy`;
      const available = state.owned.includes(copy);
      cardRow(243,"folder","现有原件",`外部资料库 / ${item.path}`,"保留","gray",`library:${source}`);
      cardRow(309,"library","Starcat 副本",shortRoot,available?"已入库":"待创建","blue",available?`library:${copy}`:"");
      fact(407,"导入范围","整个子目录 · 正文、引用与脚本");
      fact(448,"Agent 入口", "入库后单独选择目标");
      message(518,managed ? "副本已进入我的库" : "原位置仍归原管理器维护",managed ? "继续分配前可以先查看完整文件。" : "后续暂停和更新只作用于 Starcat 拥有的入口和副本。");
      footer(available?"已完成入库":"等待确认复制",[["返回盘点","go:S02"],[managed?"预览分配":available?"打开受管副本":"复制到我的库",managed?"plan":available?`library:${copy}`:"adopt","primary"]]);
    }
    function assignmentPlan() {
      const count = selected.length;
      header("本机库   /   写入预览",state.planKind==="repair"?"重新定位旧工作树":"分配到 Agent",count===1?`为 ${data.skills[selected[0]].name} 选择目标。`:`已选 ${count} 个 Skill，逐项核对目标位置。`,{glyph:"link"});
      const targets = data.permittedTargets(state);
      const missing = selected.filter(key=>!state.owned.includes(key));
      if (state.retried) message(197,"重新预览上次未完成的目标","示例中占用已解除。确认时将再次读取目标，保留已成功项。");
      else if (state.planKind==="repair") message(197,"重新定位至 Docs Lab","核对此项目的 Claude Code 入口，确认后重建对应分配。");
      else if (state.planKind==="pack") message(197,"只分配给所选工作树",`${targets[0].path} · ${targets[0].sub}`);
      else message(197,"共享入口会同时影响 Codex 和 Claude Code","在这台示例 Mac 上，两者解析到同一目录。每个 Skill 只在该目录创建一个链接。","amber");
      section(278,"目标位置",state.retried?"只重试上次失败项":"以实际目录归并");
      targets.forEach((target,index)=>{
        const editable = target.id !== "foreign";
        const items = state.retried?state.retryRows.filter(row=>row.target===target.id).map(row=>row.key):selected;
        const need = items.filter(key=>state.links[key]?.[target.id]!=="active").length;
        const label = !editable?"外部只读":need?`拟写 ${need} 项`:"已满足";
        cardRow(318+66*index,editable?"link":"lock",target.title,`${target.path}  ·  ${target.sub}`,label,editable?(need?"blue":"green"):"gray",editable?`target:${target.id}`:"",editable?state.selectedTargets.includes(target.id):undefined);
      });
      const planned = data.results(state), writes = planned.filter(row=>row.status!=="已满足").length;
      fact(609,"操作对象",selected.map(key=>data.skills[key].name).join("、"));
      fact(648,"待写入",`${writes} 个入口 · ${planned.length-writes} 项已满足`);
      if (missing.length) fact(687,"先按固定版本入库",missing.map(key=>`${data.skills[key].name}@${data.skills[key].sha.slice(0,7)}`).join("、"),true);
      footer("确认时再次核对现场",[["取消","cancelPlan"],["确认分配",state.selectedTargets.length?"apply":"","primary"]]);
    }
    function receipt() {
      const receiptRows = state.receipts || data.results(state);
      const count = label => receiptRows.filter(row=>row.status===label).length;
      header("本机库   /   分配回执","分配结果",`${count("已创建")} 项已创建，${count("已满足")} 项已满足，${count("需处理")} 项需要处理。`,{glyph:"check"});
      section(198,"逐项结果");
      const pageIndex = state.receiptPage, pageCount = Math.ceil(receiptRows.length/7);
      receiptRows.slice(pageIndex*7,(pageIndex+1)*7).forEach((row,index)=>{
        const target = data.targets.find(item=>item.id===row.target);
        const error = row.status === "需处理";
        cardRow(239+index*63,error?"info":"check",`${data.skills[row.key].name}  /  ${target.title}`,error ? "执行前目标已被其他工具占用，原文件保留。" : target.path,row.status,error?"amber":"green");
      });
      if (pageCount>1) {
        text(pane,"结果分页",margin,710,200,`第 ${pageIndex+1} / ${pageCount} 页 · ${receiptRows.length} 条回执`,13,500,colors.sub);
        button(pane,width-margin-153,705,"上一页",pageIndex?`receiptPage:${pageIndex-1}`:"","quiet",70);
        button(pane,width-margin-75,705,"下一页",pageIndex+1<pageCount?`receiptPage:${pageIndex+1}`:"","quiet",70);
      }
      footer("已保存每项目标的结果",[[...(count("需处理") ? ["只重试需处理项","retry"] : ["返回我的库","home"])],["查看分配","go:S06","primary"]]);
    }
    function assignments() {
      header("我的库   /   分配",name,item.summary,{glyph:item.glyph});
      skillTabs("分配");
      section(239,"分配现场","上次观察 · 此 Mac");
      let y = 278;
      const assigned = data.targets.filter(target=>entries[target.id]);
      if (!managed) {
        cardRow(y,"folder","外部管理器维护的条目",item.path,"外部只读");
        y+=69;
      } else if (!assigned.length) {
        message(y,"尚未分配给 Agent","副本已在私有库，可以为它选择第一个目标。");
        y+=69;
      }
      for (const target of assigned) {
        const paused = entries[target.id]==="paused";
        cardRow(y,"link",target.title,`${target.path}  ·  ${target.sub}`,paused?"已暂停":"已分配",paused?"amber":"blue");
        button(pane,margin+8,y+61,paused?"恢复此入口…":"暂停此入口…",`pause:${target.id}`);
        y+=105;
      }
      if (state.picked==="release") {
        cardRow(y,"link","旧工作树入口",state.repaired?"已重新定位至受管项目目录":"旧工作树已移动，可重新选择 Docs Lab 项目目录。",state.repaired?"已重新定位":"链接失效",state.repaired?"green":"amber");
        if (!state.repaired) button(pane,margin+8,y+62,"预览重新定位","repair");
        y+=104;
      }
      if (y+59<height-70) message(y+5,"实际调用记录","此示例只有文件与分配回执。当前没有可用于确认 Agent 调用的记录。");
      footer("回执归属 · 此 Mac",[[ "返回说明",`library:${state.picked}`],[managed?"分配到其他目标":"查看纳管位置",managed?"plan":"go:S03","primary"]]);
    }
    function discover() {
      const external = state.source === "外部目录";
      header(external?"发现   /   外部目录":"发现   /   我的 Stars",name,item.summary,{glyph:item.glyph});
      tabs(183,[["我的 Stars","source:我的 Stars",!external],["外部目录","source:外部目录",external]]);
      section(242,"候选来源");
      fact(287,"发布仓库",item.repo,true); fact(325,"仓内目录",item.path,true); fact(363,"发现于",external?"skills.sh 缓存 · 示例":"当前 GitHub 账号的 Stars");
      section(428,"阅读摘要"); paragraph(466,item.english);
      if (external) message(535,"目录来源暂不可用 · 上次成功为昨天 18:20","正在显示 skills.sh 缓存。安装时回到 GitHub 仓库解析所选子目录的提交。","amber");
      else message(535,"按 Skill 子目录选择","同一个仓库里的其他 Skill 可独立阅读、安装和订阅。");
      footer("来源信息来自示例数据",[["阅读并预览安装","go:S08","primary"]]);
    }
    function install() {
      const assignedKey = state.picked==="external"?"externalCopy":state.picked;
      const saved = state.owned.includes(assignedKey);
      header("发现   /   入库预览",name,item.summary,{glyph:"book"});
      tabs(183,[["原文","lang:原文",!state.translated],["中文翻译","lang:中文",state.translated]]);
      section(237,"SKILL.md",state.translated?"README 翻译组件 · 中文":"Markdown · 原文");
      paragraph(274,state.translated?item.summary:item.english); paragraph(308,state.translated?item.example:"Read the inputs, prepare a draft, and ask for review.",true);
      section(374,"将安装的版本");
      fact(417,"仓库",item.repo,true); fact(454,"子目录",item.path,true); fact(491,"固定提交",item.sha || "本地快照",true);
      fact(528,`包含 ${data.files.length} 个文件`,data.files.join("、"));
      fact(565,"本机目标",shortRoot,true);
      message(620,saved ? "此固定来源已有受管副本" : "将原始文件保存到私有库",saved ? "可以继续分配，或查看这个子目录的订阅。" : "中文译文用于阅读。入库使用此提交的完整原始子目录。",saved?"green":"blue");
      footer(saved?"已入库":"等待确认安装",saved?[["预览分配","installedPlan"],[state.subscriptions.includes(assignedKey)?"查看订阅":"订阅此 Skill","subscribe","primary"]]:[["返回发现","go:S07"],["安装到我的库","install","primary"]]);
    }
    function inbox() {
      if (!state.subscriptions.length) {
        header("GitHub   /   订阅更新","还没有订阅","从已收藏仓库中选择希望跟踪的 Skill 子目录。",{glyph:"inbox"});
        footer("本机库可继续使用",[["发现 Skill","source:我的 Stars","primary"]]);
        return;
      }
      const offline = state.picked==="docs", decision = state.versionBySkill[state.picked];
      header("GitHub   /   订阅更新",name,"跟踪仓内子目录，仓库内其他位置的改动不进入这份收件箱。",{glyph:"inbox"});
      section(201,"订阅范围");
      fact(242,"仓库",item.repo,true); fact(281,"跟踪目录",item.path,true); fact(320,"跟踪引用","main",true);
      message(394,offline?"来源暂不可达":decision==="备份后更新"?"已是最新":decision?"本次变化已处理":"子目录有新版本",offline?"上次成功检查 · 昨天 17:40。可单独重试。":decision?`已记录决定 · ${decision}`:`已安装 ${version} → 上游 ${incoming}`,offline?"amber":decision?"green":"blue");
      section(495,offline?"上次缓存的变更":"变更概览");
      cardRow(538,"file","SKILL.md","上游补充了输入说明","修改",offline?"gray":"blue");
      cardRow(605,"file","references/format.md","上游新增输出格式示例","修改",offline?"gray":"blue");
      footer(offline?"上次成功检查 · 昨天":"按子目录检查",[["取消订阅","unsubscribe"],["返回我的库","home"],[offline?"重试来源":"审核版本",offline?"retrySource":"review","primary"]]);
    }
    function review() {
      header("GitHub   /   版本审核",name,"先核对安装基线、本地文件和上游提交，再决定采用哪一份。",{glyph:"branch"});
      if (!managed || !item.sha) {
        message(211,managed?"此条目来自本机快照":"此版本由外部工具维护",managed?"关联 GitHub 子目录后可对照上游版本。":"纳管可保存独立副本，再对受管版本进行更新。");
        footer("当前来源",[["返回说明",`library:${state.picked}`],...(!managed?[["查看纳管位置","go:S03","primary"]]:[])]);
        return;
      }
      if (state.picked==="docs") {
        message(211,"来源暂不可达","上次成功检查为昨天 17:40，恢复连接后可重新比对。","amber");
        footer("本地文件可正常阅读",[["返回说明",`library:${state.picked}`],["重试来源","retrySource","primary"]]);
        return;
      }
      const cellWidth = Math.floor((area-18)/3);
      const decision = state.versionBySkill[state.picked];
      const local = decision==="备份后更新"?incoming:decision==="回退到基线"?version:"有修改";
      [["安装基线",version],["本地现场",local],["上游提交",incoming]].forEach(([label,value],index)=>{
        const x = margin + index*(cellWidth+9);
        rect(pane,label,x,199,cellWidth,65,index===1?colors.cream:colors.stripe,7);
        text(pane,label,x+12,208,cellWidth-22,label,12,500,colors.sub);
        text(pane,value,x+12,232,cellWidth-22,value,16,600,index===1?colors.amber:colors.text,true);
      });
      section(296,"逐文件差异");
      tabs(334,[["SKILL.md","diff:0",!state.diffFile],["references/format.md","diff:1",!!state.diffFile]]);
      code(397,state.diffFile?"references/format.md":"SKILL.md",state.diffFile?[
        ["  基线    Group by release type."],["  本地    Group by release type."],["+ 上游    Show a short example for each group.","green"]
      ]:[["  基线    Summarize the change."],["~ 本地    按读者角色整理变更。","amber"],["+ 上游    Group by user-visible change.","green"]]);
      message(559,decision ? "已记录处理结果 · 上方保留审核时的差异" : "SKILL.md 的本地文件与上游均有修改",decision || "逐文件阅读，选择将对整个 Skill 版本生效。采用上游前备份本地内容。",decision?"green":"amber");
      button(pane,margin,643,"回退到基线…","change:回退到基线");
      footer(state.flash || "待用户决定",[["返回收件箱","go:S09"],["保留本地","change:保留本地"],["备份后更新…","change:备份后更新","primary"]]);
    }
    function agent() {
      header("我的库   /   给 Agent 使用",name,"按用途复制内容，或把固定来源交给 Agent 发起安装预览。",{glyph:"code"});
      const modes = [["使用说明","任务提示及当前条目标识"],["原始正文","当前 SKILL.md 的原始内容"],["安装请求","GitHub 仓库、子目录和完整提交"],["完整文件包","正文与依赖文件一起导出"]];
      modes.forEach(([label,sub],index)=>cardRow(195+index*64,index===3?"pack":"copy",label,sub,state.copyMode===index?"已选择":"","blue",`mode:${index}`));
      const available = !!item.sha || state.copyMode!==2;
      const lines = [[`使用 ${name} 完成以下任务：`,item.example],[`# ${name}`,item.english],[item.repo,item.path,item.sha || "先关联 GitHub 来源"],data.files][state.copyMode];
      code(474,`${modes[state.copyMode][0]}预览`,lines);
      if (state.copyMode === 2 && available) button(pane,margin,635,"模拟 Agent 安装请求","agentPlan");
      footer(state.copyMode===2?"Agent 写入需在 App 核对目标":"示例动作",[
        ["返回条目","home"],[state.copyMode===3?"导出完整包":`复制${modes[state.copyMode][0]}`,available ? state.copyMode===3?"export":"copy" : "","primary"]
      ]);
    }
    function pack() {
      const docs = state.selectedPack==="docs", keys = docs?["docs","release"]:["docs","triage"], target = docs?"project":"ok";
      header("工作区   /   项目组合",docs?"Starcat Docs":"Maintainer Kit","将项目期望的版本和当前工作树中的入口逐项对照。",{glyph:"pack"});
      fact(203,"当前项目",docs?"Docs Lab":"Kit Demo"); fact(242,"目标作用域","仅所选项目的工作树");
      section(304,"组合内容","点击条目选择");
      keys.forEach((key,index)=>{
        const exists = state.links[key]?.[target]==="active", saved = state.owned.includes(key);
        const status = !saved?"需先入库":!exists?"缺少入口":"已满足";
        cardRow(347+index*70,"branch",data.skills[key].name,`期望 ${data.skills[key].sha.slice(0,7)}  ·  ${data.targets.find(value=>value.id===target).path}`,status,exists?"green":"amber",`packRow:${key}`,state.packRows.includes(key));
      });
      message(540,"组合可以在另一台 Mac 上重新应用","导出内容使用来源及固定版本。新的工作树由用户在本机选择。");
      footer(`已选择 ${state.packRows.length} 项`,[["预览所选分配",state.packRows.length?"packPlan":"","primary"]]);
    }
    function trend() {
      header("GitHub   /   Skill 趋势","仓库新增 Stars","统计已识别含有 Skill 的示例仓库，同一个仓库在榜单中占一个名次。",{glyph:"chart"});
      tabs(185,["周","月","年"].map(label=>[label,`period:${label}`,state.period===label]));
      section(245,`本${state.period}增长`,"指标 · 仓库新增 Stars");
      const rows = data.ranks[state.period];
      if (!rows.length) {
        message(308,"年度历史样本不足","目前仅有周、月两档完整示例。积累满所选区间后再计算年度增长。","amber");
      } else {
        rows.forEach(([label,score],index)=>{
          const top = 301+index*87;
          const row = hit(frame(pane,label,margin,top,area,73),`rank:${index}`);
          text(row,"名次",0,1,32,`0${index+1}`,15,600,colors.sub,true);
          text(row,"仓库",37,0,area-147,label,15,600);
          text(row,"新增 Stars",area-95,0,95,`+${score}`,15,600,colors.blue,true,"right");
          rect(row,"增长轨道",38,40,area-40,5,colors.icon,2);
          rect(row,"增长值",38,40,Math.round((area-40)*score/rows[0][1]),5,index===state.repoRank?colors.accent:colors.sub,2);
        });
      }
      fact(613,"数据来源","GitHub Stars · 演示数据"); fact(651,"样本范围","3 个仓库，可用区间 30 天");
      footer("同仓 Skill 共用仓库指标",rows.length?[["阅读所选候选","rankRead","primary"]]:[["查看月榜","period:月","primary"]]);
    }
    function publish() {
      header("工作区   /   发布",name,"准备可编辑的本地草稿，逐项复核将公开的文件。",{glyph:"branch"});
      fact(195,"目标仓库",state.draftRepo,true); fact(233,"拟用分支",state.draftBranch || `skills/${name}`,true);
      button(pane,width-margin-83,188,"更改仓库","askRepo","quiet",82);
      button(pane,width-margin-83,226,"更改分支","askBranch","quiet",82);
      section(289,"拟公开的文件");
      data.files.forEach((file,index)=>cardRow(327+index*61,"file",file,index?"可选择是否加入草稿":"入口正文随草稿保留",index===0?"必需":"","gray",index?`draftFile:${index}`:"",state.draftFiles.includes(index)));
      code(538,state.draft?"本地草稿 · 可编辑":"草稿预览",[state.draftNote || `Add ${name}`,`files: ${state.draftFiles.length}   ·   ${state.draftRepo} / ${state.draftBranch || `skills/${name}`}`]);
      if (state.draft) button(pane,margin,661,"编辑草稿说明","askDraft");
      footer(state.draft?"远端仓库尚无写入":"仅含所选相对路径",[["返回条目","home"],[state.draft?"复制草稿":"生成本地草稿",state.draft?"copy":"draft","primary"]]);
    }
    function filesPage() {
      header("我的库   /   文件",name,"阅读和复制当前版本中的文件。",{glyph:"folder"});
      skillTabs("文件"); section(241,"文件目录",`${data.files.length} 个文件`);
      data.files.forEach((file,index)=>cardRow(279+index*63,"file",file,index===0?"入口文档":index===1?"引用资料":"随包保存的脚本",state.file===index?"预览中":"","blue",`file:${index}`));
      const bodies = [[`# ${name}`,item.english,item.example],["# Output format","## Changes","- Describe a user-visible change."],["#!/bin/sh","# Format notes from standard input.","cat"]];
      code(498,data.files[state.file],bodies[state.file]);
      footer(`当前文件 · ${data.files[state.file]}`,[["返回说明",`library:${state.picked}`],["复制相对路径","copy","primary"]]);
    }
    const screen = {S01:libraryPage,S02:inventory,S03:adoption,S04:assignmentPlan,S05:receipt,S06:assignments,S07:discover,S08:install,S09:inbox,S10:review,S11:agent,S12:pack,S13:trend,S14:publish,S15:libraryPage,S16:filesPage};
    screen[state.page]();
    if (state.pending) showConfirm();
  }
  return { render };
})();
if (typeof module !== "undefined") module.exports = SkillDetails;
