// Bridge regression tests run without a browser, credentials or GUI automation.
// Only the Canvas component is substituted; the renderer and D3 forces are real.
import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { buildSync } from 'esbuild';
import { fileURLToPath } from 'node:url';
import { ProgressiveReveal } from './progressive-reveal.mjs';
import * as forces from 'd3-force-3d';

const source = buildSync({
  entryPoints: [fileURLToPath(new URL('entry.js', import.meta.url))],
  bundle: true, write: false, format: 'cjs', external: ['force-graph', 'd3-force-3d']
}).outputFiles[0].text;

/** Record the public component API so tests can drive the same callbacks as WebKit. */
function renderer({ reduced = true } = {}) {
  const props = new Map(), calls = [], messages = [], images = [], timers = new Map(), frames = new Map();
  let nextTimer = 0;
  let clock = 1000;
  let onResize;
  const target = () => ({
    listeners: new Map(),
    addEventListener(name, fn) { this.listeners.set(name, fn); },
    removeEventListener(name) { this.listeners.delete(name); }
  });
  const canvasContext = new Proxy({}, { get: (_, key) => (...args) => calls.push([key, ...args]) });
  const container = target(), document = { ...target(), hidden: false,
    getElementById: () => container,
    createElement: () => ({ getContext: () => canvasContext })
  };
  let center = { x: 0, y: 0 }, zoom = 1;
  const force = { strength() { return this; }, distance() { return this; } };
  const graph = new Proxy({}, {
    get(_, name) {
      return (...args) => {
        if (name === 'd3Force') return args.length === 1 ? force : graph;
        if (name === 'centerAt' && !args.length) return center;
        if (name === 'zoom' && !args.length) return zoom;
        if (name === 'graph2ScreenCoords') return {
          x: 600 + (args[0] - center.x) * zoom, y: 400 + (args[1] - center.y) * zoom
        };
        if (!args.length && ['nodeCanvasObject', 'nodePointerAreaPaint', 'linkColor',
          'linkWidth', 'linkDirectionalArrowLength'].includes(name)) return props.get(name);
        if (name === 'centerAt') center = { x: args[0], y: args[1] };
        if (name === 'zoom') zoom = args[0];
        calls.push([name, ...args]);
        props.set(name, args[0]);
        return graph;
      };
    }
  });
  const window = { ...target(), webkit: { messageHandlers: {
    followGraph: { postMessage: value => messages.push(value) }
  } } };
  vm.runInNewContext(source, {
    require: name => name === 'force-graph' ? function () { return graph; } : forces,
    window, document, innerWidth: 1200, innerHeight: 800, URL, performance: { now: () => clock },
    requestAnimationFrame: fn => { frames.set(++nextTimer, fn); return nextTimer; },
    cancelAnimationFrame: id => frames.delete(id),
    setTimeout: fn => { timers.set(++nextTimer, fn); return nextTimer; },
    clearTimeout: id => timers.delete(id),
    Image: class { constructor() { images.push(this); } },
    ResizeObserver: class { constructor(fn) { onResize = fn; } observe() {} disconnect() {} }
  });
  const update = (sequence, extra = {}) => window.followGraph.update({
    session: 'test', root: '1', sequence, revision: sequence,
    ...(sequence === 1 ? { reduceMotion: reduced } : {}), ...extra
  });
  const data = count => ({
    nodes: Array.from({ length: count }, (_, i) => ({
      id: String(i + 1), login: `user${i + 1}`, name: `User ${i + 1}`,
      avatar: `starcat-follow-avatar://cache/image?url=${encodeURIComponent(`https://avatars.githubusercontent.com/u/${i + 1}?s=64`)}`
    })),
    links: Array.from({ length: count - 1 }, (_, i) => ({ source: '1', target: String(i + 2) }))
  });
  return { props, calls, messages, images, timers, frames, container, document, window, graph, update, data, canvasContext,
    resize() { onResize(); },
    frame(ms = 34) { clock += ms; const pending = [...frames.values()]; frames.clear(); pending.forEach(fn => fn(clock)); },
    tick() { const pending = [...timers.values()]; timers.clear(); pending.forEach(fn => fn()); } };
}

test('2D viewport survives batches without auto-fit and stale batches are ignored', () => {
  const r = renderer();
  r.update(1, r.data(3));
  r.props.get('onEngineTick')();
  assert.ok(!r.calls.some(([name]) => name === 'zoomToFit'));
  assert.equal(r.props.get('zoom'), 0.8);
  const original = r.props.get('graphData').nodes[1];
  original.x = 200;
  r.container.listeners.get('wheel')();
  r.calls.length = 0;
  r.update(2, r.data(4));
  assert.equal(r.props.get('graphData').nodes[1], original);
  assert.equal(original.x, 200);
  assert.ok(!r.calls.some(([name]) => name === 'zoomToFit'));
  r.props.get('onEngineTick')();
  r.update(1, r.data(1));
  assert.equal(r.props.get('graphData').nodes.length, 4);
  r.update(3, { viewport: [120, -80, 1.5] });
  assert.deepEqual(r.calls.findLast(([name]) => name === 'centerAt'), ['centerAt', 120, -80, 0]);
  r.props.get('onZoomEnd')({ x: 120, y: -80, k: 1.5 });
  assert.equal(JSON.stringify(r.messages.at(-1)),
    JSON.stringify({ type: 'viewport', session: 'test', value: [120, -80, 1.5] }));
  assert.ok(!r.calls.some(([name]) => name === 'cameraPosition'));
  // A remounted Canvas may perform its own initial auto-zoom after graphData.
  // The saved viewport must win once that update reaches the layout callbacks.
  r.update(4, { ...r.data(4), viewport: [25, 40, 1] });
  r.props.get('onEngineStop')();
  assert.deepEqual(r.calls.findLast(([name]) => name === 'centerAt'), ['centerAt', 25, 40, 0]);
});

