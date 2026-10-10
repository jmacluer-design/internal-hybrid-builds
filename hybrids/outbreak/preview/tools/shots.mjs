// Screenshot generator: scripted scenes of the real NUI page against the real Lua host (preview). Reproduces everything in hybrids/outbreak/screenshots/.
//   node preview/tools/shots.mjs <out-dir> [scene ...]          scenes: hud inventory siege roster priorities build director summary map zones menu
//   SIZES=1920x1080,2560x1440 node preview/tools/shots.mjs ...  (default both)
// The world behind the HUD is the preview's stand-in backdrop (no GTA here): the pictures show the UI, not the game.
import fs from 'node:fs';
import path from 'node:path';
import { launch, openPreview } from '../tests/lib.mjs';

const OUT = path.resolve(process.argv[2] || 'shots');
const only = process.argv.slice(3);
const SIZES = (process.env.SIZES || '1920x1080,2560x1440').split(',').map(s => s.split('x').map(Number));
fs.mkdirSync(OUT, { recursive: true });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const env = await launch();

async function scene(name, w, h, query, fn) {
  if (only.length && !only.includes(name)) return;
  const p = await openPreview(env, { w, h, query: 'auto=0&' + query });
  p.ui = p.page.frames().find(f => f !== p.page.mainFrame());
  const P = (n, ...a) => p.call(n, ...a);
  const ui = (f, a) => p.ui.evaluate(f, a);
  const state = async () => JSON.parse(await p.page.evaluate(() => window.__preview.stateJson()));
  const push = async () => { const n = await ui(() => OB.S.stateCount); await P('pushState'); await p.ui.waitForFunction(c => OB.S.stateCount > c, n, { timeout: 8000 }); };
  const clean = () => ui(() => { document.querySelectorAll('.toast').forEach(t => t.remove()); const t = document.getElementById('tip'); if (t) t.hidden = true; });
  try {
    await fn({ p, P, ui, state, push, clean, w, h });
    if (name !== 'hud') await clean();
    await sleep(500);
    const file = path.join(OUT, `${name}_${w}x${h}.png`);
    await p.page.screenshot({ path: file, timeout: 120000 });
    console.log('wrote', path.relative(process.cwd(), file), (fs.statSync(file).size / 1024).toFixed(0) + ' KB', p.errors.length ? 'ERRORS: ' + p.errors.join(' | ') : '');
  } finally { await p.close(); }
}

// a populated, mid-game colony: seed 3, chaos pacing, the sim's AI plays until `day`
async function colony(c, seed, profile, n, days) {
  await c.P('newGame', seed, profile, n);
  await c.P('debug', 'autopilot', { on: true });
  await c.P('debug', 'fast_forward', { minutes: Math.round(days * 1440 - 600) });
  await c.P('setAuto', false);
}

