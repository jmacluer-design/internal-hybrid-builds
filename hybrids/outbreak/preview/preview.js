/* Outbreak preview shell. Runs the REAL resource Lua (sim + shared/host.lua) in the browser through wasmoon (Lua 5.4 -> WebAssembly) and plays
   the part of the FiveM server + client: it forwards Host output to the NUI iframe as {action, data} messages (exactly what SendNUIMessage
   delivers in game) and routes NUI callbacks (window.parent.__previewBridge.post) back into the Host. No GTA, no network, no CDN. */
(async function () {
  'use strict';
  const qs = new URLSearchParams(location.search);
  // the NUI iframe starts loading at once and looks for this bridge: define it synchronously and buffer calls until the Lua sim is up
  const pending = [];
  let handlePost = (name, data) => pending.push([name, data]);
  window.__previewBridge = { post: (name, data) => handlePost(name, data) };
  const $ = s => document.querySelector(s);
  const nui = $('#nui');
  if (qs.get('bench') === '0') document.body.classList.add('nobench');

  const P = { auto: qs.get('auto') !== '0', mode: 'survival', player: { x: 0, y: 0 }, heading: 20, uiReady: false, queue: [], counts: { out: 0, ui: 0, batches: 0 }, log: [], hudLast: null, clockLast: null, stateLast: null, catalog: null, errors: [] };
  let W3D = null, W3DUI = null;   // the optional 3D world (world3d.js) and its shell integration (world3d/ui.js)
  const world = { on: false, view: '2d', failed: '' };
  const mem = new Map();
  const store = {
    get: k => { try { const v = localStorage.getItem('ob.' + k); return v === null ? null : v; } catch (e) { return mem.has(k) ? mem.get(k) : null; } },
    set: (k, v) => { try { localStorage.setItem('ob.' + k, v); } catch (e) { mem.set(k, v); } },
    del: k => { try { localStorage.removeItem('ob.' + k); } catch (e) { mem.delete(k); } },
  };

  // ------------------------------------------------------------------------------------------------------ Lua engine
  const { LuaFactory } = window.wasmoon;
  const factory = new LuaFactory('vendor/glue.wasm');
  const lua = await factory.createEngine();
  const B = window.OUTBREAK_LUA;
  lua.global.set('read_file', p => (Object.prototype.hasOwnProperty.call(B, p) ? B[p] : null));
  lua.global.set('js_send', (topic, text) => { try { route(topic, JSON.parse(text)); } catch (e) { P.errors.push('route ' + topic + ': ' + e.message); console.error(e); } });
  lua.global.set('js_store_get', k => store.get(k));
  lua.global.set('js_store_set', (k, v) => store.set(k, v));
  lua.global.set('js_store_del', k => store.del(k));
  lua.global.set('js_log', (lvl, text) => { P.log.push('[' + lvl + '] ' + text); if (lvl === 'error') P.errors.push(text); });
  await lua.doString(B['preview/glue.lua']);
  const L = {};
  for (const n of ['P_new', 'P_advance', 'P_ui', 'P_order', 'P_in', 'P_status', 'P_hash', 'P_state', 'P_catalog', 'P_set_scale', 'P_set_speed', 'P_resync', 'P_hash_runs', 'P_why_not']) L[n] = lua.global.get(n);
  $('#loading').remove();

  // ---------------------------------------------------------------------------------------------- host <-> NUI routing
  function toUI(action, data) {
    const msg = { action, data };
    if (!P.uiReady && action !== 'boot') { P.queue.push(msg); return; }
    try { nui.contentWindow.postMessage(msg, '*'); } catch (e) { /* iframe gone */ }
  }
  function route(topic, d) {
    switch (topic) {
      case 'outbreak:events':
        P.counts.batches++; P.counts.out += d.events.length;
        for (const ev of d.events) { P.log.push(ev.type + (ev.id ? ' ' + ev.id : '') + (ev.kind ? ' ' + ev.kind : '') + (ev.text ? ': ' + ev.text : '')); }
        if (P.log.length > 60) P.log.splice(0, P.log.length - 60);
        if (d.reset) toUI('events', d.events); else toUI('events', d.events);
        if (W3D) W3D.onEvents(d.events);
        break;
      case 'outbreak:state': P.stateLast = d; toUI('state', d); break;
      case 'outbreak:hud': P.hudLast = d; toUI('hud', d); break;
      case 'outbreak:clock': P.clockLast = d; break;
      case 'outbreak:catalog': P.catalog = d; toUI('catalog', d); if (W3D) W3D.setCatalog(d); break;
      case 'outbreak:ui': P.counts.ui++; toUI(d.name, d.data); break;
      default: break;
    }
  }
  function setMode(m) {
    P.mode = m === 'colony' ? 'colony' : 'survival';
    L.P_ui('screens', JSON.stringify({ colony: P.mode === 'colony' }));
    toUI('mode', { mode: P.mode });
    document.querySelectorAll('#bench [data-mode]').forEach(b => b.classList.toggle('on', b.dataset.mode === P.mode));
    drawBackdrop(true);
    if (W3DUI) W3DUI.onMode(P.mode);
  }
  // callbacks the NUI page posts (fetch('https://outbreak/<name>') in game)
  const bridge = {
    post(name, data) {
      switch (name) {
        case 'ready':
          P.uiReady = true;
          toUI('boot', { preview: true, resource: 'outbreak', version: 'preview' });
          L.P_ui('request_catalog', '{}');
          for (const m of P.queue.splice(0)) nui.contentWindow.postMessage(m, '*');
          setMode(qs.get('mode') || P.mode);
          L.P_ui('request_state', '{}');
          sendCompass();
          if (qs.get('screen')) toUI('screen', { name: qs.get('screen') });
          break;
        case 'order': L.P_order(JSON.stringify(data)); break;
        case 'ui': L.P_ui(String(data.name), JSON.stringify(data.data || {})); break;
        case 'mode': setMode(data.mode); break;
        case 'place': if (data.op && data.op !== 'commit') break; L.P_order(JSON.stringify({ id: 'colony', kind: 'place_blueprint', target: { bp: data.bp, pos: { x: data.x, y: data.y, z: 0 } } })); break;
        case 'key': if (W3DUI) W3DUI.key(data.k, !!data.down); break;      // camera keys the NUI forwards to the game client: here they drive the 3D camera
        case 'focus': if (W3DUI && data) W3DUI.focus(+data.x, +data.y); break; // 'centre the camera here' (roster, minimap)
        default: break; // screen / mouse: nothing to do without a game
      }
    },
  };

  // ------------------------------------------------------------------------------------------- stand-in world backdrop
  const cv = $('#world'), cx = cv.getContext('2d');
  function rnd(seed) { return () => { seed |= 0; seed = (seed + 0x6D2B79F5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
  let lastDaylight = -1;
  function drawBackdrop(force) {
    if (world.on) return; // the 3D canvas replaces this stand-in
    const day = P.hudLast ? P.hudLast.daylight : 1;
    if (!force && Math.abs(day - lastDaylight) < 0.02) return;
    lastDaylight = day;
    const W = (cv.width = Math.max(2, cv.clientWidth)), H = (cv.height = Math.max(2, cv.clientHeight));
    if (P.mode === 'colony') { cx.fillStyle = '#0a0e15'; cx.fillRect(0, 0, W, H); return; }
    const mix = (a, b, t) => a.map((v, i) => Math.round(v + (b[i] - v) * t));
    const top = mix([8, 12, 28], [92, 150, 214], day), mid = mix([26, 30, 58], [196, 214, 232], day), hor = mix([40, 36, 62], [255, 214, 170], Math.min(1, day * 1.2));
    const g = cx.createLinearGradient(0, 0, 0, H * 0.7);
    g.addColorStop(0, `rgb(${top})`); g.addColorStop(0.62, `rgb(${mid})`); g.addColorStop(1, `rgb(${hor})`);
    cx.fillStyle = g; cx.fillRect(0, 0, W, H);
    const r = rnd(7);
    if (day < 0.5) { cx.fillStyle = `rgba(255,255,255,${(0.5 - day) * 1.4})`; for (let i = 0; i < 160; i++) { cx.fillRect(r() * W, r() * H * 0.5, 1.4, 1.4); } }
    const sx = W * 0.72, sy = H * (0.52 - 0.28 * Math.sin(Math.min(1, day) * 1.5));
    const glow = cx.createRadialGradient(sx, sy, 0, sx, sy, H * 0.35);
    glow.addColorStop(0, day > 0.35 ? 'rgba(255,236,190,.9)' : 'rgba(190,205,255,.55)'); glow.addColorStop(1, 'rgba(255,220,160,0)');
    cx.fillStyle = glow; cx.fillRect(0, 0, W, H);
    const layer = (base, hgt, color, seed, lit) => {
      const q = rnd(seed); cx.fillStyle = color; let x = -20;
      while (x < W + 20) { const w = 26 + q() * 80, hh = hgt * (0.25 + q() * 0.75); cx.fillRect(x, base - hh, w, hh + H); if (lit && day < 0.6) { cx.fillStyle = 'rgba(255,214,140,.55)'; for (let k = 0; k < hh / 22; k++) if (q() > 0.62) cx.fillRect(x + 6 + q() * (w - 14), base - hh + 8 + k * 20, 4, 6); cx.fillStyle = color; } x += w + q() * 10; }
    };
    layer(H * 0.7, H * 0.2, `rgb(${mix([14, 18, 32], [120, 140, 165], day)})`, 3, false);
    layer(H * 0.76, H * 0.26, `rgb(${mix([8, 10, 20], [74, 88, 110], day)})`, 11, true);
    const gr = cx.createLinearGradient(0, H * 0.74, 0, H);
    gr.addColorStop(0, `rgb(${mix([14, 16, 24], [90, 96, 104], day)})`); gr.addColorStop(1, `rgb(${mix([4, 5, 9], [40, 44, 50], day)})`);
    cx.fillStyle = gr; cx.fillRect(0, H * 0.74, W, H);
    cx.strokeStyle = `rgba(255,214,120,${0.2 + 0.2 * (1 - day)})`; cx.lineWidth = 3; cx.setLineDash([26, 22]); cx.beginPath(); cx.moveTo(W * 0.5, H * 0.74); cx.lineTo(W * 0.5 + (W * 0.2), H); cx.stroke(); cx.setLineDash([]);
    const fog = cx.createLinearGradient(0, H * 0.55, 0, H * 0.8); fog.addColorStop(0, 'rgba(180,190,210,0)'); fog.addColorStop(0.5, `rgba(${mix([40, 50, 70], [200, 210, 225], day)},.25)`); fog.addColorStop(1, 'rgba(0,0,0,0)');
    cx.fillStyle = fog; cx.fillRect(0, H * 0.55, W, H * 0.3);
  }
  addEventListener('resize', () => drawBackdrop(true));


  // ----------------------------------------------------------------------------------------------------- 3D world (optional)
  // Default view is 3D when WebGL2 works (?world=2d forces the flat map, ?world=3d forces 3D; the choice is remembered). world3d.js and three.js load lazily, so a
  // browser without WebGL (or a failed load) keeps the 2D preview exactly as it was.
  const cv3 = $('#world3d');
  const webgl2 = () => { try { return !!document.createElement('canvas').getContext('webgl2'); } catch (e) { return false; } };
  const wantView = () => { const q = qs.get('world'); if (q === '2d' || q === '3d') return q; try { const v = localStorage.getItem('ob.world'); if (v === '2d' || v === '3d') return v; } catch (e) { /* storage blocked */ } return 'auto'; };
  let w3dStarting = null;
  function showWorld(on) {
    world.on = !!on; world.view = on ? '3d' : '2d'; cv3.hidden = !on; cv.style.display = on ? 'none' : '';
    document.body.classList.toggle('w3d-low', !!(on && W3D && W3D.tierName === 'low'));
    document.querySelectorAll('#bench [data-view]').forEach(b => b.classList.toggle('on', b.dataset.view === world.view));
    if (!on) drawBackdrop(true);
  }
  async function startWorld3d() {
    if (W3D) return W3D; if (w3dStarting) return w3dStarting;
    w3dStarting = (async () => {
      const loading = document.querySelector('#loading') || (() => { const d = document.createElement('div'); d.id = 'loading'; document.querySelector('#stage').append(d); return d; })();
      loading.textContent = 'Building the 3D world…'; loading.style.display = '';
      try {
        const mod = await import('./world3d.js'); const wq = {}; for (const k of ['q', 'w3d', 'nomodels', 'pdb']) if (qs.has(k)) wq[k] = qs.get(k);
        let seed = 1; try { seed = JSON.parse(L.P_status()).seed || 1; } catch (e) { /* default */ }
        const w = await mod.createWorld3D({ canvas: cv3, labels: $('#w3d-labels'), query: wq, catalog: P.catalog, seed }, what => { loading.textContent = what === 'models' ? 'Loading 3D models…' : 'Building the settlement…'; });
        const ui = await import('./world3d/ui.js');
        W3D = w;
        W3DUI = ui.attachWorldUI({ W: w, nui, labels: $('#w3d-labels'), preview: { getPlayer: () => P.player, setPlayer: (x, y) => { P.player = { x, y }; sendPlayer(); } },
          setView: v => setWorldView(v), setQuality: q => setQuality(q), getQuality: () => { try { return localStorage.getItem('ob.quality') || 'auto'; } catch (e) { return 'auto'; } } });
        w.preFrame = dt => W3DUI.tick(dt);
        if (P.catalog) w.setCatalog(P.catalog);
        try { w.setState(JSON.parse(L.P_state())); } catch (e) { /* state not ready yet */ }
        w.onTier = name => document.body.classList.toggle('w3d-low', name === 'low' && world.on);
        return w;
      } catch (e) {
        console.warn('[outbreak] 3D world unavailable, staying on the 2D map:', e); world.failed = String(e && e.message || e); P.errors.push('world3d: ' + world.failed); W3D = null; W3DUI = null; return null;
      } finally { loading.remove(); w3dStarting = null; }
    })();
    return w3dStarting;
  }
  async function setWorldView(v) {
    try { localStorage.setItem('ob.world', v); } catch (e) { /* ignore */ }
    if (v === '3d') {
      if (!webgl2()) { showWorld(false); return false; }
      const w = await startWorld3d(); if (!w) { showWorld(false); return false; }
      showWorld(true); if (W3D.manual) W3D.frame(0.016); else W3D.start(); W3DUI.enable(true); W3DUI.onMode(P.mode); return true;
    }
    if (W3D) { W3DUI.enable(false); W3D.stop(); }
    showWorld(false); return true;
  }
  function setQuality(q) {
    try { localStorage.setItem('ob.quality', q); } catch (e) { /* ignore */ }
    if (!W3D) return; if (q === 'auto') { const probe = Object.assign(document.createElement('canvas'), {}); W3D.tierAuto = true; W3D.setTier(W3D.autoTier || W3D.tierName); } else { W3D.tierAuto = false; W3D.setTier(q); }
  }
  function pull3d() { // the sim pushes full state once a second and only in colony mode; the 3D world wants 4 Hz in every mode
    if (!W3D || !world.on || !W3D.ready || document.hidden || W3D.frozen) return;
    try { W3D.setState(JSON.parse(L.P_state())); } catch (e) { P.errors.push('w3d state: ' + e.message); }
  }
  setInterval(pull3d, 250);

  // ------------------------------------------------------------------------------------------------------- main loop
  let last = performance.now();
  function sendPlayer() { L.P_in(JSON.stringify([{ type: 'player_state', pos: { x: P.player.x, y: P.player.y, z: 0 }, moving: false }])); }
  function sendCompass() { toUI('compass', { heading: P.heading }); }
  function step() {
    const now = performance.now();
    const dt = Math.min(now - last, 1000);
    last = now;
    if (P.auto && P.uiReady) L.P_advance(dt);
  }
  setInterval(step, 100);
  setInterval(() => { if (P.uiReady) { sendPlayer(); } }, 1000);
  setInterval(() => { drawBackdrop(false); refreshBench(); }, 700);
  drawBackdrop(true);

  // --------------------------------------------------------------------------------------------------------- bench UI
  const EVENTS = ['horde_wave', 'gang_raid', 'infection_outbreak', 'helicopter_flyover', 'power_outage', 'water_outage', 'storm', 'caravan', 'supply_drop', 'refugee_arrival'];
  const ITEMS = ['canned_beans', 'water_bottle', 'bandage', 'antibiotics', 'painkillers', 'pistol', 'ammo_9mm', 'machete', 'first_aid_kit', 'ration_pack', 'scrap_wood', 'scrap_metal', 'nails', 'fuel_can'];
  $('#b-event').innerHTML = EVENTS.map(e => `<option>${e}</option>`).join('');
  $('#b-item').innerHTML = ITEMS.map(e => `<option>${e}</option>`).join('');
  const speedRow = $('#b-speed');
  for (const [label, sp] of [['pause', 0], ['1x', 1], ['2x', 2], ['4x', 4], ['8x', 8], ['16x', 16]]) {
    const b = document.createElement('button'); b.textContent = label; b.dataset.speed = sp;
    b.onclick = () => L.P_ui('set_speed', JSON.stringify({ speed: sp })); speedRow.append(b);
  }
  const num = id => +$(id).value;
  const dbg = (cmd, args) => JSON.parse(L.P_ui('debug_' + cmd, JSON.stringify(args || {})));
  $('#b-hsize').oninput = e => ($('#b-hsize-v').textContent = e.target.value);
  $('#b-hdist').oninput = e => ($('#b-hdist-v').textContent = e.target.value);
  $('#b-horde').onclick = () => dbg('horde', { n: num('#b-hsize'), dist: num('#b-hdist') });
  $('#b-siege').onclick = () => dbg('horde', { n: num('#b-hsize'), dist: 55 });
  $('#b-fire').onclick = () => dbg('event', { id: $('#b-event').value });
  $('#b-pset').onclick = () => { P.player = { x: num('#b-px'), y: num('#b-py') }; sendPlayer(); };
  $('#b-pbase').onclick = () => { P.player = { x: 0, y: 0 }; $('#b-px').value = 0; $('#b-py').value = 0; sendPlayer(); };
  $('#b-pfar').onclick = () => { P.player = { x: 300, y: 0 }; $('#b-px').value = 300; $('#b-py').value = 0; sendPlayer(); };
  $('#b-head').oninput = e => { P.heading = +e.target.value; sendCompass(); };
  $('#b-give').onclick = () => dbg('give', { item: $('#b-item').value, n: num('#b-n') });
  $('#b-scale').onchange = e => L.P_set_scale(+e.target.value);
  $('#b-auto').onclick = e => { P.auto = !P.auto; e.target.classList.toggle('on', P.auto); };
  $('#b-new').onclick = () => { L.P_new(num('#b-seed'), $('#b-profile').value, num('#b-ncol')); L.P_ui('request_state', '{}'); };
  $('#b-save').onclick = () => L.P_ui('save', '{}');
  $('#b-load').onclick = () => { L.P_ui('load', '{}'); L.P_ui('request_state', '{}'); };
  $('#b-pilot').onclick = e => { const r = dbg('autopilot', { on: !e.target.classList.contains('on') }); e.target.classList.toggle('on', r[1] === true); };
  document.querySelectorAll('#bench [data-ff]').forEach(b => (b.onclick = () => { dbg('fast_forward', { minutes: +b.dataset.ff }); L.P_ui('request_state', '{}'); }));
  document.querySelectorAll('#bench [data-ffday]').forEach(b => (b.onclick = () => { const st = JSON.parse(L.P_status()); dbg('fast_forward', { minutes: Math.max(1, (+b.dataset.ffday - st.day) * 1440 - 600) }); L.P_ui('request_state', '{}'); }));
  document.querySelectorAll('#bench [data-mode]').forEach(b => (b.onclick = () => setMode(b.dataset.mode)));
  document.querySelectorAll('#bench [data-screen]').forEach(b => (b.onclick = () => toUI('screen', { name: b.dataset.screen })));
  document.querySelectorAll('#bench [data-dock]').forEach(b => (b.onclick = () => { try { nui.contentWindow.OB.colony.setDock(b.dataset.dock); } catch (e) { /* ui not ready */ } }));
  function refreshBench() {
    if (document.body.classList.contains('nobench')) return;
    const st = JSON.parse(L.P_status());
    $('#b-time').textContent = `${st.time}  (speed ${st.paused ? 'paused' : st.speed + 'x'}, ${st.profile}, seed ${st.seed})`;
    $('#b-hash').textContent = st.hash;
    $('#b-col').textContent = st.colonists;
    $('#b-hordes').textContent = `${st.hordes} / ${st.materialized} real`;
    try { const pf = nui.contentWindow.OB.perf; $('#b-perf').textContent = pf.n ? `${pf.last.toFixed(2)} ms (max ${pf.max.toFixed(2)})` : '-'; } catch (e) { /* ignore */ }
    speedRow.querySelectorAll('button').forEach(b => b.classList.toggle('on', st.paused ? b.dataset.speed === '0' : +b.dataset.speed === st.speed));
    $('#b-log').textContent = P.log.slice(-14).join('\n');
  }


  document.querySelectorAll('#bench [data-view]').forEach(b => (b.onclick = () => setWorldView(b.dataset.view)));
  $('#b-qual').onchange = e => setQuality(e.target.value);
  $('#b-chase').onclick = () => { if (W3DUI) W3DUI.toggleChase(); };
  $('#b-camhome').onclick = () => { if (W3D) W3D.camRig.setTarget(0, 14, 150); };
  setInterval(() => { const el = $('#b-3dstat'); if (!el || document.body.classList.contains('nobench')) return; if (!W3D || !world.on) { el.textContent = world.failed ? '3D unavailable: ' + world.failed : world.view === '2d' ? '2D map (3D off)' : '-'; return; } const s = W3D.stats; el.textContent = `3D ${s.tier}${W3D.tierAuto ? ' (auto: ' + W3D.tierReason + ')' : ''}  ${s.fps.toFixed(0)} fps  ${s.calls} draws  ${(s.triangles / 1000).toFixed(0)}k tris  dpr ${s.dpr.toFixed(2)}\n${(W3D.gpu || '').slice(0, 60)}`; }, 700);

  // --------------------------------------------------------------------------------------------------- test / script API
  window.__preview = {
    P, lua: L,
    ready: Promise.resolve(true),
    uiReady: () => P.uiReady,
    advance(ms) { let n = 0; for (let left = ms; left > 0; left -= 500) n += L.P_advance(Math.min(500, left)); return n; },
    setAuto(b) { P.auto = !!b; },
    ui(name, data) { return JSON.parse(L.P_ui(name, JSON.stringify(data || {}))); },
    order(o) { return L.P_order(JSON.stringify(o)); },
    inbound(list) { return L.P_in(JSON.stringify(list)); },
    debug: dbg,
    status() { return JSON.parse(L.P_status()); },
    hash() { return L.P_hash(); },
    newGame(seed, profile, n) { const r = JSON.parse(L.P_new(seed, profile, n)); L.P_ui('request_state', '{}'); return r; },
    mode: setMode,
    toUI,
    setPlayer(x, y) { P.player = { x, y }; sendPlayer(); },
    setHeading(d) { P.heading = d; sendCompass(); },
    stateJson() { return L.P_state(); },
    setScale(n) { L.P_set_scale(n); },
    hashRuns(days) { return L.P_hash_runs(days); },
    whyNot(bp, x, y) { return L.P_why_not(bp, x, y); },
    drawBackdrop,
    pushState() { L.P_ui('request_state', '{}'); },
    world3d: () => W3D, world3dUI: () => W3DUI, worldView: () => world.view, worldFailed: () => world.failed, setWorldView, setQuality,
    ready3d: () => (world.view === '3d' ? !!(W3D && W3D.ready) : true),
  };
  // 3D world: default on when WebGL2 works (decided before the loading overlay goes away, so the first frame is already the right view)
  {
    const want = wantView(), use3d = (want === '3d' || want === 'auto') && webgl2();
    if (use3d) { setWorldView('3d').then(ok => { if (!ok) showWorld(false); window.__world3dStarted = true; }); } else { showWorld(false); window.__world3dStarted = true; }
  }
  handlePost = bridge.post; // from here on the NUI's callbacks reach the host; replay what it posted while the Lua sim was starting
  for (const [n, d] of pending.splice(0)) bridge.post(n, d);
  window.__previewReady = true;
})().catch(e => { document.body.insertAdjacentHTML('beforeend', '<pre style="color:#f88;position:fixed;inset:20px;z-index:99">preview failed: ' + (e && e.stack || e) + '</pre>'); console.error(e); window.__previewError = String(e); });
