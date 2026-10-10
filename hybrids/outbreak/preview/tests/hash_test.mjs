// Proves that the wasmoon build (Lua 5.4 -> WebAssembly, in headless Chromium) computes the SAME state hash as native lua5.4 and native luajit for the same
// seeds and days: the browser preview runs the real sim, not an approximation. Compares the byte-exact output of tests/hash_check.lua (4 colonies x N days,
// default AI policy, 1-minute steps) with __preview.hashRuns(N) running inside wasmoon.
//   node preview/tests/hash_test.mjs [days]        default 30 (native about 12 s per runtime, wasm about a minute or two)
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { launch, openPreview, ROOT } from './lib.mjs';

const days = Number(process.argv[2]) || 30;
const script = path.join(ROOT, 'tests', 'hash_check.lua');
const t0 = Date.now();
const native = {};
for (const rt of ['lua5.4', 'luajit']) {
  const s = Date.now();
  native[rt] = execFileSync(rt, [script, String(days)], { encoding: 'utf8', maxBuffer: 1 << 24 });
  console.log(`${rt}: ${native[rt].split('\n').filter(l => l.startsWith('HASH')).length} runs in ${((Date.now() - s) / 1000).toFixed(1)} s`);
}
let ok = true;
if (native['lua5.4'] !== native['luajit']) { console.error('FAIL: lua5.4 and luajit differ'); ok = false; }

const env = await launch();
let wasm;
try {
  const p = await openPreview(env, { query: 'auto=0' });
  const s = Date.now();
  wasm = await p.page.evaluate(d => window.__preview.hashRuns(d), days);
  console.log(`wasmoon: ${wasm.split('\n').filter(l => l.startsWith('HASH')).length} runs in ${((Date.now() - s) / 1000).toFixed(1)} s`);
  if (p.errors.length) { console.error('FAIL: page errors', p.errors); ok = false; }
} finally { await env.close(); }

if (wasm !== native['lua5.4']) {
  ok = false;
  console.error('FAIL: wasmoon output differs from native lua5.4');
  const a = native['lua5.4'].split('\n'), b = wasm.split('\n');
  for (let i = 0; i < Math.max(a.length, b.length); i++) if (a[i] !== b[i]) { console.error(' native: ' + a[i]); console.error(' wasm  : ' + b[i]); }
}
for (const l of native['lua5.4'].split('\n').filter(l => l.startsWith('HASH'))) console.log('  ' + l.replace(/ save_bytes=\d+ reload_equal=\w+/, ''));
console.log(ok ? `OK: wasmoon == lua5.4 == luajit byte-for-byte (${days} days x 4 colonies, ${((Date.now() - t0) / 1000).toFixed(0)} s total)` : 'HASH TEST FAILED');
process.exit(ok ? 0 : 1);
