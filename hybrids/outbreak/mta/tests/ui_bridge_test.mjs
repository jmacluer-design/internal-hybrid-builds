// Browser test of the CEF side: the UNCHANGED vanilla NUI (copied to mta/outbreak/ui) + ui/mta-bridge.js in headless Chromium, with a fake `mta.triggerEvent`.
//   node mta/tests/ui_bridge_test.mjs [session.json [calls.json]]
//   session.json  the JavaScript strings the real client Lua pushed (tests/dump_ui_session.lua writes it; generated here when the argument is missing)
//   calls.json    every mta.triggerEvent call the page made, written for tests/replay_ui_calls.lua (the Lua half of the round trip)
// What it proves: the page loads from the origin MTA uses (http://mta/local/ui/mta.html, served by a request route from the folder meta.xml ships), requests only files that meta.xml lists
// and that exist, the bridge is installed before js/core.js, the page's fetch('https://outbreak/<name>') callbacks become mta.triggerEvent('outbreak:ui', name, '<json string>') with only
// simple argument types, the state/hud/events pushed by the Lua client render, a click on a priority cell sends the right order, other callbacks (ui, screen, mode, key, mouse) have the
// right payloads, and fetches to other URLs are left alone. What it cannot prove: that CEF's `mta` object, local-origin rules, focus and GPU rendering behave the same (README "unverified").
import { chromium } from '/opt/node-tools/node_modules/playwright/index.mjs';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const RES = path.resolve(HERE, '..', 'outbreak');
const UI_DIR = path.join(RES, 'ui');
const ORIGIN = 'http://mta/local/';
const PAGE = ORIGIN + 'ui/mta.html';

let asserts = 0;
const failures = [];
const section = name => console.log('\n== ' + name);
function check(ok, msg) {
  asserts++;
  if (!ok) { failures.push(msg); console.log('  FAIL  ' + msg); } else console.log('  ok    ' + msg);
}

// ------------------------------------------------------------------------------------------------------------------------------------ the session fixture
let sessionFile = process.argv[2];
const callsOut = process.argv[3];
if (!sessionFile) {
  sessionFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'outbreak-mta-')), 'session.json');
  let ran = false;
  for (const rt of ['luajit', 'lua5.4', 'lua']) {
    const r = spawnSync(rt, [path.join(HERE, 'dump_ui_session.lua'), sessionFile], { encoding: 'utf8' });
    if (r.status === 0) { ran = true; console.log(r.stdout.trim()); break; }
    if (r.error) continue;
    console.log(r.stdout + r.stderr);
    break;
  }
  if (!ran) { console.log('FAIL: could not generate the session fixture (no Lua runtime worked)'); process.exit(1); }
}
const session = JSON.parse(fs.readFileSync(sessionFile, 'utf8'));
const BODY_RE = /^window\.dispatchEvent\(new MessageEvent\('message',\{data:([\s\S]*)\}\)\)$/;
const parsePush = js => { const m = BODY_RE.exec(js); return m ? JSON.parse(m[1]) : null; };
const pushes = session.pushes;
check(pushes.length > 20 && pushes.every(p => BODY_RE.test(p)), `the fixture holds ${pushes.length} pushes, all of the exact shape client/ui.lua sends`);

// ------------------------------------------------------------------------------------------------------------------------------------ meta.xml
const meta = fs.readFileSync(path.join(RES, 'meta.xml'), 'utf8');
const metaFiles = new Map();
for (const m of meta.matchAll(/<file\s+src="([^"]+)"([^>]*)\/>/g)) metaFiles.set(m[1], !/download\s*=\s*"false"/.test(m[2]));
const shipped = p => metaFiles.get(p) === true; // listed AND downloaded to the client

// ------------------------------------------------------------------------------------------------------------------------------------ browser
const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome', args: ['--ignore-gpu-blocklist', '--disable-dev-shm-usage', '--no-sandbox'] });
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.txt': 'text/plain', '.png': 'image/png' };

