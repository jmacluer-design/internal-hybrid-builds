// The phone page's bridge (ui/phone-bridge.js) in a real mobile-emulated Chromium against the REAL phone.lua running on the mock MTA (tests/phone_stub.lua, a child process), with a small node
// HTTP server standing in for MTA's HTTP server (Basic login, the default page, the call interface that wraps the returned string into a JSON array, every file as application/octet-stream like
// MTA). What this covers that tools/phone_e2e.sh (the real server) cannot: failure modes you can only provoke on a stand-in: the connection dropping and coming back, the server restarting under a
// page, a login that stops working in the middle, callbacks racing a resync. The happy path on the real server is phone_e2e.sh.
//   node mta/tests/phone_bridge_test.mjs
import { chromium } from '/opt/node-tools/node_modules/playwright/index.mjs';
import { spawn } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const UI = path.resolve(here, '..', 'outbreak', 'ui');
let asserts = 0; const failures = [];
const section = n => console.log('\n== ' + n);
const check = (ok, msg) => { asserts++; if (!ok) { failures.push(msg); console.log('  FAIL  ' + msg); } else console.log('  ok    ' + msg); };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (fn, ms = 10000, step = 100) => { const end = Date.now() + ms; for (;;) { const v = await fn(); if (v) return v; if (Date.now() > end) return v; await sleep(step); } };

// ------------------------------------------------------------------------------------------------------------------------------ the Lua side
const lua = spawn(process.env.LUA || 'luajit', [path.join(here, 'phone_stub.lua')], { cwd: here, stdio: ['pipe', 'pipe', 'inherit'] });
const waiting = new Map(); let nextId = 1;
readline.createInterface({ input: lua.stdout }).on('line', line => { try { const r = JSON.parse(line); const w = waiting.get(r.id); if (w) { waiting.delete(r.id); w(r); } } catch (e) { console.log('stub said: ' + line); } });
const ask = req => new Promise(res => { const id = nextId++; waiting.set(id, res); lua.stdin.write(JSON.stringify({ ...req, id }) + '\n'); });
const sim = () => ask({ cmd: 'hash' });

