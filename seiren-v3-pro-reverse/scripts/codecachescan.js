// Scan V8 Code Cache (embeds JS source) + harvest every apps.razer.com asset URL
// referenced anywhere in the Electron caches.
const fs = require('fs');
const path = require('path');

const BASE = 'C:\\Users\\yuhuan\\AppData\\Local\\Razer\\RazerAppEngine\\User Data\\Default';
const OUT = 'C:\\Users\\yuhuan\\AppData\\Local\\Temp\\claude\\C--Users-yuhuan\\8a3d7b2e-98b7-4904-b4d2-ce2ebbe5a086\\scratchpad\\cache_out';
fs.mkdirSync(OUT, { recursive: true });

const KEYWORDS = [
  'sendFeatureReport', 'getFeatureReport', 'sendFeatureReportInBatch',
  'transactionId', 'commandClass', 'dataSend',
  'equalizer', 'noiseGate', 'voiceGate', 'compressor', 'limiter',
  'micGain', 'sidetone', 'Seiren', 'protocol25', 'razerReport',
];

function walk(dir) {
  const out = [];
  let ents;
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return out; }
  for (const e of ents) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(p));
    else out.push(p);
  }
  return out;
}

// ---- 1. Code Cache keyword scan ----
console.log('=== V8 Code Cache scan ===');
const ccFiles = walk(path.join(BASE, 'Code Cache'));
console.log(`${ccFiles.length} files`);
for (const f of ccFiles) {
  let buf;
  try { buf = fs.readFileSync(f); } catch (e) { continue; }
  const text = buf.toString('latin1');
  const found = KEYWORDS.filter(k => text.includes(k));
  if (found.length) {
    console.log(`  ${path.basename(f)}  ${(buf.length / 1024).toFixed(0)} KB  -> ${found.join(', ')}`);
    fs.writeFileSync(path.join(OUT, `codecache_${path.basename(f)}.txt`), buf);
  }
}

// ---- 2. harvest asset URLs ----
console.log('\n=== apps.razer.com asset URLs found in caches ===');
const urlRe = /https:\/\/[a-zA-Z0-9._-]*razer\.com[^\s"'<>\\)\]}]{0,200}/g;
const urls = new Set();
const allFiles = [...walk(path.join(BASE, 'Cache')), ...ccFiles];
for (const f of allFiles) {
  let buf;
  try { buf = fs.readFileSync(f); } catch (e) { continue; }
  const text = buf.toString('latin1');
  let m;
  while ((m = urlRe.exec(text)) !== null) urls.add(m[0]);
}
const js = [...urls].filter(u => /\.(js|json|mjs)(\?|$)/.test(u)).sort();
const other = [...urls].filter(u => !/\.(js|json|mjs|png|jpg|jpeg|svg|webp|woff2?|css|ico|mp4)(\?|$)/.test(u)).sort();
console.log(`\n-- JS/JSON assets (${js.length}) --`);
js.slice(0, 80).forEach(u => console.log('  ' + u));
console.log(`\n-- other endpoints (${other.length}, first 60) --`);
other.slice(0, 60).forEach(u => console.log('  ' + u));

fs.writeFileSync(path.join(OUT, 'urls.txt'), [...urls].sort().join('\n'));
console.log(`\nall ${urls.size} URLs -> ${path.join(OUT, 'urls.txt')}`);
