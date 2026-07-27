// Pull printable strings out of the V8 code cache and show context around device keywords.
const fs = require('fs');
const path = require('path');

const OUT = 'C:\\Users\\yuhuan\\AppData\\Local\\Temp\\claude\\C--Users-yuhuan\\8a3d7b2e-98b7-4904-b4d2-ce2ebbe5a086\\scratchpad\\cache_out';
const target = process.argv[2];
const buf = fs.readFileSync(target);
console.log(`file: ${path.basename(target)}  ${(buf.length / 1024 / 1024).toFixed(1)} MB`);

const text = buf.toString('latin1');

// context dump around each search term
const TERMS = process.argv.slice(3);
for (const term of TERMS) {
  console.log(`\n${'='.repeat(70)}\n=== "${term}" ===`);
  let idx = -1, n = 0;
  while ((idx = text.indexOf(term, idx + 1)) !== -1 && n < 6) {
    n++;
    const from = Math.max(0, idx - 400);
    const snippet = text.slice(from, idx + 500).replace(/[^\x20-\x7e\n]/g, '.');
    console.log(`\n--- hit ${n} @ ${idx} ---`);
    console.log(snippet);
  }
  if (n === 0) console.log('  (no hits)');
  else console.log(`\n  total hits: ${(text.split(term).length - 1)}`);
}
