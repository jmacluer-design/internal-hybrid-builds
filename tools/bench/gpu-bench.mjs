// Real-GPU benchmark for the shelf games. Run on a machine WITH a GPU (e.g. the 5090 box). Software-GL sandboxes can't measure this.
//   cd tools/bench && npm install && npx playwright install chromium        (once; skip the 2nd if Chrome is installed: add --chrome)
//   node gpu-bench.mjs                              # all games, desktop 1080p + phone-emulated (4x CPU throttle), vsync on, headed
//   node gpu-bench.mjs --games shatterworld,colossus --seconds 12 --uncapped
// Flags: --share (upload ONLY the GPU name + timings to paste.rs and print a short URL, for when you can't copy the table)   --headless-gpu (no desktop session, e.g. a server: headless Chrome via Vulkan/ANGLE, best effort)   --games a,b   --mode desktop|phone|both   --seconds N   --uncapped (disable vsync/frame cap = headroom)   --chrome (use installed Chrome)   --headless   --software (sandbox self-test only)
// Output: a table on screen + bench-results/<host>-<time>.json. It contains the GPU name and timings only. Do not commit it (it is in .gitignore); paste the table back.
import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import { fileURLToPath } from 'node:url';
const HERE = path.dirname(fileURLToPath(import.meta.url)); const REPO = path.resolve(HERE, '../..');
const arg = (k, d) => { const i = process.argv.indexOf('--' + k); return i < 0 ? d : (process.argv[i + 1] && !process.argv[i + 1].startsWith('--') ? process.argv[i + 1] : true); };
const GAMES = String(arg('games', 'shatterworld,colossus,blockshot,webcraft,souls64,parkcraft')).split(',');
const MODE = arg('mode', 'both'), SECS = +arg('seconds', 10), UNCAPPED = !!arg('uncapped', false), SOFT = !!arg('software', false);
let pw; try { pw = await import('playwright'); } catch (e) { pw = await import(process.env.PLAYWRIGHT_PATH || '/opt/node-tools/node_modules/playwright/index.mjs'); }
const { chromium } = pw;
const THREE_ROOT = [process.env.THREE_DIR, path.join(HERE, 'node_modules/three'), path.join(REPO, 'tools/test/node_modules/three')].find(p => p && fs.existsSync(path.join(p, 'build/three.module.js')));
if (!THREE_ROOT) { console.error('three not found: run `npm install` in tools/bench'); process.exit(1); }
const PROBE = fs.readFileSync(path.join(REPO, 'tools/test/perf-probe.js'), 'utf8'); // borrowed: GL draw-call/triangle probe (global __ibperf)
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.png': 'image/png' };
const srv = http.createServer((q, r) => { const u = decodeURIComponent(q.url.split('?')[0]); if (u.startsWith('/api/')) { r.writeHead(404, { 'content-type': 'application/json' }); return r.end('{}'); }
  const f = path.join(REPO, u === '/' ? 'index.html' : u); if (!f.startsWith(REPO) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { r.writeHead(404); return r.end('nf'); }
  r.writeHead(200, { 'content-type': MIME[path.extname(f)] || 'application/octet-stream' }); fs.createReadStream(f).pipe(r); });
await new Promise(r => srv.listen(0, '127.0.0.1', r)); const port = srv.address().port;
const args = SOFT ? ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] : ['--ignore-gpu-blocklist', '--enable-gpu-rasterization'];
if (UNCAPPED) args.push('--disable-gpu-vsync', '--disable-frame-rate-limit');
const HGPU = !!arg('headless-gpu', false); if (HGPU) args.push('--use-angle=vulkan', '--enable-features=Vulkan', '--disable-vulkan-surface', '--enable-gpu');
const launchOpts = { headless: SOFT || HGPU || !!arg('headless', false), args }; if (arg('chrome', false)) launchOpts.channel = 'chrome'; else if (SOFT) launchOpts.executablePath = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
async function launchBrowser(opts) {
  try { return await chromium.launch(opts); } catch (e) {
    const msg = String(e.message || e); const head = msg.split('\n').filter(l => l.trim()).slice(0, 14).join('\n');
    console.error('\n=== Chrome failed to launch. First lines of the error: ===\n' + head + '\n');
    if (/is not found at|Executable doesn't exist|distribution/i.test(msg)) console.error('FIX: Chrome is not installed where Playwright looks (/opt/google/chrome/chrome). Install the Google Chrome .deb (see instructions), or leave out --chrome and run `npx playwright install chromium` on a supported OS.');
    else if (/Missing X server|\$DISPLAY|ozone|platform failed to initialize/i.test(msg)) console.error('FIX: no desktop session. Add --headless-gpu (or run this from the machine\'s own desktop).');
    else if (/sandbox|namespace|No usable|Operation not permitted|zygote/i.test(msg) && !opts.args.includes('--no-sandbox')) { console.error('Looks like the Chrome sandbox is blocked (common on new Ubuntu). Retrying once with --no-sandbox (this is a local benchmark of your own pages, so that is fine)...'); return launchBrowser({ ...opts, args: [...opts.args, '--no-sandbox'] }); }
    else if (/crash|SIGTRAP|SIGSEGV|exited|closed/i.test(msg)) console.error('Chrome crashed at start. Try again without --headless-gpu, or with --no-sandbox-always.');
    process.exit(2);
  }
}
if (arg('no-sandbox-always', false)) args.push('--no-sandbox');
const browser = await launchBrowser(launchOpts);
const PROFILES = { desktop: { viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1, isMobile: false, hasTouch: false, cpu: 1 },
  phone: { viewport: { width: 844, height: 390 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true, cpu: 4 } }; // iPhone-class landscape; the GPU cannot be throttled, see notes
const pct = (a, p) => { const s = [...a].sort((x, y) => x - y); return s.length ? s[Math.min(s.length - 1, Math.floor(s.length * p))] : 0; };
const med = a => pct(a, .5); const rows = []; let gpu = '?';
for (const prof of (MODE === 'both' ? ['desktop', 'phone'] : [MODE])) for (const game of GAMES) {
  const P = PROFILES[prof]; const name = `${game} [${prof}]`;
  try {
    const ctx = await browser.newContext({ viewport: P.viewport, deviceScaleFactor: P.deviceScaleFactor, isMobile: P.isMobile, hasTouch: P.hasTouch });
    await ctx.addInitScript(PROBE); const page = await ctx.newPage(); const errs = []; page.on('pageerror', e => errs.push(e.message));
    await page.route(/cdn\.jsdelivr\.net\/npm\/three@0\.169\.0\/(.*)/, route => { const sub = route.request().url().match(/three@0\.169\.0\/(.*)$/)[1].split('?')[0]; const f = path.join(THREE_ROOT, sub);
      fs.existsSync(f) ? route.fulfill({ status: 200, contentType: 'text/javascript', body: fs.readFileSync(f) }) : route.fulfill({ status: 404, body: 'nf' }); });
    if (P.cpu > 1) { const cdp = await ctx.newCDPSession(page); await cdp.send('Emulation.setCPUThrottlingRate', { rate: P.cpu }); }
    await page.goto(`http://127.0.0.1:${port}/games/${game}.html`, { waitUntil: 'load' }); await page.waitForTimeout(2500);
    await page.evaluate(() => { const b = document.getElementById('cta'); if (b) b.click(); }); await page.waitForTimeout(3000);
    await page.evaluate(sec => { window.__bench = { dts: [], done: false }; let last = performance.now(); const end = last + sec * 1000; (function tick(t) { window.__bench.dts.push(t - last); last = t; if (t < end) requestAnimationFrame(tick); else window.__bench.done = true; })(last); }, SECS);
    // light scripted play so the scene is not idle: run, jump, turn
    for (let i = 0; i < SECS * 2; i++) { await page.keyboard.down(['w', 'd', 'w', 'a'][i % 4]); await page.waitForTimeout(250); await page.keyboard.up(['w', 'd', 'w', 'a'][i % 4]); if (i % 4 === 1) await page.keyboard.press(' '); await page.waitForTimeout(250); }
    await page.waitForFunction(() => window.__bench.done, null, { timeout: 60000 }).catch(() => {});
    const r = await page.evaluate(() => { const gl = document.createElement('canvas').getContext('webgl2'); const ext = gl && gl.getExtension('WEBGL_debug_renderer_info');
      const h = (window.__ibperf && window.__ibperf.hist) || []; return { dts: window.__bench.dts.slice(5), gpu: ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : 'unknown', calls: h.map(x => x.calls), tris: h.map(x => x.tris), buf: window.__ibperf ? window.__ibperf.w + 'x' + window.__ibperf.h : '?', texMB: window.__ibperf ? Math.round(window.__ibperf.texBytes / 1048576) : 0 }; });
    gpu = r.gpu; const avg = r.dts.reduce((a, b) => a + b, 0) / Math.max(1, r.dts.length);
    rows.push({ name, fps: +(1000 / avg).toFixed(1), p50ms: +med(r.dts).toFixed(1), p95ms: +pct(r.dts, .95).toFixed(1), p99ms: +pct(r.dts, .99).toFixed(1), jank33: r.dts.filter(x => x > 33.4).length, frames: r.dts.length, calls: med(r.calls.filter(x => x > 0)), callsP95: pct(r.calls, .95), tris: med(r.tris.filter(x => x > 0)), trisP95: pct(r.tris, .95), buf: r.buf, texMB: r.texMB, errors: errs.length });
    await ctx.close();
  } catch (e) { rows.push({ name, error: String(e).slice(0, 140) }); }
}
await browser.close(); srv.close();
const out = { host: os.hostname(), when: new Date().toISOString(), gpu, uncapped: UNCAPPED, seconds: SECS, note: 'phone rows throttle CPU 4x only; real phone GPUs are far weaker than this GPU: use calls/tris/buf to judge them', rows };
fs.mkdirSync(path.join(HERE, 'bench-results'), { recursive: true }); const file = path.join(HERE, 'bench-results', `${os.hostname()}-${Date.now()}.json`); fs.writeFileSync(file, JSON.stringify(out, null, 1));
console.log(`\nGPU: ${gpu}   uncapped=${UNCAPPED}   ${SECS}s per run`); console.table(rows); console.log('saved', file);
if (arg('share', false)) { // opt-in: no hostname, no paths, just GPU + timings
  try { const shared = { gpu, uncapped: UNCAPPED, seconds: SECS, when: out.when, note: out.note, rows };
    const r = await fetch('https://paste.rs', { method: 'POST', body: JSON.stringify(shared, null, 1) }); const url = (await r.text()).trim();
    console.log('\n>>> SHARED RESULTS: ' + url + '   <<< (tell Claude this address)'); } catch (e) { console.log('share failed: ' + e.message); } }
