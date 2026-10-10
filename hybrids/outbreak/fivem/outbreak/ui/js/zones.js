/* Stockpile zones (dock tab): priority, accepted categories, capacity, contents; plus "new zone" placement on the map. */
(function () {
  'use strict';
  const OB = window.OB, h = OB.h, S = OB.S, F = OB.fmt;
  const zones = (OB.zones = { draft: { name: 'Stockpile', tiles: 4, prio: 3, cats: null } });
  let root, listEl, capBar, capTxt, formEls = {};

  zones.createAt = function (x, y) {
    OB.order('colony', 'zone_create', { name: 'Stockpile', pos: { x, y, z: 0 }, tiles: 4, prio: 3 });
  };
  zones.start = function () {
    zones.placing = true;
    if (OB.build.cancel) OB.build.cancel(true);
    for (const v of [OB.mapBg, OB.bigMap].filter(Boolean)) { v.ghost = { zone: true, tiles: zones.draft.tiles, x: null, y: null, ok: true }; v.canvas.style.cursor = 'crosshair'; v.dirty = true; }
    OB.toast('info', 'Click the map to place "' + zones.draft.name + '" (' + zones.draft.tiles + ' tiles). Esc cancels.', { title: 'New stockpile zone', icon: 'zone' });
  };
  zones.stop = function () { zones.placing = false; for (const v of [OB.mapBg, OB.bigMap].filter(Boolean)) { if (v.ghost && v.ghost.zone) v.ghost = null; v.canvas.style.cursor = 'default'; v.dirty = true; } };
  zones.commit = function (g) {
    const d = zones.draft;
    const t = { name: d.name || 'Stockpile', pos: { x: g.x, y: g.y, z: 0 }, tiles: d.tiles, prio: d.prio };
    if (d.cats) t.cats = Array.from(d.cats);
    OB.order('colony', 'zone_create', t);
    zones.stop();
  };
  // Esc cancels a pending zone placement as well
  const prevCancel = OB.build.cancel;
  OB.build.cancel = function (silent) { const z = zones.placing; if (z) zones.stop(); return prevCancel(silent) || !!z; };

  function catChips(active, onToggle) {
    const wrap = h('div.catchips');
    for (const c of (S.catalog ? S.catalog.item_cats : [])) {
      const on = !active || active.has(c);
      wrap.append(h('button.chip.tab' + (on ? '.on' : ''), { style: { '--c': OB.catColor[c] }, dataset: { cat: c }, 'aria-pressed': on ? 'true' : 'false', on: { click: () => onToggle(c) } }, OB.icon(OB.catIcon(c)), F.cap(c)));
    }
    return wrap;
  }

  function zoneCard(z) {
    const bar = OB.bar('thick');
    const prio = h('div.stepper', h('button.btn.sq.sm', { 'aria-label': 'Lower priority', on: { click: () => OB.order('colony', 'zone_set', { id: z.id, prio: Math.max(1, z.prio - 1) }) } }, OB.icon('minus')), h('b.num', ''), h('button.btn.sq.sm', { 'aria-label': 'Raise priority', on: { click: () => OB.order('colony', 'zone_set', { id: z.id, prio: Math.min(5, z.prio + 1) }) } }, OB.icon('plus')));
    const chipsHost = h('div');
    const top = h('div.ztop');
    const card = h('div.zcard', { dataset: { id: z.id } },
      h('div.zh', OB.icon(z.main ? 'crate' : 'zone'), h('b.grow.ell', ''), h('span.lbl', 'Priority'), prio),
      bar, h('div.zmeta.muted.t-xs', ''), top, chipsHost,
      h('div.row', h('button.btn.sm', { on: { click: () => OB.screens.open('inventory', { other: { kind: 'zone', id: z.id } }) } }, OB.icon('search'), 'Open contents')));
    card.bar = bar; card.title = card.querySelector('.zh b'); card.prio = prio.querySelector('b'); card.meta = card.querySelector('.zmeta'); card.top = top; card.chipsHost = chipsHost;
    return card;
  }
  function zoneUpdate(card, z) {
    OB.setText(card.title, z.name + (z.main ? ' (main)' : ''));
    OB.setText(card.prio, z.prio);
    const used = z.cap ? z.w / z.cap * 100 : 0;
    card.bar.set(used, used > 90 ? 'var(--bad)' : used > 70 ? 'var(--warn)' : 'var(--blue)');
    OB.setText(card.meta, F.kg(z.w) + ' / ' + F.kg(z.cap) + ' · ' + z.stacks + ' stacks · ' + z.tiles + ' tiles');
    const sig = z.top.map(t => t.id + t.n).join(',');
    if (card.top._s !== sig) { card.top._s = sig; OB.clear(card.top); for (const t of z.top) card.top.append(h('span.chip', { style: { '--c': OB.catColor[OB.item(t.id).cat] || '#9aa7bd' } }, OB.icon(OB.itemIcon(t.id)), OB.item(t.id).name + ' ×' + t.n)); if (!z.top.length) card.top.append(h('span.muted.t-xs', 'Empty')); }
    const csig = z.cats ? z.cats.join(',') : '*';
    if (card.chipsHost._s !== csig) {
      card.chipsHost._s = csig; OB.clear(card.chipsHost);
      const active = z.cats ? new Set(z.cats) : null;
      card.chipsHost.append(h('div.lbl', { style: { margin: '.5rem 0 .25rem' } }, 'Accepts'), catChips(active, c => {
        const all = S.catalog.item_cats;
        const cur = new Set(z.cats || all);
        if (cur.has(c)) cur.delete(c); else cur.add(c);
        if (cur.size === 0) { OB.toast('warn', 'A zone must accept at least one category.'); return; }
        OB.order('colony', 'zone_set', { id: z.id, cats: all.filter(x => cur.has(x)) });
      }));
    }
  }

  function update(st) {
    const r = st.res;
    capBar.set(r.stock_cap ? r.stock_g / r.stock_cap * 100 : 0, r.stock_g / Math.max(1, r.stock_cap) > 0.9 ? 'var(--bad)' : 'var(--blue)');
    OB.setText(capTxt, F.kg(r.stock_g) + ' of ' + F.kg(r.stock_cap) + ' stored across ' + st.zones.length + ' zones');
    OB.reconcile(listEl, st.zones, z => z.id, zoneCard, zoneUpdate);
  }

  zones.panel = function () {
    root = h('div.zones-panel');
    capBar = OB.bar('thick'); capTxt = h('div.muted.t-sm', '');
    listEl = h('div.zlist');
    // new zone form
    formEls.name = h('input', { type: 'text', value: zones.draft.name, maxLength: 24, 'aria-label': 'Zone name', on: { input: e => (zones.draft.name = e.target.value) } });
    formEls.tiles = h('input', { type: 'range', min: 1, max: 12, value: zones.draft.tiles, 'aria-label': 'Zone size', on: { input: e => { zones.draft.tiles = +e.target.value; OB.setText(formEls.tv, e.target.value + ' tiles'); } } });
    formEls.tv = h('b.num', zones.draft.tiles + ' tiles');
    formEls.prio = OB.seg([1, 2, 3, 4, 5].map(v => ({ value: v, label: String(v) })), zones.draft.prio, v => (zones.draft.prio = v));
    const form = h('div.zform', h('div.lbl', 'New zone'), formEls.name, h('div.row', h('span.muted.t-sm', 'Size'), formEls.tiles, formEls.tv), h('div.row', h('span.muted.t-sm', 'Priority'), formEls.prio), h('button.btn.primary', { on: { click: () => zones.start() } }, OB.icon('zone'), 'Place on map'));
    root.append(h('div.lbl', 'Storage'), capBar, capTxt, h('div.sep'), listEl, h('div.sep'), form);
    return { el: root, update, onShow() {} };
  };
})();
