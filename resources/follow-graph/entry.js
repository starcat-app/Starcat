// Offline 2D Canvas renderer. Swift owns authentication, graph semantics and caching.
import ForceGraph from 'force-graph';
import { forceCollide } from 'd3-force-3d';
import { ProgressiveReveal, compareIDs } from './progressive-reveal.mjs';

const container = document.getElementById('graph');
let session = '', root = '', selected = null, dark = false, reduceMotion = false;
let destroyed = false, active = true, lastDrag = -Infinity, activeImages = 0;
let lastSequence = 0;
let pendingView = null;
let pathEdges = new Set(), highlightedNodes = new Set();
let selectedPath = [], animationFrame = null, lastAnimationDraw = -Infinity;
const reveal = new ProgressiveReveal(), placed = new Set();
let graphRevision = -1, lastProgress = '', overviewStarted = false;
let hasAppearance = false, rootPainted = false, presented = false;
let adjacentNodes = new Set();
const nodes = new Map(), links = new Map(), resources = new Map(), imageQueue = [];
const avatarFades = new Set();
const endpoint = value => typeof value === 'object' ? value.id : value;
const edgeKey = (a, b) => `${a}:${b}`;
// Degree describes only the loaded presentation graph. Logarithmic scaling keeps
// a high-degree hub readable without allowing it to cover the surrounding graph.
const radius = node => node.radius ?? 10;
const isPath = link => pathEdges.has(edgeKey(endpoint(link.source), endpoint(link.target)));
const isAdjacent = link => selected != null &&
  (endpoint(link.source) === selected || endpoint(link.target) === selected);
const linkColor = link => isPath(link) ? '#007aff' : isAdjacent(link) ?
  (dark ? '#c3cdd9' : '#465d73') : (dark ? '#65788b45' : '#8196ab40');
const post = (type, extra = {}) => {
  if (!destroyed) window.webkit?.messageHandlers.followGraph.postMessage({ type, session, ...extra });
};

/** Rasterize each avatar once; Canvas drawing never allocates GPU textures or images per frame. */
function paint(resource, node, placeholder = false) {
  const ctx = (placeholder ? resource.placeholder : resource.canvas).getContext('2d');
  ctx.clearRect(0, 0, 64, 64);
  ctx.save();
  ctx.beginPath();
  ctx.arc(32, 32, 32, 0, Math.PI * 2);
  ctx.clip();
  ctx.fillStyle = dark ? '#46586a' : '#cdd9e5';
  ctx.fillRect(0, 0, 64, 64);
  if (resource.loaded && !placeholder) ctx.drawImage(resource.image, 0, 0, 64, 64);
  else {
    ctx.fillStyle = dark ? '#ffffff' : '#24374a';
    ctx.font = 'bold 28px -apple-system, sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(node.login.slice(0, 1).toUpperCase(), 32, 33);
  }
  ctx.restore();
}

/** Bound avatar requests; removed nodes and teardown release in-flight handlers too. */
function drainImages() {
  while (!destroyed && activeImages < 4 && imageQueue.length) {
    const [node, resource] = imageQueue.shift();
    if (resources.get(node.id) !== resource) continue;
    activeImages++;
    const image = new Image();
    resource.image = image;
    const finish = () => {
      image.onload = image.onerror = null;
      resource.cancel = null;
      activeImages--;
      drainImages();
    };
    resource.cancel = () => { finish(); image.src = ''; };
    image.onload = () => {
      if (!destroyed && resources.get(node.id) === resource) {
        resource.loaded = true;
        resource.loadedAt = performance.now();
        paint(resource, node);
        if (!reduceMotion) avatarFades.add(resource);
        // Invalidate one frame even after the force simulation has stopped.
        graph.nodeCanvasObject(drawNode);
        syncAnimation();
      }
      finish();
    };
    image.onerror = finish;
    const url = new URL(node.avatar);
    url.searchParams.set('s', '64');
    image.src = url.href;
  }
}

function avatar(node) {
  if (!resources.has(node.id)) {
    const canvas = document.createElement('canvas');
    const placeholder = document.createElement('canvas');
    canvas.width = canvas.height = 64;
    placeholder.width = placeholder.height = 64;
    const resource = { canvas, placeholder, loaded: false };
    resources.set(node.id, resource);
    paint(resource, node);
    paint(resource, node, true);
    if (node.avatar) { imageQueue.push([node, resource]); drainImages(); }
  }
  return resources.get(node.id);
}

