import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

// Keep the original asset catalog intact. Every approved replacement has a
// versioned semantic name and its own source image, rather than an atlas crop.
const root = process.cwd();
const sourceRoot = path.join(root, 'DesignAssets/SculptedViolet');
const catalog = path.join(root, 'OneWay/Assets.xcassets');
let count = 0;
for (const source of fs.readdirSync(sourceRoot).filter(f => f.endsWith('.png')).sort()) {
  const name = 'OneWaySculpted' + path.basename(source, '.png');
  const folder = path.join(catalog, name + '.imageset');
  fs.mkdirSync(folder, { recursive: true });
  const images = [1, 2, 3].map(scale => {
    const filename = name + (scale === 1 ? '' : '@' + scale + 'x') + '.png';
    execFileSync('sips', ['-z', String(96 * scale), String(96 * scale), path.join(sourceRoot, source), '--out', path.join(folder, filename)], { stdio: 'pipe' });
    return { filename, idiom: 'universal', scale: scale + 'x' };
  });
  fs.writeFileSync(path.join(folder, 'Contents.json'), JSON.stringify({ images, info: { author: 'xcode', version: 1 } }, null, 2) + '\n');
  count++;
}
console.log(`Installed ${count} individual Sculpted Violet image sets at 1x, 2x, and 3x.`);
