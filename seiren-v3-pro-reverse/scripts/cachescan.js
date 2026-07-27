// Scan the RazerAppEngine Chromium HTTP cache, decompress every entry we can,
// and report which ones contain device-control logic.
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const CACHE = 'C:\\Users\\yuhuan\\AppData\\Local\\Razer\\RazerAppEngine\\User Data\\Default\\Cache\\Cache_Data';
const OUT = 'C:\\Users\\yuhuan\\AppData\\Local\\Temp\\claude\\C--Users-yuhuan\\8a3d7b2e-98b7-4904-b4d2-ce2ebbe5a086\\scratchpad\\cache_out';
fs.mkdirSync(OUT, { recursive: true });

const KEYWORDS = [
  'sendFeatureReport', 'getFeatureReport', 'sendFeatureReportInBatch',
  'equalizer', 'Equalizer', 'EQUALIZER',
  'noiseGate', 'NoiseGate', 'noise_gate', 'voiceGate',
  'compressor', 'Compressor', 'limiter', 'Limiter',
  'seiren', 'Seiren', 'SEIREN',
  'commandClass', 'command_class', 'transactionId', 'transaction_id',
  'micGain', 'gainControl', 'sidetone', 'monitoring',
];

// try every decoding we can and return the first that yields mostly-text output
function tryDecode(buf) {
  const attempts = [
    ['raw', b => b],
    ['brotli', b => zlib.brotliDecompressSync(b)],
    ['gzip', b => zlib.gunzipSync(b)],
    ['deflate', b => zlib.inflateSync(b)],
    ['deflateRaw', b => zlib.inflateRawSync(b)],
  ];
  const results = [];
  for (const [name, fn] of attempts) {
    try {
      const out = fn(buf);
      if (out && out.length > 64) results.push([name, out]);
    } catch (e) { /* not this encoding */ }
  }
  return results;
}

// Chromium sometimes prefixes the body; retry from a few offsets to find a valid stream
function tryDecodeWithOffsets(buf) {
  let all = tryDecode(buf);
  if (all.length === 0) {
    for (const off of [8, 12, 16, 20, 24, 32, 48, 64, 128, 256]) {
      if (off >= buf.length) break;
      const r = tryDecode(buf.subarray(off));
      if (r.length) { all = r.map(([n, b]) => [`${n}+${off}`, b]); break; }
    }
  }
  return all;
}

const files = fs.readdirSync(CACHE).filter(f => f.startsWith('f_') || f.startsWith('data_'));
console.log(`scanning ${files.length} cache files...`);

const hits = [];
let decoded = 0;

for (const name of files) {
  const full = path.join(CACHE, name);
  let buf;
  try { buf = fs.readFileSync(full); } catch (e) { continue; }
  if (buf.length < 64) continue;

  for (const [enc, out] of tryDecodeWithOffsets(buf)) {
    const text = out.toString('latin1');
    const found = KEYWORDS.filter(k => text.includes(k));
    if (found.length === 0) continue;
    decoded++;
    const dest = path.join(OUT, `${name}.${enc}.txt`);
    fs.writeFileSync(dest, out);
    hits.push({ name, enc, size: out.length, found });
    break; // first successful decode with hits is enough
  }
}

console.log(`\n=== ${hits.length} cache entries contain device-control keywords ===`);
hits.sort((a, b) => b.found.length - a.found.length);
for (const h of hits) {
  console.log(`${h.name}  [${h.enc}]  ${(h.size / 1024).toFixed(0)} KB`);
  console.log(`    ${h.found.join(', ')}`);
}
console.log(`\nwrote decoded files to ${OUT}`);
