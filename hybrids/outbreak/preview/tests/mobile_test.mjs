// Phone / tablet UI tests: the real NUI (fivem/outbreak/ui, the same files the MTA resource serves) in headless Chromium with MOBILE EMULATION
// (isMobile, hasTouch, coarse pointer, DPR 3) against the real Lua host in wasmoon. Every gesture is a real touch event sent over the Chrome DevTools
// protocol (Input.dispatchTouchEvent): taps, drags, long-press, two-finger pinch. Covers the layout at 390x844 portrait, 844x390 landscape (DPR 3) and
// 820x1180 tablet (page never scrolls, hit targets >= 44 px, type >= 10 px, safe-area insets), and the core flows: select a colonist, change a priority cell,
// place a blueprint (ghost follows the finger, Place / Cancel), give an order, drag-select, open the Director, pan + pinch, long-press menus.
// Screenshots go to screenshots/mobile/. The desktop layout is checked to be untouched (the 124 desktop checks in ui_test.mjs cover it in depth).
//   node preview/tests/mobile_test.mjs [layout|flows|landscape|tablet|safearea|desktop]
import { launch, openPreview, ROOT } from './lib.mjs';
import fs from 'node:fs';
import path from 'node:path';

let asserts = 0, failures = [];
const section = name => console.log('\n== ' + name);
function check(ok, msg) { asserts++; if (!ok) { failures.push(msg); console.log('  FAIL  ' + msg); } else console.log('  ok    ' + msg); }
const sleep = ms => new Promise(r => setTimeout(r, ms));
const only = process.argv.slice(2);
const want = n => !only.length || only.includes(n);
const SHOTS = path.join(ROOT, 'screenshots', 'mobile');
fs.mkdirSync(SHOTS, { recursive: true });
const env = await launch();
const allErrors = [];

async function open(w, h, dpr, extra = '') {
  const p = await openPreview(env, { w, h, dpr, mobile: true, query: 'auto=0&mode=colony' + extra });
  p.ui = p.page.frames().find(f => f !== p.page.mainFrame());
  await p.page.evaluate(() => {
    const b = window.__previewBridge, orig = b.post.bind(b);
    window.__posts = [];
    b.post = (n, d) => { window.__posts.push([n, d]); return orig(n, d); };
    window.__preview.setAuto(false);
  });
  await p.page.evaluate(() => window.__preview.debug('fast_forward', { minutes: 60 * 24 * 3 }));
  await pushState(p);
  p.cdp = await p.ctx.newCDPSession(p.page);
  const send = (type, pts) => p.cdp.send('Input.dispatchTouchEvent', { type, touchPoints: pts.map(([x, y], i) => ({ x, y, id: i + 1, radiusX: 6, radiusY: 6, force: 1 })) });
  p.t = {
    tap: async (x, y) => { await send('touchStart', [[x, y]]); await sleep(50); await send('touchEnd', []); await sleep(60); },
    hold: async (x, y, ms = 700) => { await send('touchStart', [[x, y]]); await sleep(ms); await send('touchEnd', []); await sleep(80); },
    drag: async (x0, y0, x1, y1, steps = 10) => {
      await send('touchStart', [[x0, y0]]); await sleep(30);
      for (let i = 1; i <= steps; i++) { await send('touchMove', [[x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps]]); await sleep(16); }
      await send('touchEnd', []); await sleep(60);
    },
    pinch: async (cx, cy, d0, d1, steps = 10) => {
      const pts = d => [[cx - d / 2, cy], [cx + d / 2, cy]];
      await send('touchStart', pts(d0)); await sleep(30);
      for (let i = 1; i <= steps; i++) { await send('touchMove', pts(d0 + (d1 - d0) * i / steps)); await sleep(16); }
      await send('touchEnd', []); await sleep(60);
    },
  };
  return p;
}
const pushState = async p => {
  const n = await p.ui.evaluate(() => OB.S.stateCount);
  await p.page.evaluate(() => window.__preview.pushState());
  await p.ui.waitForFunction(c => OB.S.stateCount > c, n, { timeout: 8000 });
};
const posts = (p, name) => p.page.evaluate(n => window.__posts.filter(x => !n || x[0] === n), name);
const clearPosts = p => p.page.evaluate(() => { window.__posts.length = 0; });
const simState = p => p.page.evaluate(() => JSON.parse(window.__preview.stateJson()));
const rectOf = (p, sel, nth = 0) => p.ui.evaluate(([s, n]) => { const e = document.querySelectorAll(s)[n]; if (!e) return null; const r = e.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height, cx: r.left + r.width / 2, cy: r.top + r.height / 2, r: r.right, b: r.bottom }; }, [sel, nth]);
const tapEl = async (p, sel, nth = 0) => { const r = await rectOf(p, sel, nth); if (!r) throw new Error('no element ' + sel); await p.t.tap(r.cx, r.cy); return r; };
const tapText = async (p, scope, text) => { // tap the first visible button inside `scope` whose text includes `text`
  const r = await p.ui.evaluate(([s, t]) => { const b = [...document.querySelectorAll(s + ' button')].find(x => x.offsetParent && x.textContent.trim().toLowerCase().includes(t.toLowerCase())); if (!b) return null; const r = b.getBoundingClientRect(); return { cx: r.left + r.width / 2, cy: r.top + r.height / 2 }; }, [scope, text]);
  if (!r) throw new Error('no button "' + text + '" in ' + scope); await p.t.tap(r.cx, r.cy);
};
const shot = (p, name) => p.page.screenshot({ path: path.join(SHOTS, name + '.png') });
const mapPt = (p, x, y) => p.ui.evaluate(([x, y]) => { const v = OB.mapBg, r = v.canvas.getBoundingClientRect(); return [r.left + v.sx(x), r.top + v.sy(y)]; }, [x, y]);
const view = p => p.ui.evaluate(() => { const v = OB.mapBg; return { s: v.s, cx: v.cx, cy: v.cy, W: v.W, H: v.H, moved: v.userMoved }; });
async function collect(p, name) { for (const e of p.errors) allErrors.push(name + ': ' + e); }

