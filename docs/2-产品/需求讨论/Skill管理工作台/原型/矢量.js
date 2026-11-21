/* 将 Pencil 画板源转换为离线 SVG。热区附着在原图层上，使整行选择与行内勾选各自响应。 */
const SkillVector = (() => {
  const escape = value => String(value ?? "").replace(/[&<>"']/g, character =>
    ({"&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&apos;"})[character]);

  /** 只有确认面板中的热区能在确认阶段接收点击和键盘焦点。 */
  function draw(item, pending, inSheet = false) {
    const sheet = inSheet || item.name === "确认操作";
    const position = `transform="translate(${item.x || 0} ${item.y || 0})"`;
    const size = `width="${item.width}" height="${item.height}"`;
    const fill = escape(item.fill || "none");
    if (item.type === "frame") {
      const action = item.metadata?.action;
      const enabled = action && (!pending || sheet);
      const accessible = enabled ? ` data-action="${escape(action)}" role="button" tabindex="0" aria-label="${escape(item.metadata.label)}"` : "";
      const dialog = item.name === "确认面板" ? ' role="dialog" aria-modal="true" aria-label="确认操作"' : "";
      const backdrop = item.fill || action ? `<rect ${size} rx="${item.cornerRadius || 0}" fill="${fill}"${action ? ' pointer-events="all"' : ""}/>` : "";
      const ring = enabled ? `<rect class="focus-ring" x="1" y="1" width="${item.width-2}" height="${item.height-2}" rx="6" fill="none"/>` : "";
      return `<g ${position} data-layer="${escape(item.name)}"${accessible}${dialog}>${backdrop}${item.children.map(child=>draw(child,pending,sheet)).join("")}${ring}</g>`;
    }
    if (item.type === "text") {
      const [anchor, offset] = item.textAlign === "center" ? ["middle",item.width/2] : item.textAlign === "right" ? ["end",item.width] : ["start",0];
      const family = item.fontFamily === "IBM Plex Mono" ? "ui-monospace, Menlo, monospace" : "-apple-system, BlinkMacSystemFont, PingFang SC, Noto Sans CJK SC, sans-serif";
      return `<text ${position} x="${offset}" y="${item.height/2+item.fontSize*0.35}" text-anchor="${anchor}" font-family="${family}" font-size="${item.fontSize}" font-weight="${item.fontWeight}" fill="${fill}" xml:space="preserve">${escape(item.content)}</text>`;
    }
    if (item.type === "rectangle") return `<rect ${position} ${size} fill="${fill}" rx="${item.cornerRadius || 0}"/>`;
    if (item.type === "ellipse") return `<ellipse ${position} cx="${item.width/2}" cy="${item.height/2}" rx="${item.width/2}" ry="${item.height/2}" fill="${fill}"/>`;
    if (item.type === "path") {
      return `<svg x="${item.x}" y="${item.y}" ${size} viewBox="${item.viewBox.join(" ")}" aria-hidden="true"><path d="${escape(item.geometry)}" fill="none" stroke="${escape(item.stroke)}" stroke-width="${item.strokeWidth}" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
    }
    throw Error(`未知的画板图层 ${item.type}`);
  }

  /** 保留独立 viewBox，使标准和紧凑画板能在不同显示器上等比评审。 */
  function svg(board, pending = false) {
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${board.width} ${board.height}" role="group" aria-label="${escape(board.name)}"><title>${escape(board.name)}</title>${draw(board,pending)}</svg>`;
  }
  return {svg};
})();
if (typeof module !== "undefined") module.exports = SkillVector;
