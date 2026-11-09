// Offline 2D Canvas renderer. Swift owns authentication, graph semantics and caching.
import ForceGraph from 'force-graph';
import { forceCollide } from 'd3-force-3d';
import { ProgressiveReveal, compareIDs } from './progressive-reveal.mjs';

const container = document.getElementById('graph');
let relation = 'following';
let session = '', root = '', selected = null, dark = false, reduceMotion = false;
let destroyed = false, active = true, lastDrag = -Infinity;
let lastSequence = 0;
let imageAttempt = 0, lastAvatarRevision = 0;
let pendingView = null;
let pathEdges = new Set(), highlightedNodes = new Set();
let selectedPath = [], animationFrame = null, lastAnimationDraw = -Infinity;
let outgoingPath = [], pathChangedAt = -Infinity;
const reveal = new ProgressiveReveal(), placed = new Set();
let graphRevision = -1, lastProgress = '', overviewStarted = false;
let selectionRevision = 0, visibleLinkCount = 0;
const renderedRelations = new Map();
let hasAppearance = false, rootPainted = false, presented = false;
let adjacentNodes = new Set();
let directionLinks = [], hoveredLink = null;
const nodes = new Map(), links = new Map(), resources = new Map();
const avatarOverrides = new Map();
// Local reads must keep moving even when remote downloads are slow/offline.
const cacheQueue = { pending: [], active: 0, limit: 8, cacheOnly: true };
const downloadQueue = { pending: [], active: 0, limit: 8, cacheOnly: false };
const avatarFades = new Set();
// A soft budget evicts only offscreen, completed resources. Never evict visible
// avatars to hit an arbitrary count: that would create placeholder/cache-read churn.
const avatarBudget = 512;
let viewportBounds = null, nextAvatarTrim = 0;
const endpoint = value => typeof value === 'object' ? value.id : value;
const edgeKey = (a, b) => `${a}:${b}`;
// Degree describes only the loaded presentation graph. Logarithmic scaling keeps
// a high-degree hub readable without allowing it to cover the surrounding graph.
const radius = node => node.radius ?? 10;
const isPath = link => pathEdges.has(edgeKey(endpoint(link.source), endpoint(link.target)));
const isAdjacent = link => selected != null &&
  (endpoint(link.source) === selected || endpoint(link.target) === selected);
const pathColor = () => dark ? '#53c9b5a0' : '#087f758c';
const linkColor = link => isPath(link) ? pathColor() : isAdjacent(link) ?
  (dark ? '#9aafbf70' : '#526c8068') : (dark ? '#65788b45' : '#8196ab40');
const post = (type, extra = {}) => {
  if (!destroyed) window.webkit?.messageHandlers.followGraph.postMessage({ type, session, ...extra });
};

/** Rasterize each avatar once; Canvas drawing never allocates GPU textures or images per frame. */
function paint(resource, node, placeholder = false) {
  const surface = placeholder ? resource.placeholder : resource.canvas;
  if (!surface) return;
  const ctx = surface.getContext('2d');
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
function drainImages(queue) {
  while (!destroyed && queue.active < queue.limit && queue.pending.length) {
    const [node, resource] = queue.pending.shift();
    if (resources.get(node.id) !== resource) continue;
    queue.active++;
    const image = new Image();
    resource.image = image;
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      image.onload = image.onerror = null;
      resource.cancel = null;
      queue.active--;
      drainImages(queue);
    };
    resource.cancel = () => { finish(); image.src = ''; };
    image.onload = () => {
      if (finished) return;
      if (!destroyed && resources.get(node.id) === resource) {
        if (!reduceMotion && !queue.cacheOnly) {
          // Keep a second surface only for the actual network crossfade.
          resource.placeholder = avatarSurface();
          resource.placeholder.getContext('2d').drawImage(resource.canvas, 0, 0);
        }
        resource.probing = false;
        resource.loaded = true;
        // Disk/memory hits are already available content: never replay a download fade.
        resource.loadedAt = queue.cacheOnly ? -Infinity : performance.now();
        paint(resource, node);
        if (!reduceMotion && !queue.cacheOnly) avatarFades.add(resource);
        // Invalidate one frame even after the force simulation has stopped.
        graph.nodeCanvasObject(drawNode);
        syncAnimation();
      }
      finish();
    };
    image.onerror = () => {
      if (finished) return;
      resource.failed = !queue.cacheOnly;
      finish();
      if (queue.cacheOnly && !destroyed && resources.get(node.id) === resource) {
        resource.probing = false;
        // A local miss releases first-frame presentation immediately, without
        // waiting for the network. Keep the existing placeholder/download fade.
        graph.nodeCanvasObject(drawNode);
        if (node.id === selected) downloadQueue.pending.unshift([node, resource]);
        else downloadQueue.pending.push([node, resource]);
        drainImages(downloadQueue);
      }
    };
    const url = new URL(node.avatar);
    if (!queue.cacheOnly) url.hostname = 'load';
    url.searchParams.set('attempt', String(++imageAttempt));
    image.src = url.href;
  }
}

