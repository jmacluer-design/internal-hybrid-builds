/* Inventory screen: player grid + one other container (stockpile zone, ground pile, colonist, world container). Drag and drop (pointer events),
   shift/ctrl quick-move, context menu, search + category filter, weight/slot meters.
   borrowed: overextended/ox_inventory/web/src/components/inventory/{InventoryGrid,InventorySlot,InventoryControl,SlotTooltip}.tsx (GPL-3.0, private use; see THIRD_PARTY.md):
   layout and interaction patterns (no code copied verbatim): 5-6 column square-slot grid,
   header weight meter, count top-right / label box at the bottom of the slot, dashed drop target, drag preview following the cursor,
   tooltip after a short hover delay, context menu (use / drop / give amount), ctrl-click = move one, alt/dblclick = use. Re-implemented in
   vanilla JS against our own message contract. Hotbar, shops and crafting of ox_inventory are not used. */
(function () {
  'use strict';
  const OB = window.OB, h = OB.h, S = OB.S, F = OB.fmt;
  let root, grids = {}, srcList, search = '', catFilter = null, amount = 'stack', other = null, hdr = {};
  let drag = null;

  function usable(id) { const d = OB.item(id); return !!(d.food || (d.med && d.med.kind !== 'surgery')); }

  function slotEl(side, stack, idx) {
    const d = stack ? OB.item(stack.id) : null;
    const col = d ? OB.catColor[d.cat] || '#9aa7bd' : '';
    const s = h('div.slot' + (stack ? '.full' : ''), { dataset: { side, idx }, style: stack ? { '--c': col, '--hue': OB.hue(stack.id) } : {}, tabindex: stack ? 0 : -1, role: 'button',
      'aria-label': stack ? d.name + ' x' + stack.n : 'empty slot' });
    if (!stack) return s;
    s.append(h('div.sw.num', F.kg(stack.w)), h('div.sc.num', stack.n > 1 ? stack.n + '×' : ''), h('div.si', OB.icon(OB.itemIcon(stack.id))), h('div.sl', h('span.ell', d.name)));
    if (d.weapon && d.weapon.kind === 'ranged') s.append(h('i.sdot', { title: 'uses ' + OB.item(d.weapon.ammo).name }));
    OB.tip(s, () => OB.itemTip(stack.id, stack.n), 450);
    s.addEventListener('pointerdown', e => startDrag(e, side, idx, stack, s));
    s.addEventListener('contextmenu', e => { e.preventDefault(); slotMenu(e, side, stack); });
    s.addEventListener('dblclick', () => { if (side === 'player' && usable(stack.id)) OB.ui('use_item', { item: stack.id }); else quickMove(side, stack, stack.n); });
    s.addEventListener('keydown', e => {
      if (e.key === 'Enter') { e.preventDefault(); if (side === 'player' && usable(stack.id)) OB.ui('use_item', { item: stack.id }); else quickMove(side, stack, stack.n); }
      else if (e.key === 'ArrowRight' || e.key === 'ArrowLeft' || e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        const cells = Array.from(s.parentElement.children), i = cells.indexOf(s), cols = 6;
        const t = cells[i + ({ ArrowRight: 1, ArrowLeft: -1, ArrowDown: cols, ArrowUp: -cols }[e.key])];
        if (t) t.focus();
      }
    });
    return s;
  }

  function loc(side) { return side === 'player' ? { kind: 'player' } : { kind: other.kind, id: other.id }; }
  function moveCount(stack, mode) { return mode === 'one' ? 1 : mode === 'half' ? Math.max(1, Math.floor(stack.n / 2)) : mode === 'stack' ? stack.n : Math.min(stack.n, +amount || stack.n); }
  function quickMove(side, stack, n) {
    if (!other) { if (side === 'player') OB.toast('info', 'Pick a container on the right first.'); return; }
    OB.ui('inventory_move', { from: loc(side), to: loc(side === 'player' ? 'other' : 'player'), item: stack.id, n });
  }
  function slotMenu(e, side, stack) {
    const d = OB.item(stack.id), items = [];
    if (side === 'player' && usable(stack.id)) items.push({ icon: d.food ? 'food' : 'cross', label: 'Use', key: 'Enter', run: () => OB.ui('use_item', { item: stack.id }) });
    items.push({ icon: 'chev', label: 'Move ' + (side === 'player' ? 'to ' + (other ? other.label : 'container') : 'to you') + ' (' + stack.n + ')', run: () => quickMove(side, stack, stack.n) });
    if (stack.n > 1) { items.push({ icon: 'chev', label: 'Move half (' + Math.floor(stack.n / 2) + ')', run: () => quickMove(side, stack, Math.floor(stack.n / 2)) }); items.push({ icon: 'chev', label: 'Move one', run: () => quickMove(side, stack, 1) }); }
    if (side === 'player') items.push('-', { icon: 'down', label: 'Drop on the ground', run: () => OB.ui('drop_item', { item: stack.id, n: stack.n }) });
    OB.ctx(e.clientX, e.clientY, items);
  }

  // ----------------------------------------------------------------------------------------------------------- drag and drop
  function startDrag(e, side, idx, stack, node) {
    if (e.button !== 0) return;
    const sx = e.clientX, sy = e.clientY, ctrl = e.ctrlKey, shift = e.shiftKey;
    let started = false;
    const gh = OB.$('#dragghost');
    const onMove = ev => {
      if (!started) {
        if (Math.hypot(ev.clientX - sx, ev.clientY - sy) < 6) return;
        started = true;
        drag = { side, stack, node };
        node.classList.add('dragging');
        OB.clear(gh); gh.append(OB.icon(OB.itemIcon(stack.id)), h('b', stack.n > 1 ? stack.n + '×' : '')); gh.style.setProperty('--c', OB.catColor[OB.item(stack.id).cat] || '#fff');
        gh.hidden = false; document.body.classList.add('dragging'); OB.hideTip();
      }
      gh.style.transform = 'translate(' + (ev.clientX + 8) + 'px,' + (ev.clientY + 8) + 'px)';
      const over = document.elementFromPoint(ev.clientX, ev.clientY);
      const zone = over && over.closest && over.closest('.igrid');
      for (const k of Object.keys(grids)) grids[k].classList.toggle('drop', !!zone && zone === grids[k] && grids[k].dataset.side !== side);
    };
    const onUp = ev => {
      document.removeEventListener('pointermove', onMove); document.removeEventListener('pointerup', onUp);
      if (!started) { if (ctrl) quickMove(side, stack, 1); else if (shift) quickMove(side, stack, stack.n); return; }
      gh.hidden = true; document.body.classList.remove('dragging'); node.classList.remove('dragging');
      for (const k of Object.keys(grids)) grids[k].classList.remove('drop');
      const over = document.elementFromPoint(ev.clientX, ev.clientY);
      const zone = over && over.closest && over.closest('.igrid');
      drag = null;
      if (!zone || zone.dataset.side === side) return;
      const n = ev.shiftKey ? Math.max(1, Math.floor(stack.n / 2)) : ev.ctrlKey ? 1 : moveCount(stack, amount === 'stack' ? 'stack' : 'amt');
      if (!other && side === 'player') { OB.toast('info', 'Pick a container on the right first.'); return; }
      OB.ui('inventory_move', { from: loc(side), to: loc(side === 'player' ? 'other' : 'player'), item: stack.id, n });
    };
    document.addEventListener('pointermove', onMove); document.addEventListener('pointerup', onUp);
  }

  // --------------------------------------------------------------------------------------------------------------- rendering
  function match(stack) {
    const d = OB.item(stack.id);
    if (catFilter && d.cat !== catFilter) return false;
    if (search && d.name.toLowerCase().indexOf(search) < 0) return false;
    return true;
  }
  function fillGrid(grid, side, c) {
    OB.clear(grid);
    const stacks = c ? c.stacks.filter(match) : [];
    const cap = Math.max(30, Math.ceil(stacks.length / 6) * 6, side === 'player' && c && c.slots ? Math.ceil(c.slots / 6) * 6 : 0);
    for (let i = 0; i < cap; i++) grid.append(slotEl(side, stacks[i], i));
  }
  function meter(box, c, label) {
    const w = c ? c.w : 0, cap = c && c.cap ? c.cap : 0;
    box.bar.set(cap ? w / cap * 100 : 0, cap && w / cap > 0.9 ? 'var(--bad)' : cap && w / cap > 0.7 ? 'var(--warn)' : 'var(--weight)');
    OB.setText(box.txt, F.kg(w) + (cap ? ' / ' + F.kg(cap) : '') + (c && c.slots ? ' · ' + c.used + '/' + c.slots + ' slots' : c ? ' · ' + c.used + ' stacks' : ''));
    if (label != null) OB.setText(box.title, label);
  }

  function render(d) {
    if (!root || !d) return;
    S.inv = d;
    other = d.other || null;
    fillGrid(grids.player, 'player', d.player);
    fillGrid(grids.other, 'other', d.other);
    meter(hdr.player, d.player, 'You');
    meter(hdr.other, d.other, d.other ? d.other.label : 'No container selected');
    OB.show(OB.$('.iempty', root), !d.other);
    // source chips
    OB.reconcile(srcList, d.nearby.slice(0, 40), s => s.kind + s.id, s => {
      const b = h('button.src', { on: { click: () => OB.ui('inventory', { other: { kind: s.kind, id: s.id } }) } }, OB.icon(s.kind === 'zone' ? 'zone' : s.kind === 'colonist' ? 'person' : s.kind === 'pile' ? 'crate' : 'cross2'), h('span.ell', ''));
      b.lab = b.lastChild; return b;
    }, (b, s) => { OB.setText(b.lab, s.label); OB.toggle(b, 'on', !!d.other && d.other.kind === s.kind && d.other.id === s.id); b.title = s.kind + (s.dist ? ' · ' + F.dist(s.dist) : ''); });
  }

  function build() {
    grids.player = h('div.igrid', { dataset: { side: 'player' } });
    grids.other = h('div.igrid', { dataset: { side: 'other' } });
    for (const k of ['player', 'other']) hdr[k] = { bar: OB.bar('thick'), txt: h('span.num.muted.t-sm', ''), title: h('h3.disp', '') };
    srcList = h('div.srclist');
    const searchEl = h('input', { type: 'text', placeholder: 'Search items', 'aria-label': 'Search items', on: { input: e => { search = e.target.value.trim().toLowerCase(); if (S.inv) render(S.inv); } } });
    const cats = h('div.catchips');
    for (const c of (S.catalog ? S.catalog.item_cats : ['food', 'drink', 'medical', 'weapon', 'ammo', 'material', 'fuel', 'tool'])) {
      cats.append(h('button.chip.tab', { style: { '--c': OB.catColor[c] }, dataset: { cat: c }, 'aria-pressed': 'false', on: { click: e => { catFilter = catFilter === c ? null : c; OB.$$('.tab', cats).forEach(x => { const on = x.dataset.cat === catFilter; x.classList.toggle('on', on); x.setAttribute('aria-pressed', on ? 'true' : 'false'); }); if (S.inv) render(S.inv); } } }, OB.icon(OB.catIcon(c)), F.cap(c)));
    }
    const amt = OB.seg([{ value: 'stack', label: 'Stack' }, { value: '1', label: '1' }, { value: '5', label: '5' }, { value: '10', label: '10' }], 'stack', v => (amount = v));
    const left = h('section.icol', h('div.ih', hdr.player.title, h('span.grow'), hdr.player.txt), hdr.player.bar, grids.player);
    const right = h('section.icol', h('div.ih', hdr.other.title, h('span.grow'), hdr.other.txt), hdr.other.bar, srcList, h('div.gridwrap', grids.other, h('div.iempty', OB.icon('crate'), h('b', 'Pick a container'), h('span.muted', 'Stockpile zones, ground piles and colonists within reach are listed above.'))));
    const mid = h('div.imid', h('div.lbl', 'Move'), amt, h('div.hintlist', h('span', OB.key('Drag'), 'move a stack'), h('span', OB.key('Shift'), 'half / quick'), h('span', OB.key('Ctrl'), 'one'), h('span', OB.key('Dbl-click'), 'use')));
    root = h('div.panel.screen.inventory', h('div.panel-h', OB.icon('crate'), h('h2', 'Inventory'), h('div.grow'), searchEl, h('button.btn.sq.ghost', { 'aria-label': 'Close', on: { click: () => OB.screens.close() } }, OB.icon('x'))),
      h('div.itoolbar', cats), h('div.ibody', left, mid, right));
    OB.on('inventory', render);
    return root;
  }

  OB.screens.reg('inventory', {
    build,
    onOpen(arg) { OB.ui('inventory', { other: arg && arg.other ? arg.other : (S.inv && S.inv.other ? { kind: S.inv.other.kind, id: S.inv.other.id } : null) }); },
    onClose() { drag = null; const gh = OB.$('#dragghost'); if (gh) gh.hidden = true; document.body.classList.remove('dragging'); },
    update() { /* inventory data arrives through the `inventory` message, not the colony state */ },
  });
})();