// ------------------------------------------------------------------------------------------------------------------------------ the stand-in for MTA's HTTP server
const ACCOUNTS = { phone: ['pw-phone', 'phone'], view: ['pw-view', 'phoneview'] };
const S = { mode: 'ok', log: [], paths: [], inflightCb: 0, maxInflightCb: 0, authOk: true };
const server = http.createServer(async (req, res) => {
  const u = req.url.split('?')[0];
  S.paths.push(req.method + ' ' + u);
  const m = /^Basic (.+)$/.exec(req.headers.authorization || '');
  const [user, pass] = m ? Buffer.from(m[1], 'base64').toString().split(':') : [];
  const acct = ACCOUNTS[user] && ACCOUNTS[user][0] === pass ? ACCOUNTS[user][1] : null;
  const deny = () => { res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="stub"', 'content-type': 'text/html' }); res.end('Access denied, please login'); };
  if (u === '/outbreak/' || u === '/outbreak/ui/phone.html') { if (!acct) return deny(); res.writeHead(200, { 'content-type': 'text/html' }); return res.end(fs.readFileSync(path.join(UI, 'phone.html'))); }
  if (u.startsWith('/outbreak/ui/')) { // client files: public, labelled octet-stream like MTA does
    const f = path.join(UI, u.slice('/outbreak/ui/'.length));
    if (!f.startsWith(UI) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); return res.end('not found'); }
    res.writeHead(200, { 'content-type': 'application/octet-stream' }); return res.end(fs.readFileSync(f));
  }
  if (u === '/outbreak/call/phoneApi' && req.method === 'POST') {
    if (S.mode === 'down') return req.socket.destroy();
    if (S.mode === 'auth' || !acct) return deny();
    let body = ''; for await (const c of req) body += c;
    let args; try { args = JSON.parse(body); } catch (e) { res.writeHead(200); return res.end('error: bad body'); }
    const entry = { op: args[0], args, account: acct, t: Date.now(), headers: req.headers };
    S.log.push(entry);
    const isCb = args[0] === 'cb';
    if (isCb) { S.inflightCb++; S.maxInflightCb = Math.max(S.maxInflightCb, S.inflightCb); }
    const r = await ask({ fn: 'phoneApi', account: acct, headers: { 'x-outbreak-phone': req.headers['x-outbreak-phone'], host: req.headers.host, origin: req.headers.origin }, args });
    if (isCb) S.inflightCb--;
    res.writeHead(200, { 'content-type': 'text/html' });
    return res.end(JSON.stringify(r.result === undefined || r.result === null ? [] : [r.result])); // MTA wraps the returned string into a JSON array
  }
  res.writeHead(404); res.end('not found');
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const BASE = `http://127.0.0.1:${server.address().port}/outbreak/`;
const cbs = () => S.log.filter(e => e.op === 'cb');

// ------------------------------------------------------------------------------------------------------------------------------ the browser
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || '/opt/pw-browsers/chromium-1194/chrome-linux/chrome', args: ['--no-sandbox', '--disable-dev-shm-usage'] });
async function open(user = 'phone', w = 390, h = 844) {
  S.log.length = 0; S.paths.length = 0; S.mode = 'ok'; S.maxInflightCb = 0;
  await ask({ cmd: 'restart' });
  const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, httpCredentials: { username: user, password: ACCOUNTS[user][0], send: 'always' } });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('console.error: ' + m.text()); });
  const cdp = await ctx.newCDPSession(page);
  const tap = async (x, y) => { const pt = [{ x, y, id: 1, radiusX: 6, radiusY: 6, force: 1 }]; await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: pt }); await sleep(50); await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] }); await sleep(60); };
  await page.goto(BASE, { waitUntil: 'load' });
  await page.waitForFunction(() => window.__phone && window.__phone.connected && window.OB && OB.S.state, null, { timeout: 20000 });
  await sleep(300);
  const ph = () => page.evaluate(() => JSON.parse(JSON.stringify(window.__phone)));
  const rect = sel => page.evaluate(s => { const e = document.querySelector(s); if (!e) return null; e.scrollIntoView({ block: 'center' }); const r = e.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; }, sel);
  const tapSel = async sel => { const r = await rect(sel); if (!r) throw new Error('no ' + sel); await tap(r[0], r[1]); };
  const toasts = () => page.evaluate(() => [...document.querySelectorAll('.toast')].map(t => t.textContent.trim()));
  const badge = () => page.evaluate(() => document.getElementById('preview-badge').textContent);
  return { ctx, page, errors, tap, tapSel, ph, toasts, badge, close: () => ctx.close() };
}
async function openPriorities(b) {
  const r = await b.page.evaluate(() => { const e = [...document.querySelectorAll('#cmdbar button')].find(x => x.offsetParent && /Priorities/.test(x.textContent)); const q = e.getBoundingClientRect(); return [q.left + q.width / 2, q.top + q.height / 2]; });
  await b.tap(r[0], r[1]);
  await b.page.waitForFunction(() => OB.screens.current === 'priorities', null, { timeout: 5000 });
  await sleep(300);
}

// ================================================================================================================================ A. handshake + render
{
  section('handshake: ready first, then polls; the UI renders the stub server\'s colony; the page is self-contained');
  const b = await open();
  check(S.log[0].op === 'ready', `the first call is ready (then: ${S.log.slice(1, 4).map(e => e.op).join(',')})`);
  check(S.log.every(e => e.headers['x-outbreak-phone'] === '1' && /application\/json/.test(e.headers['content-type'])), 'every call carries X-Outbreak-Phone: 1 and a JSON body');
  const ui = await b.page.evaluate(() => ({ ui: document.documentElement.dataset.ui, mode: OB.S.mode, col: OB.S.state.colonists.length, shown: document.querySelector('.res[data-id="colonists"] .rv').textContent.trim(), day: OB.S.state.day, badge: document.getElementById('preview-badge').textContent, styled: getComputedStyle(document.querySelector('#topbar')).display }));
  check(ui.ui === 'touch' && ui.mode === 'colony' && ui.col === 4 && ui.shown === '4' && ui.styled === 'grid', `touch layout, colony mode, 4 colonists from the server (${JSON.stringify(ui)})`);
  check(/LIVE/.test(ui.badge), 'the badge says LIVE: ' + ui.badge);
  await sleep(2200);
  const p = await b.ph();
  check(p.polls >= 3 && p.errors === 0 && p.connected && p.role === 'control' && p.account === 'phone', `it polls (${p.polls} polls, ${p.errors} errors, role ${p.role}, account ${p.account})`);
  const ext = S.paths.filter(x => /\.(js|css)$/.test(x));
  check(ext.length === 0, 'the page needs no .js / .css request (MTA labels them octet-stream): ' + (ext.join(', ') || 'none'));
  check(S.paths.filter(x => x.startsWith('GET /outbreak/ui/fonts/')).length >= 1, 'fonts are fetched (from the public client files)');
  check(b.errors.length === 0, 'no console / page errors: ' + b.errors.join(' | '));
  await b.close();
}