for (const [w, h] of SIZES) {
  // 1. survival HUD in danger: low health, bleeding, thirsty, a horde closing in
  await scene('hud', w, h, 'mode=survival', async c => {
    await colony(c, 3, 'chaos', 6, 6);
    await c.P('debug', 'give', { item: 'pistol', n: 1 });
    await c.P('debug', 'give', { item: 'bandage', n: 3 });
    await c.P('debug', 'horde', { n: 60, dist: 70 });
    await c.P('inbound', [{ type: 'player_state', pos: { x: 0, y: 0, z: 0 }, moving: true }, { type: 'player_damage', amount: 38, kind: 'bite', part: 'arm' }, { type: 'player_damage', amount: 24, kind: 'bullet', part: 'torso' }]);
    await c.P('debug', 'survival', { hunger: 74, thirst: 88, fatigue: 62 });
    await c.P('setPlayer', 0, 0);
    await c.P('setHeading', 38);
    await c.P('ui', 'request_state', {}); // (the HUD numbers are pushed right away: no sim time passes, so the defenders have not killed the horde yet)
    await sleep(900);
    await c.ui(() => { document.querySelectorAll('.toast').forEach(t => t.remove()); OB.toast('bad', 'The dead are close to the base.', { title: 'Hordes nearby', icon: 'radar' }); OB.toast('warn', 'You are bleeding. Use a bandage.', { icon: 'cross' }); });
    await sleep(500);
  });

  // 2. inventory with a stockpile open next to the player's grid
  await scene('inventory', w, h, 'mode=survival', async c => {
    await colony(c, 3, 'escalating', 5, 5);
    for (const [item, n] of [['canned_beans', 6], ['water_bottle', 4], ['bandage', 5], ['pistol', 1], ['ammo_9mm', 36], ['painkillers', 2], ['machete', 1], ['scrap_wood', 12], ['fuel_can', 2], ['ration_pack', 3]]) await c.P('debug', 'give', { item, n });
    await c.P('toUI', 'screen', { name: 'inventory' });
    await sleep(300);
    const st = await c.state();
    await c.P('ui', 'inventory', { other: { kind: 'zone', id: st.zones[0].id } });
    await sleep(600);
    await c.clean();
    await c.ui(() => { const s = document.querySelector('.igrid[data-side="player"] .slot.full:nth-child(3)'); if (s) s.focus(); });
  });

  // 3. the colony mid-siege: a big horde on the base ring, colonists drafted
  await scene('siege', w, h, 'mode=colony', async c => {
    await colony(c, 3, 'chaos', 7, 7);
    await c.P('debug', 'horde', { n: 110, dist: 62 });
    await c.P('debug', 'horde', { n: 80, dist: 95 });
    await c.P('debug', 'horde', { n: 60, dist: 130 });
    await c.P('order', { id: 'all', kind: 'draft', target: true });
    await c.P('advance', 1500);
    await c.push();
    await c.ui(() => OB.mapBg.center(0, 0, 3.9));
    const st = await c.state();
    await c.ui(ids => OB.select(ids), st.colonists.slice(0, 2).map(x => x.id));
    await sleep(500);
    await c.ui(() => OB.colony.setDock('card'));
    await c.clean();
  });

  // 4. roster + colonist card (a wounded colonist selected)
  await scene('roster', w, h, 'mode=colony', async c => {
    await colony(c, 1, 'escalating', 8, 4);
    const st0 = await c.state();
    const who = st0.colonists[2];
    await c.P('debug', 'damage_colonist', { id: who.id, amount: 22, kind: 'bite', part: 'arm' });
    await c.P('debug', 'damage_colonist', { id: st0.colonists[4].id, amount: 12, kind: 'cut', part: 'leg' });
    await c.P('advance', 4000);
    await c.push();
    await c.ui(id => { OB.select([id]); OB.colony.setDock('card'); }, who.id);
    await sleep(300);
    await c.p.frame.locator('#dock .ctab, #dock .ctabs button', { hasText: 'Health' }).first().click();
    await sleep(400);
    await c.clean();
  });

  // 5. work priorities grid
  await scene('priorities', w, h, 'mode=colony', async c => {
    await colony(c, 1, 'escalating', 8, 4);
    await c.push();
    await c.P('toUI', 'screen', { name: 'priorities' });
    await sleep(500);
    await c.ui(() => { const cell = document.querySelector('.pcell[data-work="cook"]:not([disabled])'); if (cell) cell.focus(); });
    await c.clean();
  });

  // 6. build menu with a blueprint placed and another one on the cursor
  await scene('build', w, h, 'mode=colony', async c => {
    await colony(c, 1, 'escalating', 6, 3);
    for (const [bp, x, y] of [['wall', 12, 8], ['wall', 14, 8], ['watchtower', 20, -6], ['workbench', -10, 14]]) await c.P('order', { id: 'colony', kind: 'place_blueprint', target: { bp, pos: { x, y, z: 0 } } });
    await c.P('advance', 3000);
    await c.push();
    await c.ui(() => OB.colony.setDock('build'));
    await sleep(300);
    await c.ui(() => OB.$$('#dock .tab').find(b => b.dataset.cat === 'defense')?.click());
    await sleep(200);
    await c.p.frame.locator('.bcard[data-id="barricade"], .bcard[data-id="wall"]').first().click();
    const at = await c.ui(() => { const v = OB.mapBg, r = v.canvas.getBoundingClientRect(), f = window.frameElement.getBoundingClientRect(); return [f.left + r.left + v.sx(-6), f.top + r.top + v.sy(-14)]; });
    await c.p.page.mouse.move(at[0], at[1]);
    await sleep(400);
    await c.clean();
  });

  // 7. Director log around day 10
  await scene('director', w, h, 'mode=colony', async c => {
    await colony(c, 3, 'escalating', 7, 10);
    await c.push();
    await c.ui(() => OB.colony.setDock('director'));
    await sleep(500);
    await c.clean();
  });

  // 8. collapse / summary
  await scene('summary', w, h, 'mode=survival', async c => {
    await c.P('newGame', 2, 'chaos', 5);
    await c.P('debug', 'autopilot', { on: true });
    await c.P('debug', 'fast_forward', { minutes: 60 * 24 * 40 });
    await c.P('setAuto', false);
    await c.P('ui', 'request_summary', {});
    await sleep(500);
    await c.P('toUI', 'screen', { name: 'summary' });
    await sleep(900);
    await c.clean();
  });

  // extras
  await scene('map', w, h, 'mode=colony', async c => {
    await colony(c, 3, 'chaos', 7, 8);
    await c.P('debug', 'horde', { n: 50, dist: 300 });
    await c.P('advance', 4000);
    await c.push();
    await c.P('toUI', 'screen', { name: 'map' });
    await sleep(500);
    await c.ui(() => OB.bigMap.center(0, 0, 1.5));
    await sleep(300);
    await c.clean();
  });
  await scene('zones', w, h, 'mode=colony', async c => {
    await colony(c, 1, 'calm', 6, 5);
    await c.push();
    await c.ui(() => OB.colony.setDock('zones'));
    await sleep(500);
    await c.clean();
  });
  await scene('menu', w, h, 'mode=survival', async c => {
    await c.P('toUI', 'screen', { name: 'menu' });
    await sleep(500);
    await c.p.frame.locator('.scrim:not([hidden]) button[data-id="settings"]').click();
    await sleep(300);
  });
}
await env.close();
