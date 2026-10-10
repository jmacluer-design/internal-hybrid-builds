// The browser half of tools/phone_e2e.sh: a mobile-emulated Chromium (touch, DPR 3, httpCredentials) loads the phone page from the REAL MTA server over HTTP, reads what the UI shows,
// changes things by touch (a work priority, a blueprint) and reports what it saw as JSON. The shell script compares it with what the server's own console says; this file asserts nothing
// about the server, it only reports (and exits 0 unless it could not run at all).
//   node mta/tests/phone_e2e.mjs <base url, e.g. http://127.0.0.2:22985/outbreak/> <out.json> <shots dir>   env: PHONE_USER PHONE_PASS (control account)  VIEW_USER VIEW_PASS (look-only account)
import { chromium } from '/opt/node-tools/node_modules/playwright/index.mjs';
import fs from 'node:fs';
import path from 'node:path';

const [base, outFile, shots] = process.argv.slice(2);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const out = { steps: [], errors: [], facts: {} };
const note = (k, v) => { out.facts[k] = v; };
fs.mkdirSync(shots, { recursive: true });

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || '/opt/pw-browsers/chromium-1194/chrome-linux/chrome', args: ['--no-sandbox', '--disable-dev-shm-usage'] });
async function open(name, w, h, creds) {
  const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: 3, isMobile: true, hasTouch: true, ...(creds ? { httpCredentials: { username: creds[0], password: creds[1], send: 'always' } } : {}) });
  const page = await ctx.newPage();
  const errs = [];
  page.on('pageerror', e => errs.push(name + ' pageerror: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errs.push(name + ' console.error: ' + m.text()); if (m.type() === 'warning' && /\[OB\]|\[phone/.test(m.text())) errs.push(name + ' warn: ' + m.text()); });
  page.on('requestfailed', r => errs.push(name + ' requestfailed: ' + r.url()));
  page.on('response', r => { if (r.status() >= 400 && !/favicon/.test(r.url())) errs.push(name + ' http ' + r.status() + ': ' + r.url()); });
  const cdp = await ctx.newCDPSession(page);
  const send = (type, pts) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: pts.map(([x, y], i) => ({ x, y, id: i + 1, radiusX: 6, radiusY: 6, force: 1 })) });
  const t = {
    tap: async (x, y) => { await send('touchStart', [[x, y]]); await sleep(50); await send('touchEnd', []); await sleep(80); },
  };
  return { ctx, page, errs, t, name };
}
const rect = (p, sel, nth = 0) => p.page.evaluate(([s, n]) => { const e = document.querySelectorAll(s)[n]; if (!e) return null; if (e.closest('.dbody, .scrim, .pbody')) e.scrollIntoView({ block: 'center' }); const r = e.getBoundingClientRect(); return { cx: r.left + r.width / 2, cy: r.top + r.height / 2 }; }, [sel, nth]);
const tapEl = async (p, sel, nth = 0) => { const r = await rect(p, sel, nth); if (!r) throw new Error('no element ' + sel); await p.t.tap(r.cx, r.cy); };
const tapText = async (p, scope, text) => {
  const r = await p.page.evaluate(([s, t]) => { const b = [...document.querySelectorAll(s + ' button')].find(x => x.offsetParent && x.textContent.trim().toLowerCase().includes(t.toLowerCase())); if (!b) return null; const r = b.getBoundingClientRect(); return { cx: r.left + r.width / 2, cy: r.top + r.height / 2 }; }, [scope, text]);
  if (!r) throw new Error('no button ' + text); await p.t.tap(r.cx, r.cy);
};
const waitLive = async p => {
  await p.page.waitForFunction(() => window.__phone && window.__phone.connected && window.OB && OB.S.state && OB.S.mode === 'colony', null, { timeout: 30000 });
  await sleep(600);
};
// ask the server through the same call interface the page uses, with a separate session id: what the SERVER says, not what the page believes
const api = (p, op, a, b) => p.page.evaluate(async ([op, a, b, sid]) => {
  const r = await fetch('/outbreak/call/phoneApi', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Outbreak-Phone': '1' }, body: JSON.stringify([op, sid, a === undefined ? null : a, b === undefined ? null : b]) });
  return JSON.parse(JSON.parse(await r.text())[0]);
}, [op, a, b, 'e2eprobe_' + p.name + '_01']); // (a session id belongs to the account that made it: one probe session per browser)
const serverState = async p => { const r = await api(p, 'ready'); const st = r.msgs.find(m => m.action === 'state').data; return st; };
const shot = (p, name) => p.page.screenshot({ path: path.join(shots, name + '.png') });

try {
  // ---- 1. no login: the server refuses the page itself
  {
    const p = await open('anon', 390, 844, null);
    const r = await p.ctx.request.get(base);
    note('anon_status', r.status());
    note('anon_body_has_ui', /phone-bridge/.test(await r.text()));
    let navErr = '';
    try { await p.page.goto(base, { waitUntil: 'load', timeout: 8000 }); } catch (e) { navErr = String(e.message).split('\n')[0]; } // a browser with no login cannot show the page at all
    note('anon_navigation', navErr || 'loaded');
    note('anon_page_has_ui', await p.page.evaluate(() => !!window.OB).catch(() => false));
    await p.ctx.close();
  }
  // ---- 2. the phone, portrait: what the UI renders is the server's colony
  const P = await open('phone', 390, 844, [process.env.PHONE_USER, process.env.PHONE_PASS]);
  await P.page.goto(base, { waitUntil: 'load' });
  await waitLive(P);
  const ui = await P.page.evaluate(() => ({
    ui: document.documentElement.dataset.ui, badge: document.querySelector('#preview-badge').textContent, mode: OB.S.mode, role: window.__phone.role, account: window.__phone.account,
    colonists: OB.S.state.colonists.length, colonistsShown: document.querySelector('.res[data-id="colonists"] .rv').textContent.trim(), day: OB.S.state.day, dayShown: document.querySelector('.timebox .tb-b .disp').textContent.trim(), clock: OB.S.state.clock,
    cards: document.querySelectorAll('#roster .crow').length, speedPaused: OB.S.state.paused, seed: OB.S.state.seed, sheet: document.documentElement.dataset.sheet,
    styled: getComputedStyle(document.querySelector('#topbar')).display === 'grid', phone: window.__phone,
  }));
  note('ui', ui);
  const st0 = await api(P, 'ready').then(() => api(P, 'status'));
  note('api_status0', st0.status);
  await shot(P, 'live-01-portrait');
  const s0 = await serverState(P);
  const target = s0.colonists[0];
  note('target', { id: target.id, name: target.name });

  // ---- 3. change a work priority by touch (Priorities screen), then ask the server
  await tapText(P, '#cmdbar', 'Priorities');
  await P.page.waitForFunction(() => OB.screens.current === 'priorities', null, { timeout: 5000 });
  await sleep(300);
  const work = ['guard', 'cook', 'craft', 'haul'].find(w => !target.blocked[w]) || 'haul';
  const lv0 = target.prio[work];
  const want = (lv0 + 1) % 5;
  const cell = `.pcell[data-id="${target.id}"][data-work="${work}"]`;
  await tapEl(P, cell);
  await sleep(1500); // the callback is posted at once; one poll later the sim has answered
  const serverAfter = await serverState(P);
  const sPrio = serverAfter.colonists.find(c => c.id === target.id).prio[work];
  note('priority', { id: target.id, work, before: lv0, expected: want, shownInCell: await P.page.evaluate(c => document.querySelector(c).dataset.lv, cell), serverSays: sPrio });
  await shot(P, 'live-02-priorities-after-tap');
  await tapEl(P, '.scrim:not([hidden]) .panel-h .btn.sq:last-child');
  await P.page.waitForFunction(() => OB.screens.current === null, null, { timeout: 4000 });

  // ---- 4. place a blueprint by touch (Build tab -> wall -> tap -> Place)
  const b0 = serverAfter.buildings.length;
  await tapEl(P, '#dock .dtab[data-id="build"]'); await sleep(300);
  await tapEl(P, '.bcard[data-id="wall"]'); await sleep(400);
  const base0 = await P.page.evaluate(() => OB.S.catalog.tuning.base);
  const at = await P.page.evaluate(b => { const v = OB.mapBg, r = v.canvas.getBoundingClientRect(); return [r.left + v.sx(b.x + 16), r.top + v.sy(b.y + 12)]; }, base0);
  await P.t.tap(at[0], at[1]); await sleep(200);
  const ghost = await P.page.evaluate(() => { const g = OB.mapBg.ghost; return g && { x: g.x, y: g.y, ok: g.ok, reason: g.reason }; });
  note('ghost', ghost);
  await shot(P, 'live-03-placing');
  await tapEl(P, '#placebar .pb-ok'); await sleep(1800);
  const serverAfter2 = await serverState(P);
  note('build', { before: b0, after: serverAfter2.buildings.length, wall: serverAfter2.buildings.filter(b => b.bp === 'wall').map(b => ({ x: b.x, y: b.y, state: b.state })) });
  await shot(P, 'live-04-after-place');
  const st1 = await api(P, 'status');
  note('api_status1', st1.status);

  // ---- 5. the Director and the live feed
  await tapEl(P, '#dock .dtab[data-id="director"]'); await sleep(500);
  note('director', await P.page.evaluate(() => ({ lvl: (document.querySelector('.dmeter .disp') || {}).textContent, sheet: document.documentElement.dataset.sheet })));
  await shot(P, 'live-05-director');
  await tapEl(P, '#dock .dtab[data-id="director"]'); await sleep(200);
  await sleep(3000); // keep polling a while: no errors, no flood
  note('phone_after', await P.page.evaluate(() => window.__phone));
  out.errors.push(...P.errs);
  await P.ctx.close();

  // ---- 6. landscape
  const L = await open('landscape', 844, 390, [process.env.PHONE_USER, process.env.PHONE_PASS]);
  await L.page.goto(base, { waitUntil: 'load' });
  await waitLive(L);
  await shot(L, 'live-06-landscape');
  await tapEl(L, '#dock .dtab[data-id="director"]'); await sleep(500);
  await shot(L, 'live-07-landscape-director');
  note('landscape', await L.page.evaluate(() => ({ ui: document.documentElement.dataset.ui, w: innerWidth, h: innerHeight, colonists: OB.S.state.colonists.length })));
  out.errors.push(...L.errs);
  await L.ctx.close();

  // ---- 7. the look-only login: it sees the colony, but a priority tap changes nothing on the server
  const V = await open('viewer', 390, 844, [process.env.VIEW_USER, process.env.VIEW_PASS]);
  await V.page.goto(base, { waitUntil: 'load' });
  await waitLive(V);
  note('viewer', await V.page.evaluate(() => ({ role: window.__phone.role, account: window.__phone.account, colonists: OB.S.state.colonists.length })));
  const vs = await serverState(V);
  const vt = vs.colonists[1];
  const vwork = ['guard', 'cook', 'craft', 'haul'].find(w => !vt.blocked[w]) || 'haul';
  await tapText(V, '#cmdbar', 'Priorities');
  await V.page.waitForFunction(() => OB.screens.current === 'priorities', null, { timeout: 5000 });
  await sleep(300);
  await tapEl(V, `.pcell[data-id="${vt.id}"][data-work="${vwork}"]`);
  await sleep(1500);
  const toast = await V.page.evaluate(() => [...document.querySelectorAll('.toast')].map(t => t.textContent.trim()));
  note('viewer_try', { id: vt.id, work: vwork, before: vt.prio[vwork], serverSays: (await serverState(V)).colonists.find(c => c.id === vt.id).prio[vwork], toasts: toast });
  await shot(V, 'live-08-viewer-readonly');
  // the viewer's own order_result / refused toast is expected: only transport errors count
  out.errors.push(...V.errs.filter(e => !/http 4\d\d: .*phoneApi/.test(e)));
  await V.ctx.close();
} catch (e) {
  out.fatal = String(e && e.stack || e);
}
await browser.close();
fs.writeFileSync(outFile, JSON.stringify(out, null, 1));
console.log('phone_e2e.mjs: ' + (out.fatal ? 'FATAL ' + out.fatal.split('\n')[0] : 'done') + ', ' + out.errors.length + ' browser error(s)');