/** Avatars keep graph-space geometry; picking additionally guarantees a small screen-space target. */
function drawNode(node, ctx, scale) {
  if (node.id === root) rootPainted = true;
  const progress = reduceMotion ? 1 : reveal.progress(node.id, performance.now());
  // A short ease-out-back gives a readable pop without a perpetual spring simulation.
  const overshoot = progress - 1;
  const pop = progress === 0 ? 0 : 1 + 2.70158 * overshoot ** 3 + 1.70158 * overshoot ** 2;
  const r = radius(node) * Math.max(0.01, pop);
  const emphasized = node.id === root || node.id === selected ||
    highlightedNodes.has(node.id) || adjacentNodes.has(node.id);
  ctx.save();
  const opacity = (!selected || emphasized ? 1 : 0.3) * Math.min(1, progress * 3);
  ctx.globalAlpha = opacity;
  if (r * scale < 3 && !emphasized) {
    ctx.beginPath();
    ctx.arc(node.x, node.y, r, 0, Math.PI * 2);
    ctx.fillStyle = dark ? '#92a5b8' : '#687f96';
    ctx.fill();
  } else {
    const resource = avatar(node);
    const fade = !resource.loaded || reduceMotion ? 1 :
      Math.min(1, Math.max(0, (performance.now() - resource.loadedAt) / 280));
    // Keep the letter beneath the fading image, so a late download never flashes
    // an empty circle. The node's selection/reveal opacity still applies to both.
    if (fade < 1) ctx.drawImage(resource.placeholder, node.x - r, node.y - r, r * 2, r * 2);
    ctx.save();
    ctx.globalAlpha = opacity * fade;
    ctx.drawImage(resource.canvas, node.x - r, node.y - r, r * 2, r * 2);
    ctx.restore();
    ctx.beginPath();
    ctx.arc(node.x, node.y, r, 0, Math.PI * 2);
    ctx.strokeStyle = emphasized ? '#007aff' : (dark ? '#8b99a8' : '#ffffff');
    ctx.lineWidth = (emphasized ? 2 : 1) / scale;
    ctx.stroke();
  }
  if (node.id === root || node.id === selected) {
    // Only prominent nodes have persistent labels, so large graphs stay readable.
    const fontSize = 12 / scale;
    ctx.font = `500 ${fontSize}px -apple-system, sans-serif`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    ctx.fillStyle = dark ? '#f5f5f7' : '#1c1c1e';
    ctx.fillText(`@${node.login}`, node.x, node.y + r + 5 / scale);
  }
  ctx.restore();
}

const graph = new ForceGraph(container)
  .minZoom(0.05).maxZoom(8)
  .nodeRelSize(4)
  .nodeVal(node => (radius(node) / 4) ** 2)
  .nodeCanvasObject(drawNode)
  .nodePointerAreaPaint((node, color, ctx, scale = 1) => {
    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.arc(node.x, node.y, Math.max(radius(node), 6 / scale), 0, Math.PI * 2);
    ctx.fill();
  })
  .nodeLabel(node => {
    const label = document.createElement('span');
    label.textContent = `${node.name} (@${node.login})`;
    return label;
  })
  .linkWidth(link => isPath(link) ? 3 : isAdjacent(link) ? 2.4 : selected ? 0.3 : 0.6)
  .linkColor(link => !isPath(link) && !isAdjacent(link) && selected ?
    (dark ? '#65788b18' : '#8196ab18') : linkColor(link))
  .linkDirectionalArrowColor(linkColor)
  .linkDirectionalArrowLength(link => isPath(link) || isAdjacent(link) ? 6 : 0)
  .linkDirectionalArrowRelPos(1)
  .cooldownTicks(120)
  .onEngineTick(applyPendingView)
  .onEngineStop(applyPendingView)
  .onRenderFramePost((ctx, scale) => {
    drawPathFlow(ctx, scale);
    // Script readiness is earlier than the first real Canvas frame. Keep native
    // presentation hidden until the themed graph has actually painted its root.
    if (!presented && hasAppearance && rootPainted && session) {
      presented = true;
      post('presented');
    }
  })
  .onNodeClick(node => { if (performance.now() - lastDrag > 250) selectNode(node.id); })
  .onBackgroundClick(() => selectNode(null))
  // Fine edges occupy much of a dense canvas. The library dispatches link hits
  // separately from background hits; both mean deselect in this product.
  .onLinkClick(() => selectNode(null))
  .onNodeDrag(() => { lastDrag = performance.now(); })
  .onNodeDragEnd(node => {
    lastDrag = performance.now();
    node.fx = node.id === root ? 0 : node.x;
    node.fy = node.id === root ? 0 : node.y;
  })
  .onZoomEnd(({ x, y, k }) => {
    post('viewport', { value: [x, y, k] });
  });

