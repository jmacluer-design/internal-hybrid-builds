// Outbreak 3D: preview-shell integration. Everything here lives in the preview and never changes the shared NUI files (fivem/outbreak/ui/js): it reaches into the
// same-origin NUI iframe (window.OB) the way preview.js already does, and routes 3D clicks through the SAME functions the 2D tactical map (ui/js/map.js MapView) uses:
//   select -> OB.select, move order -> MapView.orderGoto -> OB.order(id,'goto'), build -> MapView.updateGhost/commitGhost -> OB.post('place') -> preview bridge -> Lua,
//   right click -> MapView.rightClick (context menu), camera keys / focus -> the same 'key' / 'focus' posts the game client receives.
// To do that the (hidden) 2D MapView instance keeps living: its draw is stopped and a few of its coordinate-dependent methods are replaced on the INSTANCE with 3D
// aware versions (the picked ground point is fed through a temporary view anchor so the original code runs unchanged). "2D" restores everything.
import { clamp, PI } from './util.js';

export function attachWorldUI(ctx) {
  const W = ctx.W, nui = ctx.nui, host = ctx.labels, api = { view: '3d', on: true, chase: false, pointer: null };
  let ui = null, OB = null, doc = null, patched = null, inited = false, selbox = null;
  const dyn = () => W.dyn, cam = () => W.camRig;

  const ready = () => { try { ui = nui.contentWindow; OB = ui.OB; doc = ui.document; return !!(OB && OB.S && OB.colony && OB.MapView && OB.h); } catch (e) { return false; } };
  const colonyMode = () => OB && OB.S.mode === 'colony';
  const typing = e => /^(INPUT|TEXTAREA|SELECT)$/.test((e.target && e.target.tagName) || '');
  const isWorld = t => { if (!t || !OB) return false; if (OB.screens && OB.screens.current) return false; return t === doc.documentElement || t === doc.body || t.id === 'app' || t.id === 'mapbg' || t.id === 'colony' || t.id === 'vignette' || (OB.mapBg && t === OB.mapBg.canvas) || (t.classList && t.classList.contains('selbox')); };

  // ------------------------------------------------------------------------------------------------ the hidden 2D view: anchor trick + instance patches
  function withAnchor(v, x, y, fn) { const o = [v.cx, v.cy, v.s]; v.cx = x; v.cy = y; v.s = 4.2; try { return fn(); } finally { v.cx = o[0]; v.cy = o[1]; v.s = o[2]; } }
  function patchView() {
    const v = OB.mapBg; if (!v || patched === v || !api.on) return; unpatchView();
    const proto = OB.MapView.prototype, save = {};
    for (const k of ['draw', 'center', 'fit', 'zoomAt', 'updateGhost', 'setState']) save[k] = Object.prototype.hasOwnProperty.call(v, k) ? v[k] : undefined;
    v.__w3d = save; patched = v;
    v.canvas.style.opacity = '0'; v.draw = function () { /* the 3D world is drawn instead */ };
    v.center = function (x, y, s) { cam().setTarget(x, -y, s ? clamp(630 / s, 18, 600) : undefined); this.cx = x; this.cy = y; };
    v.fit = function () { this.cx = 0; this.cy = 0; this.userMoved = false; };
    v.zoomAt = function () { /* wheel / pinch zoom the 3D camera */ };
    v.updateGhost = function (px, py) { const gp = dyn().groundPoint(px, py); if (!gp) return; withAnchor(this, gp.x, gp.y, () => proto.updateGhost.call(this, this.W / 2, this.H / 2)); };
    const orderGoto0 = proto.orderGoto;
    v.orderGoto = function (wx, wy) { orderGoto0.call(this, wx, wy); dyn().addPing(wx, wy); };
    if (OB.touch && OB.touch.on) v.canvas.style.touchAction = 'none';
  }
  function unpatchView() {
    const v = patched; if (!v) return; const s = v.__w3d || {};
    for (const k of ['draw', 'center', 'fit', 'zoomAt', 'updateGhost', 'orderGoto']) { if (s[k] === undefined) delete v[k]; else v[k] = s[k]; }
    v.canvas.style.opacity = ''; v.dirty = true; delete v.__w3d; patched = null; try { v.cx = cam().t.x; v.cy = -cam().t.z; v.userMoved = true; } catch (e) { /* camera gone */ }
  }

  // ------------------------------------------------------------------------------------------------ pointer handling (mouse + touch)
  const G = { mouse: null, touch: new Map(), g: null, hoverAt: 0, lastTap: null, space: false };
  const rect = (x0, y0, x1, y1) => ({ x: Math.min(x0, x1), y: Math.min(y0, y1), w: Math.abs(x1 - x0), h: Math.abs(y1 - y0) });
  function showBox(r) { if (!host) return; if (!selbox) { selbox = document.createElement('div'); selbox.className = 'w3d-selbox'; host.appendChild(selbox); } if (!r) { selbox.style.display = 'none'; return; } selbox.style.display = 'block'; selbox.style.left = r.x + 'px'; selbox.style.top = r.y + 'px'; selbox.style.width = r.w + 'px'; selbox.style.height = r.h + 'px'; }
  const ghostOn = () => !!(OB.mapBg && OB.mapBg.ghost && (OB.build.placing || (OB.zones && OB.zones.placing)));
  function moveGhost(px, py) { const v = OB.mapBg; if (v && v.ghost) { v.updateGhost(px, py); } }

  function clickAt(px, py, e, touch) {
    const hit = dyn().pick(px, py, touch); if (!hit) return;
    if (!colonyMode()) return;
    const shift = !!(e && e.shiftKey);
    if (hit.kind === 'colonist') {
      if (touch && OB.touch && OB.touch.selectMode) OB.select(OB.S.sel.indexOf(hit.id) >= 0 ? OB.S.sel.filter(id => id !== hit.id) : OB.S.sel.concat(hit.id), false); else OB.select([hit.id], shift);
      return hit;
    }
    if (hit.kind === 'building') { OB.emit('building_click', { kind: 'building', id: hit.id, bp: hit.bp }); return hit; }
    if (hit.kind === 'zone') { OB.colony.setDock('zones'); OB.emit('zone_click', { kind: 'zone', id: hit.id }); return hit; }
    if (!shift && !(touch && OB.touch && OB.touch.selectMode) && OB.S.sel.length) OB.select([]);
    return hit;
  }
  function contextAt(px, py, e) {
    const v = OB.mapBg; if (!v || !colonyMode()) return; const hit = dyn().pick(px, py, false); if (!hit || !hit.point) return;
    const extra = [];
    const tgt = hit.kind === 'horde' ? W.state.hordes.find(h => h.id === hit.id) : hit.kind === 'raid' ? W.state.raids.find(r => r.id === hit.id) : null;
    if (tgt) {
      const sel = OB.S.sel.length ? OB.S.sel : (W.state.colonists || []).map(c => c.id), bx = 0, by = 0, L = Math.hypot(tgt.x - bx, tgt.y - by) || 1, d = Math.max(0, L - 34), px2 = bx + (tgt.x - bx) / L * d, py2 = by + (tgt.y - by) / L * d;
      extra.push({ icon: 'swords', label: (hit.kind === 'horde' ? 'Draft ' : 'Draft ') + (OB.S.sel.length ? (OB.S.sel.length > 1 ? OB.S.sel.length + ' colonists' : OB.nick(OB.col(OB.S.sel[0]).name)) : 'everyone') + ' and engage ' + (hit.kind === 'horde' ? 'the horde (' + tgt.size + ')' : tgt.name || 'the raiders'), run: () => { sel.forEach((id, i) => { OB.order(id, 'draft', true); OB.order(id, 'goto', { x: px2 + (i % 3) * 2.2 - 2.2, y: py2 - Math.floor(i / 3) * 2.2, z: 0 }); }); dyn().addPing(px2, py2, [1, 0.4, 0.3]); } });
    }
    const c0 = OB.ctx; OB.ctx = (x, y, items) => c0.call(OB, x, y, items.concat(extra.length ? ['-'] : [], extra));
    try { withAnchor(v, hit.point.x, hit.point.y, () => v.rightClick(v.W / 2, v.H / 2, { clientX: e.clientX, clientY: e.clientY })); } finally { OB.ctx = c0; }
    dyn().addPing(hit.point.x, hit.point.y, [0.6, 0.8, 1]);
  }

  function onPointerDown(e) {
    if (!api.on || !isWorld(e.target)) return;
    const touch = e.pointerType === 'touch';
    e.stopImmediatePropagation(); e.preventDefault(); try { e.target.setPointerCapture(e.pointerId); } catch (err) { /* ignore */ }
    if (ctx.hideMenus) ctx.hideMenus(); if (OB.closeCtx) OB.closeCtx();
    const px = e.clientX, py = e.clientY;
    if (touch) return touchDown(e);
    G.mouse = { id: e.pointerId, btn: e.button, x0: px, y0: py, x: px, y: py, moved: false, shift: e.shiftKey, t0: performance.now(), mode: 'none' };
    const m = G.mouse;
    if (e.button === 1 || (e.button === 0 && G.space)) m.mode = 'pan';
    else if (e.button === 2) m.mode = 'rotate';
    else if (e.button === 0) m.mode = ghostOn() ? 'ghost' : colonyMode() ? 'select' : 'rotate';
    cam().dragging = m.mode === 'rotate' || m.mode === 'pan';
  }
  function onPointerMove(e) {
    if (!api.on) return; const touch = e.pointerType === 'touch';
    if (touch) { if (G.touch.has(e.pointerId)) { e.stopImmediatePropagation(); touchMove(e); } return; }
    const m = G.mouse; const px = e.clientX, py = e.clientY;
    if (!m || m.id !== e.pointerId) { // hover
      if (!isWorld(e.target)) { if (dyn().hover) dyn().setHover(null); return; }
      if (ghostOn()) { moveGhost(px, py); doc.body.style.cursor = 'crosshair'; }
      const now = performance.now(); if (now - G.hoverAt > 45) { G.hoverAt = now; const h = colonyMode() ? dyn().pick(px, py, false) : null; dyn().setHover(h && (h.kind === 'colonist' || h.kind === 'building') ? h : null); doc.body.style.cursor = ghostOn() ? 'crosshair' : h && (h.kind === 'colonist' || h.kind === 'building') ? 'pointer' : 'default'; }
      return;
    }
    e.stopImmediatePropagation();
    const dx = px - m.x, dy = py - m.y; m.x = px; m.y = py; if (!m.moved && Math.hypot(px - m.x0, py - m.y0) > 4) m.moved = true;
    if (m.mode === 'rotate' && m.moved) { cam().rotate(dx * 0.0062); cam().tilt(-dy * 0.0034); }
    else if (m.mode === 'pan') cam().panPixels(dx, dy, W.H);
    else if (m.mode === 'ghost') { moveGhost(px, py); }
    else if (m.mode === 'select' && m.moved) { showBox(rect(m.x0, m.y0, px, py)); }
  }
  function onPointerUp(e) {
    if (!api.on) return; const touch = e.pointerType === 'touch';
    if (touch) { if (G.touch.has(e.pointerId)) { e.stopImmediatePropagation(); touchUp(e); } return; }
    const m = G.mouse; if (!m || m.id !== e.pointerId) return; e.stopImmediatePropagation(); G.mouse = null; cam().dragging = false; showBox(null);
    const px = e.clientX, py = e.clientY;
    if (m.mode === 'select') {
      if (m.moved) { const ids = dyn().colonistsIn(m.x0, m.y0, px, py); OB.select(ids, m.shift); }
      else clickAt(px, py, e, false);
    } else if (m.mode === 'ghost') { if (!m.moved) { moveGhost(px, py); if (OB.mapBg.ghost) OB.mapBg.commitGhost(e.shiftKey); } }
    else if (m.mode === 'rotate' && !m.moved && m.btn === 2) { if (ghostOn()) OB.build.cancel(); else contextAt(px, py, e); }
  }
  function onWheel(e) { if (!api.on || !isWorld(e.target)) return; e.stopImmediatePropagation(); e.preventDefault(); cam().zoom(e.deltaY < 0 ? 1 / 1.16 : 1.16); }
  function onDbl(e) { if (!api.on || !isWorld(e.target) || !colonyMode()) return; const h = dyn().pick(e.clientX, e.clientY, false); if (h && h.kind === 'colonist') { e.stopImmediatePropagation(); const a = dyn().actor(h.id); if (a) { cam().setTarget(a.px, a.pz, 45); } } }
  function onContext(e) { if (api.on && isWorld(e.target)) { e.preventDefault(); e.stopImmediatePropagation(); } }

  // ---- touch: 1 finger pan / tap / long-press, 2 fingers pinch zoom + twist rotate + pan
  function touchDown(e) {
    const pts = G.touch, px = e.clientX, py = e.clientY; pts.set(e.pointerId, { x: px, y: py, x0: px, y0: py });
    if (pts.size === 1) {
      const sel = OB.touch && OB.touch.selectMode && colonyMode() && !ghostOn();
      let kind = sel ? 'box' : 'pan';
      if (ghostOn()) { const v = OB.mapBg; if (v.ghost.x != null) { const gp = dyn().groundPoint(px, py); if (gp && Math.hypot(gp.x - v.ghost.x, gp.y - v.ghost.y) < 6) kind = 'ghost'; } }
      const g = G.g = { kind, x0: px, y0: py, moved: false, long: false, t0: performance.now() };
      if (!ghostOn() && colonyMode()) g.timer = setTimeout(() => { if (G.g !== g || g.moved || pts.size !== 1) return; g.long = true; try { navigator.vibrate && navigator.vibrate(12); } catch (er) { /* n/a */ } contextAt(g.x0, g.y0, { clientX: g.x0, clientY: g.y0 }); }, 480);
    } else if (pts.size === 2) {
      if (G.g) { clearTimeout(G.g.timer); }
      const [a, b] = Array.from(pts.values()); G.g = { kind: 'pinch', d: Math.hypot(a.x - b.x, a.y - b.y) || 1, ang: Math.atan2(b.y - a.y, b.x - a.x), mx: (a.x + b.x) / 2, my: (a.y + b.y) / 2, moved: true };
    }
    cam().dragging = true;
  }
  function touchMove(e) {
    const pts = G.touch, p = pts.get(e.pointerId); if (!p) return; const dx = e.clientX - p.x, dy = e.clientY - p.y; p.x = e.clientX; p.y = e.clientY; const g = G.g; if (!g) return;
    if (g.kind === 'pinch' && pts.size >= 2) {
      const [a, b] = Array.from(pts.values()), d = Math.hypot(a.x - b.x, a.y - b.y) || 1, ang = Math.atan2(b.y - a.y, b.x - a.x), mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
      cam().zoom(g.d / d); let da = ang - g.ang; if (da > PI) da -= 2 * PI; if (da < -PI) da += 2 * PI; cam().rotate(-da); cam().panPixels(mx - g.mx, my - g.my, W.H);
      g.d = d; g.ang = ang; g.mx = mx; g.my = my; return;
    }
    if (pts.size !== 1) return;
    if (!g.moved && Math.hypot(p.x - g.x0, p.y - g.y0) > 10) { g.moved = true; clearTimeout(g.timer); }
    if (g.long) return;
    if (g.kind === 'pan' && g.moved) cam().panPixels(dx, dy, W.H);
    else if (g.kind === 'ghost' && g.moved) moveGhost(p.x, p.y);
    else if (g.kind === 'box' && g.moved) showBox(rect(g.x0, g.y0, p.x, p.y));
  }
  function touchUp(e) {
    const pts = G.touch, p = pts.get(e.pointerId), g = G.g; pts.delete(e.pointerId); if (g) clearTimeout(g.timer);
    if (pts.size === 0 && g) {
      cam().dragging = false; showBox(null);
      if (e.type === 'pointerup' && g.kind !== 'pinch' && !g.long) {
        if (!g.moved) tapAt(p.x, p.y);
        else if (g.kind === 'box') { OB.select(dyn().colonistsIn(g.x0, g.y0, p.x, p.y), false); }
      }
      G.g = null;
    } else if (pts.size === 1 && g && g.kind === 'pinch') G.g = { kind: 'none', moved: true };
  }
  function tapAt(px, py) {
    if (ghostOn()) { moveGhost(px, py); return; }
    const T = OB.touch;
    if (T && T.orderMode && colonyMode()) { const gp = dyn().groundPoint(px, py); if (gp && OB.mapBg) { OB.mapBg.orderGoto(gp.x, gp.y); T.setOrder(false); try { navigator.vibrate && navigator.vibrate(10); } catch (er) { /* n/a */ } } return; }
    const now = performance.now(), l = G.lastTap, dbl = l && now - l.t < 380 && Math.hypot(px - l.x, py - l.y) < 30; G.lastTap = { t: now, x: px, y: py };
    const hit = clickAt(px, py, null, true); if (dbl && hit && hit.kind === 'colonist') { const a = dyn().actor(hit.id); if (a) cam().setTarget(a.px, a.pz, 45); }
  }

  // ------------------------------------------------------------------------------------------------ keys
  function key(k, down) { const s = cam().keys; if (down) s.add(k); else s.delete(k); }
  function onKeyDown(e) {
    if (!api.on || typing(e) || e.ctrlKey || e.metaKey || e.altKey) return;
    const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
    if (k === ' ') G.space = true;
    if (OB.screens && OB.screens.current) return;
    if (k === 'f') { api.toggleChase(); e.preventDefault(); }
    else if (k === 'Home') { cam().setTarget(0, 14, 150); e.preventDefault(); }
    else if (!colonyMode() && ['w', 'a', 's', 'd', 'shift', 'Shift'].includes(k)) { survKeys.add(k.toLowerCase()); }
  }
  function onKeyUp(e) { const k = e.key.length === 1 ? e.key.toLowerCase() : e.key; if (k === ' ') G.space = false; survKeys.delete(k.toLowerCase()); }
  const survKeys = new Set();

  // ------------------------------------------------------------------------------------------------ chase camera
  function followTarget() {
    const st = W.state; if (!st) return null;
    if (colonyMode()) { const id = OB.S.primary || OB.S.sel[0] || (st.colonists[0] && st.colonists[0].id); const a = id && dyn().actor(id); if (!a) return null; return { get x() { return a.px; }, get z() { return a.pz; }, get yaw() { return a.yaw; }, id }; }
    const pa = dyn().pa; return pa ? { get x() { return pa.px; }, get z() { return pa.pz; }, get yaw() { return pa.yaw; }, id: 'player' } : null;
  }
  api.toggleChase = function (force) {
    const want = force != null ? force : cam().mode !== 'chase';
    if (want) { const f = followTarget(); if (!f) return false; cam().setMode('chase', { follow: f, dist: 7.5 }); api.chase = true; if (colonyMode() && f.id && OB.S.primary !== f.id) OB.select([f.id]); }
    else { cam().setMode('rts', { dist: 70 }); api.chase = false; }
    syncButtons(); return api.chase;
  };

  // ------------------------------------------------------------------------------------------------ UI additions (command bar buttons, settings rows)
  let btnFollow = null, btnView = null;
  function syncButtons() { if (btnFollow) btnFollow.classList.toggle('on', cam().mode === 'chase'); if (btnView) btnView.querySelector('span').textContent = api.on ? '2D map' : '3D world'; }
  function addButtons() {
    const bar = doc.querySelector('#cmdbar'); if (!bar || bar.querySelector('.w3d-btn')) return; const h = OB.h;
    btnFollow = h('button.cmd.w3d-btn', { dataset: { w3d: 'follow' }, on: { click: () => api.toggleChase() } }, OB.icon('crosshair'), h('span', 'Follow'));
    btnView = h('button.cmd.w3d-btn', { dataset: { w3d: 'view' }, on: { click: () => api.setView(api.on ? '2d' : '3d') } }, OB.icon('map'), h('span', api.on ? '2D map' : '3D world'));
    OB.tip && OB.tip(btnFollow, 'Chase camera on the selected colonist <kbd>F</kbd>'); OB.tip && OB.tip(btnView, 'Switch between the 3D world and the flat tactical map');
    bar.append(h('i.vsep'), btnFollow, btnView);
  }
  function observeSettings() {
    const scr = doc.querySelector('#screens'); if (!scr) return; const h = OB.h;
    const mo = new MutationObserver(() => {
      for (const row of scr.querySelectorAll('.srow')) { if (row.dataset.w3d) return; if (/Key hints/.test(row.textContent) && !scr.querySelector('.w3d-row')) {
        const mk = (label, desc, ctl) => { const r = h('div.srow.w3d-row', { dataset: { w3d: '1' } }, h('div.grow', h('b', label), h('div.muted.t-sm', desc)), ctl); return r; };
        const view = OB.seg([{ value: '3d', label: '3D' }, { value: '2d', label: '2D' }], api.on ? '3d' : '2d', v => api.setView(v), 'w3d-seg');
        const q = OB.seg([{ value: 'auto', label: 'Auto' }, { value: 'high', label: 'High' }, { value: 'mid', label: 'Mid' }, { value: 'low', label: 'Low' }], ctx.getQuality ? ctx.getQuality() : 'auto', v => api.setQuality(v), 'w3d-seg');
        row.after(mk('World view', 'Real 3D world (three.js, drawn from the live sim) or the flat tactical map.', view), mk('Graphics quality', 'Auto picks by device: desktop high, laptop mid, phone low.', q)); return; } }
    });
    mo.observe(scr, { childList: true, subtree: true });
  }

  // ------------------------------------------------------------------------------------------------ public
  api.setView = function (v) { ctx.setView(v); };
  api.setQuality = function (q) { ctx.setQuality(q); };
  api.enable = function (on) {
    api.on = !!on; if (!ready()) return;
    if (api.on) { patchView(); } else { unpatchView(); doc.body.style.cursor = ''; showBox(null); cam().setMode('rts', {}); }
    syncButtons();
  };
  api.key = key;
  api.focus = (x, y) => { cam().setTarget(x, -y); };
  api.tick = function (dt) {
    if (!inited || !api.on) return;
    if (OB.mapBg && patched !== OB.mapBg) patchView();
    const d = dyn(); if (!d) return;
    d.setSelection(OB.S.sel, OB.S.primary); d.setGhost(OB.mapBg && ghostOn() ? OB.mapBg.ghost : null);
    if (cam().mode === 'chase') { const f = followTarget(); if (!f) { cam().setMode('rts', { dist: 70 }); api.chase = false; syncButtons(); } else if (cam().follow && f.id !== cam().follow.id) cam().follow = f; }
    // survival mode: WASD walks the player (the NUI only forwards camera keys in colony mode)
    if (!colonyMode() && survKeys.size && ctx.preview) {
      const c = cam().t, sp = (survKeys.has('shift') ? 13 : 6.5) * dt; let f = 0, r = 0; if (survKeys.has('w')) f++; if (survKeys.has('s')) f--; if (survKeys.has('d')) r++; if (survKeys.has('a')) r--;
      if (f || r) { const fx = -Math.sin(c.yaw), fz = -Math.cos(c.yaw), rx = Math.cos(c.yaw), rz = -Math.sin(c.yaw), l = Math.hypot(f, r) || 1, mx = (fx * f + rx * r) / l * sp, mz = (fz * f + rz * r) / l * sp; const p = ctx.preview.getPlayer(); ctx.preview.setPlayer(p.x + mx, p.y - mz); if (d.pa) d.pa.walk = 1; }
    }
    if (!colonyMode() && cam().mode !== 'chase' && !api.userCam && d.pa) { cam().setMode('chase', { follow: followTarget(), dist: 9 }); api.chase = true; syncButtons(); }
    if (colonyMode() && cam().mode === 'chase' && !OB.S.sel.length && false) { /* keep following */ }
  };
  api.onMode = function (mode) { // preview switched between survival and colony
    if (!inited) return; if (mode === 'colony') { if (cam().mode === 'chase' && !api.userChase) { cam().setMode('rts', { dist: 140 }); api.chase = false; } cam().d.x = cam().t.x; cam().d.z = cam().t.z; syncButtons(); }
    else { api.userCam = false; }
  };
  api.dispose = function () { unpatchView(); };

  function init() {
    if (inited || !ready()) return false; inited = true;
    const opts = { capture: true, passive: false };
    doc.addEventListener('pointerdown', onPointerDown, opts); doc.addEventListener('pointermove', onPointerMove, opts); doc.addEventListener('pointerup', onPointerUp, opts); doc.addEventListener('pointercancel', onPointerUp, opts);
    doc.addEventListener('wheel', onWheel, opts); doc.addEventListener('dblclick', onDbl, opts); doc.addEventListener('contextmenu', onContext, opts);
    doc.addEventListener('keydown', onKeyDown, true); doc.addEventListener('keyup', onKeyUp, true);
    ui.addEventListener('blur', () => { cam().keys.clear(); survKeys.clear(); });
    addButtons(); observeSettings(); if (api.on) patchView(); syncButtons();
    OB.on('mapfocus', p => { if (api.on) cam().setTarget(p.x, -p.y); });
    OB.on('placing', () => { /* ghost state is read each frame */ });
    return true;
  }
  const iv = setInterval(() => { if (init()) clearInterval(iv); }, 150);
  api.init = init; api.patched = () => patched; api.G = G;
  return api;
}
