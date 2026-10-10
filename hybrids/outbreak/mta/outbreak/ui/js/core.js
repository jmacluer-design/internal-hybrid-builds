/* Outbreak NUI core: DOM helpers, formatters, store, event bus, game bridge, tooltip + context menu, settings.
   Everything hangs off window.OB (classic scripts, no modules: works in FiveM's CEF and in the browser preview alike). */
(function () {
  'use strict';
  const OB = (window.OB = { v: 1, mods: {} });

  // ---------------------------------------------------------------------------------------------------------------- DOM
  OB.$ = (sel, root) => (root || document).querySelector(sel);
  OB.$$ = (sel, root) => Array.from((root || document).querySelectorAll(sel));

  // h('div.cls#id', { class, text, html, style:{}, on:{click}, attrs:{}, dataset:{} }, ...children)
  OB.h = function h(tag, props, ...kids) {
    const m = /^([a-z0-9-]*)((?:[.#][\w:-]+)*)$/i.exec(tag) || [null, 'div', ''];
    const el = document.createElement(m[1] || 'div');
    const cls = [];
    (m[2].match(/[.#][\w:-]+/g) || []).forEach(t => (t[0] === '.' ? cls.push(t.slice(1)) : (el.id = t.slice(1))));
    if (props != null && props !== false && (props.nodeType || typeof props === 'string' || typeof props === 'number' || Array.isArray(props))) { kids.unshift(props); props = null; } // (a number as the first child, e.g. h('b', 3), is text, not a props object)
    if (props) {
      if (props.class) cls.push(props.class);
      for (const k of Object.keys(props)) {
        const v = props[k];
        if (k === 'class' || v == null || v === false) continue;
        if (k === 'text') el.textContent = v;
        else if (k === 'html') el.innerHTML = v;
        else if (k === 'style') { for (const sk of Object.keys(v)) { if (sk.charAt(0) === '-') el.style.setProperty(sk, v[sk]); else el.style[sk] = v[sk]; } }
        else if (k === 'on') for (const ev of Object.keys(v)) el.addEventListener(ev, v[ev]);
        else if (k === 'attrs') for (const a of Object.keys(v)) el.setAttribute(a, v[a]);
        else if (k === 'dataset') Object.assign(el.dataset, v);
        else if (k in el && k !== 'list') el[k] = v;
        else el.setAttribute(k, v === true ? '' : v);
      }
    }
    if (cls.length) el.className = cls.join(' ');
    for (const k of kids.flat(3)) if (k != null && k !== false) el.append(k.nodeType ? k : document.createTextNode(String(k)));
    return el;
  };
  OB.clear = el => { while (el.firstChild) el.removeChild(el.firstChild); return el; };
  OB.setText = (el, text) => { text = String(text); if (el._t !== text) { el._t = text; el.textContent = text; } };
  OB.setAttr = (el, k, v) => { v = String(v); const key = '_a_' + k; if (el[key] !== v) { el[key] = v; el.setAttribute(k, v); } };
  OB.setStyle = (el, k, v) => { const key = '_s_' + k; if (el[key] !== v) { el[key] = v; el.style.setProperty(k, v); } };
  OB.toggle = (el, cls, on) => { on = !!on; const key = '_c_' + cls; if (el[key] !== on) { el[key] = on; el.classList.toggle(cls, on); } };
  OB.show = (el, on) => { on = !!on; if (el._show !== on) { el._show = on; el.toggleAttribute('hidden', !on); } };

  // keyed child reconciliation: keeps DOM nodes alive between updates (cheap updates, preserved hover/focus/scroll)
  OB.reconcile = function (parent, list, keyFn, make, update) {
    const old = parent._keyed || (parent._keyed = new Map());
    const next = new Map();
    let prev = null;
    for (const item of list) {
      const k = keyFn(item);
      let el = old.get(k);
      if (!el) el = make(item);
      else old.delete(k);
      update(el, item);
      next.set(k, el);
      const want = prev ? prev.nextSibling : parent.firstChild;
      if (want !== el) parent.insertBefore(el, want);
      prev = el;
    }
    for (const el of old.values()) el.remove();
    parent._keyed = next;
  };

  // ------------------------------------------------------------------------------------------------------------ format
  const F = (OB.fmt = {});
  F.n = (x, d) => (x == null || isNaN(x) ? '-' : Number(x).toLocaleString('en-US', { minimumFractionDigits: d || 0, maximumFractionDigits: d || 0 }));
  F.kg = g => (g >= 1000 ? (g / 1000).toFixed(g >= 10000 ? 0 : 1) + ' kg' : Math.round(g) + ' g');
  F.pct = x => Math.round(x) + '%';
  F.cap = s => (s ? s.charAt(0).toUpperCase() + s.slice(1) : '');
  F.dur = min => {
    min = Math.max(0, Math.round(min));
    if (min < 60) return min + 'm';
    const h = Math.floor(min / 60);
    if (h < 24) return h + 'h ' + String(min % 60).padStart(2, '0') + 'm';
    return Math.floor(h / 24) + 'd ' + (h % 24) + 'h';
  };
  F.clock = (h, m) => String(h).padStart(2, '0') + ':' + String(m).padStart(2, '0');
  F.snake = s => String(s || '').replace(/_/g, ' ');
  F.dist = u => (u >= 1000 ? (u / 1000).toFixed(1) + ' km' : Math.round(u) + ' m');
  const DIRS = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  F.dir = deg => DIRS[Math.round((((deg % 360) + 360) % 360) / 45) % 8];

  OB.clamp = (x, a, b) => (x < a ? a : x > b ? b : x);
  OB.lerp = (a, b, t) => a + (b - a) * t;
  OB.throttle = (fn, ms) => { let t = 0; return (...a) => { const n = performance.now(); if (n - t >= ms) { t = n; fn(...a); } }; };

  // ------------------------------------------------------------------------------------------------------- store + bus
  OB.S = {
    boot: null, catalog: null, state: null, hud: null, mode: 'survival', screen: null, dock: 'card',
    sel: [], primary: null, inv: null, compass: 0, events: [], notes: [], keymap: null, lastStateAt: 0, stateCount: 0,
  };
  const subs = {};
  OB.on = (ev, fn) => { (subs[ev] || (subs[ev] = [])).push(fn); return fn; };
  OB.emit = (ev, data) => { for (const fn of subs[ev] || []) { try { fn(data); } catch (e) { console.error('[OB] handler for ' + ev + ' failed', e); } } };

  // ------------------------------------------------------------------------------------------------------------ bridge
  // In FiveM: fetch('https://<resource>/<callback>') is how a NUI page calls RegisterNUICallback handlers. In the browser preview the
  // page is an iframe of preview/index.html and the shell exposes window.parent.__previewBridge instead.
  Object.defineProperty(OB, 'preview', { get() { try { return window.parent !== window && !!window.parent.__previewBridge; } catch (e) { return false; } } });
  OB.resource = typeof window.GetParentResourceName === 'function' ? window.GetParentResourceName() : 'outbreak';
  OB.post = function (name, data) {
    if (OB.preview) {
      try { return window.parent.__previewBridge.post(name, data || {}); } catch (e) { console.error('[OB] preview bridge failed', e); return undefined; }
    }
    return fetch('https://' + OB.resource + '/' + name, {
      method: 'POST', headers: { 'Content-Type': 'application/json; charset=UTF-8' }, body: JSON.stringify(data || {}),
    }).catch(() => {});
  };
  OB.ui = (name, data) => OB.post('ui', { name, data: data || {} });
  OB.order = (id, kind, target) => OB.post('order', { id, kind, target });

  // ---------------------------------------------------------------------------------------------------------- settings
  const DEF = { uiScale: 1, reduceMotion: false, colorblind: false, hudOpacity: 1, compass: true, hints: true };
  OB.settings = Object.assign({}, DEF);
  try { Object.assign(OB.settings, JSON.parse(localStorage.getItem('outbreak.settings') || '{}')); } catch (e) { /* storage may be blocked */ }
  OB.applySettings = function () {
    const s = OB.settings, r = document.documentElement;
    r.style.setProperty('--ui-scale', String(OB.clamp(+s.uiScale || 1, 0.6, 1.8)));
    r.style.setProperty('--hud-opacity', String(OB.clamp(+s.hudOpacity || 1, 0.3, 1)));
    r.dataset.reduceMotion = s.reduceMotion ? '1' : '0';
    r.dataset.cb = s.colorblind ? '1' : '0';
    r.dataset.hints = s.hints ? '1' : '0';
  };
  OB.saveSettings = function () {
    OB.applySettings();
    try { localStorage.setItem('outbreak.settings', JSON.stringify(OB.settings)); } catch (e) { /* ignore */ }
    OB.emit('settings', OB.settings);
  };

  // --------------------------------------------------------------------------------------------------- catalog lookups
  OB.item = id => (OB.S.catalog && OB.S.catalog.items[id]) || { name: F.snake(id), cat: 'material', w: 0, stack: 1, value: 0 };
  OB.bp = id => (OB.S.catalog && OB.S.catalog.blueprints[id]) || { name: F.snake(id), cat: 'structure', materials: {}, work: 0, needs: {}, max: 0, size: [1, 1], tags: [] };
  OB.col = id => (OB.S.state && OB.S.state.colonists.find(c => c.id === id)) || null;
  OB.short = name => String(name || '').replace(/\s*".*"\s*$/, '');
  OB.nick = name => { const m = /"([^"]+)"/.exec(name || ''); return m ? m[1] : OB.short(name); };
  OB.initials = name => { const s = OB.short(name); return (s[0] || '?').toUpperCase() + (OB.nick(name)[0] || '').toUpperCase(); };

  // category colours shared by the inventory, the map and the build menu
  OB.catColor = {
    food: '#ffa24a', drink: '#47c7f5', medical: '#ff6b81', weapon: '#c9d2e3', ammo: '#d7b46a', material: '#9aa7bd', fuel: '#f6d04d', tool: '#7ee0c3', valuable: '#d9a8ff', ingredient: '#c3e88d',
    structure: '#9aa7bd', defense: '#ff7a7a', furniture: '#d7a36e', production: '#f6b44f', power: '#f6d04d', storage: '#7aa7ff', water: '#47c7f5', utility: '#7ee0c3',
  };
  OB.hue = str => { let h = 0; for (let i = 0; i < str.length; i++) h = (h * 31 + str.charCodeAt(i)) % 360; return h; };

  // ------------------------------------------------------------------------------------------------------------ tooltip
  let tipEl = null, tipTimer = 0;
  function placeTip(x, y) {
    const w = tipEl.offsetWidth, h = tipEl.offsetHeight, W = innerWidth, H = innerHeight, pad = 12;
    let l = x + 18, t = y + 18;
    if (l + w > W - pad) l = Math.max(pad, x - w - 14);
    if (t + h > H - pad) t = Math.max(pad, y - h - 14);
    tipEl.style.transform = 'translate(' + Math.round(l) + 'px,' + Math.round(t) + 'px)';
  }
  OB.tip = function (el, content, delay) {
    el.addEventListener('pointerenter', e => {
      clearTimeout(tipTimer);
      tipTimer = setTimeout(() => {
        tipEl = tipEl || OB.$('#tip');
        const c = typeof content === 'function' ? content() : content;
        if (c == null || c === '') return;
        OB.clear(tipEl);
        if (typeof c === 'string') tipEl.innerHTML = c; else tipEl.append(c);
        tipEl.hidden = false;
        placeTip(e.clientX, e.clientY);
      }, delay == null ? 250 : delay);
    });
    el.addEventListener('pointermove', e => { if (tipEl && !tipEl.hidden) placeTip(e.clientX, e.clientY); });
    const hide = () => { clearTimeout(tipTimer); tipEl = tipEl || OB.$('#tip'); if (tipEl) tipEl.hidden = true; };
    el.addEventListener('pointerleave', hide);
    el.addEventListener('pointerdown', hide);
    return el;
  };
  OB.hideTip = () => { clearTimeout(tipTimer); const t = OB.$('#tip'); if (t) t.hidden = true; };

  // ---------------------------------------------------------------------------------------------------- context menu
  OB.ctx = function (x, y, entries) {
    const m = OB.$('#ctx');
    OB.clear(m);
    for (const e of entries) {
      if (e === '-') { m.append(OB.h('div.sep')); continue; }
      m.append(OB.h('button.ctx-i', { disabled: !!e.disabled, on: { click: () => { OB.closeCtx(); e.run && e.run(); } } }, e.icon ? OB.icon(e.icon) : null, OB.h('span', e.label), e.key ? OB.h('kbd', e.key) : null));
    }
    m.hidden = false;
    const w = m.offsetWidth, h = m.offsetHeight;
    m.style.transform = 'translate(' + Math.round(Math.min(x, innerWidth - w - 8)) + 'px,' + Math.round(Math.min(y, innerHeight - h - 8)) + 'px)';
    const first = m.querySelector('button:not([disabled])');
    if (first) first.focus({ preventScroll: true });
  };
  OB.closeCtx = () => { const m = OB.$('#ctx'); if (m) m.hidden = true; };
  document.addEventListener('pointerdown', e => { const m = OB.$('#ctx'); if (m && !m.hidden && !m.contains(e.target)) m.hidden = true; }, true);

  // ------------------------------------------------------------------------------------------------- screen manager
  // One modal screen at a time (inventory, priorities, map, menu, summary ...). Modules register { build(), onOpen(arg), onClose(), update(state) }.
  OB.screens = (function () {
    const reg = {}; let cur = null, host = null;
    function mount() { host = host || OB.$('#screens'); return host; }
    const api = {
      reg(name, def) { reg[name] = def; },
      get current() { return cur; },
      open(name, arg) {
        const def = reg[name]; if (!def) return false;
        if (cur && cur !== name) api.close(true);
        mount();
        if (!def.el) {
          def.el = OB.h('div.scrim', { dataset: { screen: name }, on: { pointerdown: e => { if (e.target === def.el && !def.sticky) api.close(); } } }, def.build());
          host.append(def.el);
        }
        def.el.hidden = false;
        cur = name;
        document.documentElement.dataset.screen = name;
        if (def.onOpen) def.onOpen(arg);
        if (def.update && OB.S.state) def.update(OB.S.state);
        OB.post('screen', { name, open: true });
        OB.emit('screen', name);
        return true;
      },
      close(silent) {
        if (!cur) return;
        const def = reg[cur], name = cur;
        def.el.hidden = true;
        if (def.onClose) def.onClose();
        cur = null;
        document.documentElement.dataset.screen = '';
        OB.hideTip(); OB.closeCtx();
        if (!silent) { OB.post('screen', { name, open: false }); OB.emit('screen', null); }
      },
      toggle(name, arg) { if (cur === name) api.close(); else api.open(name, arg); },
      update(state) { if (cur && reg[cur].update) reg[cur].update(state); },
      has: name => !!reg[name],
    };
    return api;
  })();

  // small reusable widgets -----------------------------------------------------------------------------------------
  // bar(color) -> element with .setValue(pct)
  OB.bar = function (cls) {
    const fill = OB.h('i');
    const el = OB.h('div.bar' + (cls ? '.' + cls : ''), fill);
    el.fill = fill;
    el.set = function (pct, color) {
      pct = OB.clamp(pct, 0, 100);
      OB.setStyle(fill, 'width', pct.toFixed(1) + '%');
      if (color) OB.setStyle(el, '--c', color);
    };
    return el;
  };
  OB.seg = function (options, value, onPick, cls) {
    const el = OB.h('div.seg' + (cls ? '.' + cls : ''), { role: 'group' });
    for (const o of options) {
      const b = OB.h('button', { class: o.value === value ? 'on' : '', 'aria-pressed': o.value === value ? 'true' : 'false', dataset: { value: o.value }, on: { click: () => { el.set(o.value); onPick(o.value); } } }, o.icon ? OB.icon(o.icon) : null, o.label != null ? OB.h('span', o.label) : null);
      if (o.tip) OB.tip(b, o.tip);
      el.append(b);
    }
    el.set = v => OB.$$('button', el).forEach(b => { const on = b.dataset.value === String(v); b.classList.toggle('on', on); b.setAttribute('aria-pressed', on ? 'true' : 'false'); });
    return el;
  };
  OB.toggleSwitch = function (value, onChange, label) {
    const b = OB.h('button.tgl', { role: 'switch', 'aria-checked': value ? 'true' : 'false', 'aria-label': label || 'toggle', class: value ? 'on' : '' }, OB.h('i'));
    b.addEventListener('click', () => { const v = b.getAttribute('aria-checked') !== 'true'; b.setAttribute('aria-checked', v ? 'true' : 'false'); b.classList.toggle('on', v); onChange(v); });
    return b;
  };
  OB.key = k => OB.h('kbd', k);
})();