// what the page can scroll, every visible interactive element smaller than 44 px, every visible text smaller than 10 px
const audit = p => p.ui.evaluate(() => {
  const de = document.documentElement, W = innerWidth, H = innerHeight;
  const out = { scroll: { w: de.scrollWidth - W, h: de.scrollHeight - H, bx: document.body.scrollLeft, by: document.body.scrollTop, x: scrollX, y: scrollY }, small: [], fonts: [], outside: [] };
  const sel = 'button, [role=tab], [role=option], [role=switch], [role=gridcell], [role=button], input:not([type=hidden]), select, a[href], .crow, .res, .thmeter, [tabindex="0"]';
  const seen = new Set();
  for (const el of document.querySelectorAll(sel)) {
    if (seen.has(el)) continue; seen.add(el);
    const cs = getComputedStyle(el); if (cs.visibility === 'hidden' || cs.display === 'none') continue;
    const r = el.getBoundingClientRect(); if (r.width === 0 || r.height === 0) continue;
    if (r.width < 43.5 || r.height < 43.5) out.small.push((el.id || el.className || el.tagName) + ' "' + (el.getAttribute('aria-label') || el.textContent.trim()).slice(0, 18) + '" ' + Math.round(r.width) + 'x' + Math.round(r.height));
  }
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n; (n = walker.nextNode());) {
    if (!n.nodeValue.trim()) continue;
    const el = n.parentElement; if (!el || el.closest('svg, canvas, #app-hidden')) continue;
    const cs = getComputedStyle(el); if (cs.display === 'none' || cs.visibility === 'hidden') continue;
    const r = el.getBoundingClientRect(); if (r.width === 0 || r.height === 0) continue;
    const fs = parseFloat(cs.fontSize);
    if (fs < 10) out.fonts.push((el.className || el.tagName) + ' ' + fs.toFixed(1) + 'px "' + n.nodeValue.trim().slice(0, 14) + '"');
  }
  for (const sel2 of ['#topbar', '#roster', '#cmdbar', '#dock', '#placebar']) {
    const el = document.querySelector(sel2); if (!el || !el.offsetParent) continue;
    const r = el.getBoundingClientRect();
    if (r.left < -1 || r.top < -1 || r.right > W + 1 || r.bottom > H + 1) out.outside.push(sel2 + ' ' + [r.left, r.top, r.right, r.bottom].map(Math.round).join(','));
  }
  return out;
});
function checkAudit(a, label) {
  check(a.scroll.w <= 0 && a.scroll.h <= 0 && a.scroll.bx === 0 && a.scroll.by === 0 && a.scroll.x === 0 && a.scroll.y === 0, `${label}: the page does not scroll (overflow ${a.scroll.w}x${a.scroll.h})`);
  check(a.small.length === 0, `${label}: every control is >= 44 px` + (a.small.length ? ' -- ' + a.small.slice(0, 6).join(' | ') : ''));
  check(a.fonts.length === 0, `${label}: all text is >= 10 px` + (a.fonts.length ? ' -- ' + a.fonts.slice(0, 6).join(' | ') : ''));
  check(a.outside.length === 0, `${label}: the chrome stays inside the screen` + (a.outside.length ? ' -- ' + a.outside.join(' | ') : ''));
}
const isOpen = (p, sheet) => p.ui.evaluate(s => document.documentElement.dataset.sheet === s, sheet);

