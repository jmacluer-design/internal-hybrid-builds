/* Expeditions (dock tab): plan scavenging trips by vehicle or on foot, watch forming / active trips. Sends `order expedition` / `cancel_expedition`. */
(function () {
  'use strict';
  const OB = window.OB, h = OB.h, S = OB.S, F = OB.fmt;
  const exped = (OB.exped = { pick: null, size: 2, mode: 'vehicle' });
  let root, dlist, active, info, goBtn, modeSeg, sizeSeg;
  const STATE_LABEL = { forming: 'Forming', outbound: 'Outbound', looting: 'Searching', returning: 'Returning' };

  function update(st) {
    const cat = S.catalog; if (!cat) return;
    if (!dlist.children.length) {
      for (const d of cat.districts.slice().sort((a, b) => a.danger - b.danger || a.travel - b.travel)) {
        const pips = h('span.dpips', ...Array.from({ length: 5 }, (_, i) => h('i' + (i < d.danger ? '.on' : ''))));
        const card = h('button.dcard', { dataset: { id: d.id }, on: { click: () => { exped.pick = d.id; OB.$$('.dcard', dlist).forEach(c => c.classList.toggle('on', c.dataset.id === d.id)); sync(); } } },
          h('div.dh', h('b', d.name), pips), h('div.muted.t-xs', F.cap(d.kind) + ' · ' + d.travel + ' min by van · ~' + d.zombies + ' walkers'));
        card.style.setProperty('--dc', ['#35d39a', '#8bd04f', '#f6d04d', '#ff9a3d', '#ff5d6c'][d.danger - 1]);
        OB.tip(card, '<div class="tt-h">' + d.name + '</div><div class="tt-r"><span>Danger</span><span>' + d.danger + ' / 5</span></div><div class="tt-r"><span>Loot table</span><span>' + F.cap(d.kind) + '</span></div><div class="muted" style="margin-top:.3rem">Higher danger: better loot, more ambushes. Night makes it worse.</div>');
        dlist.append(card);
      }
    }
    const r = st.res;
    const homeVans = st.vehicles.filter(v => v.state === 'home').length;
    OB.setText(info, 'Fuel cans: ' + r.fuel + ' · Vehicles at home: ' + homeVans + '/' + st.vehicles.length + ' · Free colonists: ' + st.colonists.filter(c => c.state !== 'away' && !c.downed).length);
    sync();
    OB.reconcile(active, st.expeditions, x => x.id, x => {
      const crew = h('div.crew'), st2 = h('span.chip', ''), cancel = h('button.btn.sm.ghost', { on: { click: () => OB.order('colony', 'cancel_expedition', { id: x.id }) } }, 'Cancel');
      const row = h('div.xrow', { dataset: { id: x.id } }, h('div.xh', OB.icon('truck'), h('b.grow', ''), st2), crew, h('div.muted.t-xs.xm', ''), cancel);
      row.ttl = row.querySelector('b'); row.state = st2; row.crew = crew; row.meta = row.querySelector('.xm'); row.cancel = cancel;
      return row;
    }, (row, x) => {
      const d = cat.districts.find(q => q.id === x.district);
      OB.setText(row.ttl, d ? d.name : x.district);
      OB.setText(row.state, STATE_LABEL[x.state] || x.state);
      row.state.style.setProperty('--c', x.state === 'forming' ? 'var(--amber)' : x.state === 'returning' ? 'var(--good)' : 'var(--blue)');
      const sig = x.crew.join(',');
      if (row.crew._s !== sig) { row.crew._s = sig; OB.clear(row.crew); for (const id of x.crew) { const c = OB.col(id); row.crew.append(h('span.av.sm', { style: { '--c': 'var(--blue)', '--h': OB.hue(c ? c.name : id) }, title: c ? c.name : id }, h('span', c ? OB.initials(c.name) : id))); } if (!x.crew.length) row.crew.append(h('span.muted.t-xs', 'no volunteers yet')); }
      OB.setText(row.meta, (x.mode === 'foot' ? 'On foot' : 'By vehicle') + ' · ' + x.crew.length + '/' + x.want + ' crew' + (x.deadline != null ? ' · leaves in ' + F.dur(x.deadline) : ''));
      OB.show(row.cancel, x.state === 'forming');
    });
    OB.show(active.empty, st.expeditions.length === 0);
  }
  function sync() {
    const d = exped.pick && S.catalog ? S.catalog.districts.find(q => q.id === exped.pick) : null;
    goBtn.disabled = !d;
    OB.setText(goBtn.lastChild, d ? 'Send to ' + d.name : 'Pick a district');
  }

  exped.panel = function () {
    root = h('div.exped-panel');
    dlist = h('div.dgrid');
    info = h('div.muted.t-sm', '');
    sizeSeg = OB.seg([1, 2, 3, 4].map(v => ({ value: v, label: String(v) })), exped.size, v => (exped.size = v));
    modeSeg = OB.seg([{ value: 'vehicle', icon: 'truck', label: 'Vehicle' }, { value: 'foot', icon: 'run', label: 'On foot' }], exped.mode, v => (exped.mode = v));
    goBtn = h('button.btn.primary', { on: { click: () => { if (exped.pick) OB.order('colony', 'expedition', { district: exped.pick, size: exped.size, mode: exped.mode }); } } }, OB.icon('flag'), h('span', 'Pick a district'));
    active = h('div.xlist'); active.empty = h('div.muted.t-sm', 'No expeditions out. Colonists with a Scavenge priority volunteer for forming trips.');
    root.append(h('div.lbl', 'Plan a trip'), info, dlist, h('div.row', h('span.muted.t-sm', 'Crew'), sizeSeg, h('span.muted.t-sm', 'Travel'), modeSeg), goBtn, h('div.sep'), h('div.lbl', 'Active trips'), active, active.empty);
    return { el: root, update, onShow() {} };
  };
})();
