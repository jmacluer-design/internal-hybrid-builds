/* Colony mode chrome: top resource bar + time controls + threat meter, colonist roster, dock (colonist card / build / zones / expeditions /
   director), command bar, minimap and the world layer. All DOM is created once; updates only touch changed text/styles (see OB.setText). */
(function () {
  'use strict';
  const OB = window.OB, h = OB.h, S = OB.S, F = OB.fmt;
  const colony = (OB.colony = {});
  const el = {};
  let rows = new Map();
  const WORK = ['doctor', 'guard', 'build', 'cook', 'craft', 'haul', 'scavenge'];
  const WORK_LABEL = { doctor: 'Doctor', guard: 'Guard', build: 'Build', cook: 'Cook', craft: 'Craft', haul: 'Haul', scavenge: 'Scavenge' };
  OB.WORK_LABEL = WORK_LABEL;

  const moodColor = m => (m >= 65 ? '#35d39a' : m >= 45 ? '#9bd34f' : m >= 30 ? '#f5a524' : '#ff5d6c');
  OB.moodColor = moodColor;
  const STATE_COL = { idle: '#94a1b7', working: '#6ea8ff', sleeping: '#8b7bff', guarding: '#35d39a', drafted: '#f6b44f', downed: '#ff5d6c', away: '#62708a' };
  OB.stateColor = s => STATE_COL[s] || '#94a1b7';

  // ------------------------------------------------------------------------------------------------------------------ top bar
  const RES = [
    { id: 'colonists', icon: 'people', label: 'Colony' },
    { id: 'food', icon: 'food', label: 'Food' },
    { id: 'water', icon: 'drop', label: 'Water' },
    { id: 'medical', icon: 'cross', label: 'Medical' },
    { id: 'ammo', icon: 'ammo', label: 'Ammo' },
    { id: 'fuel', icon: 'fuel', label: 'Fuel' },
    { id: 'material', icon: 'gear', label: 'Materials' },
    { id: 'power', icon: 'bolt', label: 'Power' },
    { id: 'wealth', icon: 'star', label: 'Wealth' },
  ];

  function buildTopbar() {
    const bar = OB.$('#topbar');
    OB.clear(bar);
    bar.className = 'panel';
    const brand = h('div.brand', OB.icon('bio'), h('div', h('b', 'OUTBREAK'), h('small', 'Colony')));
    const res = h('div.resources');
    el.res = {};
    for (const r of RES) {
      const v = h('div.rv.num', '-'), sub = h('div.rs', '');
      const bar2 = OB.bar('thin');
      const node = h('div.res', { dataset: { id: r.id }, tabindex: 0 }, h('div.ri', OB.icon(r.icon)), h('div.rt', h('div.rl', r.label), v, sub), bar2);
      node.v = v; node.s = sub; node.b = bar2;
      el.res[r.id] = node;
      res.append(node);
    }
    OB.tip(el.res.food, () => { const r = S.state && S.state.res; return r ? '<div class="tt-h">Food</div><div class="tt-r"><span>Meals in stock</span><span>' + r.food + '</span></div><div class="tt-r"><span>Enough for</span><span>' + r.food_days.toFixed(1) + ' days</span></div><div class="tt-r"><span>Colonists</span><span>' + r.colonists + '</span></div><div style="margin-top:.4rem" class="muted">Scavenge, trade or wait for supply drops: there is no farming.</div>' : ''; });
    OB.tip(el.res.water, () => { const r = S.state && S.state.res; return r ? '<div class="tt-h">Water</div><div class="tt-r"><span>Bottles</span><span>' + r.bottled + '</span></div><div class="tt-r"><span>Tank</span><span>' + r.water_tank.toFixed(0) + ' / ' + r.tank_cap.toFixed(0) + ' L</span></div><div class="tt-r"><span>Mains</span><span>' + (r.mains_water ? 'running' : 'dead') + '</span></div>' : ''; });
    OB.tip(el.res.power, () => { const r = S.state && S.state.res; return r ? '<div class="tt-h">Power</div><div class="tt-r"><span>Supply</span><span>' + F.n(r.power_supply) + ' W</span></div><div class="tt-r"><span>Demand</span><span>' + F.n(r.power_demand) + ' W</span></div><div class="tt-r"><span>City grid</span><span>' + (r.mains_power ? 'up' : 'down') + '</span></div>' : ''; });
    OB.tip(el.res.colonists, () => { const r = S.state && S.state.res; return r ? '<div class="tt-h">Colony</div><div class="tt-r"><span>Average mood</span><span>' + Math.round(r.mood) + '%</span></div><div class="tt-r"><span>Injured</span><span>' + r.hurt + '</span></div><div class="tt-r"><span>Beds</span><span>' + S.state.beds + '</span></div><div class="tt-r"><span>Defense</span><span>' + r.defense + '</span></div><div class="tt-r"><span>Wall enclosure</span><span>' + Math.round(r.enclosure * 100) + '%</span></div>' : ''; });
    OB.tip(el.res.wealth, () => '<div class="tt-h">Wealth</div><div class="muted">Stockpile + buildings. The Director scales threats with it.</div>');

    el.day = h('div.disp.num', 'Day 1'); el.clockN = h('div.time.disp.num', '08:00'); el.season = h('div.lbl', 'Spring');
    el.wx = h('span.wx', OB.icon('clear'));
    const timebox = h('div.timebox', h('div.tb-a', el.clockN, el.wx), h('div.tb-b', el.day, el.season));
    el.speed = OB.seg([{ value: 0, icon: 'pause', tip: 'Pause <kbd>Space</kbd>' }, { value: 1, label: '1x', tip: 'Normal <kbd>1</kbd>' }, { value: 2, label: '2x', tip: 'Fast <kbd>2</kbd>' }, { value: 4, label: '4x', tip: 'Faster <kbd>3</kbd>' }, { value: 8, label: '8x', tip: 'Fastest <kbd>4</kbd>' }], 1, v => OB.ui('set_speed', { speed: v }), 'speed');
    el.thSeg = h('div.segbar', ...Array.from({ length: 10 }, () => h('i')));
    el.thLbl = h('b', 'Quiet'); el.thSub = h('small', 'No contacts');
    el.threat = h('div.thmeter', h('div.lbl', 'Threat'), el.thSeg, h('div.tl', el.thLbl, el.thSub));
    el.menuBtn = h('button.btn.sq.ghost', { 'aria-label': 'Menu', on: { click: () => OB.screens.open('menu') } }, OB.icon('gear'));
    OB.tip(el.menuBtn, 'Menu <kbd>Esc</kbd>');
    bar.append(brand, res, h('div.grow'), el.threat, timebox, el.speed, el.menuBtn);
  }

  function updateTopbar(st) {
    const r = st.res;
    const set = (id, val, sub, level, pct) => {
      const n = el.res[id];
      OB.setText(n.v, val); OB.setText(n.s, sub || '');
      n.b.set(pct == null ? 0 : pct);
      OB.setAttr(n, 'data-level', level || 'ok');
      OB.show(n.b, pct != null);
    };
    set('colonists', r.colonists + (r.max_colonists ? '' : ''), 'mood ' + Math.round(r.mood) + '%', r.mood < 30 ? 'bad' : r.mood < 45 ? 'warn' : 'ok', r.mood);
    el.res.colonists.b.set(r.mood, moodColor(r.mood));
    set('food', r.food_days >= 10 ? Math.round(r.food_days) + ' d' : r.food_days.toFixed(1) + ' d', r.food + ' meals', r.food_days < 1 ? 'bad' : r.food_days < 2.5 ? 'warn' : 'ok', Math.min(100, r.food_days / 8 * 100));
    set('water', r.bottled, r.water_ok ? r.water_tank.toFixed(0) + ' L tank' : 'DRY', !r.water_ok ? 'bad' : r.bottled < 4 && r.water_tank < 20 ? 'warn' : 'ok', Math.min(100, r.water_tank / Math.max(1, r.tank_cap) * 100));
    set('medical', r.medical, 'items', r.medical < 2 ? 'bad' : r.medical < 6 ? 'warn' : 'ok');
    set('ammo', r.ammo, 'rounds', r.ammo < 10 ? 'bad' : r.ammo < 40 ? 'warn' : 'ok');
    set('fuel', r.fuel, 'cans', r.fuel < 1 ? 'warn' : 'ok');
    set('material', r.material, 'pieces', 'ok');
    set('power', r.power_ok ? (r.power_supply >= 1000 ? (r.power_supply / 1000).toFixed(1) + ' kW' : F.n(r.power_supply) + ' W') : 'OFF', r.power_ok ? 'load ' + F.n(r.power_demand) : r.mains_power ? 'grid up' : 'blackout', r.power_ok ? 'ok' : 'bad', r.power_supply > 0 ? Math.min(100, r.power_demand / r.power_supply * 100) : 0);
    set('wealth', F.n(r.wealth), 'points', 'ok');
    OB.setText(el.clockN, st.clock); OB.setText(el.day, 'Day ' + st.day); OB.setText(el.season, F.cap(st.season) + (st.weather.kind !== 'clear' ? ' · ' + F.cap(st.weather.kind) : ''));
    if (el.wx._k !== st.weather.kind) { el.wx._k = st.weather.kind; el.wx.replaceChildren(OB.icon(OB.weatherIcon(st.weather.kind))); }
    el.speed.set(st.paused ? 0 : st.speed);
    const t = st.threat, on = Math.round(t.level * 10);
    Array.from(el.thSeg.children).forEach((s, i) => OB.toggle(s, 'on', i < on));
    el.threat.dataset.level = t.label.toLowerCase();
    OB.setText(el.thLbl, t.label);
    OB.setText(el.thSub, t.nearest ? (t.nearest.kind === 'raid' ? t.nearest.name : 'Horde') + ' ' + t.nearest.size + ' · ' + F.dist(t.nearest.dist) + ' ' + F.dir(t.nearest.bearing) : (st.horde_total + ' dead roaming'));
  }

  // ---------------------------------------------------------------------------------------------------------------------- roster
  function buildRoster() {
    const box = OB.$('#roster');
    OB.clear(box);
    box.className = 'panel';
    el.rosterN = h('span.chip', { style: { '--c': 'var(--amber)' } }, '0');
    el.rosterList = h('div.rlist', { role: 'listbox', 'aria-label': 'Colonists' });
    el.selAll = h('button.btn.sq.sm.ghost', { 'aria-label': 'Select everyone', on: { click: () => OB.select(S.state.colonists.map(c => c.id)) } }, OB.icon('cursor'));
    OB.tip(el.selAll, 'Select everyone <kbd>Ctrl</kbd>+<kbd>A</kbd>');
    el.draftAll = h('button.btn.sm', { on: { click: () => { const any = S.state.colonists.some(c => !c.drafted); OB.order('all', 'draft', any); } } }, OB.icon('swords'), 'Draft');
    box.append(h('div.panel-h', OB.icon('people'), h('h2', 'Colonists'), el.rosterN, h('div.grow'), el.selAll, el.draftAll), el.rosterList);
    OB.tip(el.draftAll, 'Draft or release everyone <kbd>R</kbd> acts on the selection');
  }

  function makeRow(c) {
    const av = h('div.av', h('span', ''));
    const name = h('div.rn.ell', ''), job = h('div.rj.ell', ''), flags = h('div.rf');
    const hp = OB.bar('thin'), md = OB.bar('thin');
    const draft = h('button.dbtn', { 'aria-label': 'Draft', on: { click: e => { e.stopPropagation(); const row = OB.col(c.id); OB.order(c.id, 'draft', !(row && row.drafted)); } } }, OB.icon('swords'));
    OB.tip(draft, 'Draft: hold position at full readiness');
    const row = h('div.crow', { role: 'option', tabindex: 0, dataset: { id: c.id }, on: {
      click: e => { OB.select([c.id], e.shiftKey || e.ctrlKey); },
      dblclick: () => colony.focus(c.id),
      keydown: e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); OB.select([c.id]); } else if (e.key === 'ArrowDown') { e.preventDefault(); (row.nextElementSibling || row).focus(); } else if (e.key === 'ArrowUp') { e.preventDefault(); (row.previousElementSibling || row).focus(); } },
      contextmenu: e => { e.preventDefault(); rowMenu(e, c.id); },
    } }, av, h('div.rbody', h('div.rtop', name, flags), job, h('div.rbars', hp, md)), draft);
    row.av = av; row.name = name; row.job = job; row.flags = flags; row.hp = hp; row.md = md; row.draft = draft;
    OB.tip(row, () => { const x = OB.col(c.id); return x ? '<div class="tt-h">' + x.name + '</div><div class="tt-r"><span>Health</span><span>' + Math.round(x.hp) + ' / ' + x.hp_max + '</span></div><div class="tt-r"><span>Mood</span><span>' + Math.round(x.mood) + '%</span></div><div class="tt-r"><span>Food / water / rest</span><span>' + Math.round(100 - x.hunger) + ' / ' + Math.round(100 - x.thirst) + ' / ' + Math.round(100 - x.fatigue) + '</span></div><div class="muted" style="margin-top:.3rem">' + x.job_label + '</div>' : ''; }, 450);
    return row;
  }
  function rowMenu(e, id) {
    const c = OB.col(id); if (!c) return;
    OB.ctx(e.clientX, e.clientY, [
      { icon: 'person', label: 'Open card', run: () => { OB.select([id]); colony.setDock('card'); } },
      { icon: 'crosshair', label: 'Centre camera', run: () => colony.focus(id) },
      { icon: 'swords', label: c.drafted ? 'Release from draft' : 'Draft', key: 'R', run: () => OB.order(id, 'draft', !c.drafted) },
      { icon: 'bars', label: 'Work priorities', key: 'P', run: () => { OB.select([id]); OB.screens.open('priorities'); } },
    ]);
  }
  function updateRow(r, c) {
    OB.setText(r.name, OB.short(c.name) + ' ' + '“' + OB.nick(c.name) + '”');
    OB.setText(r.av.firstChild, OB.initials(c.name));
    const col = c.downed ? STATE_COL.downed : c.drafted ? STATE_COL.drafted : STATE_COL[c.state];
    OB.setStyle(r.av, '--c', col);
    OB.setStyle(r.av, '--h', String(OB.hue(c.name)));
    OB.setText(r.job, c.job_label);
    r.hp.set(c.hp / c.hp_max * 100, c.hp / c.hp_max < 0.35 ? 'var(--bad)' : 'var(--good)');
    r.md.set(c.mood, moodColor(c.mood));
    OB.toggle(r, 'sel', S.sel.indexOf(c.id) >= 0);
    OB.toggle(r, 'prim', S.primary === c.id);
    OB.toggle(r, 'away', c.state === 'away');
    OB.toggle(r, 'down', c.downed);
    OB.toggle(r.draft, 'on', c.drafted);
    OB.setAttr(r, 'aria-selected', S.sel.indexOf(c.id) >= 0 ? 'true' : 'false');
    const f = (c.bleeding > 0.02 ? 'b' : '') + (c.infection !== 'none' ? 'i' : '') + (c.mood_break ? 'm' : '') + (c.downed ? 'd' : '') + (c.state === 'away' ? 'a' : '');
    if (r.flags._f !== f) {
      r.flags._f = f; OB.clear(r.flags);
      if (c.bleeding > 0.02) r.flags.append(h('span.fl.bleed', { title: 'Bleeding' }, OB.icon('bleed')));
      if (c.infection !== 'none') r.flags.append(h('span.fl.inf', { title: 'Infected: ' + c.infection }, OB.icon('bio')));
      if (c.mood_break) r.flags.append(h('span.fl.brk', { title: 'Mental break: ' + c.mood_break }, OB.icon('alert')));
      if (c.downed) r.flags.append(h('span.fl.dn', { title: 'Downed' }, OB.icon('skull')));
      if (c.state === 'away') r.flags.append(h('span.fl.aw', { title: 'On an expedition' }, OB.icon('truck')));
    }
  }
  function updateRoster(st) {
    OB.setText(el.rosterN, st.colonists.length);
    OB.reconcile(el.rosterList, st.colonists, c => c.id, makeRow, updateRow);
    OB.toggle(el.rosterList, 'dense', st.colonists.length > 12);
    const anyUn = st.colonists.some(c => !c.drafted);
    OB.setText(el.draftAll.lastChild, anyUn ? 'Draft' : 'Release');
    OB.toggle(el.draftAll, 'on', !anyUn && st.colonists.length > 0);
  }

  // ---------------------------------------------------------------------------------------------------------------------- dock
  const DOCK = [
    { id: 'card', icon: 'person', label: 'Colonist', key: 'C' },
    { id: 'build', icon: 'hammer', label: 'Build', key: 'B' },
    { id: 'zones', icon: 'zone', label: 'Stock', key: 'Z' },
    { id: 'exped', icon: 'truck', label: 'Expeditions' },
    { id: 'director', icon: 'radar', label: 'Director', key: 'L' },
  ];
  colony.panels = {};
  function buildDock() {
    const dock = OB.$('#dock');
    OB.clear(dock);
    el.tabs = h('div.dtabs', { role: 'tablist' });
    for (const t of DOCK) {
      const b = h('button.dtab', { role: 'tab', 'aria-label': t.label, dataset: { id: t.id }, on: { click: () => colony.setDock(t.id) } }, OB.icon(t.icon), h('span', t.label));
      OB.tip(b, t.label + (t.key ? ' <kbd>' + t.key + '</kbd>' : ''));
      el.tabs.append(b);
    }
    el.dockBody = h('div.dbody');
    dock.className = 'panel';
    dock.append(el.tabs, el.dockBody);
    colony.panels.card = OB.cardPanel();
    colony.panels.build = OB.build.panel();
    colony.panels.zones = OB.zones.panel();
    colony.panels.exped = OB.exped.panel();
    colony.panels.director = OB.director.panel();
    for (const id of Object.keys(colony.panels)) { colony.panels[id].el.hidden = true; el.dockBody.append(colony.panels[id].el); }
    colony.setDock(S.dock || 'card', true);
  }
  colony.setDock = function (id, silent) {
    if (!colony.panels[id]) return;
    if (S.dock === 'build' && id !== 'build' && OB.build.cancel) OB.build.cancel(true);
    S.dock = id;
    for (const k of Object.keys(colony.panels)) colony.panels[k].el.hidden = k !== id;
    OB.$$('.dtab', el.tabs).forEach(b => { const on = b.dataset.id === id; b.classList.toggle('on', on); b.setAttribute('aria-selected', on ? 'true' : 'false'); });
    OB.$$('#cmdbar [data-dock]').forEach(b => b.classList.toggle('on', b.dataset.dock === id));
    if (colony.panels[id].onShow) colony.panels[id].onShow();
    if (S.state && !silent) colony.panels[id].update(S.state);
    OB.emit('dock', id);
  };

  // ------------------------------------------------------------------------------------------------------------ colonist card
  OB.cardPanel = function () {
    const root = h('div.card-panel');
    const head = h('div.chead');
    const tabs = h('div.seg.ctabs');
    const body = h('div.cbody');
    root.append(head, tabs, body);
    const TABS = [['needs', 'Needs'], ['mood', 'Mood'], ['skills', 'Skills'], ['gear', 'Gear'], ['health', 'Health']];
    let tab = 'needs', lastKey = '';
    for (const [id, label] of TABS) tabs.append(h('button', { dataset: { id }, class: id === tab ? 'on' : '', on: { click: () => { tab = id; lastKey = ''; OB.$$('button', tabs).forEach(b => b.classList.toggle('on', b.dataset.id === id)); if (S.state) update(S.state); } } }, label));


    function section(title, ...kids) { return h('section.csec', h('div.lbl', title), ...kids); }
    function meter(label, value, max, color, right, tip) {
      const b = OB.bar('thick'); b.set(value / max * 100, color);
      const n = h('div.meter', h('div.mh', h('span', label), h('b.num', right)), b);
      if (tip) OB.tip(n, tip);
      return n;
    }
    function needsView(c) {
      const k = h('div.col.gap3');
      k.append(
        meter('Health', c.hp, c.hp_max, c.hp / c.hp_max < 0.35 ? 'var(--bad)' : 'var(--hp)', Math.round(c.hp) + ' / ' + c.hp_max),
        meter('Food', 100 - c.hunger, 100, 'var(--hunger)', Math.round(100 - c.hunger) + '%', 'Eats when hungry. Starvation starts at 0.'),
        meter('Water', 100 - c.thirst, 100, 'var(--thirst)', Math.round(100 - c.thirst) + '%', 'Drinks from the tank or bottles.'),
        meter('Rest', 100 - c.fatigue, 100, 'var(--fatigue)', Math.round(100 - c.fatigue) + '%', 'Sleeps on the schedule; beds give better rest.'),
        meter('Mood', c.mood, 100, moodColor(c.mood), Math.round(c.mood) + '% · ' + c.mood_name, 'Breaks begin below 30 (minor), 20 (major), 10 (extreme).'),
      );
      const wp = h('div.wprio');
      for (const w of WORK) {
        const lv = c.prio[w], blocked = c.blocked[w];
        const b = h('button.wp' + (lv ? '.p' + lv : '') + (blocked ? '.blk' : ''), { 'aria-label': WORK_LABEL[w] + ' priority ' + lv, on: { click: () => { if (!blocked) OB.order(c.id, 'priority', { work: w, level: (lv + 1) % 5 }); } } }, OB.icon(OB.workIcon(w)), h('i', blocked ? '×' : lv || '·'));
        OB.tip(b, WORK_LABEL[w] + ': ' + (blocked ? 'blocked by a trait' : lv ? 'priority ' + lv : 'never') + '<br><span class="muted">click to cycle 0-4</span>');
        wp.append(b);
      }
      k.append(section('Work priorities', wp), section('Doing now', h('div.row', OB.icon(OB.jobIcon(c.job === 'idle' && c.state === 'away' ? 'away' : c.downed ? 'downed' : c.job)), h('span', c.job_label)), h('div.muted.t-sm', c.work_speed != null ? 'Work speed ' + Math.round(c.work_speed * 100) + '%' : '')));
      return k;
    }
    function moodView(c) {
      const k = h('div.col.gap3');
      const big = h('div.moodbig', h('div.disp.num', { style: { color: moodColor(c.mood) } }, Math.round(c.mood) + '%'), h('div', h('b', c.mood_name), h('div.muted.t-sm', c.mood_break_info ? 'On a mental break: ' + c.mood_break_info.kind + ' (' + F.dur(c.mood_break_info.left) + ' left)' : c.mood < 30 ? 'At risk of a break' : 'Stable')));
      const track = h('div.mtrack', h('i.mfill', { style: { width: c.mood + '%', background: moodColor(c.mood) } }), h('i.mk', { style: { left: '30%' } }), h('i.mk', { style: { left: '20%' } }), h('i.mk', { style: { left: '10%' } }));
      const mp = c.mood_parts;
      const part = (l, v) => h('div.tt-rr', h('span', l), h('b.num', (v >= 0 ? '+' : '') + v.toFixed(0)));
      k.append(big, track, h('div.parts', part('Baseline', mp.base), part('Thoughts', mp.thoughts), part('Needs', mp.needs)));
      const list = h('div.thoughts');
      if (!c.thoughts.length) list.append(h('div.muted.t-sm', 'No notable thoughts.'));
      for (const t of c.thoughts) list.append(h('div.thought' + (t.value >= 0 ? '.pos' : '.neg'), h('span.grow', t.label), h('span.muted.t-xs', F.dur(t.left)), h('b.num', (t.value > 0 ? '+' : '') + t.value.toFixed(0))));
      k.append(section('Thoughts', list));
      return k;
    }
    function skillsView(c) {
      const k = h('div.col.gap3');
      const list = h('div.skills');
      for (const s of c.skills) {
        const pips = h('div.pips', ...Array.from({ length: 10 }, (_, i) => h('i' + (i < s.level ? '.on' : ''))));
        const bar = OB.bar('thin'); bar.set(s.pct * 100, 'var(--amber)');
        list.append(h('div.skill', h('div.sn', F.cap(s.id), h('b.num', 'L' + s.level)), pips, bar, h('div.muted.t-xs', 'speed x' + s.speed.toFixed(2))));
      }
      k.append(list);
      const tr = h('div.traits');
      for (const t of c.trait_info) tr.append(h('div.trait', h('b', t.name), h('div.muted.t-sm', t.desc)));
      k.append(section('Traits', tr));
      return k;
    }
    function gearView(c) {
      const k = h('div.col.gap3');
      const w = c.carry;
      const bar = OB.bar('thick'); bar.set(w.w / w.cap * 100, 'var(--weight)');
      k.append(h('div.meter', h('div.mh', h('span', 'Carrying'), h('b.num', (w.w / 1000).toFixed(1) + ' / ' + (w.cap / 1000).toFixed(1) + ' kg')), bar));
      const grid = h('div.mini-inv');
      for (const it of c.items) {
        const cat = OB.item(it.id).cat;
        const slot = h('div.mslot', { style: { '--c': OB.catColor[cat] || '#9aa7bd' } }, OB.icon(OB.itemIcon(it.id)), h('b', it.n), h('span.ell', it.name));
        OB.tip(slot, () => OB.itemTip(it.id, it.n));
        grid.append(slot);
      }
      if (!c.items.length) grid.append(h('div.muted.t-sm', 'Carrying nothing.'));
      k.append(section('Carried items (' + c.items.length + ')', grid));
      if (c.weapon) k.append(section('Best weapon', h('div.row', OB.icon(OB.itemIcon(c.weapon)), h('b', OB.item(c.weapon).name))));
      // schedule strip
      const strip = h('div.sched');
      const hr = S.state ? S.state.hour : 0;
      for (let i = 0; i < 24; i++) { const ch = c.sched[i] || 'W'; strip.append(h('i.s' + ch + (i === hr ? '.now' : ''), { title: String(i).padStart(2, '0') + ':00 ' + { S: 'sleep', W: 'work', A: 'anything', J: 'joy' }[ch] })); }
      k.append(section('Schedule', strip, h('div.row', h('button.btn.sm', { on: { click: () => OB.order(c.id, 'schedule', 'day') } }, 'Day'), h('button.btn.sm', { on: { click: () => OB.order(c.id, 'schedule', 'night') } }, 'Night'), h('button.btn.sm', { on: { click: () => OB.order(c.id, 'schedule', 'early') } }, 'Early'))));
      return k;
    }
    function healthView(c) {
      const k = h('div.col.gap3');
      const inf = c.infection;
      k.append(h('div.row', h('span.chip', { style: { '--c': inf === 'none' ? 'var(--good)' : 'var(--infect)' } }, OB.icon('bio'), inf === 'none' ? 'No visible infection' : 'Infection: ' + inf), c.downed ? h('span.chip', { style: { '--c': 'var(--bad)' } }, OB.icon('skull'), 'Downed') : null, c.maimed ? h('span.chip', { style: { '--c': 'var(--warn)' } }, 'Amputations: ' + c.maimed) : null));
      const wl = h('div.wounds');
      if (!c.wounds.length) wl.append(h('div.muted.t-sm', 'No open wounds.'));
      for (const w of c.wounds) wl.append(h('div.wound', OB.icon(w.kind === 'bite' ? 'bio' : 'bleed'), h('span.grow', F.cap(w.kind) + ' · ' + w.part), h('b.num' + (w.bleed > 0 ? '.bad' : '.muted'), w.bleed > 0 ? w.bleed.toFixed(2) + '/min' : 'closed')));
      k.append(section('Wounds', wl));
      k.append(h('div.row.between', h('div', h('b', 'Allow amputation'), h('div.muted.t-sm', 'Doctors may remove an infected limb (needs a surgical kit)')), (function () { const t = OB.toggleSwitch(c.allow_amputation, v => OB.order(c.id, 'amputation', v), 'Allow amputation'); return t; })()));
      k.append(h('div.row', h('span.muted.t-sm', 'Pain'), h('b.num', Math.round(c.pain) + '%'), h('span.grow'), h('span.muted.t-sm', 'Kills'), h('b.num', c.kills)));
      return k;
    }
    function update(st) {
      const c = st.card;
      if (!c) {
        const key = 'none';
        if (lastKey !== key) { lastKey = key; OB.clear(head); OB.clear(body); body.append(h('div.empty', OB.icon('cursor'), h('b', 'No colonist selected'), h('p.muted', OB.touch && OB.touch.on ? 'Tap a colonist on the map or in the strip. Use Select to drag a box around several, then Order and tap where they should go; long-press the map for more.' : 'Click a colonist on the map or in the roster. Drag to box-select, right-click to give a move order.'))); }
        tabs.hidden = true; return;
      }
      tabs.hidden = false;
      const key = c.id + '|' + tab + '|' + [c.state, c.job, Math.round(c.hp), Math.round(c.hunger), Math.round(c.thirst), Math.round(c.fatigue), Math.round(c.mood), c.drafted, c.infection, c.wounds.length, c.items.length, c.thoughts.length, JSON.stringify(c.prio), c.allow_amputation, c.sched_now, st.hour].join(',');
      if (key === lastKey) return;
      lastKey = key;
      OB.clear(head); OB.clear(body);
      const av = h('div.av.big', { style: { '--c': OB.stateColor(c.drafted ? 'drafted' : c.state), '--h': OB.hue(c.name) } }, h('span', OB.initials(c.name)));
      head.append(av, h('div.grow', h('div.cname.disp', OB.short(c.name) + ' “' + OB.nick(c.name) + '”'), h('div.muted.t-sm', 'Age ' + c.age + ' · joined day ' + c.joined_day + ' · ' + c.kills + ' kills'), h('div.cjob', OB.icon(OB.jobIcon(c.state === 'away' ? 'away' : c.downed ? 'downed' : c.job)), c.job_label)),
        h('div.col.gap1', h('button.btn.sm' + (c.drafted ? '.on' : ''), { on: { click: () => OB.order(c.id, 'draft', !c.drafted) } }, OB.icon('swords'), c.drafted ? 'Drafted' : 'Draft'), h('button.btn.sm', { on: { click: () => colony.focus(c.id) } }, OB.icon('crosshair'), 'Centre')));
      if (S.sel.length > 1) body.append(h('div.multi', OB.icon('people'), h('span', S.sel.length + ' selected'), h('span.muted.t-sm', 'commands apply to all')));
      body.append(({ needs: needsView, mood: moodView, skills: skillsView, gear: gearView, health: healthView })[tab](c));
    }
    return { el: root, update, onShow() { lastKey = ''; } };
  };
  OB.itemTip = function (id, n) {
    const d = OB.item(id);
    let rows = '<div class="tt-h">' + d.name + (n > 1 ? ' <span class="muted">x' + n + '</span>' : '') + '</div><div class="tt-r"><span>Category</span><span>' + F.cap(d.cat) + '</span></div><div class="tt-r"><span>Weight</span><span>' + F.kg(d.w) + (n > 1 ? ' (' + F.kg(d.w * n) + ')' : '') + '</span></div><div class="tt-r"><span>Value</span><span>' + d.value + '</span></div>';
    if (d.food) rows += '<div class="tt-r"><span>Restores</span><span>' + [d.food.hunger ? d.food.hunger + ' food' : '', d.food.thirst ? d.food.thirst + ' water' : ''].filter(Boolean).join(', ') + '</span></div>';
    if (d.med) rows += '<div class="tt-r"><span>Medical</span><span>' + F.cap(d.med.kind) + '</span></div>';
    if (d.weapon) rows += '<div class="tt-r"><span>' + F.cap(d.weapon.kind) + ' power</span><span>' + d.weapon.power + (d.weapon.ammo ? ' · uses ' + OB.item(d.weapon.ammo).name : '') + '</span></div><div class="tt-r"><span>Noise</span><span>' + d.weapon.noise + '</span></div>';
    if (d.fuel_l) rows += '<div class="tt-r"><span>Fuel</span><span>' + d.fuel_l + ' L</span></div>';
    return rows;
  };

  // ------------------------------------------------------------------------------------------------------------ command bar
  function buildCmdbar() {
    const bar = OB.$('#cmdbar');
    OB.clear(bar);
    bar.className = 'panel';
    const btn = (icon, label, key, run, extra) => {
      const b = h('button.cmd', { dataset: extra || {}, on: { click: run } }, OB.icon(icon), h('span', label), key ? h('kbd.hint', key) : null);
      OB.tip(b, label + (key ? ' <kbd>' + key + '</kbd>' : ''));
      return b;
    };
    el.cmdDraft = btn('swords', 'Draft', 'R', () => colony.toggleDraft());
    bar.append(
      btn('cursor', 'Select all', 'Ctrl+A', () => OB.select(S.state.colonists.map(c => c.id))),
      el.cmdDraft,
      h('i.vsep'),
      btn('bars', 'Priorities', 'P', () => OB.screens.toggle('priorities')),
      btn('hammer', 'Build', 'B', () => colony.setDock('build'), { dock: 'build' }),
      btn('zone', 'Stock', 'Z', () => colony.setDock('zones'), { dock: 'zones' }),
      btn('truck', 'Expeditions', '', () => colony.setDock('exped'), { dock: 'exped' }),
      btn('radar', 'Director', 'L', () => colony.setDock('director'), { dock: 'director' }),
      h('i.vsep'),
      btn('map', 'Map', 'M', () => OB.screens.toggle('map')),
      btn('crate', 'Inventory', 'I', () => OB.screens.toggle('inventory')),
    );
  }
  colony.toggleDraft = function () {
    if (!S.state) return;
    const ids = S.sel.length ? S.sel : S.state.colonists.map(c => c.id);
    const any = ids.some(id => { const c = OB.col(id); return c && !c.drafted; });
    if (!S.sel.length) OB.order('all', 'draft', any); else ids.forEach(id => OB.order(id, 'draft', any));
  };
  colony.focus = function (id) {
    const c = OB.col(id); if (!c) return;
    OB.post('focus', { x: c.x, y: c.y, id });
    if (OB.mapBg) OB.mapBg.center(c.x, c.y);
    OB.select([id]);
  };

  // ---------------------------------------------------------------------------------------------------------- minimap + world
  function buildMinimap() {
    const box = OB.$('#minimap');
    OB.clear(box);
    box.className = 'panel';
    const holder = h('div.mm-body');
    const zoom = h('div.mm-btns', h('button.btn.sq.sm.ghost', { 'aria-label': 'Open map', on: { click: () => OB.screens.open('map') } }, OB.icon('map')));
    box.append(holder, h('div.mm-n', 'N'), zoom, h('div.mm-l', 'Region'));
    OB.minimap = OB.map.reg(new OB.MapView(holder, { mode: 'mini', interactive: false }));
    OB.minimap.s = 0.058; OB.minimap.cx = 0; OB.minimap.cy = 0; OB.minimap.follow = false;
    OB.on('mapfocus', p => { if (OB.mapBg) OB.mapBg.center(p.x, p.y); });
  }
  function buildWorld() {
    const bg = OB.$('#mapbg');
    OB.clear(bg);
    if (OB.preview || (S.boot && S.boot.preview)) {
      bg.hidden = false;
      OB.mapBg = OB.map.reg(new OB.MapView(bg, { mode: 'full' }));
      OB.mapBg.fit(false);
      colony.worldMode = 'map';
    } else {
      // in game the 3D world shows through: forward pointer input to the Lua client (normalised 0..1 coordinates) for ray casts / box select
      bg.hidden = false;
      bg.classList.add('layer');
      const send = (type, e, extra) => OB.post('mouse', Object.assign({ type, x: e.clientX / innerWidth, y: e.clientY / innerHeight, button: e.button, shift: e.shiftKey, ctrl: e.ctrlKey, alt: e.altKey }, extra || {}));
      const mv = OB.throttle(e => send('move', e), 33);
      // the selection rectangle is drawn here (the Lua side only needs the end points); it shows once the drag is a few pixels long
      const box = h('div.selbox'); box.hidden = true; bg.append(box);
      let drag = null;
      const showBox = e => {
        const x0 = Math.min(drag.x, e.clientX), y0 = Math.min(drag.y, e.clientY), w = Math.abs(e.clientX - drag.x), hh = Math.abs(e.clientY - drag.y);
        const on = w + hh > 8;
        if (on) { box.style.left = x0 + 'px'; box.style.top = y0 + 'px'; box.style.width = w + 'px'; box.style.height = hh + 'px'; }
        box.hidden = !on;
      };
      bg.addEventListener('pointerdown', e => { bg.setPointerCapture(e.pointerId); if (e.button === 0) drag = { x: e.clientX, y: e.clientY }; send('down', e); });
      bg.addEventListener('pointerup', e => { drag = null; box.hidden = true; send('up', e); });
      bg.addEventListener('pointercancel', () => { drag = null; box.hidden = true; });
      bg.addEventListener('pointermove', e => { if (drag && !OB.build.placing) showBox(e); mv(e); });
      bg.addEventListener('dblclick', e => send('dblclick', e));
      bg.addEventListener('wheel', e => { e.preventDefault(); send('wheel', e, { dy: Math.sign(e.deltaY) }); }, { passive: false });
      bg.addEventListener('contextmenu', e => { e.preventDefault(); send('context', e); });
      colony.worldMode = 'layer';
    }
  }

  // ---------------------------------------------------------------------------------------------------------- lifecycle
  colony.init = function () {
    buildTopbar(); buildRoster(); buildDock(); buildCmdbar(); buildMinimap();
    OB.on('boot', () => {});
    OB.on('selection', () => { if (S.state) { updateRoster(S.state); } });
  };
  colony.enter = function () {
    if (!OB.mapBg && !el.worldBuilt) { el.worldBuilt = true; buildWorld(); }
    if (S.state) { colony.update(S.state); OB.map.updateAll(S.state); }
  };
  colony.leave = function () { if (OB.build) OB.build.cancel(true); };
  colony.update = function (st) {
    updateTopbar(st);
    updateRoster(st);
    const p = colony.panels[S.dock];
    if (p) p.update(st);
    OB.toggle(el.cmdDraft, 'on', S.sel.length ? S.sel.every(id => { const c = OB.col(id); return c && c.drafted; }) : st.colonists.length > 0 && st.colonists.every(c => c.drafted));
  };
})();
