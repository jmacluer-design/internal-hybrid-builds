/* Outbreak touch layer: the same UI on a phone or tablet (portrait, landscape, 820x1180). Loaded last; on a desktop it only sets data-ui="desktop"
   and does nothing else, so the desktop UI is untouched. In touch mode it sets data-ui="touch" and css/mobile.css re-lays the panels out as bottom sheets /
   side drawers; this file adds what CSS cannot:
     * the map: one-finger pan, two-finger pinch zoom (+ pan), tap to select, long-press = right-click menu, "Select" mode (drag a box), "Order" mode (tap
       the destination), placement ghost you tap / drag with confirm + cancel buttons (OB.MapView calls OB.touch.map() for touch pointers only);
     * long-press on any element = its context menu (rows, priority cells, inventory slots) or, if it has none, its tooltip; tap on a resource = its tooltip;
     * the dock as a sheet (closed / open / full, drag the grip), the resource bar scroller + collapse, safe-area / viewport layout variables.
   Mode: ?touch=1 or ?touch=0 (also on the preview shell), localStorage outbreak.touch, else a coarse primary pointer without hover, else a window < 720 px wide. */
(function () {
  'use strict';
  const OB = window.OB, h = OB.h, S = OB.S;
  const root = document.documentElement;
  const touch = (OB.touch = { on: false, selectMode: false, orderMode: false, keepPlacing: false, sheet: 'closed', lastType: '', lastAt: 0, swallow: false, map() { return false; }, helpView() { return null; } });

  function detect() {
    let q = location.search;
    try { if (window.parent !== window) q += '&' + window.parent.location.search.slice(1); } catch (e) { /* cross-origin parent */ }
    const f = new URLSearchParams(q).get('touch');
    if (f === '1' || f === '0') return f === '1';
    try { const v = localStorage.getItem('outbreak.touch'); if (v === '1' || v === '0') return v === '1'; } catch (e) { /* storage blocked */ }
    const mm = s => !!(window.matchMedia && matchMedia(s).matches);
    return (mm('(pointer: coarse)') && mm('(hover: none)')) || innerWidth < 720;
  }
  touch.on = detect();
  root.dataset.ui = touch.on ? 'touch' : 'desktop';
  if (!touch.on) return;
  root.dataset.sheet = 'closed';

  const clamp = OB.clamp;
  const vibrate = ms => { try { navigator.vibrate && navigator.vibrate(ms); } catch (e) { /* not supported */ } };

  // ------------------------------------------------------------------------------------------------------- page hardening
  // no page zoom / rubber-band / text selection: the map and the sheets handle every gesture themselves
  document.addEventListener('gesturestart', e => e.preventDefault(), { passive: false });
  document.addEventListener('gesturechange', e => e.preventDefault(), { passive: false });
  document.addEventListener('touchmove', e => { if (e.touches.length > 1) e.preventDefault(); }, { passive: false });

  // -------------------------------------------------------------------------------------------- long-press = right-click
  let lp = null;
  const cancelLong = () => { if (lp) { clearTimeout(lp.t); lp = null; } };
  function fireLong() {
    if (!lp) return;
    const { x, y, tgt } = lp; lp = null;
    touch.swallow = true; // the click that follows the lift must not act
    const ev = new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 2, buttons: 2, view: window });
    ev.fromTouch = true;
    if (!tgt.dispatchEvent(ev)) { vibrate(12); return; } // a handler took it (row menu, priority back, slot menu ...)
    touch.showTipFor(tgt, x, y);
  }
  touch.showTipFor = function (el, x, y) {
    for (let n = el; n && n !== document; n = n.parentElement) {
      if (n._tipOpen) { if (n._tipOpen(x, y)) { vibrate(8); clearTimeout(touch.tipTimer); touch.tipTimer = setTimeout(OB.hideTip, 4200); return true; } }
    }
    return false;
  };
  document.addEventListener('pointerdown', e => {
    touch.lastType = e.pointerType; touch.lastAt = performance.now();
    touch.swallow = false;
    if (e.pointerType !== 'touch') return;
    clearTimeout(touch.tipTimer); OB.hideTip();
    cancelLong();
    const t = e.target;
    if (!(t instanceof Element) || t.closest('.map-cv, input, select, textarea, #ctx, .grip')) return; // the map has its own long-press
    lp = { id: e.pointerId, x: e.clientX, y: e.clientY, tgt: t, t: setTimeout(fireLong, 480) };
  }, true);
  document.addEventListener('pointermove', e => { if (lp && e.pointerId === lp.id && Math.hypot(e.clientX - lp.x, e.clientY - lp.y) > 10) cancelLong(); }, true);
  for (const type of ['pointerup', 'pointercancel']) document.addEventListener(type, e => { if (lp && e.pointerId === lp.id) cancelLong(); }, true);
  document.addEventListener('click', e => { if (touch.swallow) { touch.swallow = false; e.preventDefault(); e.stopPropagation(); } }, true);
  // the browser's own long-press contextmenu (Android) would double our synthetic one
  document.addEventListener('contextmenu', e => { if (e.isTrusted && touch.lastType === 'touch' && performance.now() - touch.lastAt < 2000) { e.preventDefault(); e.stopImmediatePropagation(); } }, true);

  // menu next to the finger, not under it
  const ctx0 = OB.ctx;
  OB.ctx = function (x, y, entries) {
    ctx0.call(this, x, y, entries);
    const m = OB.$('#ctx'), w = m.offsetWidth, hh = m.offsetHeight, pad = 8;
    const left = clamp(x - w / 2, pad, innerWidth - w - pad);
    let top = y + 30; if (top + hh > innerHeight - pad) top = y - hh - 30;
    m.style.transform = 'translate(' + Math.round(left) + 'px,' + Math.round(clamp(top, pad, innerHeight - hh - pad)) + 'px)';
  };

  // ----------------------------------------------------------------------------------------------------------- map gestures
  const TAP = 10; // px: a touch that moved less than this is a tap
  function visibleRect(v) { // the part of the map canvas not covered by the chrome (px, canvas coordinates)
    const cr = v.canvas.getBoundingClientRect();
    let x0 = cr.left, x1 = cr.right, y0 = cr.top, y1 = cr.bottom;
    for (const sel of ['#topbar', '#roster', '#cmdbar', '#placebar', '#dock']) {
      const el = OB.$(sel); if (!el || el.hidden || !el.offsetParent) continue;
      const r = el.getBoundingClientRect(); if (r.width < 2 || r.height < 2) continue;
      if (r.width > innerWidth * 0.55) { if (r.top > innerHeight / 2) y1 = Math.min(y1, r.top); else y0 = Math.max(y0, r.bottom); }
      else if (r.left < innerWidth / 2) x0 = Math.max(x0, r.right); else x1 = Math.min(x1, r.left);
    }
    if (y1 - y0 < 80) { y0 = cr.top; y1 = cr.bottom; }
    if (x1 - x0 < 80) { x0 = cr.left; x1 = cr.right; }
    return { x0: x0 - cr.left, x1: x1 - cr.left, y0: y0 - cr.top, y1: y1 - cr.top, cx: (x0 + x1) / 2 - cr.left, cy: (y0 + y1) / 2 - cr.top };
  }
  touch.visibleRect = visibleRect;

  function ghostGrab(v, px, py) {
    const g = v.ghost; if (!g || g.x == null) return false;
    const half = g.zone ? Math.sqrt(g.tiles) * 2.1 * v.s : Math.max(12, Math.min(40, 4.4 * v.s)) / 2;
    return Math.hypot(v.sx(g.x) - px, v.sy(g.y) - py) < Math.max(48, half + 16);
  }
  function selectBox(v) {
    const d = v.drag; v.drag = null; v.dirty = true;
    if (!d || !v.state) return;
    const x0 = Math.min(d.x0, d.x1), x1 = Math.max(d.x0, d.x1), y0 = Math.min(d.y0, d.y1), y1 = Math.max(d.y0, d.y1);
    OB.select(v.state.colonists.filter(c => c.state !== 'away' && v.sx(c.x) >= x0 && v.sx(c.x) <= x1 && v.sy(c.y) >= y0 && v.sy(c.y) <= y1).map(c => c.id), false);
  }
  function hitTouch(v, px, py) { // a finger is ~40 px wide: colonists within 30 px win over the desktop 12 px test
    const st = v.state; if (!st) return null;
    let best = null, bd = 30;
    for (const c of st.colonists) { if (c.state === 'away') continue; const d = Math.hypot(v.sx(c.x) - px, v.sy(c.y) - py); if (d < bd) { bd = d; best = { kind: 'colonist', id: c.id }; } }
    return best || v.hit(px, py);
  }
  function tapMap(v, px, py, e) {
    if (v.ghost) { v.updateGhost(px, py); v.dirty = true; return; } // placement: the ghost goes where you tapped
    if (touch.orderMode) { v.orderGoto(v.wx(px), v.wy(py)); touch.setOrder(false); vibrate(10); return; }
    const hit = hitTouch(v, px, py), t = v._t, now = performance.now();
    const dbl = t.lastTap && now - t.lastTap.t < 380 && Math.hypot(px - t.lastTap.x, py - t.lastTap.y) < 30;
    t.lastTap = { t: now, x: px, y: py };
    if (hit && hit.kind === 'colonist') {
      if (touch.selectMode) OB.select(OB.S.sel.indexOf(hit.id) >= 0 ? OB.S.sel.filter(id => id !== hit.id) : OB.S.sel.concat(hit.id), false);
      else OB.select([hit.id], false);
      if (dbl) { const c = OB.col(hit.id); if (c) v.center(c.x, c.y); }
    } else if (hit && hit.kind === 'building') OB.emit('building_click', hit);
    else if (hit && hit.kind === 'zone') { OB.colony.setDock('zones'); OB.emit('zone_click', hit); }
    else if (!touch.selectMode && OB.S.sel.length) OB.select([]);
  }
  touch.map = function (v, e) {
    const t = v._t || (v._t = { p: new Map(), g: null, lastTap: null });
    const r = v.canvas.getBoundingClientRect(), px = e.clientX - r.left, py = e.clientY - r.top;
    if (e.type === 'pointerdown') {
      try { v.canvas.setPointerCapture(e.pointerId); } catch (err) { /* already gone */ }
      t.p.set(e.pointerId, { x: px, y: py });
      if (t.p.size === 1) {
        const g = t.g = { kind: v.ghost && ghostGrab(v, px, py) ? 'ghost' : touch.selectMode && !v.ghost ? 'box' : 'pan', x0: px, y0: py, cx0: v.cx, cy0: v.cy, moved: false, long: false, t0: performance.now() };
        if (g.kind === 'ghost') { g.gx = v.sx(v.ghost.x); g.gy = v.sy(v.ghost.y); }
        if (!v.ghost) g.timer = setTimeout(() => {
          if (t.g !== g || g.moved || t.p.size !== 1) return;
          g.long = true; touch.swallow = true; vibrate(12);
          v.rightClick(g.x0, g.y0, { clientX: r.left + g.x0, clientY: r.top + g.y0 }); // = right-click: move here / dismantle / new zone
        }, 480);
      } else if (t.p.size === 2) { // second finger: pinch
        if (t.g) { clearTimeout(t.g.timer); v.drag = null; }
        const [a, b] = Array.from(t.p.values());
        const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
        t.g = { kind: 'pinch', d0: Math.max(10, Math.hypot(a.x - b.x, a.y - b.y)), s0: v.s, wx: v.wx(mx), wy: v.wy(my), moved: true };
      }
      return true;
    }
    const pt = t.p.get(e.pointerId);
    if (!pt) return true;
    if (e.type === 'pointermove') {
      pt.x = px; pt.y = py;
      const g = t.g; if (!g) return true;
      if (g.kind === 'pinch' && t.p.size >= 2) {
        const [a, b] = Array.from(t.p.values());
        const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
        v.s = clamp(g.s0 * Math.hypot(a.x - b.x, a.y - b.y) / g.d0, 0.12, 16);
        v.cx = g.wx - (mx - v.W / 2) / v.s; v.cy = g.wy + (my - v.H / 2) / v.s;
        v.userMoved = true; v.dirty = true;
        if (v.ghost) touch.ghostChanged(v);
        return true;
      }
      if (t.p.size !== 1) return true;
      const dx = px - g.x0, dy = py - g.y0;
      if (!g.moved && Math.hypot(dx, dy) > TAP) { g.moved = true; clearTimeout(g.timer); }
      if (g.long) return true;
      if (g.kind === 'pan') { v.cx = g.cx0 - dx / v.s; v.cy = g.cy0 + dy / v.s; v.userMoved = true; v.dirty = true; }
      else if (g.kind === 'ghost' && g.moved) { v.updateGhost(g.gx + dx, g.gy + dy); v.dirty = true; }
      else if (g.kind === 'box' && g.moved) { v.drag = { x0: g.x0, y0: g.y0, x1: px, y1: py }; v.dirty = true; }
      return true;
    }
    // pointerup / pointercancel
    const g = t.g;
    t.p.delete(e.pointerId);
    if (g) clearTimeout(g.timer);
    if (t.p.size === 0 && g) {
      if (e.type === 'pointerup' && g.kind !== 'pinch' && !g.long) {
        if (!g.moved) tapMap(v, px, py, e);
        else if (g.kind === 'box') selectBox(v);
      }
      v.drag = null; v.dirty = true;
      t.g = null;
    } else if (t.p.size === 1 && g && g.kind === 'pinch') t.g = { kind: 'none', moved: true }; // one finger left after a pinch: ignore it until all lift
    return true;
  };

  // pan buttons on the real map get a better first view on a phone: the base fills the visible area, not 400 m of empty terrain
  const fit0 = OB.MapView.prototype.fit;
  OB.MapView.prototype.fit = function (region) {
    fit0.call(this, region);
    if (!region && this.mode === 'full' && this.W > 2 && this.H > 2) {
      const vis = this.host.id === 'mapbg' ? visibleRect(this) : { x0: 0, x1: this.W, y0: 0, y1: this.H, cx: this.W / 2, cy: this.H / 2 };
      this.s = clamp(Math.min((vis.x1 - vis.x0) / 250, (vis.y1 - vis.y0) / 300), 0.12, 16);
      this.cx = 0 - (vis.cx - this.W / 2) / this.s; this.cy = 0 + (vis.cy - this.H / 2) / this.s; // the base sits in the middle of what you can see
      this.userMoved = false; this.dirty = true;
    }
  };
  const ug0 = OB.MapView.prototype.updateGhost;
  OB.MapView.prototype.updateGhost = function (px, py) { ug0.call(this, px, py); touch.ghostChanged(this); };

  // ---------------------------------------------------------------------------------------------------- order / select modes
  touch.setSelect = function (on) {
    touch.selectMode = !!on; root.dataset.select = on ? '1' : '';
    if (on) touch.setOrder(false);
    syncButtons();
  };
  touch.setOrder = function (on) {
    if (on && !S.sel.length) { OB.toast('info', 'Select a colonist first (tap one on the map or in the strip).', { title: 'Order' }); return; }
    if (on && (OB.build.placing || (OB.zones && OB.zones.placing))) OB.build.cancel(true);
    touch.orderMode = !!on;
    if (on) { touch.selectMode = false; root.dataset.select = ''; }
    syncButtons(); renderBar();
  };

  // ------------------------------------------------------------------------------------------------- placement / order bar
  let bar = null, barEls = {};
  function ghostView() { return (OB.screens.current === 'map' && OB.bigMap) || OB.mapBg || null; }
  touch.ghostChanged = function () { if (bar && root.dataset.bar === 'place') renderBar(); };
  function renderBar() {
    if (!bar) return;
    const bp = OB.build.placing, zone = OB.zones && OB.zones.placing;
    const mode = bp || zone ? 'place' : touch.orderMode ? 'order' : '';
    root.dataset.bar = mode;
    if (!mode) return;
    const v = ghostView(), g = v && v.ghost;
    if (mode === 'order') {
      OB.setText(barEls.title, 'Move order');
      OB.setText(barEls.sub, 'Tap the map to send ' + (S.sel.length === 1 ? OB.nick((OB.col(S.sel[0]) || { name: 'the colonist' }).name) : S.sel.length + ' colonists') + ' there');
      barEls.sub.className = 'pb-sub'; return;
    }
    const name = zone ? 'Stockpile zone' : OB.bp(bp).name;
    OB.setText(barEls.title, name);
    const placed = g && g.x != null;
    OB.setText(barEls.sub, !placed ? 'Tap the map to position it' : g.ok ? 'Drag it to adjust, then Place' : OB.reason(g.reason));
    barEls.sub.className = 'pb-sub ' + (!placed ? '' : g.ok ? 'good' : 'bad');
    barEls.ok.disabled = !placed;
    barEls.keep.classList.toggle('on', touch.keepPlacing); barEls.keep.setAttribute('aria-pressed', touch.keepPlacing ? 'true' : 'false');
    barEls.keep.hidden = !!zone;
  }
  function buildBar() {
    barEls.title = h('b', ''); barEls.sub = h('span.pb-sub', '');
    barEls.cancel = h('button.btn.pb-cancel', { type: 'button', 'aria-label': 'Cancel', on: { click: () => { if (touch.orderMode) touch.setOrder(false); else OB.build.cancel(); renderBar(); } } }, OB.icon('x'), h('span', 'Cancel'));
    barEls.keep = h('button.btn.pb-keep', { type: 'button', 'aria-pressed': 'false', 'aria-label': 'Keep placing', on: { click: () => { touch.keepPlacing = !touch.keepPlacing; renderBar(); } } }, OB.icon('layers'), h('span', 'Keep'));
    barEls.ok = h('button.btn.primary.pb-ok', { type: 'button', 'aria-label': 'Place', on: { click: () => { const v = ghostView(); if (v && v.ghost) { v.commitGhost(touch.keepPlacing); renderBar(); } } } }, OB.icon('check'), h('span', 'Place'));
    bar = h('div#placebar.panel', { role: 'group', 'aria-label': 'Placement' }, barEls.cancel, h('div.pb-info', barEls.title, barEls.sub), barEls.keep, barEls.ok);
    return bar;
  }
  function onPlacing() {
    const v = ghostView();
    if (OB.build.placing || (OB.zones && OB.zones.placing)) {
      touch.setSheet('closed'); touch.setOrder(false);
      if (v) { // zoom in to a placeable scale and put the ghost in the middle of what is visible
        const vis = visibleRect(v);
        if (v.s < 3.2) v.zoomAt(vis.cx, vis.cy, 3.2 / v.s);
        if (v.ghost && v.ghost.x == null) v.updateGhost(vis.cx, vis.cy);
      }
    }
    renderBar();
  }

  // ------------------------------------------------------------------------------------------------------------------ sheet
  touch.setSheet = function (state) {
    if (state === touch.sheet) return;
    touch.sheet = state; root.dataset.sheet = state;
    const dock = OB.$('#dock'); if (dock) dock.style.removeProperty('--drag-h');
    measure(); OB.emit('sheet', state);
  };
  function buildGrip(dock) {
    const grip = h('div.grip', { role: 'separator', 'aria-orientation': 'horizontal', 'aria-label': 'Drag to resize, tap to expand' }, h('i'));
    let d = null;
    grip.addEventListener('pointerdown', e => {
      const body = OB.$('.dbody', dock); if (!body) return;
      grip.setPointerCapture(e.pointerId);
      d = { y: e.clientY, h0: body.getBoundingClientRect().height, moved: false };
    });
    grip.addEventListener('pointermove', e => {
      if (!d) return;
      const dy = e.clientY - d.y; if (Math.abs(dy) > 6) d.moved = true;
      if (d.moved && innerHeight > innerWidth) { dock.dataset.drag = '1'; dock.style.setProperty('--drag-h', clamp(d.h0 - dy, 0, innerHeight * 0.85) + 'px'); }
    });
    const end = e => {
      if (!d) return;
      const was = d; d = null;
      const cur = parseFloat(dock.style.getPropertyValue('--drag-h'));
      dock.style.removeProperty('--drag-h'); delete dock.dataset.drag;
      if (!was.moved) return touch.setSheet(touch.sheet === 'full' ? 'open' : 'full');
      if (isNaN(cur)) return;
      const open = innerHeight * 0.42, full = innerHeight * 0.74;
      touch.setSheet(cur < open * 0.55 ? 'closed' : cur > (open + full) / 2 ? 'full' : 'open');
    };
    grip.addEventListener('pointerup', end); grip.addEventListener('pointercancel', end);
    return grip;
  }

  // ------------------------------------------------------------------------------------------------------ layout variables
  // --top-h: bottom edge of the top bar; used by the floating map buttons and the toasts (landscape + portrait)
  function measure() {
    const tb = OB.$('#topbar'); if (!tb) return;
    root.style.setProperty('--top-h', Math.round(tb.getBoundingClientRect().bottom) + 'px');
  }

  // ------------------------------------------------------------------------------------------------------------------ setup
  function syncButtons() {
    if (!touch.selBtn) return;
    touch.selBtn.classList.toggle('on', touch.selectMode); touch.selBtn.setAttribute('aria-pressed', touch.selectMode ? 'true' : 'false');
    touch.orderBtn.classList.toggle('on', touch.orderMode); touch.orderBtn.setAttribute('aria-pressed', touch.orderMode ? 'true' : 'false');
    touch.orderBtn.disabled = !S.sel.length && !touch.orderMode;
  }
  function setup() {
    const colony = OB.$('#colony'), topbar = OB.$('#topbar'), dock = OB.$('#dock'), cmdbar = OB.$('#cmdbar'), roster = OB.$('#roster');
    // top bar: the threat meter rides in the scrolling resource row; the clock block collapses that row
    const res = OB.$('.resources', topbar), threat = OB.$('.thmeter', topbar), clockBox = OB.$('.timebox', topbar);
    if (res && threat) res.prepend(threat);
    if (clockBox) {
      clockBox.setAttribute('role', 'button'); clockBox.tabIndex = 0; clockBox.setAttribute('aria-label', 'Show or hide resources'); clockBox.setAttribute('aria-expanded', 'true');
      clockBox.append(h('span.collapse', OB.icon('chevd')));
      const toggle = () => { const min = root.dataset.top !== 'min'; root.dataset.top = min ? 'min' : ''; clockBox.setAttribute('aria-expanded', min ? 'false' : 'true'); try { localStorage.setItem('outbreak.topmin', min ? '1' : '0'); } catch (e) { /* ignore */ } setTimeout(measure, 30); };
      clockBox.addEventListener('click', toggle);
      clockBox.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(); } });
      try { if (localStorage.getItem('outbreak.topmin') === '1') { root.dataset.top = 'min'; clockBox.setAttribute('aria-expanded', 'false'); } } catch (e) { /* ignore */ }
    }
    // taps on a resource show its tooltip (there is no hover)
    topbar.addEventListener('click', e => { const r = e.target.closest('.res, .thmeter'); if (r && r._tipOpen) { const b = r.getBoundingClientRect(); touch.showTipFor(r, b.left + 8, b.bottom + 4); } });
    // command bar: the modes first; the dock buttons are the bottom tabs now
    const mk = (icon, label, run, aria) => h('button.cmd.tc', { type: 'button', 'aria-label': aria || label, on: { click: run } }, OB.icon(icon), h('span', label));
    touch.selBtn = mk('marquee', 'Select', () => touch.setSelect(!touch.selectMode), 'Select mode: drag a box around colonists');
    touch.orderBtn = mk('run', 'Order', () => touch.setOrder(!touch.orderMode), 'Order: tap, then tap the destination');
    cmdbar.prepend(touch.selBtn, touch.orderBtn, h('i.vsep'));
    // dock = bottom sheet: tabs at the bottom, panel above, grip on top
    dock.append(buildGrip(dock));
    const tabs = OB.$('.dtabs', dock);
    let wasActive = false;
    tabs.addEventListener('click', e => { const t = e.target.closest('.dtab'); if (t) wasActive = t.classList.contains('on') && touch.sheet !== 'closed'; }, true); // before colony.js switches the tab
    tabs.addEventListener('click', e => { const t = e.target.closest('.dtab'); if (t) touch.setSheet(wasActive ? 'closed' : touch.sheet === 'closed' ? 'open' : touch.sheet); });
    // placement / order bar + floating zoom buttons
    colony.append(buildBar());
    const zoomBy = f => { const v = ghostView(); if (!v) return; const vis = visibleRect(v); v.zoomAt(vis.cx, vis.cy, f); };
    colony.append(h('div#mapctl', { role: 'group', 'aria-label': 'Map' },
      h('button.btn.sq', { type: 'button', 'aria-label': 'Zoom in', on: { click: () => zoomBy(1.5) } }, OB.icon('plus')),
      h('button.btn.sq', { type: 'button', 'aria-label': 'Zoom out', on: { click: () => zoomBy(1 / 1.5) } }, OB.icon('minus')),
      h('button.btn.sq', { type: 'button', 'aria-label': 'Back to base', on: { click: () => { const v = ghostView(); if (v) v.fit(false); } } }, OB.icon('home'))));
    // roster: tapping a colonist brings them into view
    roster.addEventListener('click', e => {
      const row = e.target.closest('.crow'); if (!row || !OB.mapBg) return;
      const c = OB.col(row.dataset.id); if (!c) return;
      const v = OB.mapBg, vis = visibleRect(v), x = v.sx(c.x), y = v.sy(c.y);
      if (x < vis.x0 + 20 || x > vis.x1 - 20 || y < vis.y0 + 20 || y > vis.y1 - 20) { v.cx = c.x - (vis.cx - v.W / 2) / v.s; v.cy = c.y + (vis.cy - v.H / 2) / v.s; v.userMoved = true; v.dirty = true; }
    });
    new ResizeObserver(measure).observe(topbar);
    measure(); syncButtons(); renderBar();
    touch.ready = true;
  }
  const sd0 = OB.colony.setDock;
  OB.colony.setDock = function (id, silent) { // an explicit "show me this panel" (row menu, zone tap) also opens the sheet
    const r = sd0.apply(this, arguments);
    if (!silent && touch.ready && S.mode === 'colony' && touch.sheet === 'closed') touch.setSheet('open');
    return r;
  };
  const init0 = OB.colony.init;
  OB.colony.init = function () { init0.apply(this, arguments); try { setup(); } catch (e) { console.error('[OB] touch setup failed', e); } };
  OB.on('selection', () => { if (touch.orderMode && !S.sel.length) touch.setOrder(false); syncButtons(); renderBar(); });
  OB.on('placing', onPlacing);
  OB.on('mode', m => { if (m !== 'colony') { touch.setOrder(false); touch.setSheet('closed'); } measure(); });
  OB.on('screen', name => {
    if (name === 'priorities') { const p = OB.$('.pintro'); if (p && !p._t) { p._t = 1; p.textContent = 'Tap a cell to cycle 0 → 4 (1 is done first, 0 means never). Long-press a cell to go back one step; tap a column header for set-everyone options.'; } }
    if (name) { touch.setOrder(false); if (OB.build.placing || (OB.zones && OB.zones.placing)) OB.build.cancel(true); } // the confirm bar lives under the screens
    renderBar();
  });
  // zone placement has no event of its own: wrap its start / stop
  if (OB.zones) {
    const z = OB.zones, s0 = z.start, e0 = z.stop;
    z.start = function () { s0.apply(this, arguments); onPlacing(); };
    z.stop = function () { e0.apply(this, arguments); renderBar(); };
  }
  // inventory: a drag would scroll the list, so a tap on a stack opens its menu (use / move / half / one / drop)
  document.addEventListener('click', e => {
    const slot = e.target instanceof Element && e.target.closest('#screens .slot.full'); if (!slot) return;
    const b = slot.getBoundingClientRect();
    slot.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: b.left + b.width / 2, clientY: b.top + b.height / 2, button: 2, view: window }));
  });

  // ------------------------------------------------------------------------------------------------------------- help text
  touch.helpView = function () {
    const row = (k, d) => h('div.krow', h('span.keycaps', h('b', k)), h('span', d));
    return h('div.keys',
      row('Tap', 'Select a colonist or a building; tap empty ground to deselect'),
      row('Drag', 'Pan the map (one finger)'), row('Pinch', 'Zoom the map (two fingers; they also pan)'),
      row('Long-press', 'The right-click menu: move here, dismantle, new stockpile zone. On a colonist, a priority cell or an item: its menu. On a button: its tooltip'),
      row('Select', 'Switch on, then drag a box around colonists. Taps add or remove'),
      row('Order', 'With colonists selected: tap Order, then tap where they should go'),
      row('Build', 'Open the Build tab, pick a blueprint: tap or drag the ghost, then Place'),
      row('Priorities', 'Tap a cell to cycle 0 to 4; long-press goes back a step'),
      row('Sheet', 'Tap a tab to open its panel, tap it again to close; drag the grip to resize'),
      row('Resources', 'Tap a resource for details; tap the clock to hide the row'));
  };
})();