test('selected relationship count follows admitted nodes, never the incoming page size', () => {
  for (const relation of ['following', 'followers']) {
    const r = renderer({ reduced: false });
    const data = count => {
      const value = r.data(count);
      if (relation === 'followers') value.links = value.links.map(({ source, target }) => ({ source: target, target: source }));
      return value;
    };
    r.update(1, { ...data(4), relation, selected: '1', selectionRevision: 1 });
    for (let i = 0; i < 30; i++) r.frame();
    assert.equal(r.messages.filter(m => m.type === 'progress').at(-1).selectedCount, 3);
    r.update(2, { ...data(54), selected: '1', selectionRevision: 1 });
    const initial = r.messages.filter(m => m.type === 'progress').at(-1);
    assert.equal(initial.selectedCount, 3);
    const values = [];
    for (let i = 0; i < 100; i++) {
      r.frame();
      const progress = r.messages.filter(m => m.type === 'progress').at(-1);
      const visible = r.props.get('graphData');
      assert.equal(progress.selectedCount, visible.links.length);
      assert.equal(progress.revision, 2);
      assert.equal(progress.selectionRevision, 1);
      values.push(progress.selectedCount);
    }
    assert.ok(values.some(count => count > 3 && count < 53));
    assert.equal(values.at(-1), 53);
    r.window.followGraph.destroy();
  }
});

test('selection acknowledgement reports the right direction without rebuilding the graph', () => {
  for (const relation of ['following', 'followers']) {
    const r = renderer();
    const data = r.data(4);
    data.links = [{ source: '1', target: '2' }, { source: '2', target: '3' }, { source: '4', target: '2' }];
    r.update(1, { ...data, relation });
    const rebuilds = r.calls.filter(([name]) => name === 'graphData').length;
    for (const [sequence, selected, version] of [[2, '2', 1], [3, '1', 2], [4, '2', 3], [5, null, 4]]) {
      r.update(sequence, { selected, selectionRevision: version });
      const progress = r.messages.filter(m => m.type === 'progress').at(-1);
      assert.equal(progress.selected, selected);
      assert.equal(progress.selectionRevision, version);
      assert.equal(progress.selectedCount, selected === null ? 0 : selected === '1' ?
        (relation === 'followers' ? 0 : 1) : (relation === 'followers' ? 2 : 1));
    }
    assert.equal(r.calls.filter(([name]) => name === 'graphData').length, rebuilds);
    r.window.followGraph.destroy();
  }
});

test('completion, avatars, new batches and resizing never fit; explicit reset still fits', () => {
  for (const reduced of [false, true]) {
    const r = renderer({ reduced });
    r.update(1, r.data(20));
    r.props.get('onEngineTick')();
    const initialZoom = r.props.get('zoom'), initialCenter = r.props.get('centerAt');
    r.calls.length = 0;
    for (let i = 0; i < 100; i++) {
      r.frame();
      r.props.get('onEngineTick')();
    }
    r.props.get('onEngineStop')();
    assert.equal(r.props.get('graphData').nodes.length, 20);
    assert.equal(r.props.get('zoom'), initialZoom);
    assert.equal(JSON.stringify(r.props.get('centerAt')), JSON.stringify(initialCenter));
    const node = r.props.get('graphData').nodes[0];
    r.props.get('nodeCanvasObject')(node, r.canvasContext, 1);
    r.images[0].onload();
    r.frame(300);
    r.update(2, r.data(21));
    r.props.get('onEngineStop')();
    r.resize();
    assert.ok(!r.calls.some(([name]) => name === 'zoomToFit'));
    assert.ok(!r.calls.some(([name]) => name === 'zoom' || name === 'centerAt'));
    r.update(3, { focus: null });
    assert.equal(r.calls.filter(([name]) => name === 'zoomToFit').length, 1);
    r.window.followGraph.destroy();
  }
});

test('preserve exact 1x camera against library auto-zoom before drawing; explicit focus wins', () => {
  const r = renderer();
  r.update(1, r.data(3));
  r.props.get('onEngineStop')();
  r.update(2, { viewport: [50, -30, 1] });
  r.update(3, r.data(4));
  // Simulate force-graph's onFinishUpdate default-scale auto-zoom, which precedes engine callbacks.
  r.graph.zoom(0.25, 0).centerAt(0, 0, 0);
  r.props.get('onEngineTick')();
  assert.equal(r.props.get('zoom'), 1);
  assert.deepEqual(r.calls.findLast(([name]) => name === 'centerAt'), ['centerAt', 50, -30, 0]);
  r.update(4, { ...r.data(5), focus: '2' });
  r.props.get('onEngineStop')();
  const target = r.props.get('graphData').nodes[1];
  assert.deepEqual(r.calls.findLast(([name]) => name === 'centerAt'), ['centerAt', target.x, target.y, 0]);
  assert.ok(!r.calls.some(([name]) => name === 'zoomToFit'));
});

