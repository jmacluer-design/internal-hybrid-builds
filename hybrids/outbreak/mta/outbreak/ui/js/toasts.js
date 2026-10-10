/* Toasts + message log. borrowed: overextended/ox_lib/web/src/features/notifications/NotificationWrapper.tsx (LGPL-3.0, private use): the layout pattern ( icon chip, title/description,
   stacked at an edge, auto-dismiss with a progress rule), restyled; the message log feeds the Director drawer. */
(function () {
  'use strict';
  const OB = window.OB, h = OB.h;
  const ICON = { info: 'info', good: 'check', warn: 'alert', bad: 'skull', alert: 'radar' };
  const MAX = 5;

  OB.toast = function (level, text, opts) {
    opts = opts || {};
    level = ICON[level] ? level : 'info';
    const box = OB.$('#toasts');
    if (!box) return;
    // merge identical consecutive toasts (a bleeding colonist should not fill the screen)
    const last = box.lastElementChild;
    if (last && last.dataset.text === text && Date.now() - +last.dataset.at < 4000) {
      const n = (+last.dataset.n || 1) + 1;
      last.dataset.n = n; last.dataset.at = Date.now();
      last.querySelector('.x').textContent = '×' + n; last.querySelector('.x').hidden = false;
      last.classList.remove('out'); clearTimeout(last._t); last._t = setTimeout(() => dismiss(last), ttl(level));
      return;
    }
    const x = h('span.x', { hidden: true }, '');
    const t = h('div.toast.' + level + '.card-in', { role: 'status', dataset: { text, at: Date.now(), n: 1 } },
      h('div.ti', OB.icon(opts.icon || ICON[level])),
      h('div.tb', opts.title ? h('div.tt', opts.title) : null, h('div.tx', text)),
      x,
      h('i.life', { style: { animationDuration: ttl(level) + 'ms' } }));
    t.addEventListener('click', () => dismiss(t));
    box.append(t);
    while (box.children.length > MAX) box.firstElementChild.remove();
    t._t = setTimeout(() => dismiss(t), ttl(level));
  };
  function ttl(level) { return level === 'bad' ? 9000 : level === 'warn' ? 7000 : 5000; }
  function dismiss(t) { clearTimeout(t._t); t.classList.add('out'); setTimeout(() => t.remove(), 260); }

  // message log (kept in the store, shown in the Director drawer)
  OB.note = function (level, text, ev) {
    const S = OB.S;
    S.notes.push({ level, text, t: ev && ev.t, day: S.state ? S.state.day : (S.hud && S.hud.day) || 1, clock: S.state ? S.state.clock : (S.hud && S.hud.clock) || '' });
    if (S.notes.length > 200) S.notes.shift();
    OB.emit('notes', S.notes);
  };
})();