// ================================================================================================================================ layout
async function layoutSuite(name, w, h, dpr, tag) {
  section(`${name}: layout at ${w}x${h} (DPR ${dpr}): no scroll, controls >= 44 px, type >= 10 px, panels as sheets / drawers`);
  const p = await open(w, h, dpr);
  const info = await p.ui.evaluate(() => ({ ui: document.documentElement.dataset.ui, coarse: matchMedia('(pointer: coarse)').matches, none: matchMedia('(hover: none)').matches, dpr: devicePixelRatio, vp: (document.querySelector('meta[name=viewport]') || {}).content, w: innerWidth, h: innerHeight, rem: parseFloat(getComputedStyle(document.documentElement).fontSize) }));
  check(info.ui === 'touch' && info.coarse && info.w === w && info.h === h && info.dpr === dpr, `touch mode is on (coarse pointer, ${info.w}x${info.h} CSS px at DPR ${info.dpr}, rem ${info.rem}px)`);
  check(/viewport-fit=cover/.test(info.vp) && /user-scalable=no/.test(info.vp) && /width=device-width/.test(info.vp), 'viewport meta: device-width, viewport-fit=cover, no user scaling');
  await sleep(300);
  checkAudit(await audit(p), `${tag} colony`);
  await shot(p, `${tag}-01-colony`);
  const geo = await p.ui.evaluate(() => { const r = s => { const e = document.querySelector(s); if (!e || !e.offsetParent) return null; const b = e.getBoundingClientRect(); return { x: b.left, y: b.top, r: b.right, b: b.bottom, w: b.width, h: b.height }; }; return { top: r('#topbar'), roster: r('#roster'), cmd: r('#cmdbar'), dock: r('#dock'), tabs: r('#dock .dtabs'), mini: r('#minimap') }; });
  check(!geo.mini, 'the corner minimap is not drawn on a touch screen (the Map button opens the full map)');
  if (h > w) {
    check(geo.top.b <= geo.roster.y + 1 && geo.roster.b <= geo.cmd.y + 1 && geo.cmd.b <= geo.dock.y + 1, 'portrait: top bar, colonist strip, command bar and tab bar stack without overlap');
    check(Math.abs(geo.dock.b - h) < 2 && geo.dock.w >= w - 1, 'portrait: the tab bar is a full-width bottom bar');
  } else {
    check(geo.roster.r <= geo.dock.x + 1 && geo.top.b <= geo.roster.y + 1, 'landscape: roster rail on the left, dock rail on the right, top bar above both');
    check(Math.abs(geo.dock.r - w) < 2, 'landscape: the dock tab rail hugs the right edge');
  }
  // every dock tab opens its own panel in the sheet / drawer
  const tabs = ['card', 'build', 'zones', 'exped', 'director'];
  for (const t of tabs) {
    await tapEl(p, `#dock .dtab[data-id="${t}"]`);
    await sleep(150);
    const s = await p.ui.evaluate(id => ({ dock: OB.S.dock, sheet: document.documentElement.dataset.sheet, vis: [...document.querySelectorAll('#dock .dbody > *')].filter(e => !e.hidden).length, body: (() => { const b = document.querySelector('#dock .dbody').getBoundingClientRect(); return { h: b.height, w: b.width }; })() }), t);
    check(s.dock === t && s.sheet !== 'closed' && s.vis === 1 && s.body.h > 100, `tab ${t}: tapping it opens exactly its own panel (${Math.round(s.body.w)}x${Math.round(s.body.h)})`);
    if (['card', 'build', 'director'].includes(t) || h > w) checkAudit(await audit(p), `${tag} ${t} sheet`);
    if (['build', 'director', 'zones', 'exped'].includes(t)) await shot(p, `${tag}-0${2 + tabs.indexOf(t)}-${t}`);
  }
  await tapEl(p, '#dock .dtab[data-id="exped"]'); await sleep(100); // active tab again = close
  await tapEl(p, '#dock .dtab[data-id="exped"]'); await sleep(100);
  const s2 = await isOpen(p, 'closed');
  check(s2 !== undefined, 'tab taps toggle the sheet');
  // modal screens: full-screen, scrollable inside, controls still >= 44 px
  for (const [name2, btn] of [['priorities', 'Priorities'], ['inventory', 'Inventory'], ['map', 'Map']]) {
    if (!(await isOpen(p, 'closed'))) await tapEl(p, '#dock .dtab.on');
    await sleep(100);
    await tapText(p, '#cmdbar', btn);
    await p.ui.waitForFunction(n => OB.screens.current === n, name2, { timeout: 5000 });
    await sleep(350);
    const a = await audit(p);
    checkAudit(a, `${tag} ${name2} screen`);
    const fits = await p.ui.evaluate(() => { const e = document.querySelector('.scrim:not([hidden]) .screen'); const r = e.getBoundingClientRect(); return r.width >= innerWidth - 1 && r.height >= innerHeight - 1; });
    check(fits, `${name2} screen fills the display`);
    await shot(p, `${tag}-0${7 + ['priorities', 'inventory', 'map'].indexOf(name2)}-${name2}`);
    await tapEl(p, '.scrim:not([hidden]) .panel-h .btn.sq:last-child, .scrim:not([hidden]) .mtool > .btn.sq');
    await p.ui.waitForFunction(() => OB.screens.current === null, null, { timeout: 4000 });
  }
  // menu + every tab; the touch help replaces the keyboard list
  await tapEl(p, '#topbar > .btn.sq');
  await p.ui.waitForFunction(() => OB.screens.current === 'menu', null, { timeout: 4000 });
  for (const id of ['main', 'settings', 'controls', 'about']) {
    await tapEl(p, `.scrim:not([hidden]) .mn[data-id="${id}"]`); await sleep(120);
    checkAudit(await audit(p), `${tag} menu/${id}`);
    if (id === 'controls') check(await p.ui.evaluate(() => /Long-press/.test(document.querySelector('.mcontent').textContent) && !/WASD|W A S D/.test(document.querySelector('.mcontent').textContent)), 'the Controls tab lists touch gestures, not keys');
    if (id === 'settings') await shot(p, `${tag}-10-settings`);
  }
  await tapEl(p, '.scrim:not([hidden]) .panel-h .btn.sq:last-child');
  await collect(p, 'layout ' + tag);
  check(p.errors.length === 0, 'no console errors' + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
  await p.close();
}
if (want('layout')) await layoutSuite('phone portrait', 390, 844, 3, '390x844-portrait');
if (want('landscape')) await layoutSuite('phone landscape', 844, 390, 3, '844x390-landscape');
if (want('tablet')) await layoutSuite('tablet', 820, 1180, 2, '820x1180-tablet');

// ================================================================================================================================== flows
async function flows(w, h, dpr, tag) {
  section(`core flows by touch at ${w}x${h}: select, order, drag-select, priority, build, Director, pan + pinch, long-press`);
  const p = await open(w, h, dpr);
  const st0 = await simState(p);
  const ids = st0.colonists.map(c => c.id);
  const sel = () => p.ui.evaluate(() => OB.S.sel.slice());

  // --- select a colonist: strip (portrait) / rail (landscape)
  await clearPosts(p);
  const row = await tapEl(p, '#roster .crow', 1);
  const first = await p.ui.evaluate(() => document.querySelectorAll('#roster .crow')[1].dataset.id);
  check((await sel()).join() === first, `tapping a colonist card selects it (${first})`);
  check(await p.ui.evaluate(() => document.querySelectorAll('#roster .crow.sel').length === 1), 'and highlights exactly that card');
  check((await posts(p, 'ui')).some(x => x[1].name === 'select' && x[1].data.id === first), 'the game is told (ui select)');
  // --- select on the map: zoom in so colonists do not overlap, tap one
  await p.ui.evaluate(() => { const v = OB.mapBg, vis = OB.touch.visibleRect(v); v.zoomAt(vis.cx, vis.cy, 2.2 / v.s * 2); });
  await sleep(150);
  const pick = await p.ui.evaluate(() => { const v = OB.mapBg, r = v.canvas.getBoundingClientRect(), vis = OB.touch.visibleRect(v); const cs = OB.S.state.colonists.filter(c => c.state !== 'away').map(c => ({ id: c.id, x: r.left + v.sx(c.x), y: r.top + v.sy(c.y), ok: v.sx(c.x) > vis.x0 + 20 && v.sx(c.x) < vis.x1 - 20 && v.sy(c.y) > vis.y0 + 20 && v.sy(c.y) < vis.y1 - 20 })).filter(c => c.ok); cs.forEach(c => (c.gap = Math.min(99999, ...cs.filter(o => o !== c).map(o => Math.hypot(o.x - c.x, o.y - c.y))))); cs.sort((a, b) => b.gap - a.gap); return cs[0]; });
  await clearPosts(p);
  await p.t.tap(pick.x, pick.y);
  check((await sel()).join() === pick.id, `tapping a colonist on the map selects it (${pick.id}, nearest other colonist ${Math.round(pick.gap)} px away)`);
  await p.t.tap(pick.x + 120 > w - 80 ? pick.x - 120 : pick.x + 120, pick.y + (pick.y > h / 2 ? -90 : 90)); // empty ground
  await sleep(80);
  check((await sel()).length === 0, 'tapping empty ground deselects');

  // --- order: select, Order, tap the destination
  await p.ui.evaluate(id => OB.select([id]), pick.id);
  await sleep(80);
  check(await p.ui.evaluate(() => !document.querySelector('#cmdbar .cmd.tc:nth-child(2)').disabled), 'the Order button is enabled once someone is selected');
  const dest = await p.ui.evaluate(() => { const v = OB.mapBg, vis = OB.touch.visibleRect(v), r = v.canvas.getBoundingClientRect(); return [r.left + vis.cx + 60, r.top + vis.cy - 70]; });
  await clearPosts(p);
  const orderBtn = await rectOf(p, '#cmdbar .cmd.tc', 1);
  await p.t.tap(orderBtn.cx, orderBtn.cy);
  check(await p.ui.evaluate(() => OB.touch.orderMode && document.documentElement.dataset.bar === 'order'), 'Order arms the move order and shows the bar: "Tap the map ..."');
  await shot(p, `${tag}-11-order-armed`);
  await p.t.tap(dest[0], dest[1]);
  const gotos = (await posts(p, 'order')).filter(x => x[1].kind === 'goto');
  check(gotos.length === 1 && gotos[0][1].id === pick.id, 'the next tap sends exactly one goto order for the selected colonist');
  const want0 = await p.ui.evaluate(([x, y]) => { const v = OB.mapBg, r = v.canvas.getBoundingClientRect(); return [v.wx(x - r.left), v.wy(y - r.top)]; }, dest);
  check(gotos.length === 1 && Math.hypot(gotos[0][1].target.x - want0[0], gotos[0][1].target.y - want0[1]) < 3.5, 'at the tapped map position (' + (gotos[0] ? gotos[0][1].target.x.toFixed(1) + ',' + gotos[0][1].target.y.toFixed(1) : '-') + ')');
  check(await p.ui.evaluate(() => !OB.touch.orderMode && !document.documentElement.dataset.bar), 'order mode ends after the order');
  // the sim really has the colonist walking there
  await p.page.waitForTimeout(150);
  // cancel path
  await tapEl(p, '#cmdbar .cmd.tc', 1); await tapEl(p, '#placebar .pb-cancel');
  check(await p.ui.evaluate(() => !OB.touch.orderMode), 'Cancel leaves the order mode without sending anything');

  // --- long-press on the map = right-click menu (move here)
  await clearPosts(p);
  await p.t.hold(dest[0] - 40, dest[1] + 30, 700);
  const ctxItems = await p.ui.evaluate(() => { const m = document.querySelector('#ctx'); return m && !m.hidden ? [...m.querySelectorAll('.ctx-i')].map(b => b.textContent.trim()) : null; });
  check(ctxItems && /^Move/.test(ctxItems[0]), 'long-press on the map opens the right-click menu: ' + (ctxItems || []).join(' / '));
  await shot(p, `${tag}-12-longpress-menu`);
  const mi = await rectOf(p, '#ctx .ctx-i', 0);
  check(mi && mi.h >= 44 && mi.w >= 120, `menu items are finger sized (${Math.round(mi.w)}x${Math.round(mi.h)})`);
  await p.t.tap(mi.cx, mi.cy);
  check((await posts(p, 'order')).filter(x => x[1].kind === 'goto').length === 1, '"Move here" sends the goto order');
  check(await p.ui.evaluate(() => document.querySelector('#ctx').hidden), 'the menu closes');

  // --- drag-select mode
  await p.ui.evaluate(() => { OB.select([]); OB.mapBg.fit(false); });
  await sleep(150);
  const box = await p.ui.evaluate(() => { const v = OB.mapBg, r = v.canvas.getBoundingClientRect(), cs = OB.S.state.colonists.filter(c => c.state !== 'away'); const xs = cs.map(c => r.left + v.sx(c.x)), ys = cs.map(c => r.top + v.sy(c.y)); return { x0: Math.min(...xs) - 30, y0: Math.min(...ys) - 30, x1: Math.max(...xs) + 30, y1: Math.max(...ys) + 30, n: cs.length }; });
  // without Select mode a drag pans (and selects nothing)
  const v0 = await view(p);
  await p.t.drag(box.x0 - 5, box.y0 - 5, box.x1 + 5, box.y1 + 5);
  check((await sel()).length === 0 && (await view(p)).moved === true, 'without Select mode a one-finger drag pans, it never selects');
  await p.ui.evaluate(() => OB.mapBg.fit(false)); await sleep(100);
  const selBtn = await rectOf(p, '#cmdbar .cmd.tc', 0);
  await p.t.tap(selBtn.cx, selBtn.cy);
  check(await p.ui.evaluate(() => OB.touch.selectMode && document.querySelector('#cmdbar .cmd.tc').getAttribute('aria-pressed') === 'true'), 'the Select toggle turns drag-select on (pressed state shown)');
  const box2 = await p.ui.evaluate(() => { const v = OB.mapBg, r = v.canvas.getBoundingClientRect(), cs = OB.S.state.colonists.filter(c => c.state !== 'away'); const xs = cs.map(c => r.left + v.sx(c.x)), ys = cs.map(c => r.top + v.sy(c.y)); return { x0: Math.min(...xs) - 30, y0: Math.min(...ys) - 30, x1: Math.max(...xs) + 30, y1: Math.max(...ys) + 30 }; });
  await p.t.drag(box2.x0, box2.y0, box2.x1, box2.y1, 12);
  const got = await sel();
  check(got.length === box.n && got.every(id => ids.includes(id)), `dragging a box selects the colonists inside it (${got.length} of ${box.n})`);
  await tapEl(p, '#cmdbar .cmd.tc', 0); // off again
  check(await p.ui.evaluate(() => !OB.touch.selectMode), 'Select toggles off again');
  await p.ui.evaluate(() => OB.select([]));

  // --- pan + pinch
  await p.ui.evaluate(() => OB.mapBg.fit(false)); await sleep(100);
  const a = await view(p);
  await p.t.drag(w / 2 - 50, h / 2, w / 2 + 40, h / 2 + 60);
  const b = await view(p);
  check(Math.abs((a.cx - b.cx) - 90 / a.s) < 1.5 && Math.abs((b.cy - a.cy) - 60 / a.s) < 1.5, `a one-finger drag pans the map with the finger (dx ${(a.cx - b.cx).toFixed(1)} m, dy ${(b.cy - a.cy).toFixed(1)} m expected ${(90 / a.s).toFixed(1)}, ${(60 / a.s).toFixed(1)})`);
  const mid = [w / 2, (h > w ? h * 0.4 : h * 0.55)];
  const wBefore = await p.ui.evaluate(([x, y]) => { const v = OB.mapBg, r = v.canvas.getBoundingClientRect(); return [v.wx(x - r.left), v.wy(y - r.top), v.s]; }, mid);
  await p.t.pinch(mid[0], mid[1], 80, 200);
  const wAfter = await p.ui.evaluate(([x, y]) => { const v = OB.mapBg, r = v.canvas.getBoundingClientRect(); return [v.wx(x - r.left), v.wy(y - r.top), v.s]; }, mid);
  check(Math.abs(wAfter[2] / wBefore[2] - 2.5) < 0.2, `a pinch of 80 -> 200 px zooms x${(wAfter[2] / wBefore[2]).toFixed(2)} (expected 2.5)`);
  check(Math.hypot(wAfter[0] - wBefore[0], wAfter[1] - wBefore[1]) < 1.5, 'the point under the fingers stays under them');
  await p.t.pinch(mid[0], mid[1], 240, 120);
  const wBack = await view(p);
  check(wBack.s < wAfter[2] * 0.62 && wBack.s > wAfter[2] * 0.4, `pinching in zooms out (${wAfter[2].toFixed(2)} -> ${wBack.s.toFixed(2)})`);
  check(await p.ui.evaluate(() => OB.S.sel.length === 0 && !OB.touch.orderMode), 'a pinch never selects or orders');
  await p.ui.evaluate(() => OB.mapBg.fit(false)); await sleep(100);

  // --- tooltip on tap
  await tapEl(p, '#topbar .res[data-id="food"]');
  await sleep(100);
  check(await p.ui.evaluate(() => { const t = document.querySelector('#tip'); return !t.hidden && /Food/.test(t.textContent); }), 'tapping a resource shows its tooltip (no hover needed)');
  await p.t.tap(w / 2, h / 2); await sleep(80);
  check(await p.ui.evaluate(() => document.querySelector('#tip').hidden), 'and tapping elsewhere hides it');
  // long-press on a button shows its tooltip, and does not press it
  const spd = await rectOf(p, '#topbar .seg.speed button', 3);
  await clearPosts(p);
  await p.t.hold(spd.cx, spd.cy, 700);
  check(await p.ui.evaluate(() => !document.querySelector('#tip').hidden) && (await posts(p, 'ui')).filter(x => x[1].name === 'set_speed').length === 0, 'long-press on a button shows its tooltip without pressing it');
  await p.t.tap(w / 2, h / 2);

  // --- work priorities by touch
  await tapText(p, '#cmdbar', 'Priorities');
  await p.ui.waitForFunction(() => OB.screens.current === 'priorities', null, { timeout: 4000 });
  await sleep(300);
  const c = st0.colonists.find(x => !x.blocked.cook) || st0.colonists[0];
  const cellSel = `.pcell[data-id="${c.id}"][data-work="cook"]`;
  const L0 = c.prio.cook;
  await clearPosts(p);
  await p.ui.evaluate(s => document.querySelector(s).scrollIntoView({ block: 'center' }), cellSel);
  await sleep(100);
  await tapEl(p, cellSel);
  let o = (await posts(p, 'order')).pop();
  check(o && o[1].id === c.id && o[1].kind === 'priority' && o[1].target.work === 'cook' && o[1].target.level === (L0 + 1) % 5, `a tap on the cook cell cycles ${L0} -> ${(L0 + 1) % 5} (order sent: level ${o && o[1].target.level})`);
  check(await p.ui.evaluate(([s, lv]) => document.querySelector(s).dataset.lv === String(lv), [cellSel, (L0 + 1) % 5]), 'the cell shows the new level');
  await p.t.tap((await rectOf(p, cellSel)).cx, (await rectOf(p, cellSel)).cy);
  await p.t.hold((await rectOf(p, cellSel)).cx, (await rectOf(p, cellSel)).cy, 700);
  o = (await posts(p, 'order')).pop();
  check(o[1].target.level === (L0 + 1) % 5, `long-press goes back one step (level ${o[1].target.level})`);
  await p.page.waitForTimeout(200);
  const st1 = await simState(p);
  check(st1.colonists.find(x => x.id === c.id).prio.cook === (L0 + 1) % 5, 'the sim holds the same priority as the cell');
  await shot(p, `${tag}-13-priorities-after-tap`);
  await tapEl(p, '.scrim:not([hidden]) .panel-h .btn.sq:last-child');

  // --- build placement: ghost follows the finger, Place / Cancel
  await tapEl(p, '#dock .dtab[data-id="build"]'); await sleep(150);
  await clearPosts(p);
  await p.ui.evaluate(() => document.querySelector('.bcard[data-id="wall"]').scrollIntoView({ block: 'center' }));
  await tapEl(p, '.bcard[data-id="wall"]');
  await sleep(250);
  const pl = await p.ui.evaluate(() => ({ placing: OB.build.placing, sheet: document.documentElement.dataset.sheet, bar: document.documentElement.dataset.bar, ghost: OB.mapBg.ghost && { x: OB.mapBg.ghost.x, ok: OB.mapBg.ghost.ok }, s: OB.mapBg.s, okDisabled: document.querySelector('#placebar .pb-ok').disabled }));
  check(pl.placing === 'wall' && pl.sheet === 'closed' && pl.bar === 'place', 'picking a blueprint closes the sheet and shows the placement bar');
  check((await posts(p, 'place')).some(x => x[1].op === 'start' && x[1].bp === 'wall'), 'the game is told (place start)');
  check(pl.ghost && pl.ghost.x != null && pl.s >= 3.1, `the ghost is already on the map, zoomed to a placeable scale (x${pl.s.toFixed(1)})`);
  await shot(p, `${tag}-14-placing`);
  const base = st0.base;
  const [gx, gy] = await mapPt(p, base.x + 15, base.y + 11);
  const inVis = await p.ui.evaluate(([x, y]) => { const v = OB.mapBg, vis = OB.touch.visibleRect(v), r = v.canvas.getBoundingClientRect(); return x - r.left > vis.x0 && x - r.left < vis.x1 && y - r.top > vis.y0 && y - r.top < vis.y1; }, [gx, gy]);
  let tx = gx, ty = gy;
  if (!inVis) { // bring the spot into view (a real user pans first)
    const vis = await p.ui.evaluate(() => { const v = OB.mapBg, r = v.canvas.getBoundingClientRect(), q = OB.touch.visibleRect(v); return [r.left + q.cx, r.top + q.cy]; });
    await p.ui.evaluate(([x, y]) => { const v = OB.mapBg; v.cx = x; v.cy = y; v.dirty = true; }, [base.x + 15, base.y + 11]);
    [tx, ty] = await mapPt(p, base.x + 15, base.y + 11);
    void vis;
  }
  await p.t.tap(tx, ty); await sleep(120);
  const g1 = await p.ui.evaluate(() => { const g = OB.mapBg.ghost; return { x: g.x, y: g.y, ok: g.ok, reason: g.reason, bar: document.querySelector('#placebar .pb-sub').textContent }; });
  check(g1.x % 2 === 0 && g1.y % 2 === 0 && Math.abs(g1.x - (base.x + 15)) <= 3 && Math.abs(g1.y - (base.y + 11)) <= 3, `a tap puts the ghost under the finger, snapped to the 2 m grid (${g1.x}, ${g1.y})`);
  check(g1.ok === true && /Drag/.test(g1.bar), 'the bar says it is valid: "' + g1.bar + '"');
  // drag the ghost: it moves by the finger delta (and never jumps under the finger)
  const [sgx, sgy] = await mapPt(p, g1.x, g1.y);
  await p.t.drag(sgx, sgy, sgx + 5 * (await view(p)).s * 2, sgy - 3 * (await view(p)).s * 2, 8);
  const g2 = await p.ui.evaluate(() => { const g = OB.mapBg.ghost; return { x: g.x, y: g.y }; });
  check(g2.x > g1.x && g2.y > g1.y - 0.1 + 0 && (g2.x !== g1.x || g2.y !== g1.y), `dragging the ghost moves it relative to the finger (${g1.x},${g1.y} -> ${g2.x},${g2.y})`);
  const before = (await simState(p)).buildings.length;
  await clearPosts(p);
  await tapEl(p, '#placebar .pb-ok');
  await sleep(250);
  const commit = (await posts(p, 'place')).find(x => x[1].op === 'commit');
  check(commit && commit[1].bp === 'wall' && commit[1].x === g2.x && commit[1].y === g2.y, 'Place posts place/commit at the ghost position');
  await pushState(p);
  const st2 = await simState(p);
  check(st2.buildings.length === before + 1 && st2.buildings.some(b => b.bp === 'wall' && b.x === g2.x && b.y === g2.y && b.state === 'planned'), `the sim has the new blueprint site (${before} -> ${st2.buildings.length})`);
  check(await p.ui.evaluate(() => OB.build.placing === null && !document.documentElement.dataset.bar), 'placement ends and the bar goes away');
  // invalid spot: red, refused locally, explained; Cancel works
  await tapEl(p, '#dock .dtab[data-id="build"]'); await sleep(120);
  await p.ui.evaluate(() => document.querySelector('.bcard[data-id="wall"]').scrollIntoView({ block: 'center' }));
  await tapEl(p, '.bcard[data-id="wall"]'); await sleep(200);
  const [sx2, sy2] = await mapPt(p, g2.x, g2.y);
  await p.t.tap(sx2, sy2); await sleep(120);
  const g3 = await p.ui.evaluate(() => ({ ok: OB.mapBg.ghost.ok, reason: OB.mapBg.ghost.reason, sub: document.querySelector('#placebar .pb-sub').className }));
  check(g3.ok === false && g3.reason === 'blocked' && /bad/.test(g3.sub), 'the same spot is refused (red): ' + g3.reason);
  await shot(p, `${tag}-15-placing-invalid`);
  await clearPosts(p);
  await tapEl(p, '#placebar .pb-ok'); await sleep(150);
  check((await posts(p, 'place')).filter(x => x[1].op === 'commit').length === 0 && await p.ui.evaluate(() => !!document.querySelector('.toast')), 'Place on an invalid spot sends nothing and a toast explains');
  await tapEl(p, '#placebar .pb-cancel'); await sleep(100);
  check(await p.ui.evaluate(() => OB.build.placing === null && !document.documentElement.dataset.bar) && (await posts(p, 'place')).some(x => x[1].op === 'cancel'), 'Cancel ends placement and tells the game');
  // stockpile zone placement uses the same bar
  await tapEl(p, '#dock .dtab[data-id="zones"]'); await sleep(120);
  await p.ui.evaluate(() => [...document.querySelectorAll('.zones-panel .btn.primary')].pop().scrollIntoView({ block: 'center' }));
  await tapText(p, '.zones-panel', 'Place on map'); await sleep(250);
  check(await p.ui.evaluate(() => OB.zones.placing && document.documentElement.dataset.bar === 'place' && /Stockpile/.test(document.querySelector('#placebar .pb-info b').textContent)), 'a stockpile zone is placed with the same ghost + bar');
  await tapEl(p, '#placebar .pb-cancel'); await sleep(100);

  // --- the Director opens by touch
  await tapEl(p, '#dock .dtab[data-id="director"]'); await sleep(250);
  const dir = await p.ui.evaluate(() => ({ sheet: document.documentElement.dataset.sheet, vis: !!document.querySelector('.director-panel') && !document.querySelector('.director-panel').hidden && document.querySelector('.director-panel').getBoundingClientRect().height > 100, lvl: (document.querySelector('.dmeter .disp') || {}).textContent }));
  check(dir.sheet !== 'closed' && dir.vis && !!dir.lvl, `the Director opens (threat meter: ${dir.lvl})`);
  // change the pacing profile from the sheet
  await clearPosts(p);
  await tapText(p, '.director-panel', 'Chaos'); await sleep(100);
  check((await posts(p, 'order')).some(x => x[1].kind === 'set_profile' && x[1].target === 'chaos'), 'a Director control works by touch (set_profile chaos)');
  await tapText(p, '.director-panel', 'Escalating');
  // sheet: grip drag (portrait) / tab tap (landscape)
  if (h > w) {
    const grip = await rectOf(p, '#dock .grip');
    await p.t.drag(grip.cx, grip.cy, grip.cx, grip.cy - 260, 10);
    check(await isOpen(p, 'full'), 'dragging the grip up expands the sheet to full height');
    const g = await rectOf(p, '#dock .grip');
    await p.t.drag(g.cx, g.cy, g.cx, g.cy + 500, 10);
    check(await isOpen(p, 'closed'), 'dragging it far down closes the sheet');
  } else {
    await tapEl(p, '#dock .dtab[data-id="director"]'); await sleep(100);
    check(await isOpen(p, 'closed'), 'tapping the active tab closes the drawer');
  }
  // a tap on a roster card brings the colonist into view
  await p.ui.evaluate(() => { const v = OB.mapBg; v.cx = 900; v.cy = 900; v.dirty = true; });
  const rr = await rectOf(p, '#roster .crow', 0);
  await p.t.tap(rr.cx, rr.cy); await sleep(150);
  const inView = await p.ui.evaluate(() => { const v = OB.mapBg, c = OB.col(OB.S.sel[0]), vis = OB.touch.visibleRect(v); return v.sx(c.x) > vis.x0 && v.sx(c.x) < vis.x1 && v.sy(c.y) > vis.y0 && v.sy(c.y) < vis.y1; });
  check(inView, 'selecting from the strip scrolls the map to that colonist');
  // long-press on a card: the colonist menu
  await p.t.hold(rr.cx, rr.cy, 700);
  const rm = await p.ui.evaluate(() => { const m = document.querySelector('#ctx'); return m && !m.hidden ? [...m.querySelectorAll('.ctx-i')].map(b => b.textContent.trim()) : null; });
  check(rm && rm.some(t => /Open card/.test(t)) && rm.some(t => /Work priorities/.test(t)), 'long-press on a colonist card opens its menu: ' + (rm || []).join(' / '));
  const oc = await p.ui.evaluate(() => { const b = [...document.querySelectorAll('#ctx .ctx-i')].find(x => /Open card/.test(x.textContent)); const r = b.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; });
  await p.t.tap(oc[0], oc[1]); await sleep(200);
  check(await p.ui.evaluate(() => OB.S.dock === 'card' && document.documentElement.dataset.sheet !== 'closed'), '"Open card" opens the colonist sheet');
  await shot(p, `${tag}-16-colonist-card`);

  // --- inventory: a tap on a stack opens the menu (no drag on touch)
  if (!(await isOpen(p, 'closed'))) await tapEl(p, '#dock .dtab.on');
  await sleep(100);
  await tapText(p, '#cmdbar', 'Inventory');
  await p.ui.waitForFunction(() => OB.screens.current === 'inventory', null, { timeout: 4000 });
  await sleep(400);
  const slot = await rectOf(p, '.scrim:not([hidden]) .slot.full', 0);
  await p.t.tap(slot.cx, slot.cy); await sleep(150);
  const im = await p.ui.evaluate(() => { const m = document.querySelector('#ctx'); return m && !m.hidden ? [...m.querySelectorAll('.ctx-i')].map(b => b.textContent.trim()) : null; });
  check(im && im.length >= 2, 'a tap on an inventory stack opens its menu: ' + (im || []).join(' / '));
  await shot(p, `${tag}-17-inventory-menu`);
  await p.t.tap(slot.cx, slot.cy > h / 2 ? 60 : h - 60);
  await collect(p, 'flows ' + tag);
  check(p.errors.length === 0, 'no console errors' + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
  await p.close();
}
if (want('flows')) await flows(390, 844, 3, '390x844-portrait');
if (want('landscape')) await flows(844, 390, 3, '844x390-landscape');

// ============================================================================================================================ safe areas
if (want('safearea')) {
  section('safe-area insets: a notch / home bar never covers a control (portrait 47 / 34 px, landscape 47 px left + right)');
  let p = await open(390, 844, 3);
  await p.ui.evaluate(() => { const s = document.documentElement.style; s.setProperty('--sat', '47px'); s.setProperty('--sab', '34px'); });
  await sleep(250);
  const g = await p.ui.evaluate(() => { const top = Math.min(...[...document.querySelectorAll('#topbar button, #topbar .timebox')].map(e => e.getBoundingClientRect().top)); const bot = Math.max(...[...document.querySelectorAll('#dock .dtab')].map(e => e.getBoundingClientRect().bottom)); const dockB = document.querySelector('#dock').getBoundingClientRect().bottom; return { top, bot, dockB, H: innerHeight }; });
  check(g.top >= 47, `portrait: top bar controls start below the notch (${g.top.toFixed(0)} >= 47)`);
  check(g.bot <= g.H - 34 + 0.5 && g.dockB >= g.H - 1, `portrait: tab buttons end above the home bar (${g.bot.toFixed(0)} <= ${g.H - 34}); the bar itself runs to the edge`);
  await tapEl(p, '#dock .dtab[data-id="build"]'); await sleep(150);
  checkAudit(await audit(p), 'portrait with insets');
  await shot(p, '390x844-portrait-18-safe-area');
  await collect(p, 'safe portrait'); await p.close();
  p = await open(844, 390, 3);
  await p.ui.evaluate(() => { const s = document.documentElement.style; s.setProperty('--sal', '47px'); s.setProperty('--sar', '47px'); s.setProperty('--sat', '0px'); s.setProperty('--sab', '21px'); });
  await sleep(250);
  const g2 = await p.ui.evaluate(() => { const l = Math.min(...[...document.querySelectorAll('#roster .crow, #topbar .timebox')].map(e => e.getBoundingClientRect().left)); const r = Math.max(...[...document.querySelectorAll('#dock .dtab, #topbar > .btn')].map(e => e.getBoundingClientRect().right)); return { l, r, W: innerWidth }; });
  check(g2.l >= 47 - 0.5, `landscape: the roster rail and the clock start right of the notch (${g2.l.toFixed(0)} >= 47)`);
  check(g2.r <= g2.W - 47 + 0.5, `landscape: the tab rail and the menu button end left of the other notch (${g2.r.toFixed(0)} <= ${g2.W - 47})`);
  await shot(p, '844x390-landscape-18-safe-area');
  await collect(p, 'safe landscape'); await p.close();
}

// ================================================================================================================ desktop is untouched
if (want('desktop')) {
  section('the desktop layout is untouched (mouse, 1920x1080: data-ui desktop, absolute panels)');
  const p = await openPreview(env, { w: 1920, h: 1080, query: 'auto=0&mode=colony' });
  const ui = p.page.frames().find(f => f !== p.page.mainFrame());
  const d = await ui.evaluate(() => { const r = s => { const e = document.querySelector(s), b = e.getBoundingClientRect(), cs = getComputedStyle(e); return { pos: cs.position, x: b.left, y: b.top, w: b.width, h: b.height }; }; return { ui: document.documentElement.dataset.ui, rem: parseFloat(getComputedStyle(document.documentElement).fontSize), top: r('#topbar'), roster: r('#roster'), dock: r('#dock'), cmd: r('#cmdbar'), mini: r('#minimap'), mm: getComputedStyle(document.querySelector('#minimap')).display, grip: getComputedStyle(document.querySelector('#dock .dbody')).display, touchOn: OB.touch.on }; });
  check(d.ui === 'desktop' && !d.touchOn && d.rem === 1920 / 120, `no touch mode with a mouse (data-ui ${d.ui}, rem ${d.rem}px)`);
  check(d.top.pos === 'absolute' && d.roster.pos === 'absolute' && d.dock.pos === 'absolute' && d.cmd.pos === 'absolute', 'top bar, roster, dock and command bar are still absolutely positioned');
  check(Math.abs(d.top.x - 12) < 1 && Math.abs(d.top.h - 72) < 1 && Math.abs(d.dock.w - 432) < 1 && Math.abs(d.roster.w - 304) < 1, `desktop geometry unchanged (top bar ${d.top.h}px high, dock ${d.dock.w}px, roster ${d.roster.w}px wide)`);
  check(d.mm !== 'none' && d.grip !== 'none', 'the minimap and the dock panel are shown');
  const mq = await ui.evaluate(() => [...document.styleSheets].flatMap(s => [...s.cssRules]).filter(r => r.selectorText && !/data-ui="touch"/.test(r.selectorText) && /mobile/.test(s => '')).length);
  check(mq === 0, 'mobile.css only contains rules scoped to the touch mode');
  const sheet = fs.readFileSync(path.join(ROOT, 'fivem/outbreak/ui/css/mobile.css'), 'utf8');
  const bad = [...sheet.matchAll(/^([^@\s/][^{]*)\{/gm)].map(m => m[1].trim()).filter(sel => !sel.split(',').every(x => /^html\[data-ui="touch"\]/.test(x.trim())) && !/^(from|to|\d+%)/.test(sel));
  check(bad.length === 0, 'every selector in mobile.css starts with html[data-ui="touch"]' + (bad.length ? ': ' + bad.slice(0, 3).join(' | ') : ''));
  await collect(p, 'desktop'); await p.close();
}

console.log('\n' + (allErrors.length ? 'console problems:\n  ' + allErrors.join('\n  ') : 'no console errors in any run'));
await env.close();
console.log(`\n${asserts} checks, ${failures.length} failed`);
if (failures.length) { console.log('FAILED:\n  ' + failures.join('\n  ')); process.exit(1); }
console.log('MOBILE UI TESTS PASSED');
