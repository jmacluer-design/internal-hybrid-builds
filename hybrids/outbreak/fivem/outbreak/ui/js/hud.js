/* Survival HUD. Layout idea (vitals cluster, status chips, weight bar) follows the survival HUD of Paradigm-MP/fivem-rust-gamemode
   (GPL-3.0, private use: icon + fill + number stat rows) re-done as radial gauges; compass strip and threat panel are original. */
(function () {
  'use strict';
  const OB = window.OB, h = OB.h;
  const C = 113.1; // circumference of the gauge ring (r = 18)

  const hud = (OB.hud = {});
  let el = {};
  let lastHeading = -1, lastMarks = '', cvs, ctx;

  function gauge(id, icon, label, color) {
    const ring = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    ring.setAttribute('viewBox', '0 0 44 44'); ring.setAttribute('class', 'ring');
    ring.innerHTML = '<circle class="trk" cx="22" cy="22" r="18"/><circle class="val" cx="22" cy="22" r="18"/>';
    const g = h('div.gauge', { dataset: { id }, style: { '--c': color } }, ring, h('div.gi', OB.icon(icon)), h('div.gv.num', '100'), h('div.gl', label));
    g.val = ring.querySelector('.val'); g.gv = g.querySelector('.gv');
    return g;
  }

  hud.init = function () {
    const root = OB.$('#hud');
    OB.clear(root);
    el.hpIco = h('div.hp-ico', OB.icon('heart'));
    el.hpNum = h('span.disp.num', '100');
    el.hpMax = h('span.of', '/ 100');
    el.hpBar = OB.bar('thick');
    el.bleed = h('span.chip.bad-chip', { style: { '--c': 'var(--bleed)' }, hidden: true }, OB.icon('bleed'), h('span', ''));
    el.inf = h('span.chip', { style: { '--c': 'var(--infect)' }, hidden: true }, OB.icon('bio'), h('span', ''));
    el.pain = h('span.chip', { style: { '--c': 'var(--warn)' }, hidden: true }, OB.icon('alert'), h('span', 'Pain'));
    el.down = h('span.chip', { style: { '--c': 'var(--bad)' }, hidden: true }, OB.icon('skull'), h('span', 'Down'));
    el.gH = gauge('hunger', 'food', 'Food', 'var(--hunger)');
    el.gT = gauge('thirst', 'drop', 'Water', 'var(--thirst)');
    el.gF = gauge('fatigue', 'moon', 'Rest', 'var(--fatigue)');
    el.wtBar = OB.bar(); el.wtNum = h('span.num', '0 / 30 kg');
    el.wt = h('div.wt', OB.icon('weight'), el.wtBar, el.wtNum);
    el.vitals = h('div.vitals.panel',
      h('div.hp-row', el.hpIco, h('div', h('div.hp-top', el.hpNum, el.hpMax, h('span.lbl', 'Health')), el.hpBar)),
      h('div.gauges', el.gH, el.gT, el.gF),
      h('div.status-row', el.bleed, el.inf, el.pain, el.down),
      el.wt);
    OB.tip(el.vitals, () => '<div class="tt-h">Survival</div><div class="tt-r"><span>Food drains</span><span>~2.6 meals / day</span></div><div class="tt-r"><span>Water drains</span><span>~12 h to empty</span></div><div class="tt-r"><span>Rest</span><span>~18 h awake</span></div><div class="tt-r"><span>Infection</span><span>hidden while incubating</span></div>');

    // compass
    cvs = h('canvas', { width: 900, height: 90 });
    ctx = cvs.getContext('2d');
    el.deg = h('span.deg', '000');
    el.compass = h('div.compass.panel', cvs, el.deg);

    // clock
    el.sun = h('div.sun', OB.icon('sun'));
    el.time = h('div.time.num', '08:00');
    el.date = h('span', 'Day 1');
    el.weather = h('span', OB.icon('clear'));
    el.pw = h('span.ok', OB.icon('bolt'));
    el.wa = h('span.ok', OB.icon('drop'));
    el.clock = h('div.clock.panel', el.sun, el.time, h('div.meta', el.date, el.weather, el.pw, el.wa));
    OB.tip(el.weather, () => OB.fmt.cap((OB.S.hud || {}).weather || 'clear') + ' weather', 100);
    OB.tip(el.pw, () => 'Power ' + (el.pw.classList.contains('off') ? '<b>offline</b>: lights out, no stoves or workbenches' : 'online'));
    OB.tip(el.wa, () => 'Water ' + (el.wa.classList.contains('off') ? '<b>offline</b>: colonists need bottles' : 'available'));

    // colony chip
    el.chipN = h('div.big.num', '0'); el.chipS = h('small', 'Colonists');
    el.colony = h('div.colony-chip.panel', OB.icon('home'), h('div', el.chipN, el.chipS));

    // threat
    el.thIco = OB.icon('radar'); el.thLvl = h('div.lvl', 'Quiet');
    el.thSeg = h('div.segbar', ...Array.from({ length: 10 }, () => h('i')));
    el.thArrow = h('div.arrow', OB.icon('up')); el.thTxt = h('div.grow', '');
    el.threat = h('div.threat.panel.idle', h('div.th-h', el.thIco, h('span.lbl', 'Threat'), el.thLvl), el.thSeg, h('div.near', el.thArrow, el.thTxt));

    // hints
    el.hints = h('div.hints.panel', h('span', OB.key('F6'), 'Colony view'), h('span', OB.key('I'), 'Inventory'), h('span', OB.key('Esc'), 'Menu'));

    root.append(el.colony, el.compass, el.clock, el.threat, el.vitals, el.hints);
    hud.compass(0, true);
  };

  function setGauge(g, need) {
    const left = OB.clamp(100 - need, 0, 100);
    g.val.style.strokeDashoffset = (C * (1 - left / 100)).toFixed(2);
    OB.setText(g.gv, Math.round(left));
    OB.toggle(g, 'low', left < 35 && left >= 15);
    OB.toggle(g, 'crit', left < 15);
  }

  hud.update = function (d) {
    if (!el.vitals || !d) return;
    OB.setText(el.hpNum, Math.round(d.hp));
    OB.setText(el.hpMax, '/ ' + d.hp_max);
    el.hpBar.set(d.hp / d.hp_max * 100);
    OB.toggle(el.hpIco, 'crit', d.hp / d.hp_max < 0.25);
    OB.toggle(el.hpBar, 'warn', d.hp / d.hp_max < 0.25);
    setGauge(el.gH, d.hunger); setGauge(el.gT, d.thirst); setGauge(el.gF, d.fatigue);
    OB.show(el.bleed, d.bleeding > 0.02); OB.setText(el.bleed.lastChild, 'Bleeding ' + d.bleeding.toFixed(2) + '/min');
    OB.show(el.inf, d.infection !== 'none'); OB.setText(el.inf.lastChild, d.infection === 'terminal' ? 'Infection: terminal' : 'Infection: symptoms');
    OB.show(el.pain, d.pain >= 25);
    OB.show(el.down, !!d.downed);
    const frac = d.weight_max > 0 ? d.weight / d.weight_max : 0;
    el.wtBar.set(frac * 100);
    OB.toggle(el.wt, 'heavy', frac >= 0.75 && frac < 1); OB.toggle(el.wt, 'over', frac >= 1);
    OB.setText(el.wtNum, d.weight.toFixed(1) + ' / ' + d.weight_max.toFixed(0) + ' kg');

    OB.setText(el.time, d.clock);
    if (el.sun._k !== !!d.night) { el.sun._k = !!d.night; el.sun.classList.toggle('night', !!d.night); el.sun.replaceChildren(OB.icon(d.night ? 'moon' : 'sun')); }
    OB.setText(el.date, 'Day ' + d.day + ' · ' + OB.fmt.cap(d.season));
    if (el.weather._k !== d.weather) { el.weather._k = d.weather; el.weather.replaceChildren(OB.icon(OB.weatherIcon(d.weather))); }
    OB.toggle(el.pw, 'off', !d.power_ok); OB.toggle(el.pw, 'ok', d.power_ok);
    OB.toggle(el.wa, 'off', !d.water_ok); OB.toggle(el.wa, 'ok', d.water_ok);
    OB.setText(el.chipN, d.colonists);

    // threat panel
    const t = d.threat || { level: 0, label: 'Quiet' };
    const idle = t.level <= 0.05 && !d.alert;
    OB.toggle(el.threat, 'idle', idle);
    ['low', 'elevated', 'high', 'critical'].forEach(k => OB.toggle(el.threat, 't-' + k, t.label.toLowerCase() === k));
    OB.setText(el.thLvl, d.alert && t.level < 0.35 ? 'Alert' : t.label);
    const on = Math.round(t.level * 10);
    Array.from(el.thSeg.children).forEach((s, i) => OB.toggle(s, 'on', i < on || (d.alert && i < 3)));
    if (t.nearest) {
      const n = t.nearest;
      OB.setText(el.thTxt, (n.kind === 'raid' ? (n.name || 'Raiders') + ' · ' + n.size : 'Horde · ' + n.size) + ' — ' + OB.fmt.dist(n.dist) + ' ' + OB.fmt.dir(n.bearing));
      el.thArrow.firstChild.style.transform = 'rotate(' + Math.round(n.bearing - OB.S.compass) + 'deg)';
    } else OB.setText(el.thTxt, d.alert ? 'Base alert: movement detected' : 'No contacts');
    const low = d.hp / d.hp_max < 0.3, alert = t.level >= 0.6;
    const v = OB.$('#vignette');
    v.classList.toggle('on', low || alert);
    v.classList.toggle('low', low);
    hud.compass(OB.S.compass, false, d);
  };

  // compass strip (canvas): heading in degrees, markers for the base and the nearest threat
  hud.compass = function (heading, force, d) {
    if (!cvs) return;
    d = d || OB.S.hud || {};
    const marks = JSON.stringify([d.base_bearing, d.threat && d.threat.nearest && d.threat.nearest.bearing]);
    heading = ((heading % 360) + 360) % 360;
    if (!force && Math.abs(heading - lastHeading) < 0.4 && marks === lastMarks) return;
    lastHeading = heading; lastMarks = marks;
    const dpr = Math.min(window.devicePixelRatio || 1, 3);
    const W = Math.round(cvs.clientWidth * dpr) || 900, H = Math.round(cvs.clientHeight * dpr) || 90;
    if (cvs.width !== W || cvs.height !== H) { cvs.width = W; cvs.height = H; }
    ctx.clearRect(0, 0, W, H);
    const span = 150, ppd = W / span;
    const fs = H * 0.3;
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    for (let a = Math.floor((heading - span / 2) / 5) * 5; a <= heading + span / 2; a += 5) {
      const x = W / 2 + (a - heading) * ppd, ang = ((a % 360) + 360) % 360;
      const major = ang % 45 === 0, mid = ang % 15 === 0;
      const fade = 1 - Math.pow(Math.abs(x - W / 2) / (W / 2), 3);
      ctx.globalAlpha = Math.max(0, fade);
      ctx.strokeStyle = major ? '#f6b44f' : 'rgba(255,255,255,.55)'; ctx.lineWidth = Math.max(1, H * 0.018);
      ctx.beginPath(); ctx.moveTo(x, H * (major ? 0.62 : mid ? 0.7 : 0.78)); ctx.lineTo(x, H * 0.9); ctx.stroke();
      if (major) {
        const card = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'][ang / 45];
        ctx.fillStyle = card.length === 1 ? '#ffd38a' : '#c9d2e3';
        ctx.font = '700 ' + (card.length === 1 ? fs * 1.15 : fs * 0.85) + 'px Inter, sans-serif';
        ctx.fillText(card, x, H * 0.36);
      }
    }
    ctx.globalAlpha = 1;
    // markers
    const mark = (bearing, color, glyph) => {
      if (bearing == null) return;
      let diff = ((bearing - heading + 540) % 360) - 180;
      const x = W / 2 + diff * ppd;
      const inside = Math.abs(diff) < span / 2 - 4;
      const px = inside ? x : (diff > 0 ? W - H * 0.35 : H * 0.35);
      ctx.fillStyle = color; ctx.globalAlpha = inside ? 1 : 0.55;
      ctx.beginPath();
      if (glyph === 'home') { ctx.moveTo(px, H * 0.18); ctx.lineTo(px + H * 0.17, H * 0.4); ctx.lineTo(px - H * 0.17, H * 0.4); } else { ctx.moveTo(px, H * 0.6); ctx.lineTo(px + H * 0.17, H * 0.28); ctx.lineTo(px - H * 0.17, H * 0.28); }
      ctx.closePath(); ctx.fill(); ctx.globalAlpha = 1;
    };
    mark(d.base_bearing, '#3fe0c5', 'home');
    mark(d.threat && d.threat.nearest && d.threat.nearest.bearing, '#ff5d6c', 'threat');
    // centre caret
    ctx.fillStyle = '#ffd38a';
    ctx.beginPath(); ctx.moveTo(W / 2, H * 0.94); ctx.lineTo(W / 2 - H * 0.07, H); ctx.lineTo(W / 2 + H * 0.07, H); ctx.closePath(); ctx.fill();
    OB.setText(el.deg, String(Math.round(heading)).padStart(3, '0') + '°');
  };

  OB.on('hud', d => { OB.S.hud = d; hud.update(d); });
  OB.on('compass', c => { OB.S.compass = c; hud.compass(c); });
})();
