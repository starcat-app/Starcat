import assert from 'node:assert/strict';
import test from 'node:test';
import { edgeWidth, nodeRadius } from './tag-graph-style.mjs';

test('unused tags are visible and larger counts draw bigger nodes and thicker lines', () => {
  assert.ok(nodeRadius(0) >= 10);
  for (const measurement of [edgeWidth, nodeRadius]) {
    const counts = [1, 2, 10, 100, 10000];
    const sizes = counts.map(measurement);
    assert.ok(sizes.every((size, index) => index === 0 || size > sizes[index - 1]));
  }
});