/** Selection promotes queued work without exceeding eight downloads or cancelling
 * unrelated requests. Explicit re-click retries a failed avatar once, never in a render loop.
 */
function prioritizeAvatar(id) {
  const node = nodes.get(id);
  if (!node?.avatar) return;
  let resource = resources.get(id);
  if (resource?.failed) {
    discardAvatar(id);
    resource = null;
  }
  resource ??= avatar(node);
  for (const queue of [cacheQueue, downloadQueue]) {
    const index = queue.pending.findIndex(([, value]) => value === resource);
    if (index > 0) queue.pending.unshift(...queue.pending.splice(index, 1));
    drainImages(queue);
  }
}

/** Drop queued work before cancelling: cancellation drains its queue synchronously.
 * Deleting identity first prevents a captured stale callback from reviving the old image.
 */
function discardAvatar(id) {
  const resource = resources.get(id);
  resources.delete(id);
  avatarFades.delete(resource);
  for (const queue of [cacheQueue, downloadQueue]) {
    queue.pending = queue.pending.filter(([node]) => node.id !== id);
  }
  resource?.cancel?.();
  if (resource) {
    if (resource.image) resource.image.src = '';
    resource.image = null;
    resource.canvas.width = resource.canvas.height = 0;
    releasePlaceholder(resource);
  }
}

/** Free the backing pixels explicitly; a detached Canvas can otherwise retain them until GC. */
function releasePlaceholder(resource) {
  if (!resource.placeholder) return;
  resource.placeholder.width = resource.placeholder.height = 0;
  resource.placeholder = null;
}

function avatarSurface() {
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = 64;
  return canvas;
}

/** Match current graph coordinates once per base frame, not once per avatar. */
function updateViewportBounds() {
  const center = graph.centerAt(), scale = graph.zoom();
  viewportBounds = { left: center.x - innerWidth / (2 * scale), right: center.x + innerWidth / (2 * scale),
    top: center.y - innerHeight / (2 * scale), bottom: center.y + innerHeight / (2 * scale), scale };
}

function avatarOnscreen(node) {
  if (!viewportBounds || node.id === root || node.id === selected) return true;
  // Include the pop overshoot and screen-space stroke so edge avatars don't disappear early.
  const pad = radius(node) * 1.11 + 4 / viewportBounds.scale;
  return node.x + pad >= viewportBounds.left && node.x - pad <= viewportBounds.right &&
    node.y + pad >= viewportBounds.top && node.y - pad <= viewportBounds.bottom;
}

/** Trim at most twice per second; in-flight work, fades and all visible avatars stay pinned.
 * Re-entering the viewport probes native cache first, so eviction is not a network refresh.
 */
function trimAvatars() {
  const now = performance.now();
  if (resources.size <= avatarBudget || now < nextAvatarTrim) return;
  nextAvatarTrim = now + 500;
  const candidates = [...resources].filter(([id, resource]) =>
    resource.loaded && !resource.cancel && !avatarFades.has(resource) && !avatarOnscreen(nodes.get(id)));
  candidates.sort((a, b) => a[1].lastUsed - b[1].lastUsed);
  for (const [id] of candidates) {
    if (resources.size <= avatarBudget) break;
    discardAvatar(id);
  }
}

/** The card has made this avatar available in native cache. Restart only its
 * image probe with a fresh request identity, without rebuilding graphData or camera.
 */
function refreshCardAvatar(event) {
  if (event.revision <= lastAvatarRevision) return;
  lastAvatarRevision = event.revision;
  if (event.id !== selected || !nodes.has(event.id)) return;
  const node = nodes.get(event.id);
  const resource = resources.get(event.id);
  if (resource?.loaded && node.avatar === event.source) return;
  discardAvatar(event.id);
  avatarOverrides.set(event.id, event.source);
  node.avatar = event.source;
  prioritizeAvatar(event.id);
}