test('native presentation waits for a themed root paint and is sent once per renderer', () => {
  for (const reduced of [false, true]) {
    const r = renderer({ reduced });
    const presented = () => r.messages.filter(message => message.type === 'presented');
    r.props.get('onRenderFramePost')(r.canvasContext, 1);
    assert.equal(presented().length, 0);
    r.update(1, { ...r.data(3), dark: true });
    // Script readiness and data admission alone must not expose an empty WebView.
    r.props.get('onRenderFramePost')(r.canvasContext, 1);
    assert.equal(presented().length, 0);
    r.props.get('nodeCanvasObject')(r.props.get('graphData').nodes[0], r.canvasContext, 1);
    assert.equal(presented().length, 0);
    r.props.get('onRenderFramePost')(r.canvasContext, 1);
    assert.equal(presented().length, 0);
    // First frame waits only for local probing, never a network request.
    if (reduced) r.images[0].onerror();
    else r.images[0].onload();
    r.props.get('nodeCanvasObject')(r.props.get('graphData').nodes[0], r.canvasContext, 1);
    r.props.get('onRenderFramePost')(r.canvasContext, 1);
    assert.equal(presented().length, 1);
    assert.equal(presented()[0].session, 'test');
    r.update(2, { dark: false });
    r.props.get('onRenderFramePost')(r.canvasContext, 1);
    assert.equal(presented().length, 1);
    r.window.followGraph.destroy();
  }
});

test('avatar hit areas, directed path highlight and image redraw survive settled simulation', () => {
  const r = renderer();
  r.update(1, { ...r.data(3), selected: '2', path: ['1', '2'] });
  const { nodes, links } = r.props.get('graphData');
  assert.equal(r.props.get('linkDirectionalArrowLength')(links[0]), 0);
  assert.equal(r.props.get('linkDirectionalArrowLength')({ source: '2', target: '1' }), 0);
  r.props.get('nodeCanvasObject')(nodes[1], r.canvasContext, 1);
  assert.equal(r.images.length, 2); // Root is prefetched; the selected node loads on draw.
  r.calls.length = 0;
  r.images[0].onload();
  assert.ok(r.calls.some(([name]) => name === 'nodeCanvasObject'));
  r.props.get('nodePointerAreaPaint')(nodes[1], '#123456', r.canvasContext);
  assert.equal(r.calls.findLast(([name]) => name === 'arc')[3], nodes[1].radius);
  r.props.get('nodePointerAreaPaint')(nodes[1], '#123456', r.canvasContext, 0.1);
  assert.equal(r.calls.findLast(([name]) => name === 'arc')[3], 60);
  r.props.get('onNodeClick')(nodes[1]);
  assert.equal(r.messages.at(-1).id, '2');
  r.props.get('onNodeDragEnd')(nodes[1]);
  assert.equal(nodes[1].fx, nodes[1].x);
  assert.equal(nodes[1].fy, nodes[1].y);
  assert.equal(nodes[1].fz, undefined);
});

test('selection emphasizes every incoming/outgoing edge, keeps path distinct, and clears on deselect', () => {
  const r = renderer(), data = r.data(5);
  data.links.push({ source: '2', target: '3' }, { source: '4', target: '2' });
  r.update(1, { ...data, selected: '2', path: ['1', '2'] });
  const width = r.props.get('linkWidth'), color = r.props.get('linkColor');
  const arrow = r.props.get('linkDirectionalArrowLength');
  const path = { source: { id: '1' }, target: { id: '2' } };
  const incoming = { source: { id: '4' }, target: { id: '2' } };
  const outgoing = { source: { id: '2' }, target: { id: '3' } };
  const unrelated = { source: '1', target: '5' };
  assert.ok(width(incoming) > width(unrelated));
  assert.equal(width(incoming), width(outgoing));
  assert.equal(color(path), '#087f758c');
  assert.notEqual(color(incoming), color(path));
  assert.equal(arrow(incoming), 0);
  assert.equal(arrow(unrelated), 0);
  const ctx = new Proxy({}, { get: () => () => {}, set: (obj, key, value) => { obj[key] = value; return true; } });
  const alpha = [];
  const recording = new Proxy(ctx, { set: (obj, key, value) => {
    if (key === 'globalAlpha') alpha.push(value);
    obj[key] = value; return true;
  } });
  r.props.get('nodeCanvasObject')(r.props.get('graphData').nodes[3], recording, 1);
  r.props.get('nodeCanvasObject')(r.props.get('graphData').nodes[4], recording, 1);
  assert.deepEqual(alpha, [1, 1, 0.3, 0.3]);
  r.update(2, { selected: null, path: [] });
  assert.equal(width(incoming), 0.6);
  assert.equal(arrow(incoming), 0);
});

test('a real click callback highlights and selects before any native selection echo', () => {
  const r = renderer();
  r.update(1, r.data(4));
  const { nodes, links } = r.props.get('graphData');
  r.messages.length = 0;
  r.props.get('onNodeClick')(nodes[1]);
  assert.equal(r.messages[0].type, 'select');
  assert.equal(r.messages[0].id, '2');
  assert.equal(r.messages.length, 1);
  assert.equal(r.props.get('linkDirectionalArrowLength')(links[0]), 0);
  assert.ok(r.props.get('linkWidth')(links[0]) > r.props.get('linkWidth')(links[1]));
  r.update(2, { selected: '2', path: ['1', '2'] });
  r.props.get('onNodeClick')(nodes[1]);
  assert.equal(r.props.get('linkColor')(links[0]), '#087f758c');
  r.props.get('onBackgroundClick')();
  assert.equal(r.props.get('linkWidth')(links[0]), 0.6);
  r.props.get('onNodeClick')(nodes[1]);
  r.props.get('onLinkClick')(links[1]);
  assert.equal(r.messages.at(-1).id, null);
  assert.equal(r.props.get('linkWidth')(links[0]), 0.6);
  assert.equal(r.props.get('linkDirectionalArrowLength')(links[0]), 0);
});