// MTA's `mta.triggerEvent` only takes simple values (string, number, boolean): the fake throws on anything else, so a bridge that passed an object would fail here
const FAKE_MTA = () => {
  window.__mtaCalls = [];
  window.mta = {
    triggerEvent: function () {
      const args = Array.prototype.slice.call(arguments);
      for (const a of args) if (!(typeof a === 'string' || typeof a === 'number' || typeof a === 'boolean')) throw new TypeError('mta.triggerEvent: argument of type ' + typeof a + ' is not a simple value');
      window.__mtaCalls.push(args);
    },
  };
};

async function openPage({ withMta = true, w = 1920, h = 1080 } = {}) {
  const ctx = await browser.newContext({ viewport: { width: w, height: h } });
  if (withMta) await ctx.addInitScript(FAKE_MTA);
  const page = await ctx.newPage();
  const errors = [], warnings = [], requests = [], outside = [];
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('console.error: ' + m.text()); if (m.type() === 'warning') warnings.push(m.text()); });
  await page.route('**/*', route => {
    const url = route.request().url();
    if (url.startsWith(ORIGIN)) {
      const rel = decodeURIComponent(url.slice(ORIGIN.length).split(/[?#]/)[0]);
      const f = path.join(RES, rel);
      requests.push(rel);
      if (!f.startsWith(RES) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) return route.fulfill({ status: 404, body: 'not found' });
      return route.fulfill({ status: 200, contentType: MIME[path.extname(f)] || 'application/octet-stream', body: fs.readFileSync(f) });
    }
    if (url.startsWith('data:')) return route.continue();
    outside.push(url);
    return route.abort('blockedbyclient'); // nothing may leave the page: MTA's local browser has no network access we rely on
  });
  await page.goto(PAGE, { waitUntil: 'load' });
  return { ctx, page, errors, warnings, requests, outside, calls: () => page.evaluate(() => window.__mtaCalls || []) };
}
const push = (p, js) => p.page.evaluate(js);
const settle = (p, ms = 80) => p.page.waitForTimeout(ms);

const allCalls = [];
const noteCalls = async p => { for (const c of await p.calls()) allCalls.push(c); };

// ------------------------------------------------------------------------------------------------------------------------------------ 1. loading
section('the page loads from http://mta/local/ and ships exactly what meta.xml lists');
const p = await openPage();
await p.page.waitForFunction(() => typeof window.OB === 'object' && window.OB && !!window.OB.screens, null, { timeout: 15000 });
check(p.errors.length === 0, 'no page error and no console error while loading' + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
const wanted = [...new Set(p.requests)].sort();
const missing = wanted.filter(r => !shipped(r));
check(wanted.length >= 15 && missing.length === 0, `all ${wanted.length} files the page requested are <file> entries of meta.xml that the client downloads` + (missing.length ? ' (missing: ' + missing.join(', ') + ')' : ''));
check(p.outside.length === 0, 'no request leaves http://mta/local/ (no CDN, no network)' + (p.outside.length ? ': ' + p.outside.join(', ') : ''));
const order = await p.page.evaluate(() => Array.from(document.scripts).map(s => s.getAttribute('src')));
check(order.indexOf('mta-bridge.js') === 0 && order.indexOf('js/core.js') === 1, `mta-bridge.js is loaded before js/core.js (${order.slice(0, 3).join(', ')} ...)`);
const files = [...metaFiles.keys()].filter(f => f.startsWith('ui/'));
check(files.every(f => fs.existsSync(path.join(RES, f))), `all ${files.length} ui files of meta.xml exist on disk`);
check(await p.page.evaluate(() => window.GetParentResourceName() === 'outbreak' && typeof window.__obMta === 'object'), 'GetParentResourceName() is "outbreak" and the bridge counters exist');
check(await p.page.evaluate(() => OB.preview !== true), 'the page does not think it is the browser preview');
const ready = (await p.calls()).filter(c => c[1] === 'ready');
check(ready.length === 1 && ready[0][0] === 'outbreak:ui' && typeof ready[0][2] === 'string' && JSON.parse(ready[0][2]).v !== undefined, 'on load the page sends the `ready` callback as mta.triggerEvent("outbreak:ui", "ready", "<json>")');

// ------------------------------------------------------------------------------------------------------------------------------------ 2. the pushes from Lua render
section('the state, hud and events the Lua client pushed render');
const before = session.priorities_index - 1; // pushes[1 .. before] are everything before the priorities screen opens
for (let i = 0; i < before; i++) await push(p, pushes[i]);
await settle(p, 200);
check(p.errors.length === 0, `replaying ${before} pushes raises no error` + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
check(await p.page.evaluate(() => OB.S.stateCount > 0 && !!OB.S.state && !!OB.S.catalog), 'catalog and state arrived (OB.S.stateCount > 0)');
check(await p.page.evaluate(() => document.documentElement.dataset.mode === 'colony' && !document.querySelector('#colony').hidden), 'colony mode: the colony layer is visible');
const rosterIds = await p.page.evaluate(() => Array.from(document.querySelectorAll('#roster [data-id]')).map(e => e.dataset.id));
check(session.colonists.every(id => rosterIds.includes(id)), `the roster shows every colonist of the sim (${session.colonists.join(',')})`);
check(await p.page.evaluate(() => document.querySelector('#hud').children.length > 0 && document.querySelector('#topbar').innerText.trim().length > 0), 'the HUD and the top bar have content');
const lastState = (() => { for (let i = before - 1; i >= 0; i--) { const j = parsePush(pushes[i]); if (j && j.action === 'state') return j; } return null; })();
check(!!lastState, 'the fixture has a state push');
const renamed = JSON.parse(JSON.stringify(lastState));
renamed.data.colonists[0].name = 'Bridge Tester';
await push(p, `window.dispatchEvent(new MessageEvent('message',{data:${JSON.stringify(renamed)}}))`);
await settle(p, 150);
check(await p.page.evaluate(() => document.querySelector('#roster').innerText.includes('Bridge Tester')), 'a newly pushed state renders (the renamed colonist appears in the roster)');
await push(p, `window.dispatchEvent(new MessageEvent('message',{data:${JSON.stringify(lastState)}}))`);
await settle(p, 100);
await push(p, `window.dispatchEvent(new MessageEvent('message',{data:{"action":"toast","data":{"level":"warn","text":"Bridge toast 42"}}}))`);
await settle(p, 100);
check(await p.page.evaluate(() => document.querySelector('#toasts').innerText.includes('Bridge toast 42')), 'a pushed toast is shown');
// junk pushes (the Lua client never sends these) must not take the page down: the page catches handler errors and logs them with an [OB] prefix, nothing may be UNCAUGHT, and the
// next good push must render again
const nBeforeJunk = p.errors.length;
for (const junk of ['{"action":"nope"}', '{"action":"state","data":null}', '{"action":"hud","data":{"hp":"x"}}', '{"action":"events","data":[{"type":"zzz"},null,5]}', '{}', '[]', '"s"', 'null']) {
  await push(p, `window.dispatchEvent(new MessageEvent('message',{data:${junk}}))`);
}
await settle(p, 150);
const junkErrors = p.errors.splice(nBeforeJunk);
check(junkErrors.every(e => e.startsWith('console.error: [OB]')), `junk messages raise no uncaught page error (${junkErrors.length} handler errors were caught and logged by the page itself)`);
await push(p, `window.dispatchEvent(new MessageEvent('message',{data:${JSON.stringify(renamed)}}))`);
await settle(p, 150);
check(await p.page.evaluate(() => document.querySelector('#roster').innerText.includes('Bridge Tester')), 'and the next good push still renders');
await push(p, `window.dispatchEvent(new MessageEvent('message',{data:${JSON.stringify(lastState)}}))`);
await settle(p, 100);

// ------------------------------------------------------------------------------------------------------------------------------------ 3. priorities
section('the priorities screen: a click sends the right order through mta.triggerEvent');
await push(p, pushes[session.priorities_index - 1]);
await p.page.waitForFunction(() => OB.screens.current === 'priorities', null, { timeout: 5000 });
const callsBefore = (await p.calls()).length;
const cellInfo = await p.page.evaluate(() => {
  const cells = Array.from(document.querySelectorAll('.pcell[data-work="cook"]')).filter(c => !c.classList.contains('blk') && c.dataset.blocked !== '1');
  const c = cells[0] || document.querySelector('.pcell[data-work="cook"]');
  return c ? { id: c.dataset.id, work: c.dataset.work, lv: +c.dataset.lv } : null;
});
check(!!cellInfo && session.colonists.includes(cellInfo.id), 'a priority cell exists for a colonist and the cook work: ' + JSON.stringify(cellInfo));
const cell = p.page.locator(`.pcell[data-id="${cellInfo.id}"][data-work="cook"]`);
const seen = [];
for (let i = 1; i <= 5; i++) {
  await cell.click();
  const calls = await p.calls();
  const c = calls[calls.length - 1];
  check(c && c.length === 3 && c[0] === 'outbreak:ui' && c[1] === 'order' && typeof c[2] === 'string', `click ${i}: mta.triggerEvent('outbreak:ui', 'order', '<json string>')`);
  const o = JSON.parse(c[2]);
  seen.push(o.target.level);
  const exact = JSON.stringify(Object.keys(o).sort()) === '["id","kind","target"]' && JSON.stringify(Object.keys(o.target).sort()) === '["level","work"]';
  check(exact && o.id === cellInfo.id && o.kind === 'priority' && o.target.work === 'cook' && o.target.level === (cellInfo.lv + i) % 5, `click ${i}: payload ${c[2]} (expected level ${(cellInfo.lv + i) % 5})`);
  check(await cell.getAttribute('data-lv') === String((cellInfo.lv + i) % 5), `click ${i}: the cell shows level ${(cellInfo.lv + i) % 5}`);
}
check(new Set(seen).size === 5, `five clicks visit all five levels once: ${seen.join(',')}`);
const after = await p.calls();
check(after.length === callsBefore + 5, 'exactly five callbacks were sent for five clicks (no duplicates, no stray calls)');
const prioCells = await p.page.evaluate(() => Array.from(document.querySelectorAll('.pcell')).map(c => ({ id: c.dataset.id, work: c.dataset.work, lv: +c.dataset.lv })));
const stateCols = lastState.data.colonists;
let mism = 0, compared = 0;
for (const pc of prioCells) {
  const col = stateCols.find(c => c.id === pc.id);
  if (!col || pc.id === cellInfo.id && pc.work === 'cook') continue; // the clicked cell has been cycled on purpose
  compared++;
  if ((col.prio[pc.work] || 0) !== pc.lv) mism++;
}
check(compared > 20 && mism === 0, `all ${compared} other priority cells equal the pushed state (${mism} mismatches)`);

// ------------------------------------------------------------------------------------------------------------------------------------ 4. the other callbacks
section('other callbacks: screen, ui, mode, key, mouse, place, focus (all through the real page controls)');
const n0 = (await p.calls()).length;
await p.page.keyboard.press('Escape');
await p.page.waitForFunction(() => OB.screens.current === null && !document.querySelector('#screens .scrim:not([hidden])'), null, { timeout: 3000 });
await p.page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))); // Chromium drops the focus of a hidden element at the next frame: a key pressed in between would still reach the hidden cell
const afterEsc = (await p.calls()).slice(n0);
const scr = afterEsc.filter(c => c[1] === 'screen').map(c => JSON.parse(c[2]));
check(scr.length >= 1 && scr[scr.length - 1].name === 'priorities' && scr[scr.length - 1].open === false, 'closing the screen sends screen {name: "priorities", open: false}: ' + JSON.stringify(scr));
const n1 = (await p.calls()).length;
await p.page.keyboard.press('2');
await settle(p, 60);
await p.page.keyboard.press(' ');
await settle(p, 60);
const uic = (await p.calls()).slice(n1).filter(c => c[1] === 'ui').map(c => JSON.parse(c[2]));
check(uic.some(u => u.name === 'set_speed' && u.data.speed === 2) && uic.some(u => u.name === 'toggle_pause'), 'keys 2 and Space send ui {name:"set_speed", data:{speed:2}} and ui {name:"toggle_pause"}: ' + JSON.stringify(uic));
const n2 = (await p.calls()).length;
await p.page.evaluate(() => OB.requestMode('survival'));
await settle(p, 60);
check((await p.calls()).slice(n2).some(c => c[1] === 'mode' && JSON.parse(c[2]).mode === 'survival'), 'OB.requestMode sends mode {mode:"survival"}');
await p.page.evaluate(() => OB.requestMode('colony'));
await push(p, `window.dispatchEvent(new MessageEvent('message',{data:{"action":"mode","data":{"mode":"colony"}}}))`);
await settle(p, 100);
const n3 = (await p.calls()).length;
await p.page.mouse.move(700, 500);
await p.page.mouse.down();
await p.page.mouse.up();
await settle(p, 120);
const mouse = (await p.calls()).slice(n3).filter(c => c[1] === 'mouse').map(c => JSON.parse(c[2]));
check(mouse.length >= 2 && mouse.every(m => typeof m.type === 'string' && m.x >= 0 && m.x <= 1 && m.y >= 0 && m.y <= 1), `mouse events carry a type and normalised coordinates: ${mouse.map(m => m.type).join(',')}`);
const n4 = (await p.calls()).length;
await p.page.keyboard.down('w');
await p.page.keyboard.up('w');
await settle(p, 60);
const keys = (await p.calls()).slice(n4).filter(c => c[1] === 'key').map(c => JSON.parse(c[2]));
check(keys.length >= 2 && keys[0].down === true && keys[keys.length - 1].down === false, `camera keys send key {k, down:true} then {down:false}: ${JSON.stringify(keys)}`);

const n5a = (await p.calls()).length;
await p.page.keyboard.press('b'); // opens the build dock
await p.page.waitForFunction(() => OB.S.dock === 'build', null, { timeout: 3000 });
const bp = await p.page.evaluate(() => { const c = document.querySelector('.bcard:not(.lock)'); return c ? c.dataset.id : null; });
check(!!bp, 'the build dock lists a blueprint that is not locked: ' + bp);
await p.page.click(`.bcard[data-id="${bp}"]`);
await settle(p, 80);
await p.page.keyboard.press('Escape');
await settle(p, 80);
const placeCalls = (await p.calls()).slice(n5a).filter(c => c[1] === 'place').map(c => JSON.parse(c[2]));
check(placeCalls.length === 2 && placeCalls[0].op === 'start' && placeCalls[0].bp === bp && placeCalls[1].op === 'cancel', 'clicking a blueprint card sends place {op:"start", bp}, Escape sends place {op:"cancel"}: ' + JSON.stringify(placeCalls));
const n5b = (await p.calls()).length;
await p.page.dblclick('#roster [data-id="c2"]');
await settle(p, 80);
const focusCalls = (await p.calls()).slice(n5b).filter(c => c[1] === 'focus').map(c => JSON.parse(c[2]));
check(focusCalls.length === 1 && Number.isFinite(focusCalls[0].x) && Number.isFinite(focusCalls[0].y) && focusCalls[0].id === 'c2', 'double-clicking a colonist in the roster sends focus {x, y, id:"c2"}: ' + JSON.stringify(focusCalls));

// ------------------------------------------------------------------------------------------------------------------------------------ 5. what the Lua side must be able to read
section('every payload fits the Lua decoder limits (65536 bytes, depth 12) and every callback name is one the client handles');
await noteCalls(p);
const handled = new Set(['ready', 'order', 'ui', 'mode', 'mouse', 'key', 'focus', 'place', 'screen', 'close']);
const depth = (v, d = 0) => (v && typeof v === 'object') ? Math.max(d, ...Object.values(v).map(x => depth(x, d + 1))) : d;
check(allCalls.length >= 20, `${allCalls.length} calls recorded`);
check(allCalls.every(c => c[0] === 'outbreak:ui' && handled.has(c[1]) && typeof c[2] === 'string' && c[2].length < 65536), 'event name "outbreak:ui", a handled callback name, a string body under 64 KiB');
check(allCalls.every(c => { try { return depth(JSON.parse(c[2])) <= 12; } catch (e) { return false; } }), 'every body is valid JSON no deeper than 12 levels');

// ------------------------------------------------------------------------------------------------------------------------------------ 6. fetch passthrough
section('fetch: calls to https://outbreak/<name> go to mta, everything else is left alone');
const n5 = (await p.calls()).length;
const r1 = await p.page.evaluate(async () => { const r = await fetch('https://outbreak/ui', { method: 'POST', body: '{"name":"x","data":{}}' }); return { ok: r.ok, status: r.status, json: await r.json() }; });
check(r1.ok && r1.status === 200 && r1.json.ok === true, 'the promise resolves with {"ok":true} like the NUI convention');
const nErr = p.errors.length;
const r2 = await p.page.evaluate(async () => { try { const r = await fetch('https://outbreak/ui/../../x'); return r.status; } catch (e) { return 'err'; } });
const r3 = await p.page.evaluate(async () => { try { await fetch('https://some-other-resource/ui', { method: 'POST', body: '{}' }); return 'ok'; } catch (e) { return 'rejected'; } });
await settle(p, 50);
p.errors.splice(nErr).forEach(e => { if (!/ERR_BLOCKED_BY_CLIENT/.test(e)) p.errors.push(e); }); // the browser's own report of the request this test blocked on purpose
const r4 = await p.page.evaluate(async () => { const r = await fetch('http://mta/local/ui/css/base.css'); return r.status; });
const posted = (await p.calls()).slice(n5);
check(posted.length === 1 && posted[0][1] === 'ui', `only the first fetch reached mta.triggerEvent (${posted.length} call)`);
check(r2 === 'err' && r3 === 'rejected' && r4 === 200, 'a path-traversal URL and a fetch to another host are not routed to mta (they hit the network layer: here blocked), a fetch of a local file works');
check(await p.page.evaluate(() => window.__obMta.posted === window.__mtaCalls.length), 'the bridge counter equals the number of mta.triggerEvent calls');
const l1 = await p.page.evaluate(async () => { const r = await fetch('https://outbreak/ui', { method: 'POST', body: JSON.stringify({ name: 'big', data: { s: 'x'.repeat(300000) } }) }); return r.ok; });
check(l1 === true, 'an oversized body is still handed over unchanged (the Lua side rejects it by size, see client_test)');
check(p.errors.length === 0, 'no page error or console error during the whole session' + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
await noteCalls({ calls: async () => [] });

// ------------------------------------------------------------------------------------------------------------------------------------ 7. layout
section('layout: no horizontal overflow at 1920x1080 and 1280x720');
for (const [w, h] of [[1920, 1080], [1280, 720]]) {
  const q = await openPage({ w, h });
  await q.page.waitForFunction(() => typeof window.OB === 'object' && !!window.OB.screens, null, { timeout: 15000 });
  for (let i = 0; i < before; i++) await push(q, pushes[i]);
  await settle(q, 200);
  const ov = await q.page.evaluate(() => ({ sw: document.documentElement.scrollWidth, iw: innerWidth, sh: document.documentElement.scrollHeight, ih: innerHeight }));
  check(ov.sw <= ov.iw && ov.sh <= ov.ih, `${w}x${h}: scroll size ${ov.sw}x${ov.sh} fits the window ${ov.iw}x${ov.ih}`);
  check(q.errors.length === 0, `${w}x${h}: no error` + (q.errors.length ? ': ' + q.errors.join(' | ') : ''));
  await q.ctx.close();
}

// ------------------------------------------------------------------------------------------------------------------------------------ 8. outside MTA
section('opened outside MTA (no window.mta): callbacks are dropped with one warning, the page keeps working');
const o = await openPage({ withMta: false });
await o.page.waitForFunction(() => typeof window.OB === 'object' && !!window.OB.screens, null, { timeout: 15000 });
await o.page.evaluate(async () => { await fetch('https://outbreak/ui', { method: 'POST', body: '{"name":"a","data":{}}' }); await fetch('https://outbreak/ui', { method: 'POST', body: '{"name":"b","data":{}}' }); });
const stats = await o.page.evaluate(() => window.__obMta);
check(stats.dropped >= 3 && stats.posted === 0 && stats.hasMta === false, `callbacks counted as dropped (${stats.dropped}), none posted`);
check(o.warnings.filter(w => w.includes('[mta-bridge]')).length === 1, 'exactly one console warning about the missing window.mta');
check(o.errors.length === 0, 'and no error');
await o.ctx.close();

await p.ctx.close();
await browser.close();

if (callsOut) fs.writeFileSync(callsOut, JSON.stringify(allCalls.map(c => ({ event: c[0], name: c[1], json: c[2] }))));
console.log(`\n${asserts - failures.length} of ${asserts} checks passed` + (callsOut ? `; ${allCalls.length} page calls written to ${callsOut}` : ''));
if (failures.length) { for (const f of failures) console.log('  failed: ' + f); process.exit(1); }
process.exit(0);
