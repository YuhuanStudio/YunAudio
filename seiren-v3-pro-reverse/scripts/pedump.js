// Minimal PE parser: list exports/imports and pull strings out of a DLL.
const fs = require('fs');

const file = process.argv[2];
const buf = fs.readFileSync(file);
console.log(`file: ${file}\nsize: ${buf.length} bytes\n`);

const peOff = buf.readUInt32LE(0x3c);
if (buf.toString('latin1', peOff, peOff + 4) !== 'PE\0\0') { console.log('not a PE'); process.exit(1); }
const machine = buf.readUInt16LE(peOff + 4);
const numSections = buf.readUInt16LE(peOff + 6);
const optSize = buf.readUInt16LE(peOff + 20);
const optOff = peOff + 24;
const magic = buf.readUInt16LE(optOff);
const pe32plus = magic === 0x20b;
console.log(`machine: 0x${machine.toString(16)} (${machine === 0x8664 ? 'x64' : machine === 0x14c ? 'x86' : '?'})  ${pe32plus ? 'PE32+' : 'PE32'}  sections: ${numSections}`);

const dataDirOff = optOff + (pe32plus ? 112 : 96);
const exportRva = buf.readUInt32LE(dataDirOff);
const importRva = buf.readUInt32LE(dataDirOff + 8);

// section table -> RVA to file offset
const secOff = optOff + optSize;
const sections = [];
for (let i = 0; i < numSections; i++) {
  const o = secOff + i * 40;
  sections.push({
    name: buf.toString('latin1', o, o + 8).replace(/\0+$/, ''),
    vsize: buf.readUInt32LE(o + 8),
    vaddr: buf.readUInt32LE(o + 12),
    rawSize: buf.readUInt32LE(o + 16),
    rawPtr: buf.readUInt32LE(o + 20),
  });
}
console.log('\nsections:');
sections.forEach(s => console.log(`  ${s.name.padEnd(9)} vaddr=0x${s.vaddr.toString(16).padStart(6,'0')} vsize=${s.vsize} raw=${s.rawSize}`));

function rva2off(rva) {
  for (const s of sections) {
    if (rva >= s.vaddr && rva < s.vaddr + Math.max(s.vsize, s.rawSize)) return s.rawPtr + (rva - s.vaddr);
  }
  return -1;
}
function cstr(off) {
  let e = off;
  while (e < buf.length && buf[e] !== 0) e++;
  return buf.toString('latin1', off, e);
}

// ---- exports ----
console.log('\n=== EXPORTS ===');
if (exportRva) {
  const eo = rva2off(exportRva);
  const nNames = buf.readUInt32LE(eo + 24);
  const addrNames = buf.readUInt32LE(eo + 32);
  const no = rva2off(addrNames);
  const names = [];
  for (let i = 0; i < nNames; i++) names.push(cstr(rva2off(buf.readUInt32LE(no + i * 4))));
  console.log(`${nNames} exported names:`);
  names.sort().forEach(n => console.log('  ' + n));
} else console.log('  (none)');

// ---- imports ----
console.log('\n=== IMPORTED DLLs ===');
if (importRva) {
  let io = rva2off(importRva);
  const dlls = [];
  for (let i = 0; i < 200; i++) {
    const o = io + i * 20;
    const nameRva = buf.readUInt32LE(o + 12);
    if (nameRva === 0) break;
    dlls.push(cstr(rva2off(nameRva)));
  }
  dlls.forEach(d => console.log('  ' + d));
}

// ---- strings ----
const MIN = 5;
const strings = new Set();
let cur = '';
for (let i = 0; i < buf.length; i++) {
  const c = buf[i];
  if (c >= 0x20 && c < 0x7f) { cur += String.fromCharCode(c); }
  else { if (cur.length >= MIN) strings.add(cur); cur = ''; }
}
if (cur.length >= MIN) strings.add(cur);
// UTF-16LE
cur = '';
for (let i = 0; i + 1 < buf.length; i += 2) {
  const c = buf.readUInt16LE(i);
  if (c >= 0x20 && c < 0x7f) { cur += String.fromCharCode(c); }
  else { if (cur.length >= MIN) strings.add(cur); cur = ''; }
}

const all = [...strings];
console.log(`\n=== STRINGS: ${all.length} total ===`);
const KW = /eq|gain|mute|volume|noise|gate|compress|limit|effect|light|led|chroma|rgb|bright|sample|rate|monitor|sidetone|mic|preset|filter|band|freq|threshold|ratio|attack|release|clarity|normal|ambient|hid|report|command|firmware|protocol/i;
const interesting = all.filter(s => KW.test(s) && s.length < 120).sort();
console.log(`--- ${interesting.length} matching device-feature keywords ---`);
interesting.forEach(s => console.log('  ' + s));

fs.writeFileSync(file + '.strings.txt', all.sort().join('\n'));
console.log(`\nall strings -> ${file}.strings.txt`);