test('clicking a second-level node highlights every directed hop from root and runs a continuous flow', () => {
  const r = renderer(), data = r.data(4);
  data.links = [{ source: '1', target: '2' }, { source: '2', target: '3' }, { source: '4', target: '3' }];
  r.update(1, data);
  r.update(2, { reduceMotion: false });
  const { nodes, links } = r.props.get('graphData');
  nodes.forEach((node, i) => { node.x = i * 250; node.y = 0; });
  // Match force-graph's mutation of string endpoints into shared node objects.
  links.forEach(link => {
    link.source = nodes.find(node => node.id === link.source);
    link.target = nodes.find(node => node.id === link.target);
  });
  r.props.get('onNodeClick')(nodes[2]);
  assert.equal(r.props.get('linkColor')(links[0]), '#087f758c');
  assert.equal(r.props.get('linkColor')(links[1]), '#087f758c');
  assert.notEqual(r.props.get('linkColor')(links[2]), '#087f758c');
  assert.equal(r.props.get('linkDirectionalArrowLength')(links[0]), 0);
  assert.equal(r.frames.size, 1);
  r.frame(200);
  r.calls.length = 0;
  r.props.get('onRenderFramePost')(r.canvasContext, 1);
  const initial = r.calls.filter(([name]) => name === 'lineTo');
  assert.ok(initial.some(([, x]) => x > 20 && x < 239));
  assert.ok(initial.some(([, x]) => x > 261 && x < 483));
  r.frame(100);
  r.calls.length = 0;
  r.props.get('onRenderFramePost')(r.canvasContext, 1);
  assert.notDeepEqual(r.calls.filter(([name]) => name === 'lineTo'), initial);
  r.update(3, { reduceMotion: true });
  assert.equal(r.frames.size, 0);
  r.calls.length = 0;
  r.props.get('onRenderFramePost')(r.canvasContext, 1);
  assert.ok(r.calls.some(([name]) => name === 'lineTo')); // Static direction markers remain.
  assert.equal(r.props.get('linkColor')(links[0]), '#087f758c');
  r.update(4, { reduceMotion: false, active: true });
  assert.equal(r.frames.size, 1);
  r.document.hidden = true;
  r.document.listeners.get('visibilitychange')();
  assert.equal(r.frames.size, 0);
  r.document.hidden = false;
  r.document.listeners.get('visibilitychange')();
  r.props.get('onBackgroundClick')();
  assert.equal(r.frames.size, 1); // Brief fade-out, then no idle animation pump.
  r.frame(200);
  assert.equal(r.frames.size, 0);
  r.props.get('onNodeClick')(nodes[2]);
  r.window.followGraph.destroy();
  assert.equal(r.frames.size, 0);
});

test('cached snapshots visibly reveal root then children, reuse objects and report actual canvas counts', () => {
  const r = renderer({ reduced: false }), data = r.data(20);
  data.links = data.links.filter(link => link.target !== '3');
  data.links.push({ source: '2', target: '3' });
  r.update(1, data);
  assert.equal(r.props.get('graphData').nodes.length, 1);
  assert.equal(r.props.get('graphData').links.length, 0);
  assert.equal(r.messages.findLast(m => m.type === 'progress').nodes, 1);
  const root = r.props.get('graphData').nodes[0];
  r.frame(50);
  let displayed = r.props.get('graphData');
  assert.equal(displayed.nodes.length, 2);
  assert.equal(displayed.nodes[0], root);
  assert.equal(displayed.nodes[1].id, '2');
  assert.ok(Math.hypot(displayed.nodes[1].x - root.x, displayed.nodes[1].y - root.y) <= root.radius + 24.001);
  r.calls.length = 0;
  r.props.get('nodeCanvasObject')(displayed.nodes[1], r.canvasContext, 1);
  const initialSize = r.calls.findLast(([name]) => name === 'arc')[3];
  r.frame(150);
  r.calls.length = 0;
  r.props.get('nodeCanvasObject')(displayed.nodes[1], r.canvasContext, 1);
  assert.ok(r.calls.findLast(([name]) => name === 'arc')[3] > initialSize);
  for (let i = 0; i < 80; i++) r.frame(34);
  displayed = r.props.get('graphData');
  assert.equal(displayed.nodes.length, 20);
  assert.equal(displayed.links.length, data.links.length);
  assert.equal(r.messages.findLast(m => m.type === 'progress').nodes, 20);
  assert.equal(r.frames.size, 0);
  // Already-visible avatars survive a new batch; no replay of the original animation.
  r.update(2, { ...r.data(21), revision: 2 });
  assert.equal(r.props.get('graphData').nodes.length, 20);
  assert.equal(r.props.get('graphData').nodes[0], root);
  r.props.get('onEngineStop')();
  assert.ok(!r.calls.some(([name]) => name === 'zoomToFit'));
  r.frame(50);
  assert.equal(r.props.get('graphData').nodes.length, 21);
  r.window.followGraph.destroy();
  assert.equal(r.frames.size, 0);
});

