/* Work priorities grid: colonists x work types. Click cycles 0-4 (1 = highest, 0 = never), right-click goes back, digits set directly,
   arrow keys move. Every change is an `order priority {work, level}`; the cell updates optimistically and is reconciled by the next state. */
(function () {
  'use strict';
  const OB = window.OB, h = OB.h, S = OB.S, F = OB.fmt;
  const WORK = ['doctor', 'guard', 'build', 'cook', 'craft', 'haul', 'scavenge'];
  const SKILL = { doctor: 'medicine', guard: 'shooting', build: 'construction', cook: 'cooking', craft: 'construction', haul: null, scavenge: 'scavenging' };
  const NAME = { doctor: 'Doctor', guard: 'Guard', build: 'Build', cook: 'Cook', craft: 'Craft', haul: 'Haul', scavenge: 'Scavenge' };
  const HELP = { doctor: 'Treats wounds and infections', guard: 'Mans watchtowers and defends the base', build: 'Builds blueprints, repairs walls', cook: 'Cooks meals at stoves and fires', craft: 'Works at workbenches', haul: 'Carries items to stockpiles and building sites', scavenge: 'Volunteers for expeditions' };
  let root, table, body, head, foot, focusKey = '';

  function setLevel(id, work, level, cell) {
    const c = OB.col(id); if (!c || c.blocked[work]) return;
    level = ((level % 5) + 5) % 5;
    c.prio[work] = level;
    if (cell) paint(cell, c, work);
    OB.order(id, 'priority', { work, level });
  }
  function paint(cell, c, work) {
    const lv = c.prio[work], blocked = !!c.blocked[work];
    const sk = SKILL[work] ? c.skill[SKILL[work]] : null;
    OB.setAttr(cell, 'data-lv', blocked ? 'x' : lv);
    OB.setText(cell.lv, blocked ? '' : lv ? lv : '·');
    OB.show(cell.lock, blocked);
    OB.setText(cell.sk, sk != null ? 'L' + sk : '');
    OB.setAttr(cell, 'aria-label', c.name + ', ' + NAME[work] + ', ' + (blocked ? 'blocked' : lv ? 'priority ' + lv : 'never'));
    cell.disabled = blocked;
  }

  function makeRow(c) {
    const cells = {};
    const rowEl = h('div.prow', { role: 'row', dataset: { id: c.id } });
    const who = h('button.pwho', { on: { click: () => OB.select([c.id]) } }, h('span.av.sm', h('span', '')), h('span.pn.ell', ''), h('span.pm.num', ''));
    rowEl.append(who);
    WORK.forEach((w, wi) => {
      const lv = h('b', ''), sk = h('i.psk', ''), lock = OB.icon('lock'); lock.hidden = true;
      const cell = h('button.pcell', { role: 'gridcell', tabindex: -1, dataset: { work: w, id: c.id, col: wi }, on: {
        click: () => { const cc = OB.col(c.id); if (cc) setLevel(c.id, w, cc.prio[w] + 1, cell); },
        contextmenu: e => { e.preventDefault(); const cc = OB.col(c.id); if (cc) setLevel(c.id, w, cc.prio[w] - 1, cell); },
        focus: () => { focusKey = c.id + '|' + w; },
        keydown: e => {
          const cc = OB.col(c.id); if (!cc) return;
          if (/^[0-4]$/.test(e.key)) { e.preventDefault(); setLevel(c.id, w, +e.key, cell); }
          else if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); setLevel(c.id, w, cc.prio[w] + 1, cell); }
          else if (e.key === 'Delete' || e.key === 'Backspace') { e.preventDefault(); setLevel(c.id, w, 0, cell); }
          else if (e.key.startsWith('Arrow')) { e.preventDefault(); move(rowEl, wi, e.key); }
        },
      } }, lv, sk, lock);
      cell.lv = lv; cell.sk = sk; cell.lock = lock; cells[w] = cell; rowEl.append(cell);
    });
    rowEl.cells = cells; rowEl.who = who;
    return rowEl;
  }
  function move(rowEl, wi, key) {
    let r = rowEl, i = wi;
    if (key === 'ArrowLeft') i = Math.max(0, i - 1);
    else if (key === 'ArrowRight') i = Math.min(WORK.length - 1, i + 1);
    else if (key === 'ArrowUp') r = rowEl.previousElementSibling || rowEl;
    else if (key === 'ArrowDown') r = rowEl.nextElementSibling || rowEl;
    const cell = r.cells && r.cells[WORK[i]];
    if (cell && !cell.disabled) cell.focus();
    else if (cell) { const alt = Object.values(r.cells).find(x => !x.disabled); if (alt) alt.focus(); }
  }
  function updateRow(r, c) {
    OB.setText(r.who.querySelector('.pn'), OB.short(c.name));
    OB.setText(r.who.querySelector('.av span'), OB.initials(c.name));
    r.who.querySelector('.av').style.setProperty('--h', OB.hue(c.name));
    OB.setText(r.who.querySelector('.pm'), Math.round(c.mood) + '%');
    r.who.querySelector('.pm').style.color = OB.moodColor(c.mood);
    OB.toggle(r, 'sel', S.sel.indexOf(c.id) >= 0);
    for (const w of WORK) paint(r.cells[w], c, w);
  }

  function update(st) {
    if (!body) return;
    OB.reconcile(body, st.colonists, c => c.id, makeRow, updateRow);
    OB.setText(foot, st.colonists.length + ' colonists · ' + st.colonists.filter(c => c.drafted).length + ' drafted');
  }

  function colMenu(e, w) {
    const set = lv => () => { for (const c of S.state.colonists) setLevel(c.id, w, lv, null); update(S.state); };
    OB.ctx(e.clientX, e.clientY, [
      { icon: OB.workIcon(w), label: NAME[w] + ': set everyone to', disabled: true },
      { icon: 'star', label: 'Priority 1 (highest)', run: set(1) }, { icon: 'star', label: 'Priority 2', run: set(2) }, { icon: 'star', label: 'Priority 3', run: set(3) }, { icon: 'star', label: 'Priority 4 (lowest)', run: set(4) },
      '-', { icon: 'x', label: 'Never (0)', run: set(0) },
    ]);
  }

  OB.screens.reg('priorities', {
    build() {
      head = h('div.phead', { role: 'row' }, h('div.pcorner', h('span.lbl', 'Colonist')));
      for (const w of WORK) {
        const b = h('button.pcol', { 'aria-label': NAME[w] + ' column', on: { click: e => colMenu(e, w) } }, OB.icon(OB.workIcon(w)), h('span', NAME[w]));
        OB.tip(b, '<div class="tt-h">' + NAME[w] + '</div>' + HELP[w] + '<div class="muted" style="margin-top:.3rem">Click for set-all options' + (SKILL[w] ? ' · uses ' + SKILL[w] : '') + '</div>');
        head.append(b);
      }
      body = h('div.pbody', { role: 'rowgroup' });
      foot = h('span.muted.t-sm', '');
      table = h('div.ptable', { role: 'grid', 'aria-label': 'Work priorities' }, head, body);
      const legend = h('div.plegend', ...[1, 2, 3, 4, 0].map(l => h('span', h('i.pcell.static', { 'data-lv': l }, l || '·'), l === 1 ? 'highest' : l === 4 ? 'lowest' : l === 0 ? 'never' : '')), h('span.muted.t-xs', 'Ties are broken by work order, then urgency, then distance.'));
      root = h('div.panel.screen.priorities', h('div.panel-h', OB.icon('bars'), h('h2', 'Work priorities'), h('div.grow'), foot, h('button.btn.sq.ghost', { 'aria-label': 'Close', on: { click: () => OB.screens.close() } }, OB.icon('x'))),
        h('div.panel-b', h('p.muted.t-sm.pintro', 'Click a cell to cycle ', h('b', '0 → 4'), ' (1 is done first, 0 means never). Right-click goes back. Focus a cell and press ', OB.key('0'), '–', OB.key('4'), ' to set it, arrow keys to move.'), table, legend));
      return root;
    },
    onOpen() { if (S.state) update(S.state); setTimeout(() => { const first = body && body.querySelector('.pcell:not([disabled])'); if (first) first.focus({ preventScroll: true }); }, 30); },
    update,
  });
})();
