/* Tactical map (canvas 2D): base footprint, buildings + construction progress, zones, colonists, hordes, raids, caravans, expeditions, districts.
   One class, three uses: the full-screen map screen, the colony backdrop in the browser preview, and the corner minimap.
   North is up (+y). World units are sim units (~metres). */
(function () {
  'use strict';
  const OB = window.OB;
  const FAC = { rustjaw: '#ff8a3d', hollow_choir: '#b78cff', tallow: '#f6d04d', cinder: '#ff5d6c', lantern: '#35d39a' };
  const DANGER = ['#35d39a', '#8bd04f', '#f6d04d', '#ff9a3d', '#ff5d6c'];
  const STATE_COL = { idle: '#9aa7bd', working: '#6ea8ff', sleeping: '#8b7bff', guarding: '#35d39a', drafted: '#f6b44f', downed: '#ff5d6c', away: '#5d6a80' };

  // icon -> HTMLImageElement (tinted SVG), loaded lazily; the map redraws when one finishes
  const iconCache = new Map();
  OB.iconImage = function (name, color, onLoad) {
    const key = name + '|' + color;
    let im = iconCache.get(key);
    if (!im) {
      const use = document.querySelector('#i-' + name);
      const inner = use ? use.innerHTML : '';
      const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="96" height="96" fill="none" stroke="' + color + '" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round">' + inner + '</svg>';
      im = new Image();
      im.onload = () => { im._ok = true; if (onLoad) onLoad(); };
      im.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
      iconCache.set(key, im);
    } else if (!im._ok && onLoad) { const prev = im.onload; im.onload = () => { prev && prev(); onLoad(); }; }
    return im;
  };

  function hashRand(str) { let h = 2166136261; for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 16777619); } return () => { h ^= h << 13; h ^= h >>> 17; h ^= h << 5; return ((h >>> 0) % 10000) / 10000; }; }

  class MapView {
    constructor(host, opts) {
      opts = opts || {};
      this.host = host;
      this.mode = opts.mode || 'full';
      this.interactive = this.mode === 'full' && opts.interactive !== false;
      this.canvas = OB.h('canvas.map-cv');
      host.append(this.canvas);
      this.ctx = this.canvas.getContext('2d');
      this.cx = 0; this.cy = 0; this.s = this.mode === 'mini' ? 1.6 : 4.2;
      this.state = null;
      this.layers = { grid: true, zones: true, districts: true, cells: false, labels: true };
      this.ghost = null; this.drag = null; this.hover = null; this.pings = []; this.keys = {};
      this.dirty = true; this.W = 0; this.H = 0; this.dpr = 1;
      this.follow = this.mode === 'mini';
      this.region = false;
      this.userMoved = false;
      new ResizeObserver(() => this.resize()).observe(host);
      this.resize();
      if (this.interactive) this.bind();
      else if (this.mode === 'mini') this.bindMini();
      this.loop = this.loop.bind(this);
      requestAnimationFrame(this.loop);
    }
    resize() {
      const r = this.host.getBoundingClientRect();
      this.dpr = Math.min(window.devicePixelRatio || 1, 2.5);
      const W = Math.max(2, Math.round(r.width)), H = Math.max(2, Math.round(r.height));
      this.W = W; this.H = H;
      this.canvas.width = Math.round(W * this.dpr); this.canvas.height = Math.round(H * this.dpr);
      this.canvas.style.width = W + 'px'; this.canvas.style.height = H + 'px';
      this.dirty = true;
      if (this.pendingFit !== undefined && W > 2 && H > 2) { const f = this.pendingFit; this.pendingFit = undefined; this.fit(f); }
    }
    setState(st) { this.state = st; this.dirty = true; if (this.follow && st.base && !this.userMoved) { const p = st.player || st.base; this.cx = p.x; this.cy = p.y; } }
    loop() {
      if (this.keys && Object.keys(this.keys).length && this.interactive && this.host.offsetParent) {
        const sp = 520 / this.s / 60 * (this.keys.shift ? 2.2 : 1);
        if (this.keys.w || this.keys.ArrowUp) { this.cy += sp; this.userMoved = true; this.dirty = true; }
        if (this.keys.s || this.keys.ArrowDown) { this.cy -= sp; this.userMoved = true; this.dirty = true; }
        if (this.keys.a || this.keys.ArrowLeft) { this.cx -= sp; this.userMoved = true; this.dirty = true; }
        if (this.keys.d || this.keys.ArrowRight) { this.cx += sp; this.userMoved = true; this.dirty = true; }
      }
      if (this.pings.length) this.dirty = true;
      if (this.dirty && this.W > 2 && this.host.offsetParent !== null) { this.dirty = false; this.draw(); }
      requestAnimationFrame(this.loop);
    }
    // ----------------------------------------------------------------------------------------------------- transforms
    sx(x) { return (x - this.cx) * this.s + this.W / 2; }
    sy(y) { return this.H / 2 - (y - this.cy) * this.s; }
    wx(px) { return (px - this.W / 2) / this.s + this.cx; }
    wy(py) { return (this.H / 2 - py) / this.s + this.cy; }
    center(x, y, s) { this.cx = x; this.cy = y; if (s) this.s = s; this.userMoved = true; this.dirty = true; }
    zoomAt(px, py, f) {
      const wx = this.wx(px), wy = this.wy(py);
      this.s = OB.clamp(this.s * f, 0.12, 16);
      this.cx = wx - (px - this.W / 2) / this.s; this.cy = wy + (py - this.H / 2) / this.s;
      this.userMoved = true; this.dirty = true;
    }
    fit(region) {
      this.region = !!region;
      if (this.W <= 2 || this.H <= 2) this.resize();
      if (this.W <= 2 || this.H <= 2) { this.pendingFit = region; return; } // not laid out yet: the resize observer re-fits
      const tm = (OB.S.catalog && OB.S.catalog.tuning.map) || { min_x: -2400, max_x: 2400, min_y: -2400, max_y: 2400 };
      if (region) { this.cx = 0; this.cy = 0; this.s = Math.min(this.W / (tm.max_x - tm.min_x + 400), this.H / (tm.max_y - tm.min_y + 400)); }
      else { this.cx = 0; this.cy = 0; this.s = Math.min(this.W / 400, this.H / 250); }
      this.s = OB.clamp(this.s, 0.12, 16);
      this.userMoved = false; this.dirty = true;
    }
    // --------------------------------------------------------------------------------------------------------- hit test
    hit(px, py) {
      const st = this.state; if (!st) return null;
      const r = Math.max(12, 1.8 * this.s);
      let best = null, bd = 1e9;
      for (const c of st.colonists) {
        if (c.state === 'away') continue;
        const d = Math.hypot(this.sx(c.x) - px, this.sy(c.y) - py);
        if (d < r && d < bd) { bd = d; best = { kind: 'colonist', id: c.id }; }
      }
      if (best) return best;
      for (const b of st.buildings) {
        const half = Math.max(10, 1.6 * this.s);
        if (Math.abs(this.sx(b.x) - px) < half && Math.abs(this.sy(b.y) - py) < half) return { kind: 'building', id: b.id, bp: b.bp };
      }
      for (const h of st.hordes) { const rr = Math.max(16, (5 + Math.sqrt(h.size) * 2) * this.s); if (Math.hypot(this.sx(h.x) - px, this.sy(h.y) - py) < rr) return { kind: 'horde', id: h.id }; }
      for (const r2 of st.raids) { if (Math.hypot(this.sx(r2.x) - px, this.sy(r2.y) - py) < 16) return { kind: 'raid', id: r2.id }; }
      for (const z of st.zones) { const half = Math.sqrt(z.tiles) * 2 * this.s; if (Math.abs(this.sx(z.x) - px) < half && Math.abs(this.sy(z.y) - py) < half) return { kind: 'zone', id: z.id }; }
      return null;
    }
    // ----------------------------------------------------------------------------------------------------- interaction
    bindMini() {
      this.canvas.style.cursor = 'pointer';
      this.canvas.addEventListener('click', e => {
        const r = this.canvas.getBoundingClientRect();
        const x = this.wx(e.clientX - r.left), y = this.wy(e.clientY - r.top);
        OB.post('focus', { x, y });
        OB.emit('mapfocus', { x, y });
      });
    }
    bind() {
      const cv = this.canvas;
      const pos = e => { const r = cv.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
      cv.addEventListener('contextmenu', e => e.preventDefault());
      cv.addEventListener('wheel', e => { e.preventDefault(); const [px, py] = pos(e); this.zoomAt(px, py, e.deltaY < 0 ? 1.18 : 1 / 1.18); }, { passive: false });
      cv.addEventListener('pointerdown', e => {
        const [px, py] = pos(e);
        cv.setPointerCapture(e.pointerId);
        this.down = { px, py, button: e.button, shift: e.shiftKey, moved: false, cx: this.cx, cy: this.cy, t: performance.now() };
        if (e.button === 1 || (e.button === 0 && this.keys.space)) { this.down.pan = true; cv.style.cursor = 'grabbing'; }
        if (e.button === 2) this.down.ctx = true;
      });
      cv.addEventListener('pointermove', e => {
        const [px, py] = pos(e);
        this.mouse = { px, py };
        const d = this.down;
        if (d) {
          if (Math.hypot(px - d.px, py - d.py) > 4) d.moved = true;
          if (d.pan) { this.cx = d.cx - (px - d.px) / this.s; this.cy = d.cy + (py - d.py) / this.s; this.userMoved = true; }
          else if (d.button === 0 && d.moved && !this.ghost) this.drag = { x0: d.px, y0: d.py, x1: px, y1: py };
          this.dirty = true;
        } else {
          const h = this.hit(px, py);
          const key = h ? h.kind + h.id : '';
          if (key !== this.hoverKey) { this.hoverKey = key; this.hover = h; this.dirty = true; cv.style.cursor = this.ghost ? 'crosshair' : h ? 'pointer' : 'default'; }
        }
        if (this.ghost) { this.updateGhost(px, py); this.dirty = true; }
      });
      cv.addEventListener('pointerup', e => {
        const [px, py] = pos(e);
        const d = this.down; this.down = null; cv.style.cursor = this.ghost ? 'crosshair' : 'default';
        if (!d) return;
        if (d.pan) return;
        if (d.button === 0) {
          if (this.ghost) { if (!d.moved) this.commitGhost(e.shiftKey); this.dirty = true; return; }
          if (this.drag && d.moved) {
            const x0 = Math.min(this.drag.x0, this.drag.x1), x1 = Math.max(this.drag.x0, this.drag.x1), y0 = Math.min(this.drag.y0, this.drag.y1), y1 = Math.max(this.drag.y0, this.drag.y1);
            const ids = this.state.colonists.filter(c => c.state !== 'away' && this.sx(c.x) >= x0 && this.sx(c.x) <= x1 && this.sy(c.y) >= y0 && this.sy(c.y) <= y1).map(c => c.id);
            this.drag = null; OB.select(ids, e.shiftKey);
            this.dirty = true; return;
          }
          this.drag = null;
          const h = this.hit(px, py);
          if (h && h.kind === 'colonist') { OB.select([h.id], e.shiftKey); if (e.detail >= 2) this.center(this.state.colonists.find(c => c.id === h.id).x, this.state.colonists.find(c => c.id === h.id).y); }
          else if (h && h.kind === 'building') { OB.emit('building_click', h); }
          else if (h && h.kind === 'zone') { OB.colony.setDock('zones'); OB.emit('zone_click', h); }
          else if (!e.shiftKey) OB.select([]);
        } else if (d.button === 2 && !d.moved) {
          if (this.ghost) { OB.build.cancel(); return; }
          this.rightClick(px, py, e);
        }
      });
      cv.addEventListener('pointerleave', () => { this.hover = null; this.hoverKey = ''; if (!this.down) this.dirty = true; });
      window.addEventListener('keydown', e => { if (!this.host.offsetParent) return; if (/INPUT|SELECT|TEXTAREA/.test((e.target || {}).tagName || '')) return; const k = e.key === ' ' ? 'space' : e.key.length === 1 ? e.key.toLowerCase() : e.key; if (['w', 'a', 's', 'd', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'space'].includes(k)) { this.keys[k] = true; } this.keys.shift = e.shiftKey; });
      window.addEventListener('keyup', e => { const k = e.key === ' ' ? 'space' : e.key.length === 1 ? e.key.toLowerCase() : e.key; delete this.keys[k]; this.keys.shift = e.shiftKey; });
      window.addEventListener('blur', () => { this.keys = {}; });
    }
    rightClick(px, py, e) {
      const st = this.state, wx = this.wx(px), wy = this.wy(py);
      const h = this.hit(px, py);
      const sel = OB.S.sel;
      const items = [];
      if (sel.length) items.push({ icon: 'run', label: 'Move ' + (sel.length > 1 ? sel.length + ' colonists' : OB.nick(OB.col(sel[0]).name)) + ' here', run: () => this.orderGoto(wx, wy) });
      if (h && h.kind === 'building') {
        const b = st.buildings.find(x => x.id === h.id);
        if (b) {
          items.push({ icon: 'trash', label: (b.state === 'planned' ? 'Cancel ' : 'Dismantle ') + OB.bp(b.bp).name, run: () => OB.order('colony', 'cancel_blueprint', { id: b.id }) });
          const d = OB.bp(b.bp);
          if (d.power_use > 0 && b.state === 'built') items.push({ icon: 'bolt', label: (b.enabled ? 'Switch off ' : 'Switch on ') + d.name, run: () => OB.order('colony', 'toggle_building', { id: b.id, enabled: !b.enabled }) });
        }
      }
      items.push({ icon: 'zone', label: 'New stockpile zone here', run: () => OB.zones && OB.zones.createAt(wx, wy) });
      items.push({ icon: 'crosshair', label: 'Centre map here', run: () => this.center(wx, wy) });
      if (!sel.length && items.length === 2) items.unshift({ icon: 'info', label: 'Select colonists first (click or drag)', disabled: true });
      OB.ctx(e.clientX, e.clientY, items);
    }
    orderGoto(wx, wy) {
      const sel = OB.S.sel; if (!sel.length) return;
      sel.forEach((id, i) => OB.order(id, 'goto', { x: wx + (i % 3) * 2.2 - 2.2, y: wy - Math.floor(i / 3) * 2.2, z: 0 }));
      this.pings.push({ x: wx, y: wy, t: performance.now() });
      this.dirty = true;
    }
    // placement ghost: grid snap + local validation (same rules as sim/blueprints.lua why_not)
    updateGhost(px, py) {
      const g = this.ghost, grid = 2;
      g.x = Math.round(this.wx(px) / grid) * grid; g.y = Math.round(this.wy(py) / grid) * grid;
      if (g.zone) { g.ok = true; g.reason = 'ok'; return; }
      const v = OB.build.validate(g.bp, g.x, g.y);
      g.ok = v.ok; g.reason = v.reason;
    }
    commitGhost(multi) {
      const g = this.ghost; if (!g) return;
      if (g.zone) { OB.zones.commit(g); this.pings.push({ x: g.x, y: g.y, t: performance.now(), c: '#7ee0c3' }); return; }
      if (!g.ok) { OB.toast('warn', OB.reason(g.reason), { title: 'Cannot build here' }); return; }
      OB.post('place', { op: 'commit', bp: g.bp, x: g.x, y: g.y });
      this.pings.push({ x: g.x, y: g.y, t: performance.now(), c: '#35d39a' });
      if (!multi) OB.build.cancel(true);
    }
    // -------------------------------------------------------------------------------------------------------- drawing
    draw() {
      const ctx = this.ctx, W = this.W, H = this.H, st = this.state;
      ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
      ctx.clearRect(0, 0, W, H);
      const rem = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16;
      this.rem = rem;
      const mini = this.mode === 'mini';
      this.drawTerrain(ctx, W, H, mini);
      if (!st) return;
      const s = this.s;
      if (this.layers.grid && !mini) this.drawGrid(ctx, W, H);
      if (this.layers.districts && s < 1.6 && (!mini || s < 0.3)) this.drawDistricts(ctx, st, mini);
      this.drawBase(ctx, st, mini);
      if (this.layers.zones) this.drawZones(ctx, st, mini);
      this.drawExpeditions(ctx, st);
      this.drawBuildings(ctx, st, mini);
      this.drawPiles(ctx, st);
      this.drawZoneLabels(ctx, st);
      this.drawCaravans(ctx, st);
      this.drawHordes(ctx, st, mini);
      this.drawRaids(ctx, st);
      this.drawColonists(ctx, st, mini);
      this.drawPlayer(ctx, st);
      if (this.ghost) this.drawGhost(ctx);
      this.drawPings(ctx);
      if (this.drag) { ctx.fillStyle = 'rgba(246,180,79,.12)'; ctx.strokeStyle = 'rgba(246,180,79,.9)'; ctx.lineWidth = 1.5; const d = this.drag; ctx.fillRect(d.x0, d.y0, d.x1 - d.x0, d.y1 - d.y0); ctx.strokeRect(d.x0, d.y0, d.x1 - d.x0, d.y1 - d.y0); }
      if (!mini) this.drawScale(ctx, W, H, rem);
      if (st.night && !mini) { ctx.fillStyle = 'rgba(10,18,50,.18)'; ctx.fillRect(0, 0, W, H); }
      if (!st.res.power_ok && !mini) { ctx.fillStyle = 'rgba(0,0,0,.22)'; ctx.fillRect(0, 0, W, H); }
    }
    drawTerrain(ctx, W, H, mini) {
      const g = ctx.createRadialGradient(W / 2, H / 2, 0, W / 2, H / 2, Math.hypot(W, H) / 1.6);
      g.addColorStop(0, mini ? '#17202c' : '#162030'); g.addColorStop(1, mini ? '#0b1018' : '#080c13');
      ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
      if (mini) return;
      // faint contour noise so the backdrop reads as terrain, not a flat panel
      ctx.save(); ctx.globalAlpha = 0.07; ctx.strokeStyle = '#8fb4ff'; ctx.lineWidth = 1;
      const r = hashRand('terrain');
      for (let i = 0; i < 26; i++) {
        const ox = (r() - 0.5) * 2600, oy = (r() - 0.5) * 2600, rad = 120 + r() * 520;
        ctx.beginPath();
        for (let a = 0; a <= 6.4; a += 0.16) { const k = 1 + 0.18 * Math.sin(a * 3 + i) + 0.1 * Math.cos(a * 5 + i * 2); const x = this.sx(ox + Math.cos(a) * rad * k), y = this.sy(oy + Math.sin(a) * rad * k); if (a === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y); }
        ctx.stroke();
      }
      ctx.restore();
    }
    drawGrid(ctx, W, H) {
      const s = this.s;
      const steps = [10, 20, 50, 100, 200, 500, 1000].find(u => u * s >= 46) || 1000;
      const x0 = this.wx(0), x1 = this.wx(W), y1 = this.wy(0), y0 = this.wy(H);
      ctx.lineWidth = 1;
      for (let x = Math.floor(x0 / steps) * steps, n = 0; x <= x1 && n < 400; x += steps, n++) {
        const major = Math.round(x / steps) % 5 === 0;
        ctx.strokeStyle = major ? 'rgba(150,180,230,.16)' : 'rgba(150,180,230,.07)';
        const px = Math.round(this.sx(x)) + 0.5; ctx.beginPath(); ctx.moveTo(px, 0); ctx.lineTo(px, H); ctx.stroke();
      }
      for (let y = Math.floor(y0 / steps) * steps, n = 0; y <= y1 && n < 400; y += steps, n++) {
        const major = Math.round(y / steps) % 5 === 0;
        ctx.strokeStyle = major ? 'rgba(150,180,230,.16)' : 'rgba(150,180,230,.07)';
        const py = Math.round(this.sy(y)) + 0.5; ctx.beginPath(); ctx.moveTo(0, py); ctx.lineTo(W, py); ctx.stroke();
      }
      if (this.layers.cells || s < 0.5) {
        ctx.setLineDash([6, 6]); ctx.strokeStyle = 'rgba(255,120,120,.22)';
        for (let x = Math.floor(x0 / 200) * 200, n = 0; x <= x1 && n < 200; x += 200, n++) { const px = Math.round(this.sx(x)) + 0.5; ctx.beginPath(); ctx.moveTo(px, 0); ctx.lineTo(px, H); ctx.stroke(); }
        for (let y = Math.floor(y0 / 200) * 200, n = 0; y <= y1 && n < 200; y += 200, n++) { const py = Math.round(this.sy(y)) + 0.5; ctx.beginPath(); ctx.moveTo(0, py); ctx.lineTo(W, py); ctx.stroke(); }
        ctx.setLineDash([]);
      }
    }
    drawDistricts(ctx, st, mini) {
      const cat = OB.S.catalog; if (!cat) return;
      for (const d of cat.districts) {
        const x = this.sx(d.x), y = this.sy(d.y), r = d.radius * this.s;
        if (x + r < 0 || y + r < 0 || x - r > this.W || y - r > this.H) continue;
        const c = DANGER[d.danger - 1] || '#fff';
        ctx.beginPath(); ctx.arc(x, y, r, 0, 6.2832);
        ctx.fillStyle = c + '14'; ctx.fill(); ctx.strokeStyle = c + '66'; ctx.lineWidth = 1.5; ctx.setLineDash([8, 6]); ctx.stroke(); ctx.setLineDash([]);
        if (this.layers.labels && !mini) {
          ctx.fillStyle = '#c9d2e3'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
          ctx.font = '600 ' + Math.max(11, this.rem * 0.8) + 'px Inter, sans-serif'; ctx.fillText(d.name, x, y - 7);
          ctx.fillStyle = c; ctx.font = '600 ' + Math.max(10, this.rem * 0.68) + 'px Inter, sans-serif'; ctx.fillText('danger ' + d.danger + ' · ' + d.kind, x, y + 9);
        }
      }
    }
    drawBase(ctx, st, mini) {
      const b = st.base, x = this.sx(b.x), y = this.sy(b.y);
      const ring = (r, col, w, dash, fill) => { ctx.beginPath(); ctx.arc(x, y, r * this.s, 0, 6.2832); if (fill) { ctx.fillStyle = fill; ctx.fill(); } ctx.strokeStyle = col; ctx.lineWidth = w; ctx.setLineDash(dash || []); ctx.stroke(); ctx.setLineDash([]); };
      if (this.s < 1.2) ring(b.alert_radius, 'rgba(255,93,108,.28)', 1.2, [4, 8]);
      ring(b.build_radius, 'rgba(246,180,79,.35)', 1.4, [10, 8]);
      ring(b.radius, 'rgba(63,224,197,.55)', 2, null, 'rgba(63,224,197,.05)');
      if (!mini && this.s < 2.5) { ctx.fillStyle = '#3fe0c5'; ctx.font = '700 ' + Math.max(11, this.rem * 0.75) + 'px Inter'; ctx.textAlign = 'center'; ctx.textBaseline = 'top'; ctx.fillText('BASE', x, y + b.radius * this.s + 6); }
    }
    drawZones(ctx, st, mini) {
      for (const z of st.zones) {
        const half = Math.sqrt(z.tiles) * 2.1 * this.s;
        const x = this.sx(z.x), y = this.sy(z.y);
        ctx.fillStyle = z.main ? 'rgba(126,167,255,.10)' : 'rgba(126,224,195,.10)';
        ctx.strokeStyle = z.main ? 'rgba(126,167,255,.6)' : 'rgba(126,224,195,.6)'; ctx.lineWidth = 1.4; ctx.setLineDash([6, 5]);
        ctx.fillRect(x - half, y - half, half * 2, half * 2); ctx.strokeRect(x - half, y - half, half * 2, half * 2); ctx.setLineDash([]);
        if (!mini && this.s > 1.4) {
          const used = z.cap ? z.w / z.cap : 0;
          ctx.fillStyle = 'rgba(255,255,255,.12)'; ctx.fillRect(x - half, y + half + 3, half * 2, 3);
          ctx.fillStyle = used > 0.9 ? '#ff5d6c' : '#7aa7ff'; ctx.fillRect(x - half, y + half + 3, half * 2 * Math.min(1, used), 3);
        }
      }
    }
    // zone names are drawn AFTER the buildings and piles (so nothing covers them), on a dark pill, and never over each other: a label that would overlap
    // one already drawn tries the other side of its zone, then is skipped (zoom in to see it)
    drawZoneLabels(ctx, st) {
      if (this.s <= 2.2) return; // at a wider zoom the names would sit on top of the colonists
      const fs = Math.max(10, this.rem * 0.68), placed = [];
      ctx.font = '600 ' + fs + 'px Inter'; ctx.textAlign = 'center'; ctx.textBaseline = 'alphabetic';
      for (const z of st.zones) {
        const half = Math.sqrt(z.tiles) * 2.1 * this.s, x = this.sx(z.x), y = this.sy(z.y);
        const text = z.name + '  P' + z.prio, tw = ctx.measureText(text).width;
        for (const below of [false, true]) {
          const base = below ? y + half + 10 + fs : y - half - 5;
          const box = { x0: x - tw / 2 - 5, x1: x + tw / 2 + 5, y0: base - fs - 3, y1: base + 4 };
          if (placed.some(b => box.x0 < b.x1 && box.x1 > b.x0 && box.y0 < b.y1 && box.y1 > b.y0)) continue;
          placed.push(box);
          ctx.fillStyle = 'rgba(8,12,20,.78)'; ctx.fillRect(box.x0, box.y0, box.x1 - box.x0, box.y1 - box.y0);
          ctx.fillStyle = '#c4d2ee'; ctx.fillText(text, x, base);
          break;
        }
      }
    }
    drawExpeditions(ctx, st) {
      const cat = OB.S.catalog; if (!cat || this.mode === 'mini') return;
      const g = cat.tuning.base.garage;
      for (const x of st.expeditions) {
        if (x.state === 'forming') continue;
        const d = cat.districts.find(q => q.id === x.district); if (!d) continue;
        ctx.strokeStyle = 'rgba(102,173,255,.6)'; ctx.lineWidth = 1.6; ctx.setLineDash([3, 7]);
        ctx.beginPath(); ctx.moveTo(this.sx(g.x), this.sy(g.y)); ctx.lineTo(this.sx(d.x), this.sy(d.y)); ctx.stroke(); ctx.setLineDash([]);
        const im = OB.iconImage('truck', '#66adff', () => (this.dirty = true));
        if (im._ok) ctx.drawImage(im, this.sx(d.x) - 11, this.sy(d.y) - 11, 22, 22);
      }
    }
    drawBuildings(ctx, st, mini) {
      const s = this.s;
      const bpS = Math.max(mini ? 4 : 12, Math.min(40, 4.4 * s));
      for (const b of st.buildings) {
        const x = this.sx(b.x), y = this.sy(b.y);
        if (x < -40 || y < -40 || x > this.W + 40 || y > this.H + 40) continue;
        const d = OB.bp(b.bp), col = OB.catColor[d.cat] || '#9aa7bd';
        const built = b.state === 'built';
        const h = bpS / 2;
        if (mini) { ctx.fillStyle = built ? col : col + '66'; ctx.fillRect(x - h / 1.4, y - h / 1.4, h * 1.4, h * 1.4); continue; }
        ctx.save();
        ctx.beginPath(); const rr = Math.min(6, h * 0.35); ctx.roundRect ? ctx.roundRect(x - h, y - h, h * 2, h * 2, rr) : ctx.rect(x - h, y - h, h * 2, h * 2);
        ctx.fillStyle = built ? 'rgba(14,20,30,.92)' : 'rgba(14,20,30,.5)'; ctx.fill();
        ctx.lineWidth = built ? 1.8 : 1.4; ctx.strokeStyle = built ? col : col + 'aa'; if (!built) ctx.setLineDash([4, 3]); ctx.stroke(); ctx.setLineDash([]);
        if (h > 8) { const im = OB.iconImage(OB.bpIcon(b.bp), built ? col : col + '99', () => (this.dirty = true)); if (im._ok) { const q = h * 1.15; ctx.globalAlpha = built ? 1 : 0.8; ctx.drawImage(im, x - q / 2, y - q / 2, q, q); ctx.globalAlpha = 1; } }
        if (!built) { // progress arc + missing materials flag
          ctx.beginPath(); ctx.arc(x, y, h + 3, -1.5708, -1.5708 + 6.2832 * (b.pct / 100)); ctx.strokeStyle = '#35d39a'; ctx.lineWidth = 2.2; ctx.stroke();
          if (b.missing && h > 8) { ctx.fillStyle = '#f5a524'; ctx.beginPath(); ctx.arc(x + h, y - h, 4, 0, 6.2832); ctx.fill(); }
        } else if (b.hp < b.hp_max * 0.995) {
          ctx.fillStyle = 'rgba(255,255,255,.15)'; ctx.fillRect(x - h, y + h + 2, h * 2, 3);
          const f = b.hp / b.hp_max; ctx.fillStyle = f < 0.35 ? '#ff5d6c' : f < 0.7 ? '#f5a524' : '#35d39a'; ctx.fillRect(x - h, y + h + 2, h * 2 * f, 3);
        }
        if (built && d.power_use > 0 && !b.powered) { ctx.fillStyle = '#ff5d6c'; ctx.beginPath(); ctx.arc(x + h, y - h, 4.2, 0, 6.2832); ctx.fill(); }
        if (this.hover && this.hover.kind === 'building' && this.hover.id === b.id) { ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.6; ctx.strokeRect(x - h - 3, y - h - 3, h * 2 + 6, h * 2 + 6); }
        ctx.restore();
      }
    }
    drawPiles(ctx, st) {
      if (this.s < 1.4) return;
      for (const p of st.piles) { const x = this.sx(p.x), y = this.sy(p.y); ctx.fillStyle = '#d7a36e'; ctx.fillRect(x - 5, y - 5, 10, 10); ctx.strokeStyle = '#2a1c0c'; ctx.lineWidth = 1.2; ctx.strokeRect(x - 5, y - 5, 10, 10); if (this.s > 3) { ctx.fillStyle = '#e9d3b4'; ctx.font = '600 10px Inter'; ctx.textAlign = 'center'; ctx.fillText(p.n, x, y + 17); } }
    }
    drawCaravans(ctx, st) {
      for (const c of st.caravans) {
        const x = this.sx(c.x), y = this.sy(c.y);
        ctx.beginPath(); ctx.arc(x, y, 13, 0, 6.2832); ctx.fillStyle = 'rgba(246,208,77,.15)'; ctx.fill(); ctx.strokeStyle = FAC[c.faction] || '#f6d04d'; ctx.lineWidth = 2; ctx.stroke();
        const im = OB.iconImage('trade', '#f6d04d', () => (this.dirty = true)); if (im._ok) ctx.drawImage(im, x - 8, y - 8, 16, 16);
        if (this.mode !== 'mini' && this.s > 1) { ctx.fillStyle = '#f6d04d'; ctx.font = '600 ' + Math.max(10, this.rem * 0.68) + 'px Inter'; ctx.textAlign = 'center'; ctx.textBaseline = 'top'; ctx.fillText(c.name + ' · ' + OB.fmt.dur(c.leave_in), x, y + 17); }
      }
    }
    drawHordes(ctx, st, mini) {
      const t = performance.now();
      for (const hd of st.hordes) {
        const x = this.sx(hd.x), y = this.sy(hd.y);
        if (x < -80 || y < -80 || x > this.W + 80 || y > this.H + 80) continue;
        const assault = hd.state === 'assault';
        const rWorld = 5 + Math.sqrt(hd.size) * 2.1;
        const r = Math.max(mini ? 6 : 15, rWorld * this.s);
        const col = assault ? '#ff3b4d' : hd.mat > 0 ? '#ff7a3d' : '#ff5d6c';
        const g = ctx.createRadialGradient(x, y, 0, x, y, r);
        g.addColorStop(0, col + (assault ? '88' : '55')); g.addColorStop(1, col + '00');
        ctx.fillStyle = g; ctx.beginPath(); ctx.arc(x, y, r * 1.25, 0, 6.2832); ctx.fill();
        if (this.s > 2.2 && !mini) { // individual shamblers
          const rnd = hashRand(hd.id); ctx.fillStyle = col;
          for (let i = 0; i < Math.min(hd.size, 60); i++) { const a = rnd() * 6.2832, d = Math.sqrt(rnd()) * rWorld; ctx.fillRect(x + Math.cos(a) * d * this.s - 1.5, y - Math.sin(a) * d * this.s - 1.5, 3, 3); }
        }
        ctx.beginPath(); ctx.arc(x, y, Math.max(mini ? 4 : 11, r * 0.5), 0, 6.2832); ctx.fillStyle = 'rgba(40,6,12,.82)'; ctx.fill();
        ctx.lineWidth = hd.mat > 0 ? 2.4 : 1.6; ctx.strokeStyle = col; if (hd.mat <= 0) ctx.setLineDash([3, 3]); ctx.stroke(); ctx.setLineDash([]);
        if (assault) { ctx.beginPath(); ctx.arc(x, y, r * (0.8 + 0.25 * ((t % 1200) / 1200)), 0, 6.2832); ctx.strokeStyle = 'rgba(255,59,77,' + (0.7 - 0.6 * ((t % 1200) / 1200)) + ')'; ctx.lineWidth = 2; ctx.stroke(); }
        if (!mini) {
          ctx.fillStyle = '#fff'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle'; ctx.font = '700 ' + Math.max(11, Math.min(18, r * 0.5)) + 'px "Barlow Condensed", Inter';
          ctx.fillText(hd.size, x, y + 1);
          if (r > 22) { ctx.font = '600 ' + Math.max(9, this.rem * 0.62) + 'px Inter'; ctx.fillStyle = col; ctx.textBaseline = 'top'; ctx.fillText(assault ? 'ASSAULT' : hd.mat > 0 ? 'LIVE ' + hd.mat : hd.state.toUpperCase(), x, y + r * 0.62); }
          if (hd.state === 'seek' || hd.state === 'wander') { ctx.strokeStyle = col; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(x + hd.hx * r * 0.55, y - hd.hy * r * 0.55); ctx.lineTo(x + hd.hx * r * 1.25, y - hd.hy * r * 1.25); ctx.stroke(); }
        }
      }
    }
    drawRaids(ctx, st) {
      for (const r of st.raids) {
        const x = this.sx(r.x), y = this.sy(r.y), c = FAC[r.faction] || '#ff5d6c';
        ctx.beginPath(); ctx.moveTo(x, y - 14); ctx.lineTo(x + 12, y + 9); ctx.lineTo(x - 12, y + 9); ctx.closePath();
        ctx.fillStyle = 'rgba(20,8,10,.9)'; ctx.fill(); ctx.strokeStyle = c; ctx.lineWidth = 2.2; ctx.stroke();
        ctx.fillStyle = c; ctx.font = '700 12px "Barlow Condensed", Inter'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle'; ctx.fillText(r.count, x, y + 2);
        if (this.mode !== 'mini') { ctx.font = '600 ' + Math.max(10, this.rem * 0.66) + 'px Inter'; ctx.textBaseline = 'top'; ctx.fillText(r.name, x, y + 14); }
      }
    }
    drawColonists(ctx, st, mini) {
      const s = this.s, R = mini ? 5 : OB.clamp(2.3 * s, 12, 21);
      const sel = new Set(OB.S.sel);
      for (const c of st.colonists) {
        if (c.state === 'away') continue;
        const x = this.sx(c.x), y = this.sy(c.y);
        if (x < -30 || y < -30 || x > this.W + 30 || y > this.H + 30) continue;
        const col = c.downed ? STATE_COL.downed : c.drafted ? STATE_COL.drafted : STATE_COL[c.state] || '#9aa7bd';
        const isSel = sel.has(c.id), primary = OB.S.primary === c.id;
        if (mini) { ctx.beginPath(); ctx.arc(x, y, R, 0, 6.2832); ctx.fillStyle = col; ctx.fill(); if (isSel) { ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.5; ctx.stroke(); } continue; }
        if (isSel) { ctx.beginPath(); ctx.arc(x, y, R + 5, 0, 6.2832); ctx.strokeStyle = primary ? '#ffd38a' : '#fff'; ctx.lineWidth = 2; ctx.stroke(); }
        if (c.drafted) { ctx.beginPath(); ctx.arc(x, y, R + 2.5, 0, 6.2832); ctx.strokeStyle = '#f6b44f'; ctx.lineWidth = 1.5; ctx.stroke(); }
        ctx.beginPath(); ctx.arc(x, y, R, 0, 6.2832); ctx.fillStyle = 'rgba(12,17,26,.95)'; ctx.fill();
        ctx.lineWidth = 2.4; ctx.strokeStyle = col; ctx.stroke();
        // mood arc
        ctx.beginPath(); ctx.arc(x, y, R - 3.4, -1.5708, -1.5708 + 6.2832 * (c.mood / 100)); ctx.strokeStyle = c.mood < 30 ? '#ff5d6c' : c.mood < 45 ? '#f5a524' : '#35d39a'; ctx.lineWidth = 1.6; ctx.stroke();
        ctx.fillStyle = '#eaf0f9'; ctx.font = '700 ' + Math.round(R * 0.78) + 'px Inter'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle'; ctx.fillText(OB.initials(c.name)[0], x, y + 0.5);
        if (c.hp < c.hp_max * 0.98) { ctx.fillStyle = 'rgba(255,255,255,.18)'; ctx.fillRect(x - R, y + R + 3, R * 2, 3); ctx.fillStyle = c.hp / c.hp_max < 0.35 ? '#ff5d6c' : '#35d39a'; ctx.fillRect(x - R, y + R + 3, R * 2 * (c.hp / c.hp_max), 3); }
        if (c.bleeding > 0.02) { ctx.fillStyle = '#ff3b5c'; ctx.beginPath(); ctx.arc(x + R, y - R, 3.2, 0, 6.2832); ctx.fill(); }
        if ((isSel || (this.hover && this.hover.id === c.id) || s > 6) && this.layers.labels) {
          ctx.font = '600 ' + Math.max(10, this.rem * 0.7) + 'px Inter'; ctx.textAlign = 'center'; ctx.textBaseline = 'bottom';
          const nm = OB.nick(c.name), tw = ctx.measureText(nm).width;
          ctx.fillStyle = 'rgba(8,12,20,.8)'; ctx.fillRect(x - tw / 2 - 5, y - R - 20, tw + 10, 16);
          ctx.fillStyle = '#eaf0f9'; ctx.fillText(nm, x, y - R - 7);
        }
      }
    }
    drawPlayer(ctx, st) {
      if (!st.player) return;
      const x = this.sx(st.player.x), y = this.sy(st.player.y);
      ctx.save(); ctx.translate(x, y);
      ctx.beginPath(); ctx.moveTo(0, -11); ctx.lineTo(8, 9); ctx.lineTo(0, 5); ctx.lineTo(-8, 9); ctx.closePath();
      ctx.fillStyle = '#3fe0c5'; ctx.shadowColor = '#3fe0c5'; ctx.shadowBlur = 8; ctx.fill(); ctx.restore();
    }
    drawGhost(ctx) {
      const g = this.ghost; if (g.x == null) return;
      if (g.zone) {
        const x = this.sx(g.x), y = this.sy(g.y), half = Math.sqrt(g.tiles) * 2.1 * this.s;
        ctx.fillStyle = 'rgba(126,224,195,.16)'; ctx.strokeStyle = '#7ee0c3'; ctx.lineWidth = 2; ctx.setLineDash([6, 5]); ctx.fillRect(x - half, y - half, half * 2, half * 2); ctx.strokeRect(x - half, y - half, half * 2, half * 2); ctx.setLineDash([]);
        return;
      }
      const x = this.sx(g.x), y = this.sy(g.y), d = OB.bp(g.bp), h = Math.max(12, Math.min(40, 4.4 * this.s)) / 2;
      const col = g.ok ? '#35d39a' : '#ff5d6c';
      ctx.fillStyle = g.ok ? 'rgba(53,211,154,.18)' : 'rgba(255,93,108,.18)'; ctx.fillRect(x - h, y - h, h * 2, h * 2);
      ctx.strokeStyle = col; ctx.lineWidth = 2; ctx.setLineDash([5, 4]); ctx.strokeRect(x - h, y - h, h * 2, h * 2); ctx.setLineDash([]);
      const im = OB.iconImage(OB.bpIcon(g.bp), col, () => (this.dirty = true)); if (im._ok) ctx.drawImage(im, x - h * 0.6, y - h * 0.6, h * 1.2, h * 1.2);
      ctx.font = '600 ' + Math.max(11, this.rem * 0.75) + 'px Inter'; ctx.textAlign = 'center'; ctx.textBaseline = 'top';
      const label = d.name + (g.ok ? '' : ' — ' + OB.reason(g.reason));
      const tw = ctx.measureText(label).width;
      ctx.fillStyle = 'rgba(8,12,20,.85)'; ctx.fillRect(x - tw / 2 - 6, y + h + 5, tw + 12, 20); ctx.fillStyle = col; ctx.fillText(label, x, y + h + 9);
      // snap guide lines to the base
      ctx.strokeStyle = 'rgba(255,255,255,.12)'; ctx.setLineDash([2, 6]); ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, this.H); ctx.moveTo(0, y); ctx.lineTo(this.W, y); ctx.stroke(); ctx.setLineDash([]);
    }
    drawPings(ctx) {
      const now = performance.now();
      this.pings = this.pings.filter(p => now - p.t < 900);
      for (const p of this.pings) {
        const k = (now - p.t) / 900;
        ctx.beginPath(); ctx.arc(this.sx(p.x), this.sy(p.y), 6 + 26 * k, 0, 6.2832); ctx.strokeStyle = (p.c || '#ffd38a'); ctx.globalAlpha = 1 - k; ctx.lineWidth = 2.5; ctx.stroke(); ctx.globalAlpha = 1;
      }
    }
    drawScale(ctx, W, H, rem) {
      // scale bar + north marker (bottom-right)
      const steps = [5, 10, 20, 50, 100, 200, 500, 1000, 2000];
      const u = steps.find(v => v * this.s >= 90) || 2000, px = u * this.s;
      const x = W - rem * 1.5 - px, y = H - rem * 1.6;
      ctx.strokeStyle = 'rgba(255,255,255,.7)'; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(x, y - 5); ctx.lineTo(x, y); ctx.lineTo(x + px, y); ctx.lineTo(x + px, y - 5); ctx.stroke();
      ctx.fillStyle = 'rgba(255,255,255,.8)'; ctx.font = '600 ' + Math.max(10, rem * 0.72) + 'px Inter'; ctx.textAlign = 'right'; ctx.textBaseline = 'bottom'; ctx.fillText(u + ' m', x + px, y - 8);
    }
  }
  OB.MapView = MapView;
  // registry so main.js can push every state update to every live view (hidden ones just mark themselves dirty)
  OB.map = { views: [], reg(v) { this.views.push(v); return v; }, updateAll(st) { for (const v of this.views) v.setState(st); } };
})();
