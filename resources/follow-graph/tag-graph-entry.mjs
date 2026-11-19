// 离线标签画布。SQLite ID 是身份；只在真实数据变化时重新交给物理引擎。
import ForceGraph from 'force-graph';
import { forceCollide } from 'd3-force-3d';
import { edgeColor, edgeWidth, nodeRadius } from './tag-graph-style.mjs';

const host = document.getElementById('graph');
let options = {}, currentNodes = new Map(), links = [], neighbors = new Set();
let icons = new Map(), firstFit = true, painted = false, lastCamera = -1;
const post = (kind, ids = []) => window.webkit.messageHandlers.tagGraph.postMessage({
  kind, ids, session: options.session, generation: options.generation
});
const graph = new ForceGraph(host).width(host.clientWidth).height(host.clientHeight)
  .backgroundColor('transparent').autoPauseRedraw(true).warmupTicks(65).cooldownTicks(24)
  .nodeLabel(() => '').linkLabel(() => '').linkHoverPrecision(6)
  .nodeVal(n => (nodeRadius(n.repo_count) / 4) ** 2)
  .nodeCanvasObject(drawNode).nodePointerAreaPaint((n, color, ctx) => {
    ctx.fillStyle = color; ctx.beginPath(); ctx.arc(n.x,n.y,nodeRadius(n.repo_count),0,2*Math.PI); ctx.fill();
  }).linkWidth(e => edgeWidth(e.shared_count)).linkVisibility(e => e.shared_count >= options.minimum)
  .onNodeClick(n => post('select', [n.id])).onLinkClick(e => post('select', [e.left_id, e.right_id]))
  .onBackgroundClick(() => post('select')).onNodeDragEnd(n => { n.fx = n.x; n.fy = n.y; })
  .onRenderFramePost(() => {
    if (!painted && currentNodes.size) { painted = true; post('painted'); }
  })
  .onEngineStop(() => { if (firstFit && currentNodes.size) { firstFit = false; fit(); } });
graph.d3Force('charge').strength(-330);
graph.d3Force('link').distance(95);
graph.d3Force('collision', forceCollide(n => nodeRadius(n.repo_count) + 20));

// 主题色与选中项只触发重绘，不改变节点坐标或缩放。
function drawNode(n, ctx) {
  const r = nodeRadius(n.repo_count), dark = options.dark;
  const selected = options.selected?.includes(n.id);
  ctx.save();
  ctx.globalAlpha = options.selected?.length && !neighbors.has(n.id) ? 0.38 : 1;
  ctx.fillStyle = /^#?[a-f\d]{6}$/i.test(n.color || '') ? '#' + n.color.replace('#','') : '#347ac5';
  ctx.beginPath(); ctx.arc(n.x,n.y,r,0,2*Math.PI); ctx.fill();
  ctx.strokeStyle = selected ? (dark ? 'white' : '#16161a') : (dark ? '#ffffff66' : '#00000033');
  ctx.lineWidth = selected ? 3 : 1; ctx.stroke();
  ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  // SF Symbols 由原生端提供透明 PNG；未知符号回退到首字。
  const image = icons.get(n.icon); const ink = ctx.fillStyle;
  const rgb = [1,3,5].map(i => parseInt(ink.slice(i,i+2),16));
  const lightInk = (rgb[0]*299 + rgb[1]*587 + rgb[2]*114) < 145000;
  if (image?.naturalWidth) {
    ctx.filter = lightInk ? 'brightness(0) invert(1)' : 'brightness(0)';
    const scale = r * 1.22 / Math.max(image.naturalWidth,image.naturalHeight);
    const w = scale*image.naturalWidth, h = scale*image.naturalHeight;
    ctx.drawImage(image,n.x-w/2,n.y-h/2,w,h); ctx.filter = 'none';
  } else { ctx.fillStyle = lightInk ? 'white' : '#151515'; ctx.font = `bold ${r}px system-ui`; ctx.fillText(Array.from(n.name)[0] || '•',n.x,n.y); }
  ctx.font = `${selected ? '600' : '500'} 12px system-ui`;
  ctx.strokeStyle = dark ? '#1d1d20' : '#fafafa'; ctx.lineWidth = 3; ctx.lineJoin = 'round';
  ctx.strokeText(n.name,n.x,n.y+r+10); ctx.fillStyle = dark ? '#fafafa' : '#222'; ctx.fillText(n.name,n.x,n.y+r+10);
  ctx.restore();
}
function fit() { graph.zoomToFit(0,50); }
function refreshStyle() {
  // ForceGraph 的 setter 标记一帧为脏；静止时不连续重画。
  graph.linkColor(e => {
    const ids = options.selected || [];
    const hit = ids.length && ids.every(id => id === e.left_id || id === e.right_id);
    return edgeColor(e.shared_count, options.dark, hit);
  });
}
function apply(state) {
  const first = !options.session;
  options = state;
  if (state.data) {
    const {nodes,edges} = state.data;
    currentNodes = new Map(nodes.map(n => [n.id,Object.assign(currentNodes.get(n.id) || {}, n)]));
    links = edges.map(e => ({...e,source:e.left_id,target:e.right_id}));
    graph.cooldownTicks(state.reduced ? 0 : 24).graphData({nodes:[...currentNodes.values()],links});
    for (const [key,src] of Object.entries(state.icons || {})) if (!icons.has(key)) {
      const img = new Image(); icons.set(key,img); img.onload = refreshStyle; img.src = src;
    }
  }
  neighbors = new Set(state.selected);
  if (state.selected.length === 1) for (const e of links) {
    if (e.shared_count >= state.minimum && (e.left_id === state.selected[0] || e.right_id === state.selected[0])) {
      neighbors.add(e.left_id); neighbors.add(e.right_id);
    }
  }
  graph.linkVisibility(e => e.shared_count >= state.minimum);
  if (lastCamera !== state.camera && !first) {
    firstFit = false;
    const n = currentNodes.get(state.focus);
    if (n) { graph.centerAt(n.x,n.y,state.reduced ? 0 : 160); } else { fit(); }
  }
  lastCamera = state.camera; refreshStyle();
}
// 用户已经开始平移、拖动或缩放时，不再执行首次自动适配。
const takeCamera = () => { firstFit = false; };
host.addEventListener('pointerdown', takeCamera);
host.addEventListener('wheel', takeCamera, {passive: true});
const resize = new ResizeObserver(() => graph.width(host.clientWidth).height(host.clientHeight)); resize.observe(host);
window.tagGraph = {apply, destroy() { host.removeEventListener('pointerdown', takeCamera); host.removeEventListener('wheel', takeCamera);
  resize.disconnect(); graph._destructor(); icons.clear(); }};
window.webkit.messageHandlers.tagGraph.postMessage({kind:'ready'});