test('restored and initialized canvases replay cached nodes without fitting at completion', () => {
  // Native restoration and initialization both replace the WebView identity.
  // Reusing data must not reuse the previous canvas reveal queue.
  for (const relation of ['following', 'followers']) {
    for (const count of [24, 12]) {
      const r = renderer({ reduced: false }), data = r.data(count);
      data.relation = relation;
      if (relation === 'followers') data.links = data.links.map(({ source, target }) => ({ source: target, target: source }));
      r.update(1, data);
      assert.equal(r.props.get('graphData').nodes.length, 1);
      assert.equal(r.props.get('graphData').nodes[0].id, '1');
      r.frame(50);
      assert.equal(r.props.get('graphData').nodes.length, 2);
      for (let i = 0; i < 100; i++) r.frame(34);
      assert.equal(r.props.get('graphData').nodes.length, count);
      r.props.get('onEngineStop')();
      assert.ok(!r.calls.some(([name]) => name === 'zoomToFit'));
      r.window.followGraph.destroy();
      assert.equal(r.frames.size, 0);
    }
  }
});

test('reveal queue preserves BFS order and pause time; removed pending nodes never resurrect', () => {
  const q = new ProgressiveReveal();
  const nodes = new Map(['1', '2', '3', '4'].map(id => [id, { id }]));
  const links = new Map([
    ['a', { source: '1', target: '2' }], ['b', { source: '2', target: '3' }],
    ['c', { source: '1', target: '4' }]
  ]);
  q.sync(nodes, links, '1', 0, false);
  assert.deepEqual([...q.visible], ['1']);
  q.advance(50);
  assert.deepEqual([...q.visible], ['1', '2']);
  q.setRunning(false, 50);
  q.advance(10_000);
  assert.equal(q.visible.size, 2);
  q.setRunning(true, 10_050);
  assert.equal(q.progress('2', 10_050), 0);
  assert.equal(q.advance(10_050), false);
  q.advance(10_100);
  assert.deepEqual([...q.visible], ['1', '2', '4']);
  nodes.delete('3');
  q.sync(nodes, new Map([...links].filter(([id]) => id !== 'b')), '1', 10_100, false);
  q.advance(20_000);
  assert.equal(q.visible.has('3'), false);
  q.sync(nodes, links, '1', 20_000, true);
  assert.equal(q.animating, false);
  assert.equal(q.visible.size, 3);
});

test('large cached graphs accelerate to completion without a minute-long serial wait', () => {
  const q = new ProgressiveReveal();
  const nodes = new Map(Array.from({ length: 10_000 }, (_, i) => [String(i + 1), { id: String(i + 1) }]));
  const links = new Map([...nodes.keys()].slice(1).map(id => [id, { source: '1', target: id }]));
  q.sync(nodes, links, '1', 0, false);
  let time = 0;
  while (q.animating && time < 15_000) { time += 34; q.advance(time); }
  assert.equal(q.visible.size, 10_000);
  assert.equal(q.animating, false);
  assert.ok(time < 15_000);
});

test('selection stays native while pan/zoom and rendering send no card coordinates', () => {
  const r = renderer();
  r.update(1, { ...r.data(3), selected: '2', path: ['1', '2'] });
  r.update(2, { viewport: [100, -50, 2] });
  const before = r.messages.length;
  const node = r.props.get('graphData').nodes[1];
  node.x = 150; node.y = -30;
  for (let i = 0; i < 20; i++) r.props.get('onRenderFramePost')();
  r.tick();
  assert.equal(r.messages.length, before);
  assert.ok(r.messages.every(message => message.type !== 'anchor'));
  r.props.get('onBackgroundClick')();
  assert.equal(r.messages.at(-1).type, 'select');
  assert.equal(r.messages.at(-1).id, null);
  r.window.followGraph.destroy();
  assert.equal(r.timers.size, 0);
});

test('hidden/inactive canvas stays paused; teardown releases avatar loads and listeners', () => {
  const r = renderer();
  r.update(1, { ...r.data(6), reduceMotion: true, active: false });
  assert.equal(r.props.get('cooldownTicks'), 0);
  for (const node of r.props.get('graphData').nodes) {
    r.props.get('nodeCanvasObject')(node, r.canvasContext, 1);
  }
  assert.equal(r.images.length, 6); // Cache probes have their own eight-request budget.
  r.document.listeners.get('visibilitychange')();
  assert.equal(r.calls.at(-1)[0], 'pauseAnimation');
  r.window.followGraph.destroy();
  assert.ok(r.images.every(image => image.onload === null && image.onerror === null && image.src === ''));
  assert.equal(r.container.listeners.size, 0);
  const before = r.messages.length;
  r.update(2, r.data(3));
  assert.equal(r.messages.length, before);
});

test('downloaded avatars crossfade after layout settles and stop scheduling after completion', () => {
  const r = renderer();
  r.update(1, r.data(2));
  r.update(2, { reduceMotion: false });
  const node = r.props.get('graphData').nodes[1];
  const alphas = [];
  const ctx = new Proxy({}, {
    get: () => () => {},
    set: (_, key, value) => { if (key === 'globalAlpha') alphas.push(value); return true; }
  });
  const draw = () => { alphas.length = 0; r.props.get('nodeCanvasObject')(node, ctx, 1); return alphas.at(-1); };
  draw();
  const cached = r.images.find(image => decodeURIComponent(image.src).includes('/u/2?'));
  cached.onerror();
  r.images.at(-1).onload();
  assert.equal(draw(), 0);
  assert.equal(r.frames.size, 1);
  r.frame(140);
  assert.equal(draw(), 0.5);
  r.frame(140);
  assert.equal(draw(), 1);
  assert.equal(r.frames.size, 0);
  r.update(3, { reduceMotion: true });
  assert.equal(draw(), 1);
});

