import { launch } from './harness.mjs';
import fs from 'node:fs';
const probe = fs.readFileSync(new URL('./perf-probe.js', import.meta.url), 'utf8');
const games = process.argv.slice(2).map(s => { const [f, q] = s.split('?'); return { f, q: q ? '?' + q : '' }; });
const med = a => { const s = [...a].sort((x, y) => x - y); return s.length ? s[s.length >> 1] : 0; };
const p95 = a => { const s = [...a].sort((x, y) => x - y); return s.length ? s[Math.min(s.length - 1, Math.floor(s.length * .95))] : 0; };
const rows = [];
for (const { f, q } of games) {
  const name = f.split('/').pop().replace('.html', '') + (q ? ' ' + q : '');
  try {
    const g = await launch('/home/user/internal-hybrid-builds/' + f, { w: 1920, h: 1080, query: q, initScript: probe });
    await g.wait(1500);
    const clicked = await g.eval(() => { const b = document.getElementById('cta'); if (b) { b.click(); return true; } return false; });
    await g.wait(2500); await g.hold('w', 1200); await g.press(' ', 120); await g.hold('d', 600); await g.wait(800);
    let frames = []; for (let i = 0; i < 12 && frames.length < 20; i++) { await g.wait(1500); frames = await g.eval(() => window.__ibperf.hist.map(h => [h.calls, h.tris, h.js, h.instDraws])); }
    const st = await g.eval(() => ({ w: __ibperf.w, h: __ibperf.h, tex: __ibperf.texBytes, progs: __ibperf.progs, total: __ibperf.frames, heap: performance.memory ? performance.memory.usedJSHeapSize : 0 }));
    rows.push({ name, n: frames.length, calls: med(frames.map(x => x[0])), callsP95: p95(frames.map(x => x[0])), tris: med(frames.map(x => x[1])), inst: med(frames.map(x => x[3])),
      js: med(frames.map(x => x[2])), jsP95: p95(frames.map(x => x[2])), buf: st.w + 'x' + st.h, texMB: Math.round(st.tex / 1048576), progs: st.progs, heapMB: Math.round(st.heap / 1048576), errors: g.errors.length });
    await g.close();
  } catch (e) { rows.push({ name, error: String(e).slice(0, 120) }); }
}
console.log(JSON.stringify(rows, null, 1));