/** Give immediate visual feedback before Swift's next update pass. The native side still
 * owns loading and receives selection even if the card is already showing this user.
 */
function selectNode(id) {
  if (selected === id) {
    post('select', { id });
    return;
  }
  selected = id;
  // Compute from the same loaded directed graph immediately. Waiting for a SwiftUI
  // representable update left only the final adjacent edge visible after clicks.
  setPath(pathFromRoot(id));
  const oldCount = reveal.visible.size;
  reveal.show(selectedPath, performance.now());
  if (reduceMotion) reveal.finish();
  if (oldCount !== reveal.visible.size) applyVisibleGraph();
  updateAdjacency();
  redrawSelection();
  syncAnimation();
  post('select', { id });
}

/** The reveal queue already builds the same stable BFS tree on each graph revision.
 * Reuse it for selection instead of sorting/scanning the whole graph on every click.
 */
function pathFromRoot(id) {
  if (!id || !nodes.has(id)) return [];
  const parents = reveal.parents;
  if (!parents.has(id)) return [];
  const path = [];
  for (let current = id; current != null; current = parents.get(current)) path.push(current);
  return path.reverse();
}

function setPath(path) {
  selectedPath = path;
  highlightedNodes = new Set(path);
  pathEdges = new Set(path.slice(1).map((id, i) => edgeKey(path[i], id)));
}

/** One shared phase traverses every directed hop. Clip at avatar rims instead of painting faces. */
function drawPathFlow(ctx, scale = 1) {
  if (!ctx || reduceMotion || !selected || selectedPath.length < 2) return;
  const spacing = 90 / scale, phase = performance.now() * 0.065 / scale;
  let traveled = 0;
  ctx.save();
  ctx.strokeStyle = dark ? '#b9e7ff' : '#59c4ff';
  ctx.lineWidth = 3 / scale;
  ctx.lineCap = 'round';
  for (let i = 1; i < selectedPath.length; i++) {
    const source = nodes.get(selectedPath[i - 1]), target = nodes.get(selectedPath[i]);
    if (!source || !target || !pathEdges.has(edgeKey(source.id, target.id))) continue;
    const dx = target.x - source.x, dy = target.y - source.y, length = Math.hypot(dx, dy);
    if (!Number.isFinite(length) || length <= 0) continue;
    const start = radius(source) + 2 / scale, end = length - radius(target) - 2 / scale;
    for (let d = ((phase - traveled) % spacing + spacing) % spacing; d < end; d += spacing) {
      if (d < start) continue;
      const tail = Math.max(start, d - 12 / scale);
      ctx.beginPath();
      ctx.moveTo(source.x + dx * tail / length, source.y + dy * tail / length);
      ctx.lineTo(source.x + dx * d / length, source.y + dy * d / length);
      ctx.stroke();
    }
    traveled += length;
  }
  ctx.restore();
}

function updateAdjacency() {
  adjacentNodes = new Set();
  for (const link of links.values()) {
    if (isAdjacent(link)) {
      adjacentNodes.add(endpoint(link.source));
      adjacentNodes.add(endpoint(link.target));
    }
  }
}

function redrawSelection() {
  graph.nodeCanvasObject(drawNode).nodePointerAreaPaint(graph.nodePointerAreaPaint())
    .linkColor(graph.linkColor()).linkWidth(graph.linkWidth())
    .linkDirectionalArrowLength(graph.linkDirectionalArrowLength());
}

// force-graph runs its simulation in two dimensions. The shared D3 extension supplies
// collision detection without bringing back Three.js, a perspective camera or WebGL.
const collision = forceCollide(node => radius(node) + 6).iterations(2);
graph.d3Force('collide', collision);
graph.d3Force('charge').strength(-90);
graph.d3Force('link').distance(65).strength(0.12);

function fit(duration = 0) {
  graph.zoomToFit(duration, Math.min(90, innerWidth / 5, innerHeight / 5));
}

/** The component applies graphData asynchronously and may auto-zoom on that update.
 * Restore the preserved viewport before painting, including zero-tick Reduce Motion.
 */
