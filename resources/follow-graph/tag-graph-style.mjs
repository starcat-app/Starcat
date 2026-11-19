// The drawing scales stay readable when tag populations differ by orders of magnitude.
// Raw counts stay in the native inspector, and also set these scales without normalization.
export function nodeRadius(count) {
  return 10 + 15 * Math.log1p(count) / (Math.log1p(count) + 4);
}

// 同一边权同时控制线宽和不透明度，筛掉弱边后无需重新标定。
function edgeStrength(count) {
  const weight = Math.log1p(count);
  return weight / (weight + 3);
}

export function edgeWidth(count) {
  return 0.75 + 4 * edgeStrength(count);
}

/** 高亮以色相标识关系，并保留弱边和强边之间的明暗差异。 */
export function edgeColor(count, dark, highlighted) {
  const rgb = highlighted
    ? (dark ? '131,186,255' : '39,106,194')
    : (dark ? '160,168,184' : '84,95,113');
  const alpha = (highlighted ? 0.68 : 0.34) + 0.32 * edgeStrength(count);
  return `rgba(${rgb},${alpha})`;
}
