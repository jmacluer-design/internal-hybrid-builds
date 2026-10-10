/* Outbreak NUI main: routes game messages ({action, data} from SendNUIMessage), applies state, owns the keyboard and the mode switch. */
(function () {
  'use strict';
  const OB = window.OB, S = OB.S;

  OB.perf = { n: 0, sum: 0, max: 0, last: 0, samples: [] };
  const REASONS = {
    blocked: 'Something is already built there.', too_far: 'Too far from the base.', max_reached: 'You already have the maximum of those.', unknown_blueprint: 'Unknown blueprint.',
    no_such_colonist: 'That colonist is gone.', bad_target: 'That order makes no sense here.', no_vehicle: 'No vehicle is available.', vehicle_damaged: 'The vehicle is too damaged.',
    no_fuel: 'Not enough fuel cans for the trip.', too_far_on_foot: 'Too far to go on foot.', no_crew: 'Nobody is free to go.', not_in_stock: 'Not in the stockpile.',
    offer_too_low: 'The offer is too low.', clamped: 'Level adjusted.',
  };
  OB.reason = r => { r = String(r || ''); if (r.indexOf('prereq:') === 0) return 'Needs a finished ' + OB.fmt.snake(r.slice(7)) + ' first.'; if (r.indexOf('rejected:') === 0) return 'Rejected by the server.'; return REASONS[r] || OB.fmt.cap(OB.fmt.snake(r)); };

  // ------------------------------------------------------------------------------------------------------------ mode
  OB.setMode = function (mode) {
    if (mode !== 'colony') mode = 'survival';
    S.mode = mode;
    document.documentElement.dataset.mode = mode;
    OB.show(OB.$('#colony'), mode === 'colony');
    if (mode === 'colony') { OB.colony.enter(); } else { OB.colony.leave(); if (OB.screens.current === 'map' || OB.screens.current === 'priorities') OB.screens.close(); }
    OB.ui('screens', { colony: mode === 'colony' });
    OB.emit('mode', mode);
  };
  OB.requestMode = function (mode) { OB.post('mode', { mode }); if (!S.boot) OB.setMode(mode); };

  // ------------------------------------------------------------------------------------------------------------ events
  function onEvent(ev, silent) {
    if (!ev || !ev.type) return;
    S.events.push(ev);
    if (S.events.length > 300) S.events.shift();
    switch (ev.type) {
      case 'notify': if (!silent) OB.toast(ev.level, ev.text); OB.note(ev.level, ev.text, ev); break;
      case 'play_alert': {
        const t = { horde_near: ['Hordes nearby', 'The dead are close to the base.'], raid_incoming: ['Raid incoming', (ev.faction ? OB.fmt.cap(OB.fmt.snake(ev.faction)) + ' raiders are coming.' : 'Raiders are coming.')],
          caravan: ['Caravan', 'Traders have arrived.'], helicopter: ['Helicopter', 'A helicopter passes overhead.'], supply_drop: ['Supply drop', 'A crate has landed nearby.'] }[ev.kind];
        if (t && !silent) OB.toast(ev.kind === 'caravan' || ev.kind === 'supply_drop' ? 'good' : 'warn', t[1], { title: t[0], icon: ev.kind === 'caravan' ? 'trade' : ev.kind === 'supply_drop' ? 'crate' : 'radar' });
        break;
      }
      case 'order_result': if (!silent && !ev.ok && ev.reason) OB.toast('warn', OB.reason(ev.reason), { title: 'Order failed' }); break;
      case 'item_result': if (!silent && !ev.ok && ev.reason && ev.reason !== 'ok') OB.toast('warn', ev.reason === 'nothing_moved' ? 'Nothing could be moved (full or not enough).' : OB.reason(ev.reason)); break;
      case 'game_over': OB.screens.open('summary'); break;
      case 'day_start': if (!silent) OB.toast('info', 'Day ' + ev.day + ' begins.', { icon: 'sun' }); break;
      case 'colonist_turned': if (!silent) OB.toast('bad', ev.name + ' has turned.', { icon: 'skull' }); break;
      default: break;
    }
    OB.emit('ev:' + ev.type, ev);
    OB.emit('event', ev);
  }

  // ------------------------------------------------------------------------------------------------------------ state
  function applyState(st) {
    const t0 = performance.now();
    S.state = st;
    S.stateCount++;
    // keep the selection valid
    const ids = new Set(st.colonists.map(c => c.id));
    S.sel = S.sel.filter(id => ids.has(id));
    if (S.primary && !ids.has(S.primary)) S.primary = S.sel[0] || null;
    if (S.mode === 'colony') { OB.colony.update(st); OB.map.updateAll(st); }
    OB.screens.update(st);
    OB.emit('state', st);
    const dt = performance.now() - t0;
    const p = OB.perf;
    p.n++; p.sum += dt; p.last = dt; if (dt > p.max) p.max = dt;
    p.samples.push(dt); if (p.samples.length > 200) p.samples.shift();
  }

  // ------------------------------------------------------------------------------------------------------ message router
  const ROUTE = {
    boot(d) {
      S.boot = d || {};
      OB.show(OB.$('#preview-badge'), !!(d && d.preview) || OB.preview);
      if (d && d.settings) { Object.assign(OB.settings, d.settings); OB.applySettings(); }
    },
    catalog(d) { S.catalog = d; OB.emit('catalog', d); },
    state: applyState,
    hud(d) { OB.emit('hud', d); },
    compass(d) { OB.emit('compass', d && d.heading != null ? d.heading : d); },
    event: onEvent,
    events(d) {
      d = d || [];
      const silent = d.length > 12; // fast-forward / resync bursts: log them, do not spam toasts
      d.forEach(e => onEvent(e, silent));
      if (silent) { const bad = d.filter(e => e.type === 'colonist_died').length; if (bad) OB.toast('bad', d.length + ' events processed, ' + bad + ' colonist(s) lost.', { icon: 'list' }); } // (a join / load resync is not news)
    },
    mode(d) { OB.setMode(d && d.mode); },
    screen(d) { if (d && d.open === false) OB.screens.close(); else if (d && d.name) OB.screens.open(d.name, d.arg); },
    selection(d) { if (d && d.ids) { S.sel = d.ids.slice(); S.primary = d.ids[0] || null; OB.emit('selection', S.sel); if (S.primary) OB.ui('select', { id: S.primary }); } },
    inventory(d) { S.inv = d; OB.emit('inventory', d); },
    summary(d) { OB.emit('summary', d); },
    toast(d) { if (d) OB.toast(d.level, d.text, d); },
    place(d) { OB.emit('place', d); },
    settings(d) { Object.assign(OB.settings, d || {}); OB.applySettings(); },
    note(d) { if (d) OB.note(d.level, d.text); },
  };
  window.addEventListener('message', e => {
    const m = e.data;
    if (!m || typeof m.action !== 'string') return;
    const f = ROUTE[m.action];
    if (f) { try { f(m.data); } catch (err) { console.error('[OB] ' + m.action + ' failed', err); } }
  });

  // -------------------------------------------------------------------------------------------------------------- keys
  OB.selectNext = function (dir) {
    const cs = S.state ? S.state.colonists : [];
    if (!cs.length) return;
    let i = cs.findIndex(c => c.id === S.primary);
    i = (i + dir + cs.length) % cs.length;
    OB.select([cs[i].id]);
  };
  OB.select = function (ids, add) {
    ids = ids.filter(Boolean);
    S.sel = add ? Array.from(new Set(S.sel.concat(ids))) : ids.slice();
    S.primary = S.sel[S.sel.length - 1] || null;
    if (S.primary) OB.ui('select', { id: S.primary }); else OB.ui('select', { id: '' });
    OB.emit('selection', S.sel);
    if (S.state && S.mode === 'colony') { OB.colony.update(S.state); OB.map.updateAll(S.state); }
  };

  // The page owns the keyboard while it has NUI focus, so the game never sees WASD: the camera keys are forwarded to the Lua client (client/camera.lua
  // on_key) as down / up pairs. Keys still held when the window loses focus or a screen opens are released, so the camera never keeps drifting.
  const CAM_KEYS = { w: 'w', a: 'a', s: 's', d: 'd', q: 'q', e: 'e', ArrowUp: 'ArrowUp', ArrowDown: 'ArrowDown', ArrowLeft: 'ArrowLeft', ArrowRight: 'ArrowRight', Shift: 'shift' };
  const heldKeys = new Set();
  OB.releaseKeys = function () { heldKeys.forEach(k => OB.post('key', { k, down: false })); heldKeys.clear(); };
  document.addEventListener('keyup', e => {
    const k = CAM_KEYS[e.key.length === 1 ? e.key.toLowerCase() : e.key];
    if (k && heldKeys.delete(k)) OB.post('key', { k, down: false });
  });
  window.addEventListener('blur', () => OB.releaseKeys());
  OB.on('screen', () => { if (OB.screens.current) OB.releaseKeys(); });

  document.addEventListener('keydown', e => {
    const tag = (e.target && e.target.tagName) || '';
    const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(tag);
    if (!typing && S.mode === 'colony' && !OB.screens.current && !e.ctrlKey && !e.altKey && !e.metaKey) {
      const ck = CAM_KEYS[e.key.length === 1 ? e.key.toLowerCase() : e.key];
      if (ck && !heldKeys.has(ck)) { heldKeys.add(ck); OB.post('key', { k: ck, down: true }); }
    }
    if (e.key === 'Escape') {
      if (!OB.$('#ctx').hidden) { OB.closeCtx(); return e.preventDefault(); }
      if (OB.build && OB.build.cancel()) return e.preventDefault();
      if (OB.screens.current) { OB.screens.close(); return e.preventDefault(); }
      if (S.mode === 'colony' && S.dock !== 'card' && OB.colony.setDock) { OB.colony.setDock('card'); return e.preventDefault(); }
      OB.screens.open('menu');
      return e.preventDefault();
    }
    if (typing || e.ctrlKey && e.key !== 'a' || e.altKey || e.metaKey) return;
    const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
    if (k === 'F6' || (k === 'Tab' && !OB.screens.current)) { OB.requestMode(S.mode === 'colony' ? 'survival' : 'colony'); return e.preventDefault(); }
    if (k === 'i') { OB.screens.toggle('inventory'); return e.preventDefault(); }
    if (S.mode !== 'colony') return;
    switch (k) {
      case 'b': OB.screens.close(); OB.colony.setDock('build'); break;
      case 'z': OB.screens.close(); OB.colony.setDock('zones'); break;
      case 'l': OB.screens.close(); OB.colony.setDock('director'); break;
      case 'c': OB.screens.close(); OB.colony.setDock('card'); break;
      case 'p': OB.screens.toggle('priorities'); break;
      case 'm': OB.screens.toggle('map'); break;
      case ' ': OB.ui('toggle_pause'); break;
      case '1': OB.ui('set_speed', { speed: 1 }); break;
      case '2': OB.ui('set_speed', { speed: 2 }); break;
      case '3': OB.ui('set_speed', { speed: 4 }); break;
      case '4': OB.ui('set_speed', { speed: 8 }); break;
      case 'r': OB.colony.toggleDraft(); break;
      case 'a': if (e.ctrlKey && S.state) { OB.select(S.state.colonists.map(c => c.id)); } break;
      case '.': OB.selectNext(1); break;
      case ',': OB.selectNext(-1); break;
      default: return;
    }
    e.preventDefault();
  });

  // ------------------------------------------------------------------------------------------------------------- init
  function init() {
    OB.applySettings();
    OB.hud.init();
    OB.colony.init();
    for (const name of ['inventory', 'priorities', 'map', 'menu', 'summary']) if (!OB.screens.has(name)) console.warn('[OB] screen missing: ' + name);
    OB.post('ready', { v: OB.v });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