test('cached avatars display immediately without replaying download fades', () => {
  const r = renderer();
  r.update(1, r.data(1));
  r.update(2, { reduceMotion: false });
  r.images[0].onload();
  const alphas = [];
  const ctx = new Proxy({}, {
    get: () => () => {},
    set: (_, key, value) => { if (key === 'globalAlpha') alphas.push(value); return true; }
  });
  r.props.get('nodeCanvasObject')(r.props.get('graphData').nodes[0], ctx, 1);
  assert.equal(alphas.at(-1), 1);
  assert.equal(r.frames.size, 0);
  assert.ok(r.images.every(image => new URL(image.src).hostname === 'cache'));
});

test('bounded lookahead probes cache independently of slow downloads', () => {
  const r = renderer({ reduced: false });
  r.update(1, r.data(10_000));
  assert.equal(r.images.length, 8);
  // Cache misses fill eight remote slots; remaining local hits keep flowing.
  for (let i = 0; i < 8; i++) r.images.filter(image => new URL(image.src).hostname === 'cache')[i].onerror();
  assert.equal(r.images.filter(image => new URL(image.src).hostname === 'load').length, 8);
  while (true) {
    const next = r.images.find(image => image.onload && new URL(image.src).hostname === 'cache');
    if (!next) break;
    next.onload();
  }
  // Only root plus sixteen future nodes have allocated resources, not the whole graph.
  assert.equal(r.images.filter(image => new URL(image.src).hostname === 'cache').length, 17);
  assert.equal(r.images.filter(image => image.onload && new URL(image.src).hostname === 'load').length, 8);
  r.window.followGraph.destroy();
  assert.ok(r.images.every(image => image.onload === null && image.onerror === null));
});

/** Finish local probes without completing remote loads, creating a deterministic backlog. */
function missLocalProbes(r) {
  while (true) {
    const image = r.images.find(value => value.onerror && new URL(value.src).hostname === 'cache');
    if (!image) break;
    image.onerror();
  }
}

const imageUser = image => /\/u\/(\d+)/.exec(new URL(image.src).searchParams.get('url'))?.[1];

test('eight downloads stay bounded and selected queued avatar starts before background work', () => {
  const r = renderer();
  r.update(1, r.data(20));
  const nodes = r.props.get('graphData').nodes;
  for (const node of nodes) r.props.get('nodeCanvasObject')(node, r.canvasContext, 1);
  missLocalProbes(r);
  let active = r.images.filter(image => image.onload && new URL(image.src).hostname === 'load');
  assert.equal(active.length, 8);
  const selected = nodes[19];
  r.props.get('onNodeClick')(selected);
  active[0].onload();
  assert.equal(imageUser(r.images.at(-1)), selected.id);
  let waves = 1, completed = 1;
  while ((active = r.images.filter(image => image.onload && new URL(image.src).hostname === 'load')).length) {
    assert.ok(active.length <= 8);
    const batch = [...active];
    batch.forEach(image => image.onload());
    completed += batch.length;
    waves++;
  }
  assert.equal(completed, 20);
  assert.equal(waves, 4); // One selected completion, then three bounded batches.
  r.window.followGraph.destroy();
});

test('failed selected avatar retries only on a deliberate click with a fresh request identity', () => {
  const r = renderer();
  r.update(1, r.data(2));
  const node = r.props.get('graphData').nodes[1];
  r.props.get('onNodeClick')(node);
  missLocalProbes(r);
  const failed = r.images.find(image => image.onerror && new URL(image.src).hostname === 'load' && imageUser(image) === '2');
  failed.onerror();
  const count = r.images.length;
  for (let i = 0; i < 10; i++) r.props.get('nodeCanvasObject')(node, r.canvasContext, 1);
  r.update(2, { selected: '2' }); // Native echo must not repeatedly retry a failure.
  assert.equal(r.images.length, count);
  r.props.get('onNodeClick')(node);
  assert.equal(r.images.length, count + 1);
  assert.notEqual(r.images.at(-1).src, failed.src);
  assert.equal(new URL(r.images.at(-1).src).hostname, 'cache');
  r.images.at(-1).onload();
  const done = r.images.length;
  r.props.get('onNodeClick')(node);
  assert.equal(r.images.length, done);
  r.window.followGraph.destroy();
});

