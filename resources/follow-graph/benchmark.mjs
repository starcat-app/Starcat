// CPU-only synthetic benchmark for the real reveal queue. No browser, GitHub data
// or FPS claims: warm twice, then report seven-run medians on fixed graph shapes.
import { performance } from 'node:perf_hooks';
import { ProgressiveReveal } from './progressive-reveal.mjs';

/** Include a large hub plus shorter alternative paths to exercise numeric sorting/BFS. */
function fixture(count) {
  const nodes = new Map(Array.from({ length: count }, (_, i) => [String(i + 1), { id: String(i + 1) }]));
  const links = new Map();
  for (let i = 2; i <= count; i++) {
    for (const source of ['1', String(Math.max(1, Math.floor(i / 2))), String(Math.max(1, i - 7))]) {
      links.set(`${source}:${i}`, { source, target: String(i) });
    }
  }
  return { nodes, links };
}

const median = values => values.sort((a, b) => a - b)[Math.floor(values.length / 2)];
for (const count of [1000, 5000, 10000]) {
  const { nodes, links } = fixture(count), samples = [];
  for (let run = 0; run < 9; run++) {
    const queue = new ProgressiveReveal(), start = performance.now();
    queue.sync(nodes, links, '1', 0, false);
    const sync = performance.now() - start, advanceStart = performance.now();
    let time = 0;
    while (queue.animating && time < 20000) { time += 34; queue.advance(time); }
    if (queue.visible.size !== count || queue.animating) throw new Error('Reveal did not finish');
    if (run > 1) samples.push({ sync, advance: performance.now() - advanceStart });
  }
  console.log(JSON.stringify({
    count, edges: links.size,
    syncMedian: median(samples.map(sample => sample.sync)),
    advanceMedian: median(samples.map(sample => sample.advance))
  }));
}
