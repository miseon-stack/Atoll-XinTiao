// Deterministic macOS asset packaging; no image generation or visual redesign.
// Run on macOS: node scripts/update-brand-icons.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = path.join(root, '.github/assets/work-tempo-icon.png');
const expected = 'e0e411fd2c63e286465c64668428744ef641200715de5a8cb9393a2ca0e41aaf';
if (createHash('sha256').update(fs.readFileSync(source)).digest('hex') !== expected) {
  throw new Error('The source is not the approved Work Tempo icon #5. Confirm new artwork before changing this check.');
}
const assets = path.join(root, 'DynamicIsland/Assets.xcassets');
let count = 0;
for (const name of fs.readdirSync(assets).filter(name => /^AppIcon.*\.appiconset$/.test(name))) {
  const directory = path.join(assets, name);
  const contents = JSON.parse(fs.readFileSync(path.join(directory, 'Contents.json'), 'utf8'));
  for (const item of contents.images) {
    if (!item.filename) continue;
    const pixels = Number(item.size.split('x')[0]) * Number(item.scale.replace('x', ''));
    execFileSync('/usr/bin/sips', ['--resampleHeightWidth', String(pixels), String(pixels), source, '--out', path.join(directory, item.filename)], {stdio: 'ignore'});
    count++;
  }
}
for (const name of ['logo.imageset', 'logo2.imageset']) {
  const directory = path.join(assets, name);
  const contents = JSON.parse(fs.readFileSync(path.join(directory, 'Contents.json'), 'utf8'));
  for (const item of contents.images) {
    if (item.filename) { fs.copyFileSync(source, path.join(directory, item.filename)); count++; }
  }
}
// Keep legacy source links usable while the README uses the new canonical path.
for (const pixels of [18, 36]) {
  execFileSync('/usr/bin/sips', ['--resampleHeightWidth', String(pixels), String(pixels), source, '--out', path.join(assets, 'MenuBarIcon.imageset', `work-tempo-${pixels}.png`)], {stdio: 'ignore'});
  count++;
}
fs.copyFileSync(source, path.join(root, '.github/assets/atoll-logo.png'));
console.log(`Packaged ${count} application icon assets from approved icon #5.`);
