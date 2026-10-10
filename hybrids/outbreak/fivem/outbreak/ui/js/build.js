/* Build menu (dock tab) + blueprint placement. Placement validity is computed here with the same rules as sim/blueprints.lua `why_not`
   (distance to base, prerequisites, max count, spacing) so the ghost tints instantly; the sim still has the final say (order_result). */
(function () {
  'use strict';
  const OB = window.OB, h = OB.h, S = OB.S, F = OB.fmt;
  const build = (OB.build = { placing: null });
  let cat = 'all', els = {};

  build.validate = function (bp, x, y) {
    const st = S.state, cata = S.catalog;
    if (!st || !cata) return { ok: false, reason: 'unknown' };
    const d = cata.blueprints[bp]; if (!d) return { ok: false, reason: 'unknown_blueprint' };
    const base = cata.tuning.base;
    if (Math.hypot(x - base.x, y - base.y) > base.build_radius) return { ok: false, reason: 'too_far' };
    for (const need of Object.keys(d.needs || {})) {
      const have = st.buildings.filter(b => b.bp === need && b.state === 'built').length;
      if (have < d.needs[need]) return { ok: false, reason: 'prereq:' + need };
    }
    if (d.max > 0 && st.buildings.filter(b => b.bp === bp).length >= d.max) return { ok: false, reason: 'max_reached' };
    for (const b of st.buildings) if (Math.hypot(b.x - x, b.y - y) < base.min_spacing) return { ok: false, reason: 'blocked' };
    return { ok: true, reason: 'ok' };
  };

  function views() { return [OB.mapBg, OB.screens.current === 'map' && OB.bigMap].filter(Boolean); }
  build.start = function (bp) {
    build.placing = bp;
    S.placing = bp;
    for (const v of views()) { v.ghost = { bp, x: null, y: null, ok: false, reason: 'ok' }; v.canvas.style.cursor = 'crosshair'; v.dirty = true; }
    OB.post('place', { op: 'start', bp });
    OB.emit('placing', bp);
    if (S.state) update(S.state);
  };
  build.cancel = function (silent) {
    const was = !!build.placing;
    build.placing = null; S.placing = null;
    for (const v of [OB.mapBg, OB.bigMap].filter(Boolean)) { v.ghost = null; v.canvas.style.cursor = 'default'; v.dirty = true; }
    if (was) { OB.post('place', { op: 'cancel' }); OB.emit('placing', null); if (S.state && !silent) update(S.state); }
    return was;
  };
  // the big map screen creates its view later: give it the active ghost
  OB.on('screen', () => { if (build.placing && OB.bigMap) { OB.bigMap.ghost = { bp: build.placing, x: null, y: null, ok: false, reason: 'ok' }; } });

  function statusOf(st, id, d) {
    const built = {};
    for (const b of st.buildings) { if (b.state === 'built') built[b.bp] = (built[b.bp] || 0) + 1; }
    const total = st.buildings.filter(b => b.bp === id).length;
    const missing = [];
    for (const need of Object.keys(d.needs || {})) if ((built[need] || 0) < d.needs[need]) missing.push(F.cap(F.snake(need)) + ' x' + d.needs[need] + ' (' + (built[need] || 0) + ' built)');
    return { missing, total, maxed: d.max > 0 && total >= d.max };
  }

  let list, queue, banner, tabs, cards = new Map(), lastSig = '';

  function makeCard(id) {
    const d = OB.bp(id), col = OB.catColor[d.cat] || '#9aa7bd';
    const mats = h('div.mats');
    for (const m of Object.keys(d.materials)) mats.append(h('span.mat', { dataset: { item: m } }, OB.icon(OB.itemIcon(m)), h('b', d.materials[m]), h('i', OB.item(m).name)));
    const stats = h('div.bstats',
      h('span', OB.icon('clock'), F.dur(d.work) + ' work'),
      d.power_use ? h('span.pw', OB.icon('bolt'), d.power_use + ' W') : null,
      d.power_gen ? h('span.pg', OB.icon('bolt'), '+' + d.power_gen + ' W') : null,
      d.defense ? h('span', OB.icon('shield'), '+' + d.defense) : null);
    const status = h('div.bstat');
    const card = h('button.bcard', { dataset: { id }, style: { '--c': col }, on: { click: () => { if (card.classList.contains('lock') && !card.classList.contains('maxed')) { OB.toast('warn', card.dataset.why || 'Locked', { title: d.name }); return; } build.start(id); } } },
      h('div.bi', OB.icon(OB.bpIcon(id))), h('div.bb', h('div.bn', d.name), stats, mats, status));
    OB.tip(card, () => { const x = OB.bp(id); return '<div class="tt-h">' + x.name + '</div><div class="tt-r"><span>Category</span><span>' + F.cap(x.cat) + '</span></div><div class="tt-r"><span>Work</span><span>' + x.work + ' min (avg skill)</span></div><div class="tt-r"><span>Min. construction skill</span><span>' + x.skill_min + '</span></div><div class="tt-r"><span>Hit points</span><span>' + x.hp + '</span></div>' + (x.max ? '<div class="tt-r"><span>Limit</span><span>' + x.max + '</span></div>' : '') + (x.storage_g ? '<div class="tt-r"><span>Adds storage</span><span>' + F.kg(x.storage_g) + '</span></div>' : '') + (x.tank_l ? '<div class="tt-r"><span>Water tank</span><span>' + x.tank_l + ' L</span></div>' : ''); }, 400);
    card.status = status;
    return card;
  }

  function update(st) {
    if (!list || !S.catalog) return;
    const order = S.catalog.blueprint_order.filter(id => cat === 'all' || OB.bp(id).cat === cat);
    const stock = new Map(st.stock.map(s => [s.id, s.n]));
    const sig = cat + '|' + order.join(',');
    if (sig !== lastSig) { lastSig = sig; OB.clear(list); list._keyed = null; for (const id of order) { let c = cards.get(id); if (!c) { c = makeCard(id); cards.set(id, c); } list.append(c); } }
    for (const id of order) {
      const c = cards.get(id), d = OB.bp(id), s = statusOf(st, id, d);
      const lock = s.missing.length > 0 || s.maxed;
      OB.toggle(c, 'lock', lock); OB.toggle(c, 'maxed', s.maxed);
      OB.toggle(c, 'on', build.placing === id);
      c.dataset.why = s.maxed ? 'Limit reached' : s.missing.length ? 'Needs ' + s.missing[0] : '';
      OB.setText(c.status, s.maxed ? 'Limit reached (' + s.total + '/' + d.max + ')' : s.missing.length ? 'Needs ' + s.missing.join(', ') : d.max ? s.total + ' / ' + d.max + ' built' : (s.total ? s.total + ' built' : 'Ready'));
      OB.toggle(c.status, 'warn', s.missing.length > 0);
      for (const m of c.querySelectorAll('.mat')) OB.toggle(m, 'short', (stock.get(m.dataset.item) || 0) < d.materials[m.dataset.item]);
    }
    // active placement banner
    OB.show(banner, !!build.placing);
    if (build.placing) { const d = OB.bp(build.placing); OB.setText(banner.firstChild.nextSibling, 'Placing ' + d.name); }
    // construction queue
    const sites = st.buildings.filter(b => b.state === 'planned');
    OB.setText(queue.hd, 'Construction sites (' + sites.length + ')');
    OB.reconcile(queue.list, sites, b => b.id, b => {
      const bar = OB.bar('thin');
      const row = h('div.site', { dataset: { id: b.id } }, OB.icon(OB.bpIcon(b.bp)), h('div.grow', h('div.sn', ''), h('div.sm.muted.t-xs', ''), bar), h('button.btn.sq.sm.ghost', { 'aria-label': 'Cancel', on: { click: () => OB.order('colony', 'cancel_blueprint', { id: b.id }) } }, OB.icon('x')));
      row.bar = bar; row.sn = row.querySelector('.sn'); row.sm = row.querySelector('.sm');
      return row;
    }, (row, b) => {
      OB.setText(row.sn, OB.bp(b.bp).name);
      const miss = b.missing ? Object.keys(b.missing).map(k => b.missing[k] + ' ' + OB.item(k).name).join(', ') : '';
      OB.setText(row.sm, b.missing ? 'waiting for ' + miss : b.pct + '% built');
      row.bar.set(b.pct, b.missing ? 'var(--warn)' : 'var(--good)');
    });
    OB.show(queue.empty, sites.length === 0);
  }

  build.panel = function () {
    const root = h('div.build-panel');
    tabs = h('div.ctabs.wrap');
    const cats = ['all'].concat((S.catalog && S.catalog.blueprint_cats) || ['structure', 'defense', 'furniture', 'production', 'power', 'storage', 'water', 'utility']);
    for (const c of cats) tabs.append(h('button.chip.tab' + (c === cat ? '.on' : ''), { dataset: { cat: c }, style: { '--c': OB.catColor[c] || '#f6b44f' }, on: { click: () => { cat = c; OB.$$('.tab', tabs).forEach(b => b.classList.toggle('on', b.dataset.cat === c)); if (S.state) update(S.state); } } }, c === 'all' ? 'All' : OB.icon(OB.catIcon(c)), c === 'all' ? null : F.cap(c)));
    banner = h('div.pbanner', OB.icon('ghost'), h('b', 'Placing'), h('span.muted', 'Click to place · Shift to chain · Esc or right-click to cancel'), h('button.btn.sm', { on: { click: () => build.cancel() } }, 'Done'));
    banner.hidden = true;
    list = h('div.bgrid');
    queue = { hd: h('div.lbl', 'Construction sites'), list: h('div.sites'), empty: h('div.muted.t-sm', 'Nothing under construction. Pick a blueprint, then click the map.') };
    root.append(tabs, banner, list, h('div.sep'), queue.hd, queue.list, queue.empty);
    OB.on('catalog', () => { lastSig = ''; });
    return { el: root, update, onShow() { lastSig = ''; } };
  };
})();