// ================================================================================================================================ B. callbacks
{
  section('callbacks: the in-game client\'s camera and window callbacks never leave the page; orders go out one at a time, in order');
  const b = await open();
  await b.page.evaluate(() => { OB.post('mouse', { type: 'move', x: .5, y: .5 }); OB.post('key', { k: 'w', down: true }); OB.post('screen', { name: 'inventory', open: true }); OB.post('focus', { x: 1, y: 2 }); OB.post('mode', { mode: 'survival' }); OB.post('close', {}); OB.post('place', { op: 'start', bp: 'wall' }); OB.post('place', { op: 'cancel' }); OB.ui('screens', { colony: true }); });
  await sleep(1200);
  check(cbs().length === 0, `none of mouse / key / screen / focus / mode / close / place start+cancel / ui screens was sent (${cbs().length} callbacks)`);
  await openPriorities(b);
  const st = await sim();
  const c = Object.keys(st.prio)[0];
  const cell = `.pcell[data-id="${c}"][data-work="cook"]`;
  const l0 = st.prio[c].cook;
  for (let i = 0; i < 4; i++) await b.tapSel(cell);
  await until(async () => cbs().length >= 4, 6000);
  const orders = cbs().filter(e => e.args[2] === 'order');
  check(orders.length === 4, `four taps made four order callbacks (${orders.length})`);
  const levels = orders.map(e => e.args[3].target.level);
  check(levels.join() === [1, 2, 3, 4].map(i => (l0 + i) % 5).join(), `in order: levels ${levels.join(',')} from ${l0}`);
  check(S.maxInflightCb === 1, `one callback at a time (max in flight ${S.maxInflightCb})`);
  const after = await sim();
  check(after.prio[c].cook === (l0 + 4) % 5, `the sim holds the last level (${after.prio[c].cook})`);
  await b.close();
}

// ================================================================================================================================ C. look-only
{
  section('look-only login: the page works, an order is refused with a toast and the sim does not change');
  const b = await open('view');
  const p = await b.ph();
  check(p.role === 'view' && p.account === 'phoneview', 'role view: ' + p.role);
  await openPriorities(b);
  const st = await sim();
  const c = Object.keys(st.prio)[0];
  await b.tapSel(`.pcell[data-id="${c}"][data-work="cook"]`);
  await until(async () => (await b.toasts()).some(t => /read-only/.test(t)), 5000);
  check((await b.toasts()).some(t => /read-only/.test(t)), 'the toast says read-only: ' + (await b.toasts()).join(' | '));
  const after = await sim();
  check(after.hash === st.hash && after.prio[c].cook === st.prio[c].cook, 'the sim hash is unchanged');
  await b.close();
}

