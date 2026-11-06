// Bundle runtime dependencies and collect their upstream LICENSE files.
// The manifest is also the evidence used to register embedded resources in About.
import { build } from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';

const output = '../../Starcat/Resources/FollowGraph';
const result = await build({
  entryPoints: ['entry.js'], bundle: true, minify: true, format: 'iife',
  target: 'safari18', outfile: `${output}/follow-graph.js`, metafile: true,
  legalComments: 'eof'
});
const packages = new Map();
for (const input of Object.keys(result.metafile.inputs)) {
  if (!input.startsWith('node_modules/')) continue;
  const parts = input.split('/');
  const directory = parts[1].startsWith('@') ? parts.slice(0, 3).join('/') : parts.slice(0, 2).join('/');
  if (packages.has(directory)) continue;
  const pkg = JSON.parse(fs.readFileSync(`${directory}/package.json`, 'utf8'));
  const licenseFile = fs.readdirSync(directory).find(name => /^licen[cs]e(\.|$)/i.test(name));
  // bezier-js 6.1.4 ships its MIT declaration in README/source instead of a LICENSE
  // file. Preserve those exact upstream notices, with no invented copyright year.
  const notice = pkg.name === 'bezier-js' && pkg.version === '6.1.4'
    ? 'notices/bezier-js-6.1.4.txt' : null;
  if (!licenseFile && !notice) throw new Error(`Missing upstream LICENSE: ${pkg.name}`);
  const license = fs.readFileSync(licenseFile ? path.join(directory, licenseFile) : notice, 'utf8');
  let repository = typeof pkg.repository === 'object' ? pkg.repository.url : pkg.repository;
  if (/^[\w.-]+\/[\w.-]+$/.test(repository)) repository = `https://github.com/${repository}`;
  packages.set(directory, { name: pkg.name, version: pkg.version, license: pkg.license,
    repository, text: license });
}
const manifest = [...packages.values()].sort((a, b) => a.name.localeCompare(b.name));
fs.writeFileSync(`${output}/follow-graph-licenses.txt`, manifest.map(pkg =>
  `${pkg.name} ${pkg.version}\n${pkg.repository}\n\n${pkg.text}`).join('\n\n--------------------\n\n'));
fs.writeFileSync('licenses.json', `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`Bundled ${manifest.length} runtime packages; all upstream licenses included.`);