function applyPendingView() {
  const action = pendingView;
  pendingView = null;
  action?.();
}

/** Keep the same camera across graphData. The library can otherwise auto-zoom
 * whenever scale returns to exactly 1, even after the initial view was set.
 */
function preserveView() {
  const { x, y } = graph.centerAt(), zoom = graph.zoom();
  return () => {
    // Most batches do not move the camera. Avoid generating redundant zoom-end
    // messages and native observation updates on every reveal frame.
    if (graph.zoom() !== zoom) graph.zoom(zoom, 0);
    const center = graph.centerAt();
    if (center.x !== x || center.y !== y) graph.centerAt(x, y, 0);
  };
}

function syncAnimation() {
  const running = active && !document.hidden;
  reveal.setRunning(running, performance.now());
  if (running) graph.resumeAnimation();
  else graph.pauseAnimation();
  for (const resource of avatarFades) {
    if (reduceMotion || performance.now() - resource.loadedAt >= 280) avatarFades.delete(resource);
  }
  if (destroyed || !running || reduceMotion ||
      (selectedPath.length < 2 && !reveal.animating && !avatarFades.size)) {
    if (animationFrame !== null) cancelAnimationFrame(animationFrame);
    animationFrame = null;
  } else if (animationFrame === null) animationFrame = requestAnimationFrame(animate);
}

/** Invalidate at most 30 frames/sec; no extra pump survives deselection, backgrounding or teardown. */
function animate() {
  animationFrame = null;
  if (performance.now() - lastAnimationDraw >= 32) {
    lastAnimationDraw = performance.now();
    if (reveal.advance(performance.now())) applyVisibleGraph();
    else graph.nodeCanvasObject(drawNode);
  }
  syncAnimation();
}

/** Only revealed objects enter the force simulation and pointer canvas. Newly admitted
 * children start next to their actual parent; shared node objects preserve the rest of the layout.
 */
function applyVisibleGraph() {
  for (const id of reveal.visible) {
    if (placed.has(id)) continue;
    const node = nodes.get(id), parent = nodes.get(reveal.parents.get(id));
    if (!node) continue;
    if (parent && !reduceMotion) {
      const angle = placed.size * 2.39996323, distance = radius(parent) + 24;
      node.x = parent.x + Math.cos(angle) * distance;
      node.y = parent.y + Math.sin(angle) * distance;
    }
    placed.add(id);
  }
  const visibleLinks = [...links.values()].filter(link =>
    reveal.visible.has(endpoint(link.source)) && reveal.visible.has(endpoint(link.target)));
  // Retain an already queued explicit focus/restore command over this neutral preservation.
  if (!pendingView) pendingView = preserveView();
  graph.graphData({
    nodes: [...nodes.values()].filter(node => reveal.visible.has(node.id)), links: visibleLinks
  });
  const identity = `${graphRevision}:${reveal.visible.size}:${visibleLinks.length}`;
  if (lastProgress !== identity) {
    lastProgress = identity;
    post('progress', { revision: graphRevision, nodes: reveal.visible.size, edges: visibleLinks.length });
  }
}