// ================================================================================================================================ D. connection loss
{
  section('connection loss and return: OFFLINE badge + toast, back-off, then LIVE + Reconnected, polling resumes');
  const b = await open();
  const n0 = (await b.ph()).polls;
  S.mode = 'down';
  await until(async () => !(await b.ph()).connected, 15000);
  const p1 = await b.ph();
  check(!p1.connected && p1.failStreak >= 2 && p1.errors >= 2, `connected=false after ${p1.failStreak} failures (${p1.lastError})`);
  check(/OFFLINE/.test(await b.badge()), 'the badge says OFFLINE: ' + await b.badge());
  check((await b.toasts()).some(t => /lost/i.test(t)), 'a "connection lost" toast');
  S.mode = 'ok';
  await until(async () => (await b.ph()).connected, 20000, 200);
  const p2 = await b.ph();
  check(p2.connected && p2.failStreak === 0, 'connected again');
  check(/LIVE/.test(await b.badge()), 'the badge says LIVE again: ' + await b.badge());
  check((await b.toasts()).some(t => /Reconnected/.test(t)), 'a "Reconnected" toast');
  await sleep(1500);
  check((await b.ph()).polls > n0, 'polling resumed');
  check(b.errors.every(e => !/pageerror/.test(e)), 'no page errors: ' + b.errors.join(' | '));
  await b.close();
}

// ================================================================================================================================ E. server restart
{
  section('the server restarts under the page: the page notices (resync), signs in again by itself, and a callback sent during it is not lost');
  const b = await open();
  await openPriorities(b);
  const st = await sim();
  const c = Object.keys(st.prio)[0];
  const l0 = st.prio[c].cook;
  const readies0 = S.log.filter(e => e.op === 'ready').length;
  await ask({ cmd: 'restart' });                       // every session is gone, the world is a new one
  await b.tapSel(`.pcell[data-id="${c}"][data-work="cook"]`); // an order straight away: the server answers resync, the bridge signs in again and sends it
  await until(async () => (await sim()).prio[c].cook === (l0 + 1) % 5, 10000, 200);
  const after = await sim();
  check(after.prio[c].cook === (l0 + 1) % 5, `the order sent during the resync reached the new server (cook ${l0} -> ${after.prio[c].cook})`);
  const p = await b.ph();
  check(p.resyncs >= 1 && S.log.filter(e => e.op === 'ready').length > readies0, `the page resynchronised (${p.resyncs} resync, ${S.log.filter(e => e.op === 'ready').length - readies0} new ready)`);
  check(p.connected && p.errors === 0, 'and is connected with no transport error');
  check(await b.page.evaluate(() => OB.S.state && OB.S.state.colonists.length === 4), 'the UI still shows the colony');
  await b.close();
}

// ================================================================================================================================ F. login stops working
{
  section('the login stops working mid-session (401): LOGIN REQUIRED, one clear toast, and the page stops hammering the server');
  const b = await open();
  S.mode = 'auth';
  await until(async () => (await b.ph()).authFailed, 10000);
  const p = await b.ph();
  check(p.authFailed && !p.connected, 'authFailed, not connected');
  check(/LOGIN/.test(await b.badge()), 'the badge says LOGIN REQUIRED: ' + await b.badge());
  check((await b.toasts()).some(t => /login/i.test(t)), 'a toast says to reload and sign in again');
  const n = S.log.length, nAll = S.paths.length;
  await sleep(3500);
  check(S.paths.length - nAll <= 1, `no more calls once refused (${S.paths.length - nAll} after)`);
  await b.close();
}

// ================================================================================================================================ G. a browser with no login
{
  section('no login at all: the server answers 401 to the page and the API');
  const r = await fetch(BASE); check(r.status === 401 && /login/.test(await r.text()), 'GET /outbreak/ without credentials: ' + r.status);
  const r2 = await fetch(BASE + 'call/phoneApi', { method: 'POST', headers: { 'content-type': 'application/json', 'X-Outbreak-Phone': '1' }, body: '["ready","nologinsession01"]' });
  check(r2.status === 401, 'POST phoneApi without credentials: ' + r2.status);
  const r3 = await fetch(BASE, { headers: { authorization: 'Basic ' + Buffer.from('phone:wrong').toString('base64') } });
  check(r3.status === 401, 'a wrong password: ' + r3.status);
}

await browser.close(); server.close(); lua.stdin.end(); lua.kill();
console.log(`\n${asserts} checks, ${failures.length} failed`);
if (failures.length) { console.log('FAILED:\n  ' + failures.join('\n  ')); process.exit(1); }
console.log('PHONE BRIDGE TESTS PASSED');
process.exit(0);
