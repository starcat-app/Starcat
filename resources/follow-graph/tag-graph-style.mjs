// The drawing scales stay readable when tag populations differ by orders of magnitude.
// Raw counts stay in the native inspector, and also set these scales without normalization.
export function nodeRadius(count) {
  return 10 + 15 * Math.log1p(count) / (Math.log1p(count) + 4);
}

export function edgeWidth(count) {
  return 0.75 + 4 * Math.log1p(count) / (Math.log1p(count) + 3);
}
