/* Pause menu + settings + controls, and the collapse / summary screen (with a small-multiples history chart). */
(function () {
  'use strict';
  const OB = window.OB, h = OB.h, S = OB.S, F = OB.fmt;

  // ============================================================================================================== pause menu
  let mroot, mcontent, mnav, curTab = 'main';
  const KEYS = [
    ['F6', 'Toggle colony view'], ['I', 'Inventory'], ['Esc', 'Menu / close / cancel'],
    ['W A S D', 'Pan the camera (colony view)'], ['Q E', 'Rotate the camera'], ['Mouse wheel', 'Zoom'], ['Left click / drag', 'Select colonists (box select)'], ['Right click', 'Move order / context menu'],
    ['B', 'Build menu'], ['Z', 'Stockpile zones'], ['L', 'Director log'], ['P', 'Work priorities'], ['M', 'Tactical map'], ['R', 'Draft / release selection'],
    ['Space', 'Pause'], ['1 2 3 4', 'Speed 1x / 2x / 4x / 8x'], ['. ,', 'Next / previous colonist'], ['Ctrl+A', 'Select all colonists'], ['Shift+click', 'Add to selection / chain placement'],
  ];
  function row(label, desc, control) { return h('div.srow', h('div.grow', h('b', label), desc ? h('div.muted.t-sm', desc) : null), control); }
  function slider(key, min, max, step, fmt) {
    const val = h('b.num', fmt(OB.settings[key]));
    const inp = h('input', { type: 'range', min, max, step, value: OB.settings[key], 'aria-label': key, on: { input: e => { OB.settings[key] = +e.target.value; OB.setText(val, fmt(+e.target.value)); OB.saveSettings(); } } });
    return h('div.sl', inp, val);
  }
  const TABS = {
    main() {
      const k = h('div.col.gap3');
      k.append(h('p.muted', 'The colony keeps running while this menu is open only if you leave it on a speed; use Space to pause the clock.'));
      k.append(h('div.btnrow', h('button.btn.primary', { on: { click: () => OB.screens.close() } }, OB.icon('play'), 'Resume'),
        h('button.btn', { on: { click: () => { OB.ui('save'); OB.toast('good', 'Game saved.', { icon: 'save' }); } } }, OB.icon('save'), 'Save game'),
        h('button.btn', { on: { click: () => { OB.ui('load'); OB.toast('info', 'Loading the latest save…', { icon: 'undo' }); OB.screens.close(); } } }, OB.icon('undo'), 'Load game')));
      const seed = h('input', { type: 'number', value: (S.state && S.state.seed) || 1, 'aria-label': 'Seed' });
      const prof = h('select', { 'aria-label': 'Pacing profile' }, ...['calm', 'escalating', 'chaos'].map(p => h('option', { value: p, selected: p === ((S.state && S.state.profile) || 'escalating') }, F.cap(p))));
      k.append(h('section.csec', h('div.lbl', 'New game'), h('div.row', h('label.muted.t-sm', 'Seed'), seed, h('label.muted.t-sm', 'Pacing'), prof, h('button.btn.danger', { on: { click: () => { OB.ui('new_game', { seed: +seed.value, profile: prof.value }); OB.screens.close(); OB.toast('warn', 'New colony started.', { icon: 'flag' }); } } }, 'Start new colony')),
        h('div.muted.t-xs', 'The same seed and profile give the same colony and the same Director schedule (the sim is deterministic).')));
      if (OB.preview || (S.boot && S.boot.preview)) k.append(h('div.notice', OB.icon('info'), h('span', h('b', 'Browser preview. '), 'This page is the real NUI running against the real Lua sim in WebAssembly. There is no GTA here: no peds, no camera, no world.')));
      return k;
    },
    settings() {
      const k = h('div.col');
      k.append(
        row('UI scale', 'Everything scales with the window; this adds a multiplier.', slider('uiScale', 0.75, 1.5, 0.05, v => Math.round(v * 100) + '%')),
        row('HUD opacity', 'Survival HUD only.', slider('hudOpacity', 0.4, 1, 0.05, v => Math.round(v * 100) + '%')),
        row('Reduce motion', 'Turns off pulses, slides and fades.', OB.toggleSwitch(OB.settings.reduceMotion, v => { OB.settings.reduceMotion = v; OB.saveSettings(); }, 'Reduce motion')),
        row('Colour-blind safe palette', 'Swaps red/green status colours for blue/amber.', OB.toggleSwitch(OB.settings.colorblind, v => { OB.settings.colorblind = v; OB.saveSettings(); }, 'Colour-blind safe palette')),
        row('Key hints', 'Show key caps in tooltips and bars.', OB.toggleSwitch(OB.settings.hints, v => { OB.settings.hints = v; OB.saveSettings(); }, 'Key hints')));
      return k;
    },
    controls() {
      const t = h('div.keys');
      for (const [k, d] of KEYS) t.append(h('div.krow', h('span.keycaps', ...k.split(' ').map(x => OB.key(x))), h('span', d)));
      return t;
    },
    about() {
      return h('div.col.gap3', h('p', 'Outbreak is a private, non-commercial zombie-survival colony manager. The simulation is pure Lua; GTA V (FiveM, local server) is only the stage.'),
        h('p.muted.t-sm', 'No Rockstar characters, story, voice lines or third-party IP are used. Names, art and rules are original. See THIRD_PARTY.md for the code this UI borrows patterns from.'),
        h('p.muted.t-sm', 'Fonts: Inter and Barlow Condensed (SIL OFL 1.1), bundled locally. No network access is needed or used.'));
    },
  };
  const NAV = [['main', 'Game', 'play'], ['settings', 'Settings', 'gear'], ['controls', 'Controls', 'list'], ['about', 'About', 'info']];
  function showTab(id) {
    curTab = id;
    OB.clear(mcontent); mcontent.append(TABS[id]());
    OB.$$('button', mnav).forEach(b => b.classList.toggle('on', b.dataset.id === id));
  }
  OB.screens.reg('menu', {
    build() {
      mnav = h('nav.mnav', ...NAV.map(([id, label, icon]) => h('button.mn', { dataset: { id }, on: { click: () => showTab(id) } }, OB.icon(icon), label)));
      mcontent = h('div.mcontent');
      mroot = h('div.panel.screen.menu', h('div.panel-h', OB.icon('bio'), h('h2', 'Outbreak'), h('div.grow'), h('button.btn.sq.ghost', { 'aria-label': 'Close', on: { click: () => OB.screens.close() } }, OB.icon('x'))), h('div.mbody', mnav, mcontent));
      return mroot;
    },
    onOpen() { showTab('main'); },
    update() {},
  });

  // ================================================================================================================ summary
  let sroot, sbody, summary = null;
  const CAUSE = { zombies: 'killed by the dead', bled_out: 'bled out', starved: 'starved', dehydrated: 'died of thirst', infection: 'infection', wounds: 'wounds', wandered_off: 'wandered off', lost_on_run: 'lost on a run', debug: 'debug' };
  const SVGNS = 'http://www.w3.org/2000/svg';
  const svgEl = (tag, attrs) => { const e = document.createElementNS(SVGNS, tag); for (const k of Object.keys(attrs || {})) e.setAttribute(k, attrs[k]); return e; };
  // validated categorical slots (dark surface): blue / orange / aqua. One series per panel, so the panel title names the series.
  const SERIES = [['colonists', 'Colonists alive', '#3987e5', v => String(Math.round(v))], ['mood', 'Average mood', '#d95926', v => Math.round(v) + '%'], ['wealth', 'Wealth', '#199e70', v => F.n(v)]];

  function lineChart(rows, key, color, fmt, tip) {
    const W = 360, H = 150, pl = 34, pr = 40, pt = 12, pb = 24;
    const svg = svgEl('svg', { viewBox: '0 0 ' + W + ' ' + H, class: 'lc', role: 'img', 'aria-label': key + ' by day' });
    const xs = rows.map(r => r.day), ys = rows.map(r => r[key]);
    const x0 = Math.min(...xs), x1 = Math.max(...xs, x0 + 1);
    let ymax = Math.max(...ys, 1); const nice = Math.pow(10, Math.floor(Math.log10(ymax))); ymax = Math.ceil(ymax / nice * 2) / 2 * nice; if (key === 'mood') ymax = 100;
    const X = d => pl + (d - x0) / (x1 - x0) * (W - pl - pr), Y = v => pt + (1 - v / ymax) * (H - pt - pb);
    for (let i = 0; i <= 2; i++) { // hairline grid + y ticks, recessive
      const v = ymax * i / 2, y = Y(v);
      svg.append(svgEl('line', { x1: pl, x2: W - pr, y1: y, y2: y, stroke: 'rgba(255,255,255,.09)', 'stroke-width': 1 }));
      const t = svgEl('text', { x: pl - 6, y: y + 3.5, 'text-anchor': 'end', fill: '#898781', 'font-size': 10 }); t.textContent = key === 'wealth' && v >= 1000 ? (v / 1000).toFixed(1) + 'K' : Math.round(v); svg.append(t);
    }
    for (const d of [x0, Math.round((x0 + x1) / 2), x1]) { const t = svgEl('text', { x: X(d), y: H - 6, 'text-anchor': 'middle', fill: '#898781', 'font-size': 10 }); t.textContent = 'D' + d; svg.append(t); }
    if (rows.length) {
      const pts = rows.map(r => [X(r.day), Y(r[key])]);
      const d = pts.map((p, i) => (i ? 'L' : 'M') + p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join('');
      svg.append(svgEl('path', { d: d + 'L' + pts[pts.length - 1][0] + ' ' + Y(0) + 'L' + pts[0][0] + ' ' + Y(0) + 'Z', fill: color, opacity: 0.1 }));
      svg.append(svgEl('path', { d, fill: 'none', stroke: color, 'stroke-width': 2, 'stroke-linejoin': 'round', 'stroke-linecap': 'round' }));
      const last = pts[pts.length - 1];
      svg.append(svgEl('circle', { cx: last[0], cy: last[1], r: 4.5, fill: color, stroke: '#10151f', 'stroke-width': 2 }));
      const lab = svgEl('text', { x: last[0] + 8, y: last[1] + 4, fill: '#eaf0f9', 'font-size': 12, 'font-weight': 600 }); lab.textContent = fmt(rows[rows.length - 1][key]); svg.append(lab);
      // hover layer: crosshair + dot + shared tooltip
      const cross = svgEl('line', { y1: pt, y2: H - pb, stroke: 'rgba(255,255,255,.35)', 'stroke-width': 1, visibility: 'hidden' });
      const dot = svgEl('circle', { r: 4.5, fill: color, stroke: '#10151f', 'stroke-width': 2, visibility: 'hidden' });
      const hit = svgEl('rect', { x: pl, y: pt, width: W - pl - pr, height: H - pt - pb, fill: 'transparent' });
      svg.append(cross, dot, hit);
      const move = ev => {
        const r = svg.getBoundingClientRect(), px = (ev.clientX - r.left) / r.width * W;
        let bi = 0, bd = 1e9; pts.forEach((p, i) => { const dd = Math.abs(p[0] - px); if (dd < bd) { bd = dd; bi = i; } });
        cross.setAttribute('x1', pts[bi][0]); cross.setAttribute('x2', pts[bi][0]); cross.setAttribute('visibility', 'visible');
        dot.setAttribute('cx', pts[bi][0]); dot.setAttribute('cy', pts[bi][1]); dot.setAttribute('visibility', 'visible');
        tip(ev, rows[bi]);
      };
      hit.addEventListener('pointermove', move);
      hit.addEventListener('pointerleave', () => { cross.setAttribute('visibility', 'hidden'); dot.setAttribute('visibility', 'hidden'); tip(null); });
    }
    return svg;
  }
  function chartTip(ev, row) {
    const t = OB.$('#tip');
    if (!row) { t.hidden = true; return; }
    t.innerHTML = '<div class="tt-h">Day ' + row.day + '</div>' + SERIES.map(s => '<div class="tt-r"><span><i class="sw" style="background:' + s[2] + '"></i>' + s[1] + '</span><span>' + s[3](row[s[0]]) + '</span></div>').join('');
    t.hidden = false;
    t.style.transform = 'translate(' + Math.min(ev.clientX + 16, innerWidth - t.offsetWidth - 8) + 'px,' + (ev.clientY + 16) + 'px)';
  }

  function renderSummary(d) {
    if (!sbody) return;
    summary = d;
    OB.clear(sbody);
    const st = d.stats || {};
    const lost = d.dead || [];
    const hero = h('div.shero', h('div.lbl', d.over ? 'The colony has fallen' : 'Colony report'), h('div.disp.sbig', d.survived_days + (d.survived_days === 1 ? ' day' : ' days')),
      h('div.muted', d.over ? 'survived. The last colonist is gone on day ' + d.day + '.' : 'survived so far, ' + d.alive + ' colonists alive.'));
    const stat = (l, v, icon) => h('div.sstat', OB.icon(icon), h('div', h('div.disp.num', F.n(v)), h('div.lbl', l)));
    const grid = h('div.sgrid',
      stat('Dead put down', st.zombies_killed || 0, 'skull'), stat('Raiders killed', st.raiders_killed || 0, 'swords'), stat('Attacks repelled', st.attacks_repelled || 0, 'shield'),
      stat('Expeditions', st.expeditions_done || 0, 'truck'), stat('Survivors taken in', st.refugees || 0, 'person'), stat('Trades', st.trades || 0, 'trade'),
      stat('Mental breaks', st.mental_breaks || 0, 'alert'), stat('Infections cured', st.infections_cured || 0, 'cross'), stat('Wealth peak', d.wealth_peak || 0, 'star'));
    const charts = h('div.scharts');
    for (const s of SERIES) charts.append(h('div.schart', h('div.row.between', h('b', s[1]), h('span.sw', { style: { background: s[2] } })), lineChart(d.history, s[0], s[2], s[3], chartTip)));
    const lostEl = h('div.slost');
    for (const x of lost) lostEl.append(h('div.lrow', OB.icon(x.turns ? 'bio' : 'skull'), h('b.grow', OB.short(x.name)), h('span.muted.t-sm', 'day ' + x.day + ' · ' + (CAUSE[x.cause] || x.cause) + (x.turns ? ' · turned' : ''))));
    if (!lost.length) lostEl.append(h('div.muted.t-sm', 'Nobody has died. Yet.'));
    const table = h('table.stable', h('thead', h('tr', h('th', 'Day'), h('th', 'Colonists'), h('th', 'Mood'), h('th', 'Wealth'))), h('tbody', ...d.history.map(r => h('tr', h('td', r.day), h('td', r.colonists), h('td', Math.round(r.mood) + '%'), h('td', F.n(r.wealth))))));
    table.hidden = true;
    const tg = h('button.btn.sm.ghost', { on: { click: () => { table.hidden = !table.hidden; charts.hidden = !table.hidden; tg.lastChild.textContent = table.hidden ? 'Table view' : 'Chart view'; } } }, OB.icon('list'), h('span', 'Table view'));
    sbody.append(hero, grid, h('div.row.between', h('div.lbl', 'Colony over time'), tg), charts, table, h('div.lbl', { style: { marginTop: '1rem' } }, 'Colonists lost (' + lost.length + ')'), lostEl,
      h('div.meta.muted.t-xs', 'Profile ' + d.profile + ' · seed ' + d.seed + ' · ' + d.threat_events + ' threat events'));
  }
  OB.on('summary', renderSummary);

  OB.screens.reg('summary', {
    sticky: false,
    build() {
      sbody = h('div.sbody');
      sroot = h('div.panel.screen.summary', h('div.panel-h', OB.icon('skull'), h('h2', 'Colony summary'), h('div.grow'),
        h('button.btn.primary', { on: { click: () => { OB.ui('new_game', { seed: Math.floor(Math.random() * 90000) + 1, profile: summary ? summary.profile : 'escalating' }); OB.screens.close(); } } }, OB.icon('flag'), 'New colony'),
        h('button.btn.sq.ghost', { 'aria-label': 'Close', on: { click: () => OB.screens.close() } }, OB.icon('x'))), sbody);
      return sroot;
    },
    onOpen() { OB.ui('request_summary'); },
    update() {},
  });
})();
