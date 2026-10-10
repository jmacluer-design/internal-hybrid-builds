/* Full-screen tactical map screen (M): the same MapView as the colony backdrop, with a toolbar (layers, zoom) and a district list. */
(function () {
  'use strict';
  const OB = window.OB, h = OB.h, S = OB.S, F = OB.fmt;
  let root, host, view, dl;
  const LAYERS = [['grid', 'Grid'], ['districts', 'Districts'], ['zones', 'Zones'], ['cells', 'Horde cells'], ['labels', 'Labels']];
  const DCOL = ['#35d39a', '#8bd04f', '#f6d04d', '#ff9a3d', '#ff5d6c'];

  function fillDistricts() {
    if (!S.catalog || !dl || dl.children.length) return;
    for (const d of S.catalog.districts.slice().sort((a, b) => a.danger - b.danger)) {
      dl.append(h('button.drow', { on: { click: () => { view.center(d.x, d.y, Math.min(view.W, view.H) / (d.radius * 2.6)); } } },
        h('i.dd', { style: { background: DCOL[d.danger - 1] } }), h('div.grow', h('b', d.name), h('div.muted.t-xs', F.cap(d.kind) + ' · danger ' + d.danger + ' · ' + d.travel + ' min')),
        h('span.muted.t-xs', F.dist(Math.hypot(d.x, d.y)))));
    }
  }
  OB.screens.reg('map', {
    sticky: true,
    build() {
      host = h('div.mapfull');
      const layers = h('div.layers');
      for (const [k, label] of LAYERS) layers.append(h('button.chip.tab.on', { style: { '--c': '#66adff' }, 'aria-pressed': 'true', on: { click: e => { view.layers[k] = !view.layers[k]; e.currentTarget.classList.toggle('on', view.layers[k]); e.currentTarget.setAttribute('aria-pressed', view.layers[k] ? 'true' : 'false'); view.dirty = true; } } }, label));
      layers.querySelector('[style*="--c"]');
      const cells = layers.children[3]; cells.classList.remove('on'); cells.setAttribute('aria-pressed', 'false');
      const zoom = h('div.row', h('button.btn.sq.sm', { 'aria-label': 'Zoom in', on: { click: () => view.zoomAt(view.W / 2, view.H / 2, 1.4) } }, OB.icon('plus')), h('button.btn.sq.sm', { 'aria-label': 'Zoom out', on: { click: () => view.zoomAt(view.W / 2, view.H / 2, 1 / 1.4) } }, OB.icon('minus')),
        h('button.btn.sm', { on: { click: () => view.fit(false) } }, OB.icon('home'), 'Base'), h('button.btn.sm', { on: { click: () => view.fit(true) } }, OB.icon('map'), 'Region'));
      dl = h('div.dlist2');
      root = h('div.screen.mapscreen', host,
        h('div.mtool.panel', OB.icon('map'), h('h2.disp', 'Tactical map'), layers, h('div.grow'), zoom, h('button.btn.sq.ghost', { 'aria-label': 'Close map', on: { click: () => OB.screens.close() } }, OB.icon('x'))),
        h('div.mside.panel', h('div.lbl', 'Districts'), dl),
        h('div.mlegend.panel', h('span', h('i.lg.c1'), 'Colonist'), h('span', h('i.lg.c2'), 'Horde'), h('span', h('i.lg.c3'), 'Raiders'), h('span', h('i.lg.c4'), 'Caravan'), h('span', h('i.lg.c5'), 'Expedition'), h('span', OB.key('Wheel'), 'zoom'), h('span', OB.key('Middle drag'), 'pan'), h('span', OB.key('Right click'), 'orders')));
      return root;
    },
    onOpen() {
      if (!view) { view = OB.bigMap = OB.map.reg(new OB.MapView(host, { mode: 'full' })); }
      fillDistricts();
      requestAnimationFrame(() => { view.resize(); if (S.state) view.setState(S.state); if (!view.userMoved) view.fit(false); if (OB.build.placing) view.ghost = { bp: OB.build.placing, x: null, y: null, ok: false, reason: 'ok' }; });
    },
    onClose() { if (view) { view.ghost = null; } },
    update(st) { if (view) view.setState(st); },
  });
})();
