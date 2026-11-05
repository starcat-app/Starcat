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
    ResizeObserver: class { observe() {} disconnect() {} }
  });
  const update = (sequence, extra = {}) => window.followGraph.update({
    session: 'test', root: '1', sequence, revision: sequence,
    ...(sequence === 1 ? { reduceMotion: reduced } : {}), ...extra
  });
  const data = count => ({
    nodes: Array.from({ length: count }, (_, i) => ({
      id: String(i + 1), login: `user${i + 1}`, name: `User ${i + 1}`,
      avatar: `https://avatars.githubusercontent.com/u/${i + 1}`
    })),
    links: Array.from({ length: count - 1 }, (_, i) => ({ source: '1', target: String(i + 2) }))
  });
  return { props, calls, messages, images, timers, frames, container, document, window, update, data, canvasContext,
    frame(ms = 34) { clock += ms; const pending = [...frames.values()]; frames.clear(); pending.forEach(fn => fn(clock)); },
    tick() { const pending = [...timers.values()]; timers.clear(); pending.forEach(fn => fn()); } };
}

test('2D viewport survives batches; gestures stop auto-fit and stale batches are ignored', () => {
  const r = renderer();
  r.update(1, r.data(3));
  r.props.get('onEngineTick')();
  assert.ok(r.calls.some(([name]) => name === 'zoomToFit'));
  const original = r.props.get('graphData').nodes[1];
  original.x = 200;
  r.container.listeners.get('wheel')();
  r.calls.length = 0;
  r.update(2, r.data(4));
  assert.equal(r.props.get('graphData').nodes[1], original);
  assert.equal(original.x, 200);
  assert.ok(!r.calls.some(([name]) => name === 'zoomToFit'));
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

test('avatar hit areas, directed path highlight and image redraw survive settled simulation', () => {
  const r = renderer();
  r.update(1, { ...r.data(3), selected: '2', path: ['1', '2'] });
  const { nodes, links } = r.props.get('graphData');
  assert.equal(r.props.get('linkDirectionalArrowLength')(links[0]), 6);
  assert.equal(r.props.get('linkDirectionalArrowLength')({ source: '2', target: '1' }), 6);
  r.props.get('nodeCanvasObject')(nodes[1], r.canvasContext, 1);
  assert.equal(r.images.length, 1);
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
  assert.equal(color(path), '#007aff');
  assert.notEqual(color(incoming), color(path));
  assert.equal(arrow(incoming), 6);
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
  assert.equal(r.props.get('linkDirectionalArrowLength')(links[0]), 6);
  assert.ok(r.props.get('linkWidth')(links[0]) > r.props.get('linkWidth')(links[1]));
  r.update(2, { selected: '2', path: ['1', '2'] });
  r.props.get('onNodeClick')(nodes[1]);
  assert.equal(r.props.get('linkColor')(links[0]), '#007aff');
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
  assert.equal(r.props.get('linkColor')(links[0]), '#007aff');
  assert.equal(r.props.get('linkColor')(links[1]), '#007aff');
  assert.notEqual(r.props.get('linkColor')(links[2]), '#007aff');
  assert.equal(r.props.get('linkDirectionalArrowLength')(links[0]), 6);
  assert.equal(r.frames.size, 1);
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
  assert.ok(!r.calls.some(([name]) => name === 'lineTo'));
  assert.equal(r.props.get('linkColor')(links[0]), '#007aff');
  r.update(4, { reduceMotion: false, active: true });
  assert.equal(r.frames.size, 1);
  r.document.hidden = true;
  r.document.listeners.get('visibilitychange')();
  assert.equal(r.frames.size, 0);
  r.document.hidden = false;
  r.document.listeners.get('visibilitychange')();
  r.props.get('onBackgroundClick')();
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
  assert.equal(r.images.length, 4);
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
  r.images[0].onload();
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
