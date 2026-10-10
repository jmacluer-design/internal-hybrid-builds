/* Director drawer (dock tab): live threat meter, storyteller budget + pacing profile, per-day event chart, event log, active threats, message log. */
(function () {
  'use strict';
  const OB = window.OB, h = OB.h, S = OB.S, F = OB.fmt;
  const director = (OB.director = {});
  const EV = {
    horde_wave: ['Horde wave', 'skull'], gang_raid: ['Gang raid', 'swords'], infection_outbreak: ['Infection outbreak', 'bio'], helicopter_flyover: ['Helicopter flyover', 'radio'],
    power_outage: ['Power outage', 'bolt'], water_outage: ['Water outage', 'drop'], storm: ['Storm', 'storm'], caravan: ['Trade caravan', 'trade'], supply_drop: ['Supply drop', 'crate'], refugee_arrival: ['Refugee arrival', 'person'],
  };
  OB.eventInfo = id => EV[id] || [F.cap(F.snake(id)), 'alert'];
  const CAT_COL = { threat: 'var(--bad)', hazard: 'var(--warn)', boon: 'var(--good)' };
  let root, el = {}, tab = 'log', sig = '';

  function update(st) {
    const d = st.director, t = st.threat;
    // threat meter
    const on = Math.round(t.level * 10);
    Array.from(el.seg.children).forEach((s, i) => OB.toggle(s, 'on', i < on));
    el.meter.dataset.level = t.label.toLowerCase();
    OB.setText(el.lvl, t.label);
    OB.setText(el.near, t.nearest ? (t.nearest.kind === 'raid' ? t.nearest.name + ' (' + t.nearest.size + ' raiders)' : 'Horde of ' + t.nearest.size) + ' — ' + F.dist(t.nearest.dist) + ' ' + F.dir(t.nearest.bearing) : 'No threat within the alert radius.');
    // budget
    const pct = d.cap > 0 ? d.budget / d.cap * 100 : 0;
    el.budget.set(pct, pct > 75 ? 'var(--bad)' : pct > 45 ? 'var(--warn)' : 'var(--info)');
    OB.setText(el.bnum, d.budget.toFixed(1) + ' / ' + d.cap.toFixed(0));
    OB.setText(el.rate, '+' + d.rate_day.toFixed(0) + ' pts / day');
    OB.setText(el.next, d.grace_left > 0 ? 'Grace period: ' + F.dur(d.grace_left) : 'Next threat check in ~' + F.dur(d.next_threat_in));
    el.profile.set(d.profile);
    // chart: last 12 days of events from the log
    const days = [];
    const last = st.day;
    for (let i = Math.max(1, last - 11); i <= last; i++) days.push(i);
    const byDay = {};
    for (const e of d.log) { const b = byDay[e.day] || (byDay[e.day] = { threat: 0, hazard: 0, boon: 0 }); b[e.cat]++; }
    const csig = days.map(x => x + ':' + (byDay[x] ? byDay[x].threat + '.' + byDay[x].hazard + '.' + byDay[x].boon : '0')).join(',');
    if (el.chart._s !== csig) {
      el.chart._s = csig; OB.clear(el.chart);
      const max = Math.max(3, ...days.map(x => (byDay[x] ? byDay[x].threat + byDay[x].hazard + byDay[x].boon : 0)));
      for (const x of days) {
        const b = byDay[x] || { threat: 0, hazard: 0, boon: 0 };
        const col = h('div.dcol', { title: 'Day ' + x + ': ' + b.threat + ' threats, ' + b.hazard + ' hazards, ' + b.boon + ' boons' },
          h('div.dbars', h('i.ev-t', { style: { height: b.threat / max * 100 + '%' } }), h('i.ev-h', { style: { height: b.hazard / max * 100 + '%' } }), h('i.ev-b', { style: { height: b.boon / max * 100 + '%' } })), h('span' + (x === last ? '.now' : ''), String(x)));
        el.chart.append(col);
      }
    }
    // active threats
    const threats = st.hordes.filter(q => q.size >= 3).map(q => ({ kind: 'horde', id: q.id, x: q.x, y: q.y, size: q.size, state: q.state, mat: q.mat })).concat(st.raids.map(q => ({ kind: 'raid', id: q.id, x: q.x, y: q.y, size: q.count, state: q.state, name: q.name })));
    const base = st.base;
    threats.forEach(q => (q.dist = Math.hypot(q.x - base.x, q.y - base.y)));
    threats.sort((a, b) => a.dist - b.dist);
    OB.reconcile(el.threats, threats.slice(0, 6), q => q.id, q => {
      const row = h('div.trow', { on: { click: () => { const v = OB.mapBg; if (v) v.center(+row.dataset.x, +row.dataset.y); OB.post('focus', { x: +row.dataset.x, y: +row.dataset.y }); } } }, h('span.tic', OB.icon('skull')), h('div.grow', h('b', ''), h('div.muted.t-xs', '')), h('b.num', ''));
      row.t = row.querySelector('b'); row.s = row.querySelector('.muted'); row.d = row.lastChild; return row;
    }, (row, q) => {
      row.dataset.x = q.x; row.dataset.y = q.y;
      row.firstChild.replaceChildren(OB.icon(q.kind === 'raid' ? 'swords' : 'skull'));
      OB.setText(row.t, q.kind === 'raid' ? q.name : 'Horde of ' + q.size);
      OB.setText(row.s, (q.state === 'assault' ? 'attacking the base' : q.state) + (q.mat ? ' · ' + q.mat + ' live' : '') + (q.kind === 'raid' ? ' · ' + q.size + ' raiders' : ''));
      OB.setText(row.d, F.dist(q.dist));
      row.d.style.color = q.dist < 120 ? 'var(--bad)' : q.dist < 400 ? 'var(--warn)' : '';
    });
    OB.show(el.noThreat, threats.length === 0);

    // logs
    OB.show(el.logBox, tab === 'log'); OB.show(el.noteBox, tab === 'notes');
    if (tab === 'log') {
      const lsig = d.log.length + ':' + (d.log[0] ? d.log[0].t : 0);
      if (sig !== lsig) {
        sig = lsig; OB.clear(el.logBox);
        for (const e of d.log) {
          const [name, icon] = OB.eventInfo(e.event);
          el.logBox.append(h('div.lg.' + e.cat, { style: { '--c': CAT_COL[e.cat] } }, h('div.lgi', OB.icon(icon)), h('div.grow', h('div.lgt', h('b', name), e.cost > 0 ? h('span.chip', { style: { '--c': 'var(--bad)' } }, '−' + e.cost.toFixed(1)) : h('span.chip', { style: { '--c': 'var(--good)' } }, 'free')), h('div.muted.t-sm', e.detail), h('div.muted.t-xs', 'Day ' + e.day + ' · ' + String(Math.floor((e.t % 1440) / 60)).padStart(2, '0') + ':' + String(e.t % 60).padStart(2, '0') + ' · budget ' + e.before.toFixed(0) + ' → ' + e.after.toFixed(0)))));
        }
        if (!d.log.length) el.logBox.append(h('div.muted.t-sm', 'The Director has not sent anything yet. Day 1 is a grace day.'));
      }
    } else renderNotes();
  }

  function renderNotes() {
    const n = S.notes;
    const nsig = n.length + ':' + (n.length ? n[n.length - 1].text : '');
    if (el.noteBox._s === nsig) return;
    el.noteBox._s = nsig; OB.clear(el.noteBox);
    const ICON = { info: 'info', good: 'check', warn: 'alert', bad: 'skull' };
    for (let i = n.length - 1; i >= Math.max(0, n.length - 60); i--) {
      const x = n[i];
      el.noteBox.append(h('div.nt.' + x.level, h('span.nti', OB.icon(ICON[x.level] || 'info')), h('div.grow', h('div', x.text), h('div.muted.t-xs', 'Day ' + x.day + (x.clock ? ' · ' + x.clock : '')))));
    }
    if (!n.length) el.noteBox.append(h('div.muted.t-sm', 'No messages yet.'));
  }

  director.panel = function () {
    root = h('div.director-panel');
    el.seg = h('div.segbar', ...Array.from({ length: 10 }, () => h('i')));
    el.lvl = h('b.disp', 'Quiet'); el.near = h('div.muted.t-sm', '');
    el.meter = h('div.dmeter', h('div.row.between', h('span.lbl', 'Threat meter'), el.lvl), el.seg, el.near);
    el.budget = OB.bar('thick'); el.bnum = h('b.num', ''); el.rate = h('span.muted.t-sm', ''); el.next = h('div.muted.t-sm', '');
    el.profile = OB.seg(['calm', 'escalating', 'chaos'].map(p => ({ value: p, label: F.cap(p), tip: { calm: 'Long quiet stretches, boons weighted up', escalating: 'Gentle start, steady ramp', chaos: 'Short gaps, spikes, little rest' }[p] })), 'escalating', p => OB.order('colony', 'set_profile', p));
    el.chart = h('div.dchart');
    el.threats = h('div.tlist'); el.noThreat = h('div.muted.t-sm', 'No hostile groups tracked right now.');
    el.logBox = h('div.logbox'); el.noteBox = h('div.logbox'); el.noteBox.hidden = true;
    const tabs = OB.seg([{ value: 'log', label: 'Director log' }, { value: 'notes', label: 'Messages' }], 'log', v => { tab = v; sig = ''; el.noteBox._s = ''; if (S.state) update(S.state); }, 'ctabs');
    root.append(el.meter,
      h('section.csec', h('div.row.between', h('span.lbl', 'Storyteller budget'), el.bnum), el.budget, h('div.row.between', el.rate, el.next), el.profile),
      h('section.csec', h('div.lbl', 'Events per day'), el.chart, h('div.legend', h('span', h('i.ev-t'), 'threat'), h('span', h('i.ev-h'), 'hazard'), h('span', h('i.ev-b'), 'boon'))),
      h('section.csec', h('div.lbl', 'Tracked threats'), el.threats, el.noThreat),
      tabs, el.logBox, el.noteBox);
    OB.on('notes', () => { if (S.state && tab === 'notes') update(S.state); });
    return { el: root, update, onShow() { sig = ''; el.noteBox._s = ''; } };
  };
})();
