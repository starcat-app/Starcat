import assert from 'node:assert/strict';
import test from 'node:test';
import { edgeColor, edgeWidth, nodeRadius } from './tag-graph-style.mjs';

test('unused tags are visible and larger counts draw bigger nodes and thicker lines', () => {
  assert.ok(nodeRadius(0) >= 10);
  for (const measurement of [edgeWidth, nodeRadius]) {
    const counts = [1, 2, 10, 100, 10000];
    const sizes = counts.map(measurement);
    assert.ok(sizes.every((size, index) => index === 0 || size > sizes[index - 1]));
  }
});

test('edge opacity preserves weight order in both themes, including highlighted edges', () => {
  const alpha = color => Number(color.slice(color.lastIndexOf(',') + 1, -1));
  for (const dark of [false, true]) {
    for (const highlighted of [false, true]) {
      const values = [1, 2, 100, 10000].map(count => alpha(edgeColor(count, dark, highlighted)));
      assert.ok(values[0] > 0 && values.at(-1) <= 1);
      assert.ok(values.every((value, i) => !i || value > values[i - 1]));
    }
    assert.ok(alpha(edgeColor(1, dark, true)) > alpha(edgeColor(10000, dark, false)));
  }
});
