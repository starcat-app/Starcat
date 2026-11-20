// Spatial layout for the tag view. Repositories stay in the shared Canvas graph;
// only the tag groups are packed, once per membership snapshot.
import { forceCollide, forceSimulation, forceX, forceY } from 'd3-force-3d';
import { compareIDs } from './progressive-reveal.mjs';

const goldenAngle = Math.PI * (3 - Math.sqrt(5));
const repoSpacing = 11;
const tagClearance = 39;
const previewCount = 4;
const smallGroupLimit = 12;

/** Choose a real associated tag as each repository's position. The graph keeps
 * all its memberships. Assign single-tag repos first, then balance shared repos
 * between their eligible tags so the layout doesn't bury them in one group.
 */
function membershipGroups(nodes, links, anchorID) {
  const groups = new Map(), tagsByRepo = new Map();
  for (const node of nodes.values()) {
    if (node.kind === 'tag') groups.set(node.id, { id: node.id, repos: [], relatedToAnchor: false });
  }
  for (const link of links.values()) {
    const tagID = typeof link.source === 'string' ? link.source : link.source.id;
    const repoID = typeof link.target === 'string' ? link.target : link.target.id;
    const group = groups.get(tagID);
    if (!group) continue;
    if (repoID === anchorID) {
      group.relatedToAnchor = true;
    } else {
      if (!tagsByRepo.has(repoID)) tagsByRepo.set(repoID, []);
      tagsByRepo.get(repoID).push(group);
    }
  }
  const repos = [...tagsByRepo].sort(([a, tagsA], [b, tagsB]) =>
    tagsA.length - tagsB.length || compareIDs(a, b));
  for (const [id, candidates] of repos) {
    const group = candidates.reduce((best, candidate) =>
      candidate.repos.length < best.repos.length ||
        (candidate.repos.length === best.repos.length && compareIDs(candidate.id, best.id) < 0) ? candidate : best);
    group.repos.push(id);
  }
  return [...groups.values()];
}

/** Give each tag its own space around the opening node. Only these groups run
 * collision checks. Repository positions and the camera are ready before the
 * first paint, so revealing another repository never reheats the whole graph.
 */
export function layoutTagGraph(nodes, links, anchorID, width, height) {
  const groups = membershipGroups(nodes, links, anchorID);
  const center = groups.find(group => group.id === anchorID) ??
    { id: anchorID, repos: [], relatedToAnchor: true };
  const outer = groups.filter(group => group !== center).sort((a, b) =>
    Number(b.relatedToAnchor) - Number(a.relatedToAnchor) ||
    b.repos.length - a.repos.length || compareIDs(a.id, b.id));
  const repoDistance = index => Math.hypot(tagClearance, repoSpacing * Math.sqrt(index));
  for (const group of [center, ...outer]) {
    group.extent = group.repos.length ? repoDistance(group.repos.length - 1) + 9 : 31;
  }
  center.extent = Math.max(center.extent, 68);
  Object.assign(center, { x: 0, y: 0, fx: 0, fy: 0, preferredX: 0, preferredY: 0 });

  const aspect = Math.sqrt(Math.max(1, width / Math.max(1, height)));
  const pitch = Math.sqrt(outer.reduce((sum, group) => sum + (group.extent + 12) ** 2, 0) /
    Math.max(1, outer.length));
  outer.forEach((group, index) => {
    const angle = index * goldenAngle - Math.PI / 2;
    const distance = center.extent + pitch * Math.sqrt(0.6 + index);
    group.x = group.preferredX = Math.cos(angle) * distance * aspect;
    group.y = group.preferredY = Math.sin(angle) * distance / aspect;
  });
  forceSimulation([center, ...outer], 2).stop()
    .force('collide', forceCollide(group => group.extent + 14).iterations(3))
    .force('horizontal', forceX(group => group.preferredX).strength(0.035))
    .force('vertical', forceY(group => group.preferredY).strength(0.035))
    .tick(96);

  const positions = new Map();
  let boundX = 0, boundY = 0;
  for (const [groupIndex, group] of [center, ...outer].entries()) {
    if (nodes.has(group.id)) positions.set(group.id, { x: group.x, y: group.y, groupID: group.id });
    group.repos.forEach((id, index) => {
      const angle = (index + groupIndex) * goldenAngle;
      const distance = repoDistance(index);
      positions.set(id, {
        x: group.x + Math.cos(angle) * distance,
        y: group.y + Math.sin(angle) * distance,
        groupID: group.id,
        // Small groups already have room to show each repository's identity.
        preview: group.repos.length <= smallGroupLimit || index < previewCount
      });
    });
    // Fit all the clusters against the pinned center, including space for
    // captions and the controls at the top of the overlay.
    boundX = Math.max(boundX, Math.abs(group.x) + group.extent);
    boundY = Math.max(boundY, Math.abs(group.y) + group.extent);
  }
  const zoom = Math.max(0.05, Math.min(1, width / (2 * (boundX + 34)), height / (2 * (boundY + 40))));
  return { positions, zoom };
}