test('card completion cancels stale node load and reads cache without layout or camera changes', () => {
  const r = renderer();
  r.update(1, { ...r.data(3), selected: '2' });
  missLocalProbes(r);
  const old = r.images.find(image => image.onload && new URL(image.src).hostname === 'load' && imageUser(image) === '2');
  const stale = old.onload;
  r.calls.length = 0;
  const source = r.data(3).nodes[1].avatar;
  r.update(2, { avatarReady: { id: '2', source, revision: 1 } });
  assert.equal(old.onload, null);
  assert.equal(old.src, '');
  const fresh = r.images.at(-1);
  assert.equal(new URL(fresh.src).hostname, 'cache');
  stale();
  fresh.onload();
  assert.ok(!r.calls.some(([name]) => ['graphData', 'zoom', 'centerAt', 'zoomToFit'].includes(name)));
  const count = r.images.length;
  r.update(3, { avatarReady: { id: '2', source, revision: 1 } });
  assert.equal(r.images.length, count);
  const user2Count = r.images.filter(image => image.src && imageUser(image) === '2').length;
  r.update(4, { selected: '3', avatarReady: { id: '2', source, revision: 2 } });
  assert.equal(r.images.filter(image => image.src && imageUser(image) === '2').length, user2Count);
  r.window.followGraph.destroy();
});

test('new card avatar source survives older relationship batches without another image load', () => {
  const r = renderer();
  r.update(1, { ...r.data(3), selected: '2' });
  const node = r.props.get('graphData').nodes[1];
  const updated = new URL(node.avatar);
  updated.searchParams.set('url', 'https://avatars.githubusercontent.com/u/2?v=5&s=64');
  r.update(2, { avatarReady: { id: '2', source: updated.href, revision: 1 } });
  r.images.at(-1).onload();
  const count = r.images.length;
  r.update(3, r.data(3));
  assert.equal(r.props.get('graphData').nodes[1], node);
  assert.equal(node.avatar, updated.href);
  assert.equal(r.images.length, count);
  r.window.followGraph.destroy();
});

test('removed avatar requests cannot resurrect or enqueue a download', () => {
  const r = renderer();
  r.update(1, r.data(1));
  const stale = r.images[0].onerror;
  r.update(2, { nodes: [], links: [] });
  stale();
  assert.equal(r.images.length, 1);
  r.window.followGraph.destroy();
  assert.equal(r.frames.size, 0);
});

test('degree sizes count incoming/outgoing loaded edges and selection never changes geometry', () => {
  const r = renderer(), data = r.data(6);
  data.links = [
    { source: '1', target: '2' },
    ...['3', '4', '5', '6'].map(target => ({ source: '2', target }))
  ];
  r.update(1, data);
  const nodes = r.props.get('graphData').nodes;
  assert.ok(nodes[1].radius > nodes[0].radius);
  assert.equal(nodes[0].radius, nodes[2].radius);
  const radius = nodes[1].radius;
  r.props.get('onNodeClick')(nodes[1]);
  assert.equal(nodes[1].radius, radius);
  r.update(2, { ...data, links: [{ source: '1', target: '2' }] });
  assert.ok(nodes[1].radius < radius);
  assert.equal(nodes[2].radius, 10);
  r.update(3, r.data(10_000));
  assert.ok(r.props.get('graphData').nodes.every(node => node.radius >= 10 && node.radius <= 26));
});

test('cached BFS respects numeric tie breaks, cycles and edge removal on the next revision', () => {
  const r = renderer(), data = r.data(10);
  data.links = [
    { source: '1', target: '10' }, { source: '10', target: '3' },
    { source: '1', target: '2' }, { source: '2', target: '3' },
    { source: '3', target: '1' }
  ];
  r.update(1, data);
  r.props.get('onNodeClick')(r.props.get('graphData').nodes.find(node => node.id === '3'));
  const color = r.props.get('linkColor');
  assert.equal(color(data.links[2]), '#087f758c');
  assert.equal(color(data.links[3]), '#087f758c');
  assert.notEqual(color(data.links[0]), '#087f758c');
  r.update(2, { ...data, links: data.links.filter(link => link.source !== '2') });
  assert.equal(color(data.links[0]), '#087f758c');
  assert.equal(color(data.links[1]), '#087f758c');
  r.update(3, { ...data, links: [] });
  assert.notEqual(color(data.links[0]), '#087f758c');
});

// Followers changes traversal only; native payloads and Canvas arrows retain real direction.
test('followers reveal traverses incoming edges and keeps parents stable across cycles', () => {
  const reveal = new ProgressiveReveal();
  const nodes = new Map(['1', '2', '3', '10'].map(id => [id, { id }]));
  const links = new Map([
    ['2:1', { source: '2', target: '1' }], ['10:1', { source: '10', target: '1' }],
    ['3:2', { source: '3', target: '2' }], ['3:10', { source: '3', target: '10' }],
    ['2:3', { source: '2', target: '3' }]
  ]);
  reveal.sync(nodes, links, '1', 1000, false, 'followers');
  assert.deepEqual([...reveal.visible], ['1']);
  assert.deepEqual(reveal.pending, ['2', '10', '3']);
  assert.equal(reveal.parents.get('3'), '2');
  assert.equal(links.get('2:1').source, '2');
});

