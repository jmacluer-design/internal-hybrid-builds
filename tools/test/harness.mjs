// Shared headless test harness for games/*.html
//   import { launch } from '/tmp/.../scratchpad/tools/harness.mjs'
//   const g = await launch('/home/user/internal-hybrid-builds/games/foo.html', { w:1280, h:720 })
//   await g.click('#cta'); await g.hold('w', 800); await g.shot('/path/out.png'); console.log(await g.dbg()); await g.close()
//
// - serves the repo over http://127.0.0.1:<port> so location.protocol is http (shelf bridge active)
// - routes cdn.jsdelivr.net/npm/three@0.169.0/** to the local node_modules copy (offline, deterministic)
// - collects console errors + pageerrors in g.errors
// - WebGL via swiftshader (software), so expect low fps: use g.wait() not fps assertions
import { chromium } from '/opt/node-tools/node_modules/playwright/index.mjs';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const HERE = path.dirname(new URL(import.meta.url).pathname);
const THREE_ROOT = path.join(HERE, 'node_modules', 'three');
const REPO = '/home/user/internal-hybrid-builds';
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.png': 'image/png' };

function serve(root) {
  const srv = http.createServer((req, res) => {
    const u = decodeURIComponent(req.url.split('?')[0]);
    if (u.startsWith('/api/')) { // no relay in tests: behave like static hosting (shelf bridge falls back)
      res.writeHead(404, { 'content-type': 'application/json' }); return res.end('{"err":"no api"}');
    }
    if (u.startsWith('/__nm/')) { const nf = path.join(HERE, 'node_modules', u.slice(6));
      if (nf.startsWith(path.join(HERE,'node_modules')) && fs.existsSync(nf) && fs.statSync(nf).isFile()) { res.writeHead(200, { 'content-type': MIME[path.extname(nf)] || 'text/javascript' }); return fs.createReadStream(nf).pipe(res); } }
    let f = path.join(root, u === '/' ? 'index.html' : u);
    if (!f.startsWith(root) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); return res.end('nf'); }
    res.writeHead(200, { 'content-type': MIME[path.extname(f)] || 'application/octet-stream' });
    fs.createReadStream(f).pipe(res);
  });
  return new Promise(r => srv.listen(0, '127.0.0.1', () => r(srv)));
}

export async function launch(gameFile, { w = 1280, h = 720, touch = false, root = REPO } = {}) {
  const rel = path.relative(root, path.resolve(gameFile));
  const srv = await serve(root);
  const port = srv.address().port;
  const browser = await chromium.launch({
    executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome',
    args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--autoplay-policy=no-user-gesture-required'],
  });
  const ctx = await browser.newContext({ viewport: { width: w, height: h }, hasTouch: touch });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('console', m => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push('console.error: ' + m.text()); });
  // /api/* 404s are expected (static hosting, no relay); any other failed request is a real error
  page.on('response', r => { if (r.status() >= 400 && !r.url().includes('/api/')) errors.push('http ' + r.status() + ': ' + r.url()); });
  await page.route(/cdn\.jsdelivr\.net\/npm\/three@0\.169\.0\/(.*)/, route => {
    const sub = route.request().url().match(/three@0\.169\.0\/(.*)$/)[1].split('?')[0];
    const f = path.join(THREE_ROOT, sub);
    if (!fs.existsSync(f)) return route.fulfill({ status: 404, body: 'nf' });
    route.fulfill({ status: 200, contentType: 'text/javascript', body: fs.readFileSync(f) });
  });
  await page.goto(`http://127.0.0.1:${port}/${rel}`, { waitUntil: 'load' });
  const g = {
    page, errors,
    wait: ms => page.waitForTimeout(ms),
    click: sel => page.click(sel),
    clickAt: (x, y) => page.mouse.click(x, y),
    down: k => page.keyboard.down(k), up: k => page.keyboard.up(k),
    press: (k, ms = 60) => page.keyboard.press(k, { delay: ms }),
    hold: async (k, ms) => { await page.keyboard.down(k); await page.waitForTimeout(ms); await page.keyboard.up(k); },
    // simulate a phone-pad event stream: same shapes pad.html posts (see games contract)
    padEvent: ev => page.evaluate(e => window.__padInject && window.__padInject(e), ev),
    mouse: (dx, dy) => page.evaluate(([a, b]) => window.dispatchEvent(new MouseEvent('mousemove', { movementX: a, movementY: b })), [dx, dy]),
    dbg: () => page.evaluate(() => (window.__dbg ? window.__dbg() : null)),
    shot: p => page.screenshot({ path: p }),
    eval: (fn, arg) => page.evaluate(fn, arg),
    close: async () => { await browser.close(); srv.close(); },
  };
  return g;
}
