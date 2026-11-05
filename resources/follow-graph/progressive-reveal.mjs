// Presentation-only queue: no requests, cache mutation or synthetic relationships.
// Time is injected so ordering, suspension and Reduce Motion are deterministic in tests.

// Reuse ICU collation state across all sorts instead of rebuilding it per comparison.
// Numeric GitHub IDs retain the same stable traversal ordering as the native model.
export const compareIDs = new Intl.Collator('en', { numeric: true }).compare;

/** Reveal parents before children and retain existing nodes across incoming data batches. */
export class ProgressiveReveal {
  visible = new Set();
  births = new Map();
  parents = new Map();
  pending = [];
  nextAt = 0;
  burst = 0;
  pausedAt = null;
  root = null;

  /** Reconcile the latest full snapshot without restarting already-visible avatars. */
  sync(nodes, links, root, now, reduced) {
    if (root !== this.root) {
      this.clear();
      this.root = root;
    }
    for (const id of this.visible) {
      if (!nodes.has(id)) { this.visible.delete(id); this.births.delete(id); }
    }
    const outgoing = new Map();
    for (const link of links.values()) {
      const source = typeof link.source === 'object' ? link.source.id : link.source;
      const target = typeof link.target === 'object' ? link.target.id : link.target;
      if (!outgoing.has(source)) outgoing.set(source, []);
      outgoing.get(source).push(target);
    }
    for (const targets of outgoing.values()) targets.sort(compareIDs);
    this.parents = new Map([[root, null]]);
    const ordered = nodes.has(root) ? [root] : [];
    for (let i = 0; i < ordered.length; i++) {
      for (const id of outgoing.get(ordered[i]) || []) {
        if (nodes.has(id) && !this.parents.has(id)) {
          this.parents.set(id, ordered[i]);
          ordered.push(id);
        }
      }
    }
    ordered.push(...[...nodes.keys()].filter(id => !this.parents.has(id)).sort(compareIDs));
    if (this.pending.length === 0) { this.nextAt = now + 45; this.burst = 0; }
    this.pending = ordered.filter(id => !this.visible.has(id));
    if (reduced) this.finish();
    else if (!this.visible.size && nodes.has(root)) this.show([root], now);
  }

  /** Gradually accelerate large graphs, while the first few avatars remain visibly separate. */
  advance(now) {
    if (this.pausedAt !== null) return false;
    this.prune(now);
    let changed = false, batch = 0;
    while (this.pending.length && now >= this.nextAt && batch++ < 60) {
      const id = this.pending.shift();
      this.visible.add(id);
      this.births.set(id, now);
      changed = true;
      this.nextAt += Math.max(0.75, 45 / (1 + ++this.burst / 30));
    }
    return changed;
  }

  /** Search/selection may immediately reveal a real path to a still-queued node. */
  show(ids, now) {
    for (const id of ids) {
      if (!this.visible.has(id)) { this.visible.add(id); this.births.set(id, now); }
    }
    this.pending = this.pending.filter(id => !this.visible.has(id));
  }

  finish() {
    for (const id of this.pending) this.visible.add(id);
    this.pending = [];
    this.births.clear();
  }

  progress(id, now) {
    const born = this.births.get(id);
    return born === undefined ? 1 : Math.max(0, Math.min(1, (now - born) / 360));
  }

  prune(now) {
    for (const [id, born] of this.births) if (now - born >= 360) this.births.delete(id);
  }

  /** Background time does not consume the queue or make pending avatars all arrive at once. */
  setRunning(running, now) {
    if (!running && this.pausedAt === null) this.pausedAt = now;
    else if (running && this.pausedAt !== null) {
      const elapsed = now - this.pausedAt;
      this.nextAt += elapsed;
      for (const [id, born] of this.births) this.births.set(id, born + elapsed);
      this.pausedAt = null;
    }
  }

  get animating() { return this.pending.length > 0 || this.births.size > 0; }

  clear() {
    this.visible.clear();
    this.births.clear();
    this.parents.clear();
    this.pending = [];
    this.pausedAt = null;
  }
}