test('followers selection highlights and animates selected user to root, never the reciprocal edge', () => {
  const r = renderer(), data = r.data(3);
  data.links = [{ source: '2', target: '1' }, { source: '3', target: '2' },
    { source: '1', target: '2' }];
  r.update(1, { ...data, relation: 'followers' });
  r.update(2, { reduceMotion: false });
  const { nodes, links } = r.props.get('graphData');
  nodes.forEach((node, i) => { node.x = i * 250; node.y = 0; });
  r.props.get('onNodeClick')(nodes.find(node => node.id === '3'));
  assert.equal(r.props.get('linkColor')(links[0]), '#087f758c');
  assert.equal(r.props.get('linkColor')(links[1]), '#087f758c');
  assert.notEqual(r.props.get('linkColor')(links[2]), '#087f758c');
  r.frame(200);
  r.calls.length = 0;
  r.props.get('onRenderFramePost')(r.canvasContext, 1);
  // Flow strokes have one segment; open direction markers have two.
  const segments = r.calls.filter((call, i) => call[0] === 'moveTo' &&
    r.calls[i + 1]?.[0] === 'lineTo' && r.calls[i + 2]?.[0] === 'stroke');
  const starts = segments;
  const ends = segments.map(call => r.calls[r.calls.indexOf(call) + 1]);
  assert.ok(ends.length > 0);
  assert.ok(ends.every(([, x], i) => x < starts[i][1]));
  assert.ok(ends.some(([, x]) => x > 20 && x < 239));
  assert.ok(ends.some(([, x]) => x > 261 && x < 483));
  r.update(3, { selected: '3', path: ['3', '2', '1'] });
  assert.equal(r.props.get('linkColor')(links[0]), '#087f758c');
  r.props.get('onBackgroundClick')();
  assert.equal(r.props.get('linkWidth')(links[0]), 0.6);
});


test('open direction marks stay screen-sized at target rims and suppress dense hub arrows', () => {
  const r = renderer();
  r.update(1, r.data(30));
  const { nodes, links } = r.props.get('graphData');
  nodes.forEach((node, i) => { node.x = i * 300; node.y = 0; });
  r.props.get('onNodeClick')(nodes[0]);
  r.calls.length = 0;
  r.props.get('onRenderFramePost')(r.canvasContext, 1);
  assert.equal(r.calls.filter(([name]) => name === 'lineTo').length, 0);
  r.props.get('onLinkHover')(links[0]);
  for (const scale of [0.5, 1, 8]) {
    r.calls.length = 0;
    r.props.get('onRenderFramePost')(r.canvasContext, scale);
    const points = r.calls.filter(([name]) => name === 'lineTo');
    assert.equal(points.length, 2);
    assert.ok(Math.abs((points[0][1] - points[1][1]) * scale - 6) < 1e-8);
    assert.ok(points[0][1] > nodes[0].radius && points[0][1] < nodes[1].x - nodes[1].radius);
    assert.ok(Math.abs((nodes[1].x - points[0][1] - nodes[1].radius) * scale - 3) < 1e-8);
  }
  r.props.get('onLinkHover')(null);
  r.props.get('onNodeClick')(nodes[1]);
  r.calls.length = 0;
  r.props.get('onRenderFramePost')(r.canvasContext, 1);
  assert.equal(r.calls.filter(([name]) => name === 'lineTo').length, 2);
});

test('direction tips follow the real target rim in both graph modes, including diagonal edges', () => {
  for (const relation of ['following', 'followers']) {
    const r = renderer(), data = r.data(2);
    if (relation === 'followers') data.links = [{ source: '2', target: '1' }];
    r.update(1, { ...data, relation });
    const { nodes } = r.props.get('graphData');
    nodes[0].x = nodes[0].y = 0;
    nodes[1].x = 300; nodes[1].y = 200;
    r.props.get('onNodeClick')(nodes[1]);
    const source = nodes[relation === 'following' ? 0 : 1];
    const target = nodes[relation === 'following' ? 1 : 0];
    for (const scale of [0.5, 1, 8]) {
      r.calls.length = 0;
      r.props.get('onRenderFramePost')(r.canvasContext, scale);
      const points = r.calls.filter(([name]) => name === 'lineTo');
      assert.equal(points.length, 2);
      const [, x, y] = points[0];
      assert.ok(Math.abs((Math.hypot(x - target.x, y - target.y) - target.radius) * scale - 3) < 1e-8);
      // The open wings point back toward the source, regardless of exploration direction.
      const length = Math.hypot(target.x - source.x, target.y - source.y);
      const projection = ((x - points[1][1]) * (target.x - source.x) +
        (y - points[1][2]) * (target.y - source.y)) / length;
      assert.ok(Math.abs(projection * scale - 6) < 1e-8);
    }
  }
});


test('flow has bounded fading tails and fades out without animating reduced-motion paths', () => {
  const r = renderer();
  r.update(1, r.data(3));
  const { nodes } = r.props.get('graphData');
  nodes.forEach((node, i) => { node.x = i * 400; node.y = 0; });
  r.update(2, { reduceMotion: false });
  r.props.get('onNodeClick')(nodes[1]);
  r.frame(200);
  const alpha = [], radii = [];
  const ctx = new Proxy({}, {
    get: (_, key) => (...args) => { if (key === 'arc') radii.push(args[2]); },
    set: (_, key, value) => { if (key === 'globalAlpha') alpha.push(value); return true; }
  });
  r.props.get('onRenderFramePost')(ctx, 1);
  assert.ok(alpha.some(value => value > 0 && value < 0.1));
  assert.ok(radii.includes(4.5) && radii.includes(1));
  r.props.get('onBackgroundClick')();
  r.frame(90);
  alpha.length = 0;
  r.props.get('onRenderFramePost')(ctx, 1);
  assert.ok(alpha.length && alpha.every(value => value <= 0.5));
  r.frame(100);
  assert.equal(r.frames.size, 0);
  r.update(3, { reduceMotion: true, selected: '2', path: ['1', '2'] });
  alpha.length = 0;
  r.props.get('onRenderFramePost')(ctx, 1);
  assert.equal(alpha.length, 0);
  assert.equal(r.frames.size, 0);
});