function avatar(node) {
  if (!resources.has(node.id)) {
    const resource = { canvas: avatarSurface(), placeholder: null, loaded: false, probing: Boolean(node.avatar) };
    resources.set(node.id, resource);
    paint(resource, node);
    if (node.avatar) { cacheQueue.pending.push([node, resource]); drainImages(cacheQueue); }
  }
  const resource = resources.get(node.id);
  resource.lastUsed = performance.now();
  return resource;
}

/** Avatars keep graph-space geometry; picking additionally guarantees a small screen-space target. */
function drawNode(node, ctx, scale) {
  // Only the root's bounded local probe gates initial presentation. A cached root
  // should not flash its letter first; no remote request can hold this gate.
  if (node.id === root && avatar(node).probing) return;
  if (node.id === root) rootPainted = true;
  if (!avatarOnscreen(node)) return;
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
    ctx.strokeStyle = emphasized ? (dark ? '#64d8c6' : '#168f83') : (dark ? '#8b99a8' : '#ffffff');
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
  .linkWidth(link => isPath(link) ? 1.25 : isAdjacent(link) ? 0.8 : selected ? 0.3 : 0.6)
  .linkColor(link => !isPath(link) && !isAdjacent(link) && selected ?
    (dark ? '#65788b18' : '#8196ab18') : linkColor(link))
  .linkDirectionalArrowColor(linkColor)
  // Native arrow lengths live in graph coordinates and become spikes when zoomed.
  .linkDirectionalArrowLength(() => 0)
  .linkDirectionalArrowRelPos(1)
  .cooldownTicks(120)
  .onRenderFramePre(updateViewportBounds)
  .onEngineTick(applyPendingView)
  .onEngineStop(applyPendingView)
  .onRenderFramePost((ctx, scale) => {
    drawDirections(ctx, scale);
    // Geometry/zoom changes refresh the overlay in the same frame as the graph.
    // Settled path animation can then leave the base and picking canvases asleep.
    drawFlowOverlay(scale);
    trimAvatars();
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
  .onLinkHover(link => { hoveredLink = link; redrawSelection(); })
  .onNodeDrag(() => { lastDrag = performance.now(); })
  .onNodeDragEnd(node => {
    lastDrag = performance.now();
    node.fx = node.id === root ? 0 : node.x;
    node.fy = node.id === root ? 0 : node.y;
  })
  .onZoomEnd(({ x, y, k }) => {
    post('viewport', { value: [x, y, k] });
  });

// Keep the existing post-node compositing order, but do not let an animated
// path invalidate thousands of static avatars/edges or the library's picking layer.
const flowCanvas = document.createElement('canvas');
flowCanvas.width = flowCanvas.height = 0;
Object.assign(flowCanvas.style, { position: 'absolute', left: '0', top: '0',
  width: '100%', height: '100%', pointerEvents: 'none' });
container.style.position = 'relative';
container.appendChild(flowCanvas);

/** Mirror the library's graph-to-screen transform, including Retina backing size.
 * Resize only when necessary: assigning canvas dimensions also clears its state.
 */
function drawFlowOverlay(scale = graph.zoom()) {
  if (reduceMotion || destroyed ||
      (selectedPath.length < 2 && !(outgoingPath.length > 1 && performance.now() - pathChangedAt < 180))) {
    // No flow needs a backing store once deselection has finished fading.
    if (flowCanvas.width) flowCanvas.width = flowCanvas.height = 0;
    return;
  }
  const ratio = window.devicePixelRatio || 1;
  const width = Math.round(innerWidth * ratio), height = Math.round(innerHeight * ratio);
  if (flowCanvas.width !== width || flowCanvas.height !== height) {
    flowCanvas.width = width;
    flowCanvas.height = height;
  }
  const ctx = flowCanvas.getContext('2d');
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, width, height);
  const origin = graph.graph2ScreenCoords(0, 0);
  ctx.setTransform(ratio * scale, 0, 0, ratio * scale, ratio * origin.x, ratio * origin.y);
  drawPathFlow(ctx, scale);
}

/** Give immediate visual feedback before Swift's next update pass. The native side still
 * owns loading and receives selection even if the card is already showing this user.
 */
function selectNode(id) {
  prioritizeAvatar(id);
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
  return relation === 'followers' ? path : path.reverse();
}

function setPath(path) {
  if (path.join(':') !== selectedPath.join(':')) {
    // Keep one outgoing path only; fast switching must not accumulate animation layers.
    outgoingPath = selectedPath;
    pathChangedAt = performance.now();
  }
  selectedPath = path;
  highlightedNodes = new Set(path);
  pathEdges = new Set(path.slice(1).map((id, i) => edgeKey(path[i], id)));
}

/** One shared screen-space phase traverses every directed hop, including hidden
 * distances beneath avatars. Bounded segmented tails avoid blur filters per edge.
 */
function drawPathFlow(ctx, scale = 1) {
  if (!ctx || reduceMotion) return;
  const blend = Math.min(1, (performance.now() - pathChangedAt) / 180);
  if (outgoingPath.length > 1 && blend < 1) drawFlow(ctx, scale, outgoingPath, 1 - blend);
  if (selectedPath.length > 1) drawFlow(ctx, scale, selectedPath, blend);
}

function drawFlow(ctx, scale, path, opacity) {
  if (opacity <= 0) return;
  const spacing = 220 / scale, phase = performance.now() * 0.075 / scale;
  let traveled = 0;
  ctx.save();
  ctx.strokeStyle = dark ? '#8cf5dc' : '#098c7e';
  ctx.lineWidth = 1.6 / scale;
  ctx.lineCap = 'round';
  for (let i = 1; i < path.length; i++) {
    const source = nodes.get(path[i - 1]), target = nodes.get(path[i]);
    if (!source || !target || !links.has(edgeKey(source.id, target.id))) continue;
    const dx = target.x - source.x, dy = target.y - source.y, length = Math.hypot(dx, dy);
    if (!Number.isFinite(length) || length <= 0) continue;
    const start = radius(source) + 2 / scale, end = length - radius(target) - 2 / scale;
    for (let d = ((phase - traveled) % spacing + spacing) % spacing; d < end; d += spacing) {
      if (d < start) continue;
      for (let segment = 0; segment < 7; segment++) {
        const head = d - segment * 4 / scale, tail = Math.max(start, head - 4 / scale);
        if (head <= start) break;
        ctx.globalAlpha = opacity * (1 - segment / 7) ** 2;
        ctx.beginPath();
        ctx.moveTo(source.x + dx * tail / length, source.y + dy * tail / length);
        ctx.lineTo(source.x + dx * head / length, source.y + dy * head / length);
        ctx.stroke();
      }
      const x = source.x + dx * d / length, y = source.y + dy * d / length;
      for (const [size, alpha] of [[4.5, 0.12], [2.2, 0.5], [1, 1]]) {
        ctx.globalAlpha = opacity * alpha;
        ctx.fillStyle = dark ? '#c6fff0' : '#08776c';
        ctx.beginPath();
        ctx.arc(x, y, size / scale, 0, Math.PI * 2);
        ctx.fill();
      }
    }
    // A brief rim pulse at arrival echoes the flow without washing out the avatar.
    const arrival = ((phase - traveled - end) % spacing + spacing) % spacing * scale;
    if (arrival < 24) {
      ctx.globalAlpha = opacity * 0.35 * (1 - arrival / 24);
      ctx.beginPath();
      ctx.arc(target.x, target.y, radius(target) + (2 + arrival / 8) / scale, 0, Math.PI * 2);
      ctx.stroke();
    }
    traveled += length;
  }
  ctx.restore();
}

function updateAdjacency() {
  adjacentNodes = new Set();
  const adjacent = [];
  for (const link of links.values()) {
    if (isAdjacent(link)) {
      adjacent.push(link);
      adjacentNodes.add(endpoint(link.source));
      adjacentNodes.add(endpoint(link.target));
    }
  }
  // Hubs should not acquire a crown of arrows. Keep the full selected path,
  // and reveal a dense hub's other directions only on the hovered relationship.
  directionLinks = [...links.values()].filter(isPath);
  if (adjacent.length <= 12) directionLinks.push(...adjacent.filter(link => !isPath(link)));
}

/** Small open chevrons stay six screen points long, with tips three points
 * outside the target avatar. Both dimensions remain stable while zooming.
 */
function drawDirections(ctx, scale = 1) {
  if (!ctx || !selected) return;
  const candidates = hoveredLink && isAdjacent(hoveredLink) && !directionLinks.includes(hoveredLink) ?
    [...directionLinks, hoveredLink] : directionLinks;
  ctx.save();
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  ctx.lineWidth = 1.1 / scale;
  for (const link of candidates) {
    const source = nodes.get(endpoint(link.source)), target = nodes.get(endpoint(link.target));
    if (!source || !target || !reveal.visible.has(source.id) || !reveal.visible.has(target.id)) continue;
    const dx = target.x - source.x, dy = target.y - source.y, length = Math.hypot(dx, dy);
    const start = radius(source) + 8 / scale, end = length - radius(target) - 3 / scale;
    if (!Number.isFinite(length) || end - start < 16 / scale) continue;
    const d = end, ux = dx / length, uy = dy / length;
    const x = source.x + ux * d, y = source.y + uy * d;
    const size = 6 / scale, wing = 2.5 / scale;
    ctx.strokeStyle = linkColor(link);
    ctx.beginPath();
    ctx.moveTo(x - ux * size - uy * wing, y - uy * size + ux * wing);
    ctx.lineTo(x, y);
    ctx.lineTo(x - ux * size + uy * wing, y - uy * size - ux * wing);
    ctx.stroke();
  }
  ctx.restore();
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
    if (reduceMotion || performance.now() - resource.loadedAt >= 280) {
      avatarFades.delete(resource);
      releasePlaceholder(resource);
    }
  }
  if (destroyed || !running || reduceMotion ||
      (selectedPath.length < 2 && !(outgoingPath.length > 1 && performance.now() - pathChangedAt < 180) &&
        !reveal.animating && !avatarFades.size)) {
    if (animationFrame !== null) cancelAnimationFrame(animationFrame);
    animationFrame = null;
  } else if (animationFrame === null) animationFrame = requestAnimationFrame(animate);
}

/** Invalidate at most 30 frames/sec; no extra pump survives deselection, backgrounding or teardown. */
function animate() {
  animationFrame = null;
  if (performance.now() - lastAnimationDraw >= 32) {
    lastAnimationDraw = performance.now();
    const needsBaseFrame = reveal.animating || avatarFades.size > 0;
    if (reveal.advance(performance.now())) applyVisibleGraph();
    else if (needsBaseFrame) graph.nodeCanvasObject(drawNode);
    drawFlowOverlay();
  }
  syncAnimation();
}

/** Only revealed objects enter the force simulation and pointer canvas. Newly admitted
 * children start next to their actual parent; shared node objects preserve the rest of the layout.
 */
function applyVisibleGraph() {
  // Decode a bounded lookahead before these nodes pop in. Do not allocate avatar
  // canvases for the entire graph (10,000 nodes would cost hundreds of MB).
  if (nodes.has(root)) avatar(nodes.get(root));
  for (const id of reveal.pending.slice(0, 16)) {
    if (nodes.has(id)) avatar(nodes.get(id));
  }
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
  const visibleLinks = [];
  renderedRelations.clear();
  // Count actual admitted relationships in the existing visibility pass. Selection
  // changes reuse this map instead of scanning the graph or sending every visible ID.
  for (const link of links.values()) {
    const source = endpoint(link.source), target = endpoint(link.target);
    if (!reveal.visible.has(source) || !reveal.visible.has(target)) continue;
    visibleLinks.push(link);
    const owner = relation === 'followers' ? target : source;
    renderedRelations.set(owner, (renderedRelations.get(owner) || 0) + 1);
  }
  visibleLinkCount = visibleLinks.length;
  // Retain an already queued explicit focus/restore command over this neutral preservation.
  if (!pendingView) pendingView = preserveView();
  graph.graphData({
    nodes: [...nodes.values()].filter(node => reveal.visible.has(node.id)), links: visibleLinks
  });
  reportProgress();
}

/** Bridge only real reveal changes (at most 30/sec) and selection acknowledgements.
 * The native selection version rejects delayed counts even after A -> B -> A.
 */
function reportProgress() {
  const selectedCount = renderedRelations.get(selected) || 0;
  const identity = `${graphRevision}:${reveal.visible.size}:${visibleLinkCount}:${selected}:${selectionRevision}:${selectedCount}`;
  if (lastProgress !== identity) {
    lastProgress = identity;
    post('progress', { revision: graphRevision, nodes: reveal.visible.size, edges: visibleLinkCount,
      selected, selectionRevision, selectedCount });
  }
}

/** Apply ordered native batches without rebuilding existing node positions or user pan/zoom. */
function update(payload) {
  if (destroyed || payload.sequence <= lastSequence) return;
  const previousRoot = root, previousRelation = relation, previousVisibleCount = reveal.visible.size;
  let topologyChanged = false, graphApplied = false;
  lastSequence = payload.sequence;
  session = payload.session;
  root = payload.root;
  if ('relation' in payload) relation = payload.relation;
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
  const oldSelection = selected;
  if ('selectionRevision' in payload) selectionRevision = payload.selectionRevision;
  if ('selected' in payload) selected = payload.selected;
  if (payload.path) setPath(payload.path);
  if (payload.nodes) {
    const incoming = new Set(payload.nodes.map(node => node.id));
    // A new bridge revision can contain only profile changes. graphData() reheats
    // D3 even with identical objects; compare identity sets, independent of order.
    topologyChanged = previousRoot !== root || previousRelation !== relation ||
      incoming.size !== nodes.size || [...incoming].some(id => !nodes.has(id)) ||
      payload.links.length !== links.size ||
      payload.links.some(link => !links.has(edgeKey(link.source, link.target)));
    for (const id of nodes.keys()) {
      if (!incoming.has(id)) {
        nodes.delete(id);
        avatarOverrides.delete(id);
        placed.delete(id);
        discardAvatar(id);
      }
    }
    // Sorted phyllotaxis is deterministic on reopen and valid even with Reduce Motion.
    const sorted = [...payload.nodes].sort((a, b) =>
      a.id === b.id ? 0 : a.id === root ? -1 : b.id === root ? 1 :
        compareIDs(a.id, b.id));
    sorted.forEach((value, index) => {
      // A later relationship batch may still carry the older snapshot avatar URL.
      // Keep the selected card's newer profile source for this Canvas session.
      if (avatarOverrides.has(value.id)) value = { ...value, avatar: avatarOverrides.get(value.id) };
      if (nodes.has(value.id)) {
        const node = nodes.get(value.id);
        if (node.avatar !== value.avatar || node.login !== value.login) {
          discardAvatar(value.id);
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
    if (topologyChanged) {
      const degrees = new Map();
      for (const link of links.values()) {
        for (const id of new Set([endpoint(link.source), endpoint(link.target)])) {
          degrees.set(id, (degrees.get(id) || 0) + 1);
        }
      }
      for (const node of nodes.values()) {
        node.radius = Math.min(26, 10 + 2 * Math.log2(1 + (degrees.get(node.id) || 0)));
      }
      // D3 caches collision radii. Profiles and pagination do not alter geometry.
      collision.radius(node => radius(node) + 6);
      reveal.sync(nodes, links, root, performance.now(), reduceMotion, relation);
    }
    graphRevision = payload.revision;
    if (!overviewStarted) {
      overviewStarted = true;
      // Fix the camera once before the first root frame, independent of arrival count
      // or Reduce Motion. New nodes animate into this view; completion never fits it.
      graph.zoom(0.8, 0).centerAt(0, 0, 0);
    }
    if (topologyChanged) { applyVisibleGraph(); graphApplied = true; }
    setPath(pathFromRoot(selected));
  }
  if (selected) {
    const oldCount = reveal.visible.size;
    reveal.show(selectedPath, performance.now());
    if (reduceMotion) reveal.finish();
    if (oldCount !== reveal.visible.size) { applyVisibleGraph(); graphApplied = true; }
  }
  // Reducing motion can admit the rest of a pending queue even without new topology.
  if (!graphApplied && reveal.visible.size !== previousVisibleCount) applyVisibleGraph();
  if ('selected' in payload || payload.nodes) {
    updateAdjacency();
  }
  if (selected !== oldSelection) prioritizeAvatar(selected);
  if (payload.avatarReady) refreshCardAvatar(payload.avatarReady);
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
  reportProgress();
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
    for (const id of resources.keys()) discardAvatar(id);
    avatarOverrides.clear();
    cacheQueue.pending.length = downloadQueue.pending.length = 0;
    avatarFades.clear();
    flowCanvas.width = flowCanvas.height = 0;
    flowCanvas.remove();
    graph._destructor();
  }
};
post('ready');