/** Apply ordered native batches without rebuilding existing node positions or user pan/zoom. */
function update(payload) {
  if (destroyed || payload.sequence <= lastSequence) return;
  lastSequence = payload.sequence;
  session = payload.session;
  root = payload.root;
  if ('dark' in payload) {
    hasAppearance = true;
    dark = payload.dark;
    graph.backgroundColor(dark ? '#1c1c1e' : '#f5f5f7');
    for (const [id, resource] of resources) {
      paint(resource, nodes.get(id));
      paint(resource, nodes.get(id), true);
    }
  }
  if ('reduceMotion' in payload) {
    reduceMotion = payload.reduceMotion;
    graph.cooldownTicks(reduceMotion ? 0 : 120);
    if (reduceMotion) reveal.finish();
  }
  if ('selected' in payload) selected = payload.selected;
  if (payload.path) setPath(payload.path);
  if (payload.nodes) {
    const incoming = new Set(payload.nodes.map(node => node.id));
    for (const id of nodes.keys()) {
      if (!incoming.has(id)) {
        nodes.delete(id);
        placed.delete(id);
        const resource = resources.get(id);
        resources.delete(id);
        avatarFades.delete(resource);
        resource?.cancel?.();
      }
    }
    // Sorted phyllotaxis is deterministic on reopen and valid even with Reduce Motion.
    const sorted = [...payload.nodes].sort((a, b) =>
      a.id === b.id ? 0 : a.id === root ? -1 : b.id === root ? 1 :
        compareIDs(a.id, b.id));
    sorted.forEach((value, index) => {
      if (nodes.has(value.id)) {
        const node = nodes.get(value.id);
        if (node.avatar !== value.avatar || node.login !== value.login) {
          const resource = resources.get(value.id);
          resources.delete(value.id);
          avatarFades.delete(resource);
          resource?.cancel?.();
        }
        Object.assign(node, value);
      } else {
        const theta = index * 2.39996323, distance = 34 * Math.sqrt(index);
        nodes.set(value.id, { ...value, x: distance * Math.cos(theta), y: distance * Math.sin(theta) });
      }
      if (value.id === root) Object.assign(nodes.get(value.id), { x: 0, y: 0, fx: 0, fy: 0 });
    });
    const newLinks = new Map();
    payload.links.forEach(value => {
      const key = edgeKey(value.source, value.target);
      newLinks.set(key, links.get(key) || value);
    });
    links.clear(); for (const [key, link] of newLinks) links.set(key, link);
    const degrees = new Map();
    for (const link of links.values()) {
      for (const id of new Set([endpoint(link.source), endpoint(link.target)])) {
        degrees.set(id, (degrees.get(id) || 0) + 1);
      }
    }
    for (const node of nodes.values()) {
      node.radius = Math.min(26, 10 + 2 * Math.log2(1 + (degrees.get(node.id) || 0)));
    }
    // D3 caches collision radii. Refresh it when the graph changes, not on selection.
    collision.radius(node => radius(node) + 6);
    graphRevision = payload.revision;
    reveal.sync(nodes, links, root, performance.now(), reduceMotion);
    if (!overviewStarted) {
      overviewStarted = true;
      // Fix the camera once before the first root frame, independent of arrival count
      // or Reduce Motion. New nodes animate into this view; completion never fits it.
      graph.zoom(0.8, 0).centerAt(0, 0, 0);
    }
    applyVisibleGraph();
    setPath(pathFromRoot(selected));
  }
  if (selected) {
    const oldCount = reveal.visible.size;
    reveal.show(selectedPath, performance.now());
    if (reduceMotion) reveal.finish();
    if (oldCount !== reveal.visible.size) applyVisibleGraph();
  }
  if (!payload.nodes && 'reduceMotion' in payload) applyVisibleGraph();
  if ('selected' in payload || payload.nodes) {
    updateAdjacency();
  }
  // Request redraws for selection/avatars without keeping a settled canvas rendering forever.
  redrawSelection();
  const applyView = () => {
    if (payload.viewport) {
      const [x, y, zoom] = payload.viewport;
      graph.zoom(zoom, 0).centerAt(x, y, 0);
    } else if ('focus' in payload) {
      const node = nodes.get(payload.focus);
      const duration = reduceMotion ? 0 : 300;
      if (node) graph.centerAt(node.x, node.y, duration).zoom(Math.max(1, graph.zoom()), duration);
      else fit(duration);
    }
  };
  if (payload.viewport || 'focus' in payload) {
    if (pendingView) pendingView = applyView;
    else applyView();
  }
  if ('active' in payload) active = payload.active;
  syncAnimation();
}

// A real gesture takes precedence over a viewport captured before that gesture.
// Library zoom callbacks also fire for automatic transforms, so use DOM input here.
const touchViewport = () => { pendingView = null; };
container.addEventListener('pointerdown', touchViewport);
container.addEventListener('wheel', touchViewport, { passive: true });
const resize = new ResizeObserver(() => {
  graph.width(innerWidth).height(innerHeight);
});
resize.observe(container);
document.addEventListener('visibilitychange', syncAnimation);
const onError = () => post('error');
window.addEventListener('error', onError);
window.followGraph = {
  update,
  destroy() {
    destroyed = true;
    reveal.clear();
    placed.clear();
    if (animationFrame !== null) cancelAnimationFrame(animationFrame);
    animationFrame = null;
    pendingView = null;
    resize.disconnect();
    container.removeEventListener('pointerdown', touchViewport);
    container.removeEventListener('wheel', touchViewport);
    document.removeEventListener('visibilitychange', syncAnimation);
    window.removeEventListener('error', onError);
    for (const resource of resources.values()) resource.cancel?.();
    resources.clear(); imageQueue.length = 0;
    avatarFades.clear();
    graph._destructor();
  }
};
post('ready');
