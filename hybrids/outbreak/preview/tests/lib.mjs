// Shared helpers for the preview tests: static server over hybrids/outbreak/ (with the right MIME types incl. wasm + woff2) and a
// headless Chromium (same launch pattern as scratchpad/tools/harness.mjs). Console errors, page errors and failed requests are collected.
import { chromium } from '/opt/node-tools/node_modules/playwright/index.mjs';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.wasm': 'application/wasm', '.woff2': 'font/woff2', '.png': 'image/png', '.svg': 'image/svg+xml', '.txt': 'text/plain' };

export function serve(root = ROOT) {
  const srv = http.createServer((req, res) => {
    const u = decodeURIComponent(req.url.split('?')[0]);
    const f = path.join(root, u === '/' ? 'preview/index.html' : u);
    if (!f.startsWith(root) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); return res.end('not found'); }
    res.writeHead(200, { 'content-type': MIME[path.extname(f)] || 'application/octet-stream', 'cache-control': 'no-store' });
    fs.createReadStream(f).pipe(res);
  });
  return new Promise(r => srv.listen(0, '127.0.0.1', () => r(srv)));
}

export async function launch() {
  const srv = await serve();
  const port = srv.address().port;
  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome', args: ['--ignore-gpu-blocklist', '--disable-dev-shm-usage', '--no-sandbox'] });
  return { srv, browser, port, close: async () => { await browser.close(); srv.close(); } };
}

// opts: { w, h, query: 'seed=1&mode=colony', bench: false }
export async function openPreview(env, opts = {}) {
  const { w = 1920, h = 1080, query = '', bench = false } = opts;
  const ctx = await env.browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: opts.dpr || 1 });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('console.error: ' + m.text()); if (m.type() === 'warning' && /\[OB\]/.test(m.text())) errors.push('warn: ' + m.text()); });
  page.on('requestfailed', r => errors.push('requestfailed: ' + r.url()));
  page.on('response', r => { if (r.status() >= 400) errors.push('http ' + r.status() + ': ' + r.url()); });
  const q = (bench ? '' : 'bench=0&') + query;
  await page.goto(`http://127.0.0.1:${env.port}/preview/index.html?${q}`, { waitUntil: 'load' });
  await page.waitForFunction(() => window.__previewReady === true || window.__previewError, null, { timeout: 60000 });
  const err = await page.evaluate(() => window.__previewError || null);
  if (err) throw new Error('preview failed to start: ' + err);
  await page.waitForFunction(() => window.__preview && window.__preview.uiReady(), null, { timeout: 30000 });
  const frame = page.frameLocator('#nui');
  const ui = page.frames().find(f => f !== page.mainFrame());
  const api = {
    page, ctx, errors, frame, ui,
    pv: (fn, arg) => page.evaluate(fn, arg),
    call: (name, ...args) => page.evaluate(([n, a]) => window.__preview[n](...a), [name, args]),
    inUI: (fn, arg) => ui.evaluate(fn, arg),
    settle: async (ms = 250) => { await page.waitForTimeout(ms); },
    shot: (file, o = {}) => page.screenshot({ path: file, ...o }),
    close: async () => { await ctx.close(); },
  };
  return api;
}
