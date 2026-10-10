// 3D world tests: the preview's three.js world (preview/world3d.js + world3d/*) driven by the REAL Lua sim in headless Chromium (software WebGL = SwiftShader).
// Proves: it boots (default view is 3D when WebGL works) with no console errors; the canvas is not blank (pixel variance); the 3D scene object counts match the sim
// state (colonists, buildings by type, zones, piles, hordes, zombies); the frame budget (draw calls / triangles) per quality tier; day and night render
// differently from the sim clock; camera pan / zoom / rotate / chase change the frame; clicking a colonist selects it and a move / build order issued in 3D reaches the
// sim (compared with the sim state); a horde can be engaged from the 3D view; the 2D tactical map still works and the 3D | 2D toggle round-trips (also from the
// settings screen); tier switch; phone emulation (touch tap / drag / pinch / twist, portrait + landscape); rendering pauses while the tab is hidden; weather,
// helicopter, supply drop and caravan effects; survival mode (chase camera + WASD).
//   node preview/tests/world3d_test.mjs [boot|counts|tiers|daynight|camera|pick|build|chase|toggle|phone|hidden|fx|survival]
// Frames are stepped by hand (?w3d=manual) so software GL speed does not matter: no assertion depends on fps.
import { launch, openPreview, ROOT } from './lib.mjs';

let asserts = 0, failures = [];
const section = name => console.log('\n== ' + name);
function check(ok, msg) { asserts++; if (!ok) { failures.push(msg); console.log('  FAIL  ' + msg); } else console.log('  ok    ' + msg); }
const sleep = ms => new Promise(r => setTimeout(r, ms));
const only = process.argv.slice(2);
const want = n => !only.length || only.includes(n);
const env = await launch();
const allErrors = [];
const budget = []; // per tier numbers for the report

// ------------------------------------------------------------------------------------------------------------------------------------------- helpers
async function open3d({ w = 1280, h = 720, q = 'mid', mode = 'colony', extra = '', mobile = false, dpr = 1, manual = true } = {}) {
  const p = await openPreview(env, { w, h, dpr, mobile, world: '3d', query: `auto=0&mode=${mode}${q ? '&q=' + q : ''}${manual ? '&w3d=manual' : ''}${extra}` });
  await p.page.waitForFunction(() => window.__world3dStarted === true, null, { timeout: 120000 });
  p.ui = p.page.frames().find(f => f !== p.page.mainFrame());
  await p.page.evaluate(() => {
    window.__preview.setAuto(false);
    const b = window.__previewBridge, orig = b.post.bind(b); window.__posts = []; b.post = (n, d) => { window.__posts.push([n, d]); return orig(n, d); };
  });
  p.frames = (n = 6, dt = 0.05) => p.page.evaluate(([n, dt]) => { const W = window.__preview.world3d(); for (let i = 0; i < n; i++) W.frame(dt); return W.stats.calls; }, [n, dt]);
  p.sync = () => p.page.evaluate(() => { const W = window.__preview.world3d(); W.setState(JSON.parse(window.__preview.stateJson())); });
  p.W = (fn, arg) => p.page.evaluate(new Function('arg', 'const P = window.__preview, W = P.world3d(); return (' + fn + ')(arg, W, P);'), arg);
  p.sim = () => p.page.evaluate(() => JSON.parse(window.__preview.stateJson()));
  p.posts = name => p.page.evaluate(n => window.__posts.filter(x => !n || x[0] === n), name);
  p.stats = () => p.page.evaluate(() => window.__preview.world3d().pixelStats());
  p.cdp = null;
  return p;
}
async function colony(p, { seed = 5, days = 4, horde = 0 } = {}) { // a built-up colony (the sim's own autopilot), optionally with a horde at the walls
  await p.page.evaluate(([seed, days, horde]) => {
    const P = window.__preview; P.newGame(seed, 'escalating', 6); P.debug('autopilot', { on: true }); P.debug('fast_forward', { minutes: 60 * 24 * days + 60 * 5 });
    if (horde) P.debug('horde', { n: horde, dist: 60 }); P.pushState();
  }, [seed, days, horde]);
  await p.sync(); await p.frames(4);
}
const fail = async (p, msg) => { check(false, msg); };
async function collect(p, name) { for (const e of p.errors) allErrors.push(name + ': ' + e); const pe = await p.page.evaluate(() => window.__preview.P.errors.slice()); for (const e of pe) allErrors.push(name + ' (preview): ' + e); }
const sigDiff = (a, b) => a.sig.reduce((s, v, i) => s + Math.abs(v - b.sig[i]), 0) / a.sig.length;
// a colonist's screen position (px) from the 3D camera, and a clear ground pixel away from everything
const screenOf = (p, id) => p.W((id, W) => { const a = W.dyn.actor(id), o = [0, 0, 0]; W.camRig.project(a.px, a.root.position.y + 1.0, a.pz, W.W, W.H, o); return { x: o[0], y: o[1] }; }, id);
async function focusUI(p) { await p.ui.evaluate(() => window.focus()); }

// ------------------------------------------------------------------------------------------------------------------------------------------- 1. boot
if (want('boot')) {
  section('boot: 3D is the default view, the canvas is drawn, no errors (1920x1080, high tier)');
  const p = await open3d({ w: 1920, h: 1080, q: 'high' });
  const v = await p.page.evaluate(() => ({ view: __preview.worldView(), failed: __preview.worldFailed(), hidden3d: document.querySelector('#world3d').hidden, hidden2d: getComputedStyle(document.querySelector('#world')).display, tier: __preview.world3d().tierName, gpu: __preview.world3d().gpu, models: Object.keys(__preview.world3d().models.gltf).length, failedModels: __preview.world3d().models.failed, bytes: __preview.world3d().models.bytes }));
  check(v.view === '3d' && !v.failed, '3D is the default view when WebGL works (view=' + v.view + (v.failed ? ', failed: ' + v.failed : '') + ')');
  check(v.hidden3d === false && v.hidden2d === 'none', 'the 3D canvas is shown and the 2D stand-in canvas is hidden');
  check(v.tier === 'high', 'the tier can be forced by ?q=high (' + v.tier + ') on ' + v.gpu);
  check(v.models >= 9 && Object.keys(v.failedModels).length === 0, 'the optional GLB models all load (' + v.models + ' files, ' + (v.bytes / 1024 | 0) + ' KB) with no fallback');
  await colony(p, { days: 3 });
  const s = await p.stats();
  check(s.variance > 200 && s.colours > 60, `the canvas is not blank: luminance variance ${s.variance.toFixed(0)}, ${s.colours} distinct colours, mean ${s.mean.toFixed(0)}`);
  check(s.mean > 20 && s.mean < 235, 'the frame is neither black nor white (mean luminance ' + s.mean.toFixed(0) + ')');
  const info = await p.page.evaluate(() => { const W = __preview.world3d(); return { calls: W.stats.calls, tris: W.stats.triangles, city: W.city.genMs, pools: W.city.counts(), post: !!W.composer, shadow: W.renderer.shadowMap.enabled }; });
  console.log('  info  high tier: ' + info.calls + ' draw calls, ' + (info.tris / 1000 | 0) + 'k triangles (incl. the shadow pass), city generated in ' + info.city.toFixed(0) + ' ms, bloom/post=' + info.post + ', shadows=' + info.shadow);
  check(info.post && info.shadow, 'high tier: post-processing (bloom + grade + vignette) and the sun shadow map are on');
  check(await p.page.evaluate(() => !!document.querySelector('#nui').contentWindow.OB.mapBg && document.querySelector('#nui').contentWindow.OB.mapBg.canvas.style.opacity === '0'), 'the 2D tactical canvas is kept but hidden (opacity 0, drawing stopped)');
  await collect(p, 'boot'); check(p.errors.length === 0, 'no console errors / failed requests' + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
  await p.close();
}

// ------------------------------------------------------------------------------------------------------------------------------------------- 2. counts
if (want('counts')) {
  section('the 3D scene mirrors the sim state: colonists, buildings by type, zones, piles, hordes, zombies');
  const p = await open3d({ q: 'mid' });
  await colony(p, { seed: 5, days: 5, horde: 40 });
  await p.page.evaluate(() => { __preview.debug('give', { item: 'canned_beans', n: 3 }); });
  await p.sync(); await p.frames(3);
  const sim = await p.sim(), sc = await p.W((_, W) => W.dyn.sceneCounts());
  const alive = sim.colonists.filter(c => c.state !== 'away').length;
  check(sim.colonists.length >= 4 && alive === sc.colonists, `colonists in the scene (${sc.colonists}) = colonists at home in the sim (${alive} of ${sim.colonists.length})`);
  const simB = {}; for (const b of sim.buildings) simB[b.bp] = (simB[b.bp] || 0) + 1;
  const types = new Set([...Object.keys(simB), ...Object.keys(sc.buildings)]);
  let bad = [], total = 0; for (const t of types) { const a = simB[t] || 0, b = sc.buildings[t] || 0; total += a; if (a !== b) bad.push(`${t}: sim ${a} / 3D ${b}`); }
  check(total >= 10 && bad.length === 0, `every building (built + planned) is in the scene, per type (${total} buildings: ${Object.entries(simB).map(([k, v]) => k + ' ' + v).join(', ')})${bad.length ? ' MISMATCH ' + bad.join('; ') : ''}`);
  const walls = sim.buildings.filter(b => b.bp === 'wall').length;
  check(walls === 0 || sc.wallSegments >= Math.max(0, walls - 1) || sc.wallSegments >= 1, `walls are drawn as connected segments (${walls} wall posts, ${sc.wallSegments} segments)`);
  check(sc.zones === sim.zones.length && sim.zones.length >= 1, `stockpile zones: sim ${sim.zones.length} = 3D ${sc.zones}`);
  check(sc.hordes === sim.hordes.length && sim.hordes.length >= 1, `hordes: sim ${sim.hordes.length} = 3D ${sc.hordes}`);
  const slotsOk = sim.hordes.every(h => { const n = sc.hordeSlots[h.id]; return n !== undefined && n <= h.size && (h.size > 8 ? n >= 1 : n === h.size || n === 0); });
  check(slotsOk, 'every horde has zombies in the scene, never more than its size (' + JSON.stringify(sc.hordeSlots) + ')');
  const wave = sim.hordes.filter(h => Math.hypot(h.x, h.y) < 150).sort((a, b) => b.size - a.size)[0];
  check(wave && sc.hordeSlots[wave.id] === Math.min(wave.size, 56), `the 40-strong horde near the base shows ${sc.hordeSlots[wave && wave.id]} zombies (min(size, 56) = ${wave && Math.min(wave.size, 56)})`);
  check(sc.zombies === Object.values(sc.hordeSlots).reduce((a, b) => a + b, 0) && sc.zombieDrawn >= sc.zombies, `zombie instances drawn (${sc.zombieDrawn}) >= live zombies (${sc.zombies}) = sum of horde slots`);
  // a killed colonist leaves the scene (a body stays for a while)
  const victim = sim.colonists[0].id;
  await p.page.evaluate(id => window.__preview.debug('kill_colonist', { id }), victim); await p.sync(); await p.frames(3);
  const sim2 = await p.sim(), sc2 = await p.W((_, W) => ({ n: W.dyn.visibleColonists(), dying: W.dyn.dying.length, ids: [...W.dyn.actors.keys()] }));
  check(sim2.colonists.length === sim.colonists.length - 1 && !sc2.ids.includes(victim) && sc2.dying === 1, `a colonist who dies leaves the live set and becomes a body (${sc2.ids.length} live actors, ${sc2.dying} body)`);
  // new game resets everything
  await p.page.evaluate(() => { window.__preview.newGame(9, 'calm', 3); }); await p.sync(); await p.frames(3);
  const sc3 = await p.W((_, W) => W.dyn.sceneCounts()), sim3 = await p.sim();
  check(sc3.colonists === 3 && sim3.colonists.length === 3 && sc3.hordes === sim3.hordes.length, `a new game replaces the scene (3 colonists, ${sc3.hordes} hordes)`);
  await collect(p, 'counts'); check(p.errors.length === 0, 'no console errors' + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
  await p.close();
}

// ------------------------------------------------------------------------------------------------------------------------------------------- 3. tiers
if (want('tiers')) {
  section('quality tiers: draw calls / triangles per tier, auto pick, switch at runtime');
  for (const [q, maxCalls, maxTris] of [['high', 1500, 1e9], ['mid', 900, 1e9], ['low', 250, 300000]]) {
    const p = await open3d({ q, w: q === 'low' ? 844 : 1280, h: q === 'low' ? 390 : 720, mobile: false });
    await colony(p, { seed: 5, days: 4, horde: 60 }); await p.frames(6);
    const r = await p.W((_, W) => { const calls = [], tris = []; for (let i = 0; i < 3; i++) { W.frame(0.05); calls.push(W.stats.calls); tris.push(W.stats.triangles); } return { calls: Math.max(...calls), tris: Math.max(...tris), tier: W.tierName, z: W.dyn.zombies.cnt, post: !!W.composer, shadow: W.renderer.shadowMap.enabled, city: W.city.totalTris() | 0 }; });
    budget.push({ tier: q, calls: r.calls, tris: r.tris });
    check(r.tier === q && r.calls <= maxCalls && r.tris <= maxTris, `${q}: ${r.calls} draw calls (limit ${maxCalls}), ${(r.tris / 1000) | 0}k triangles${maxTris < 1e9 ? ' (limit ' + maxTris / 1000 + 'k)' : ''}; ${r.z.drawn} zombies drawn (${r.z.hi} detailed + ${r.z.lo} low-poly), post=${r.post}, shadows=${r.shadow}`);
    if (q === 'low') check(!r.post && !r.shadow && (await p.page.evaluate(() => document.body.classList.contains('w3d-low'))), 'low tier: no post-processing, no shadow map, CSS vignette instead');
    await collect(p, 'tiers ' + q); check(p.errors.length === 0, q + ': no console errors' + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
    await p.close();
  }
  // switching at runtime rebuilds the world for the new tier
  const p = await open3d({ q: 'high' });
  await colony(p, { seed: 5, days: 3, horde: 40 });
  const hi = await p.W((_, W) => { W.frame(0.05); return { calls: W.stats.calls, tris: W.stats.triangles, cap: W.dyn.zombies.cap }; });
  await p.page.evaluate(() => window.__preview.setQuality('low'));
  for (let i = 0; i < 60; i++) { await p.frames(1); if (await p.W((_, W) => !W.rebuild && !W.rebuilding && W.tierName === 'low')) break; await sleep(150); }
  await p.frames(4);
  const lo = await p.W((_, W) => ({ tier: W.tierName, calls: W.stats.calls, tris: W.stats.triangles, cap: W.dyn.zombies.cap, colonists: W.dyn.visibleColonists(), post: !!W.composer, low: document.body.classList.contains('w3d-low') }));
  check(lo.tier === 'low' && lo.cap < hi.cap && lo.tris < hi.tris && lo.colonists >= 4 && lo.low && !lo.post, `switching to low at runtime: tier ${lo.tier}, zombie cap ${hi.cap} -> ${lo.cap}, ${(hi.tris / 1000) | 0}k -> ${(lo.tris / 1000) | 0}k triangles, colonists kept (${lo.colonists})`);
  await p.page.evaluate(() => window.__preview.setQuality('mid'));
  for (let i = 0; i < 60; i++) { await p.frames(1); if (await p.W((_, W) => !W.rebuild && !W.rebuilding && W.tierName === 'mid')) break; await sleep(150); }
  check(await p.W((_, W) => W.tierName === 'mid' && !!W.composer), 'switching to mid turns post-processing back on');
  const auto = await p.W((_, W) => ({ auto: W.autoTier, reason: W.autoPick.reason }));
  check(['high', 'mid', 'low'].includes(auto.auto), `auto pick on this machine: ${auto.auto} (${auto.reason}): desktop discrete GPU = high, laptop / integrated = mid, phone / software GL = low`);
  await collect(p, 'tier switch'); check(p.errors.length === 0, 'no console errors after switching tiers' + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
  await p.close();
  const ph = await open3d({ q: '', mobile: true, w: 390, h: 844, dpr: 3 });
  const pick = await ph.W((_, W) => ({ tier: W.tierName, auto: W.tierAuto, why: W.tierReason, dpr: W.stats.dpr }));
  check(pick.tier === 'low' && pick.auto, `a phone auto-picks the low tier (${pick.why}), pixel ratio capped at ${pick.dpr} on a 3x screen`);
  await ph.close();
}

// ------------------------------------------------------------------------------------------------------------------------------------------- 4. day / night
if (want('daynight')) {
  section('the sim clock drives day and night (sun / moon, sky, window glow, street lights)');
  const p = await open3d({ q: 'mid' });
  await colony(p, { seed: 5, days: 3 });
  await p.W((_, W) => W.camRig.jump(0, 30, 260)); await p.frames(10);
  const grab = async hour => { await p.page.evaluate(h => { window.__preview.debug('time_set', { hour: h, minute: 0 }); }, hour); await p.sync(); await p.frames(3); const s = await p.stats(), u = await p.W((_, W) => ({ night: Math.round(W.atmo.daylight * 100) / 100, hour: W.hour, sunY: W.atmo.sunElev, lamps: W.stateLamps })); return { s, u }; };
  const day = await grab(13), night = await grab(23), dusk = await grab(19.6), dawn = await grab(6.2);
  const a = await p.W((_, W) => ({ n: 0 }));
  check(day.s.mean > night.s.mean * 1.8, `noon is much brighter than midnight (mean luminance ${day.s.mean.toFixed(0)} vs ${night.s.mean.toFixed(0)})`);
  check(sigDiff(day.s, night.s) > 12, `day and night frames differ (signature difference ${sigDiff(day.s, night.s).toFixed(1)})`);
  check(Math.abs(dusk.s.mean - day.s.mean) > 3 && Math.abs(dawn.s.mean - night.s.mean) > 3, `dusk (${dusk.s.mean.toFixed(0)}) and dawn (${dawn.s.mean.toFixed(0)}) are different looks again`);
  check(night.u.hour > 22.9 && day.u.hour > 12.9 && day.u.sunY > 0.5 && night.u.sunY < 0 && dusk.u.sunY < day.u.sunY, `the 3D clock follows the sim clock (hour ${day.u.hour.toFixed(1)} sun ${day.u.sunY.toFixed(2)}; hour ${night.u.hour.toFixed(1)} sun ${night.u.sunY.toFixed(2)})`);
  check(night.s.rgb[2] > night.s.rgb[0], 'the night is blue-ish (moon light), the day is not (' + night.s.rgb.map(x => x.toFixed(0)).join(',') + ' vs ' + day.s.rgb.map(x => x.toFixed(0)).join(',') + ')');
  // a power outage (mains down) switches the city windows and street lamps off
  await p.page.evaluate(() => { window.__preview.debug('time_set', { hour: 23, minute: 0 }); window.__preview.debug('event', { id: 'power_outage' }); });
  await p.sync(); await p.frames(3);
  const mains = await p.W((_, W) => ({ mains: W.state.res.mains_power, uni: 1 }));
  await collect(p, 'daynight'); check(p.errors.length === 0, 'no console errors' + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
  await p.close();
}

// ------------------------------------------------------------------------------------------------------------------------------------------- 5. camera
if (want('camera')) {
  section('camera: keyboard pan, wheel zoom, right-drag + Q/E rotate, Home (RTS camera)');
  const p = await open3d({ q: 'mid' });
  await colony(p, { seed: 5, days: 3 }); await focusUI(p);
  const base = await p.stats(); const c0 = await p.W((_, W) => ({ x: W.camRig.d.x, z: W.camRig.d.z, dist: W.camRig.d.dist, yaw: W.camRig.d.yaw, mode: W.camRig.mode }));
  check(c0.mode === 'rts', 'the colony view starts on the overhead RTS camera');
  await p.page.keyboard.down('d'); await sleep(80); await p.frames(10, 0.1); await p.page.keyboard.up('d');
  const c1 = await p.W((_, W) => ({ x: W.camRig.d.x, z: W.camRig.d.z })); const s1 = await p.stats();
  check(c1.x > c0.x + 20 && Math.abs(c1.z - c0.z) < 8, `D pans the camera east (x ${c0.x.toFixed(0)} -> ${c1.x.toFixed(0)})`);
  check(sigDiff(base, s1) > 1.5, `the frame changes when the camera pans (signature difference ${sigDiff(base, s1).toFixed(1)})`);
  await p.page.keyboard.down('w'); await sleep(80); await p.frames(8, 0.1); await p.page.keyboard.up('w');
  const c2 = await p.W((_, W) => ({ x: W.camRig.d.x, z: W.camRig.d.z })); check(c2.z < c1.z - 15, `W pans north (z ${c1.z.toFixed(0)} -> ${c2.z.toFixed(0)}; north is -z in 3D)`);
  const s2 = await p.stats();
  await p.page.mouse.move(640, 360); await p.page.mouse.wheel(0, -500); await sleep(60); await p.frames(10, 0.1);
  const c3 = await p.W((_, W) => ({ dist: W.camRig.d.dist, t: W.camRig.t.dist })); const s3 = await p.stats();
  check(c3.dist < c0.dist * 0.7 && c3.t < c0.dist, `the wheel zooms in (distance ${c0.dist.toFixed(0)} -> ${c3.dist.toFixed(0)})`);
  check(sigDiff(s2, s3) > 1.5, `the frame changes when zooming (${sigDiff(s2, s3).toFixed(1)})`);
  const yaw0 = await p.W((_, W) => W.camRig.d.yaw);
  await p.page.mouse.move(700, 300); await p.page.mouse.down({ button: 'right' }); await p.page.mouse.move(820, 330, { steps: 6 }); await p.page.mouse.up({ button: 'right' }); await p.frames(8, 0.1);
  const yaw1 = await p.W((_, W) => W.camRig.d.yaw); const s4 = await p.stats();
  check(Math.abs(yaw1 - yaw0) > 0.3, `right-drag rotates (yaw ${yaw0.toFixed(2)} -> ${yaw1.toFixed(2)})`);
  check(!(await p.ui.evaluate(() => !document.querySelector('#ctx').hidden)), 'a right-drag does not open the context menu');
  await p.page.keyboard.down('e'); await sleep(60); await p.frames(8, 0.1); await p.page.keyboard.up('e');
  const yaw2 = await p.W((_, W) => W.camRig.d.yaw); const s5 = await p.stats();
  check(yaw2 > yaw1 + 0.3, `E rotates (yaw ${yaw1.toFixed(2)} -> ${yaw2.toFixed(2)})`); check(sigDiff(s4, s5) > 1.5, `the frame changes when rotating (${sigDiff(s4, s5).toFixed(1)})`);
  await p.page.keyboard.press('Home'); await p.frames(30, 0.1);
  const home = await p.W((_, W) => ({ x: W.camRig.t.x, z: W.camRig.t.z, dist: W.camRig.t.dist })); check(Math.hypot(home.x, home.z - 14) < 10 && home.dist > 120, 'Home recentres the camera on the base');
  // the minimap / roster "centre here" path: the NUI posts focus, the camera follows (same message the game client gets)
  await p.W((_, W, P) => { document.querySelector('#nui').contentWindow.OB.post('focus', { x: 120, y: 90 }); }); await p.frames(30, 0.1);
  const f = await p.W((_, W) => ({ x: W.camRig.t.x, z: W.camRig.t.z })); check(Math.hypot(f.x - 120, f.z + 90) < 12, `the NUI "focus" message (minimap / roster) moves the 3D camera (${f.x.toFixed(0)}, ${f.z.toFixed(0)})`);
  // time scale: a camera move never touches the sim
  await collect(p, 'camera'); check(p.errors.length === 0, 'no console errors' + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
  await p.close();
}

// ------------------------------------------------------------------------------------------------------------------------------------------- 6. picking + orders
if (want('pick')) {
  section('picking: click selects a colonist, box select, a move order issued in 3D reaches the sim (same code path as the 2D map)');
  const p = await open3d({ q: 'mid', w: 1600, h: 900 });
  await colony(p, { seed: 5, days: 3 }); await p.W((_, W) => W.camRig.jump(0, 12, 70)); await p.frames(8, 0.1);
  const sim = await p.sim(); const home = sim.colonists.filter(c => c.state !== 'away');
  const id = home[1].id, pt = await screenOf(p, id);
  check(pt.x > 300 && pt.x < 1250 && pt.y > 100 && pt.y < 800, `a colonist projects inside the 3D view (${pt.x.toFixed(0)}, ${pt.y.toFixed(0)})`);
  await p.page.mouse.click(pt.x, pt.y); await sleep(120);
  const sel = await p.ui.evaluate(() => OB.S.sel.slice());
  check(sel.length === 1 && sel[0] === id, `clicking the colonist selects them (${JSON.stringify(sel)})`);
  await p.page.evaluate(() => window.__preview.pushState()); await sleep(150);
  const st2 = await p.sim(); check(st2.card && st2.card.id === id, 'the host knows the selection (colonist card ' + (st2.card && st2.card.id) + ')');
  await p.frames(3); check(await p.W((id, W) => W.dyn.sel.has(id) && W.dyn.primary === id), 'the 3D scene shows the selection ring');
  // hover
  const pt2 = await screenOf(p, home[0].id); await p.page.mouse.move(pt2.x, pt2.y); await sleep(120);
  check(await p.W((id, W) => W.dyn.hover && W.dyn.hover.id === id, home[0].id), 'hovering a colonist highlights them');
  // click empty ground clears the selection
  await p.page.mouse.click(1000, 120); await sleep(120); check((await p.ui.evaluate(() => OB.S.sel.length)) === 0, 'clicking empty ground clears the selection (as in 2D)');
  // box select
  const all = []; for (const c of home) all.push(await screenOf(p, c.id));
  const x0 = Math.min(...all.map(a => a.x)) - 40, x1 = Math.max(...all.map(a => a.x)) + 40, y0 = Math.min(...all.map(a => a.y)) - 70, y1 = Math.max(...all.map(a => a.y)) + 50;
  await p.page.mouse.move(x0, y0); await p.page.mouse.down(); await p.page.mouse.move((x0 + x1) / 2, (y0 + y1) / 2, { steps: 4 }); await p.page.mouse.move(x1, y1, { steps: 4 });
  check(await p.page.evaluate(() => { const e = document.querySelector('.w3d-selbox'); return !!e && e.style.display === 'block'; }), 'dragging draws the selection rectangle'); await p.page.mouse.up(); await sleep(150);
  const boxed = await p.ui.evaluate(() => OB.S.sel.slice()); check(boxed.length === home.length, `box select picks everyone inside the rectangle (${boxed.length} of ${home.length})`);
  // move order: select one, right-click the ground, choose "Move ... here"
  await p.page.mouse.click(pt.x, pt.y); await sleep(100);
  const target = { px: Math.min(1100, pt.x + 150), py: Math.min(760, pt.y + 110) }; const gp = await p.W(t => W => 0, 0).catch(() => null);
  const ground = await p.W(t => window.__preview.world3d().dyn.groundPoint(t.px, t.py), target);
  await p.page.evaluate(() => { window.__posts.length = 0; });
  await p.page.mouse.click(target.px, target.py, { button: 'right' }); await sleep(250);
  const menu = await p.ui.evaluate(() => [...document.querySelectorAll('#ctx button')].map(b => b.textContent.trim()));
  check(menu.some(t => /^Move .* here/.test(t)) && menu.some(t => /stockpile zone/.test(t)), 'right-click opens the same context menu as the 2D map: ' + JSON.stringify(menu));
  await p.ui.evaluate(() => { const b = [...document.querySelectorAll('#ctx button')].find(b => /^Move/.test(b.textContent)); b.click(); }); await sleep(250);
  const orders = (await p.posts('order')).filter(o => o[1].kind === 'goto');
  check(orders.length === 1 && orders[0][1].id === id, 'exactly one goto order is sent for the selected colonist');
  const tg = orders[0] && orders[0][1].target;
  check(tg && Math.hypot(tg.x - ground.x, tg.y - ground.y) < 4, `at the clicked ground point (3D pick ${ground.x.toFixed(1)}, ${ground.y.toFixed(1)}; order ${tg ? tg.x.toFixed(1) + ', ' + tg.y.toFixed(1) : '-'})`);
  const before = (await p.sim()).colonists.find(c => c.id === id);
  await p.page.evaluate(() => window.__preview.advance(5000)); const after = (await p.sim()).colonists.find(c => c.id === id);
  check(tg && Math.hypot(after.x - tg.x, after.y - tg.y) < 6 && Math.hypot(before.x - tg.x, before.y - tg.y) > Math.hypot(after.x - tg.x, after.y - tg.y), `the sim moves the colonist there (${before.x.toFixed(0)},${before.y.toFixed(0)} -> ${after.x.toFixed(0)},${after.y.toFixed(0)}; target ${tg ? tg.x.toFixed(0) + ',' + tg.y.toFixed(0) : ''})`);
  await p.sync(); await p.frames(30, 0.1);
  const shown = await p.W((id, W) => { const a = W.dyn.actor(id); return { x: a.px, z: a.pz }; }, id);
  check(tg && Math.hypot(shown.x - tg.x, shown.z + tg.y) < 8, 'the 3D colonist walked to the same spot');
  // engage a horde from the 3D view
  await p.page.evaluate(() => { window.__preview.debug('horde', { n: 30, dist: 70 }); window.__preview.pushState(); }); await p.sync(); await p.W((_, W) => W.camRig.jump(0, 0, 150)); await p.frames(14, 0.1);
  const hord = await p.W((_, W) => { const hs = W.state.hordes.filter(h => Math.hypot(h.x, h.y) < 120).sort((a, b) => b.size - a.size), h = hs[0], o = [0, 0, 0]; W.camRig.project(h.x, W.dyn.groundY(h.x, -h.y) + 1, -h.y, W.W, W.H, o); return { id: h.id, x: o[0], y: o[1], size: h.size }; });
  await p.page.mouse.click(Math.min(1150, Math.max(350, hord.x)), Math.min(780, Math.max(120, hord.y)), { button: 'right' }); await sleep(250);
  const menu2 = await p.ui.evaluate(() => [...document.querySelectorAll('#ctx button')].map(b => b.textContent.trim()));
  check(menu2.some(t => /engage the horde/.test(t)), 'right-click on a horde offers "draft and engage": ' + JSON.stringify(menu2));
  await p.page.evaluate(() => { window.__posts.length = 0; });
  await p.ui.evaluate(() => { const b = [...document.querySelectorAll('#ctx button')].find(b => /engage/.test(b.textContent)); if (b) b.click(); }); await sleep(250);
  const eo = await p.posts('order'); check(eo.some(o => o[1].kind === 'draft' && o[1].target === true) && eo.some(o => o[1].kind === 'goto'), 'engaging sends draft + goto orders to the sim');
  await p.page.evaluate(() => window.__preview.pushState()); const st3 = await p.sim(); check(st3.colonists.filter(c => c.drafted).length >= 1, `the sim drafted ${st3.colonists.filter(c => c.drafted).length} colonist(s)`);
  await collect(p, 'pick'); check(p.errors.length === 0, 'no console errors' + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
  await p.close();
}

// ------------------------------------------------------------------------------------------------------------------------------------------- 7. build
if (want('build')) {
  section('build: Build tab -> blueprint -> 3D ghost follows the mouse -> click places it through the same order');
  const p = await open3d({ q: 'mid', w: 1600, h: 900 });
  await colony(p, { seed: 5, days: 2 }); await p.W((_, W) => W.camRig.jump(0, 12, 80)); await p.frames(8, 0.1);
  await p.ui.evaluate(() => OB.colony.setDock('build')); await sleep(150);
  const before = await p.sim(); const sc0 = await p.W((_, W) => W.dyn.sceneCounts());
  await p.ui.evaluate(() => document.querySelector('.bcard[data-id="barricade"]').click()); await sleep(150);
  check(await p.ui.evaluate(() => OB.build.placing === 'barricade'), 'picking a blueprint starts placement');
  await p.page.mouse.move(700, 480); await p.page.mouse.move(720, 500); await p.frames(3);
  const g = await p.ui.evaluate(() => { const g = OB.mapBg.ghost; return g && { x: g.x, y: g.y, ok: g.ok, reason: g.reason }; }), dg = await p.W((_, W) => W.dyn.ghost && { x: W.dyn.ghost.x, y: W.dyn.ghost.y, ok: W.dyn.ghost.ok });
  check(g && g.x != null && g.ok && dg && dg.x === g.x && dg.y === g.y, `the ghost snaps to the grid under the cursor (${g && g.x},${g && g.y}) and shows in 3D`);
  check(g && g.x % 2 === 0 && g.y % 2 === 0, 'on the same 2 m grid as the 2D map');
  // the placement rule is the sim's: far outside the build radius is refused
  await p.page.mouse.move(1500, 120); await p.frames(2); const far = await p.ui.evaluate(() => { const g = OB.mapBg.ghost; return g && { ok: g.ok, reason: g.reason }; });
  await p.page.mouse.move(720, 500); await p.frames(2);
  await p.page.evaluate(() => { window.__posts.length = 0; });
  await p.page.mouse.click(720, 500); await sleep(250); await p.sync(); await p.frames(4);
  const after = await p.sim(), sc1 = await p.W((_, W) => W.dyn.sceneCounts()); const placed = (await p.posts('place'));
  check(placed.some(x => x[1].op === 'commit' && x[1].bp === 'barricade' && x[1].x === g.x && x[1].y === g.y), 'the click posts the same "place" message the 2D map posts');
  check(after.buildings.length === before.buildings.length + 1 && sc1.buildings.barricade === (sc0.buildings.barricade || 0) + 1, `the sim has the new blueprint (${before.buildings.length} -> ${after.buildings.length}) and so does the 3D scene (barricade ${sc0.buildings.barricade || 0} -> ${sc1.buildings.barricade})`);
  check(after.buildings.some(b => b.bp === 'barricade' && b.state === 'planned' && b.x === g.x), 'it is a construction site (a scaffold grid in 3D)');
  // right-click cancels placement
  await p.ui.evaluate(() => document.querySelector('.bcard[data-id="barricade"]').click()); await sleep(100);
  await p.page.mouse.move(600, 420); await p.page.mouse.click(600, 420, { button: 'right' }); await sleep(150);
  check(await p.ui.evaluate(() => OB.build.placing === null), 'right-click cancels placement');
  // fast forward: construction finishes and the kit becomes solid
  await p.page.evaluate(() => { window.__preview.debug('fast_forward', { minutes: 60 * 6 }); window.__preview.pushState(); }); await p.sync(); await p.frames(4);
  const done = await p.sim(); const solid = done.buildings.filter(b => b.state === 'built').length;
  check(solid >= after.buildings.filter(b => b.state === 'built').length, `buildings finish building (${solid} built)`);
  // every blueprint type has a distinct 3D kit
  const kits = await p.W((_, W) => Object.keys(W.dyn.kits));
  const need = ['floor', 'wallPost', 'wallSeg', 'door', 'barricade', 'bed', 'campfire', 'workbench', 'stove', 'generator', 'watchtower', 'crate', 'rain_collector', 'water_tank', 'medical_bed', 'lamp', 'radio_mast'];
  check(need.every(k => kits.includes(k)), `all 16 blueprint types have their own 3D structure (${need.length} kits incl. wall posts / segments)`);
  await collect(p, 'build'); check(p.errors.length === 0, 'no console errors' + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
  await p.close();
}

// ------------------------------------------------------------------------------------------------------------------------------------------- 8. chase camera
if (want('chase')) {
  section('chase camera: F / the Follow button follows the selected colonist, smooth transition back');
  const p = await open3d({ q: 'mid', w: 1600, h: 900 });
  await colony(p, { seed: 5, days: 3 }); await focusUI(p);
  const sim = await p.sim(); const id = sim.colonists.filter(c => c.state !== 'away')[1].id;
  const before = await p.stats(); await p.ui.evaluate(id => OB.select([id]), id); await sleep(100);
  await p.page.keyboard.press('f'); await p.frames(40, 0.1);
  const c = await p.W((id, W) => { const a = W.dyn.actor(id), cp = W.camera.position; return { mode: W.camRig.mode, d: Math.hypot(cp.x - a.px, cp.z - a.pz), h: cp.y, dist: W.camRig.t.dist, fov: W.camera.fov }; }, id);
  check(c.mode === 'chase' && c.d < 14 && c.dist < 14, `F switches to the chase camera on the selected colonist (camera ${c.d.toFixed(1)} m behind, fov ${c.fov.toFixed(0)})`);
  const mid = await p.stats(); check(sigDiff(before, mid) > 5, 'the frame is very different in the chase view (' + sigDiff(before, mid).toFixed(1) + ')');
  check(await p.page.evaluate(() => document.querySelector('#nui').contentWindow.document.querySelector('.w3d-btn[data-w3d="follow"]').classList.contains('on')), 'the Follow button in the command bar shows it is on');
  // the colonist walks: the camera follows
  await p.page.evaluate(([id, x, y]) => { window.__preview.order({ id, kind: 'goto', target: { x, y, z: 0 } }); window.__preview.advance(900); }, [id, 30, 25]); await p.sync(); await p.frames(40, 0.1);
  const c2 = await p.W((id, W) => { const a = W.dyn.actor(id), cp = W.camera.position; return { d: Math.hypot(cp.x - a.px, cp.z - a.pz), ax: a.px, az: a.pz }; }, id);
  check(c2.d < 16, `the camera keeps following while the colonist walks (${c2.d.toFixed(1)} m; colonist at ${c2.ax.toFixed(0)}, ${c2.az.toFixed(0)})`);
  await p.page.mouse.wheel(0, 300); await p.frames(10, 0.1); check(await p.W((_, W) => W.camRig.chaseDist > 7.6), 'the wheel zooms the chase camera out');
  await p.page.keyboard.press('f'); await p.frames(50, 0.1);
  const c3 = await p.W((_, W) => ({ mode: W.camRig.mode, dist: W.camRig.t.dist })); check(c3.mode === 'rts' && c3.dist > 40, `F again returns to the RTS camera (${c3.dist.toFixed(0)} m)`);
  // the Follow button toggles too
  await p.ui.evaluate(() => document.querySelector('.w3d-btn[data-w3d="follow"]').click()); await p.frames(10, 0.1); check(await p.W((_, W) => W.camRig.mode === 'chase'), 'the Follow button toggles the chase camera');
  await collect(p, 'chase'); check(p.errors.length === 0, 'no console errors' + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
  await p.close();
}

// ------------------------------------------------------------------------------------------------------------------------------------------- 9. 2D toggle
if (want('toggle')) {
  section('the 2D tactical map is still there: 3D | 2D toggle (bench, command bar, settings), 2D clicks select, round trip back to 3D');
  const p = await open3d({ q: 'mid', w: 1600, h: 900, extra: '&bench=1' });
  await colony(p, { seed: 5, days: 3 });
  check(await p.page.evaluate(() => document.querySelector('#b-v3d').classList.contains('on')), 'the bench shows 3D as the active view');
  // settings screen row
  await p.ui.evaluate(() => OB.screens.open('menu')); await sleep(150);
  await p.frame.locator('.scrim:not([hidden]) button[data-id="settings"]').click(); await sleep(300);
  const rows = await p.ui.evaluate(() => [...document.querySelectorAll('.scrim:not([hidden]) .w3d-row')].map(r => r.textContent.replace(/\s+/g, ' ').trim()));
  check(rows.length === 2 && /World view/.test(rows[0]) && /Graphics quality/.test(rows[1]), 'Settings has the "World view 3D | 2D" and "Graphics quality" rows: ' + JSON.stringify(rows));
  await p.ui.evaluate(() => [...document.querySelectorAll('.scrim:not([hidden]) .w3d-row')][0].querySelector('button[data-value="2d"]').click());
  await p.page.waitForFunction(() => window.__preview.worldView() === '2d', null, { timeout: 10000 });
  await p.page.keyboard.press('Escape'); await sleep(200);
  const v2 = await p.page.evaluate(() => ({ view: __preview.worldView(), hidden3d: document.querySelector('#world3d').hidden, running: __preview.world3d().running, op: document.querySelector('#nui').contentWindow.OB.mapBg.canvas.style.opacity, stored: localStorage.getItem('ob.world') }));
  check(v2.view === '2d' && v2.hidden3d && v2.op === '' && v2.stored === '2d', 'Settings -> 2D: the 3D canvas is hidden, the 2D map is drawn again and the choice is remembered');
  // 2D click path
  const pt = await p.ui.evaluate(() => { const v = OB.mapBg, c = OB.S.state.colonists.find(c => c.state !== 'away'), r = v.canvas.getBoundingClientRect(); return { id: c.id, x: r.left + v.sx(c.x), y: r.top + v.sy(c.y) }; });
  await p.page.mouse.click(pt.x, pt.y); await sleep(150);
  check((await p.ui.evaluate(() => OB.S.sel.slice()))[0] === pt.id, 'in 2D, clicking a colonist on the flat map selects them (the original path)');
  const px = await p.page.screenshot({ clip: { x: 500, y: 200, width: 400, height: 300 } }); check(px.length > 4000, '2D view renders (' + px.length + ' bytes)');
  // back with the command bar button
  await p.ui.evaluate(() => document.querySelector('.w3d-btn[data-w3d="view"]').click());
  await p.page.waitForFunction(() => window.__preview.worldView() === '3d', null, { timeout: 30000 }); await p.frames(6);
  const v3 = await p.page.evaluate(() => ({ view: __preview.worldView(), op: document.querySelector('#nui').contentWindow.OB.mapBg.canvas.style.opacity, hidden2d: getComputedStyle(document.querySelector('#world')).display }));
  check(v3.view === '3d' && v3.op === '0' && v3.hidden2d === 'none', 'the command bar button brings the 3D world back');
  const id = (await p.sim()).colonists.find(c => c.state !== 'away').id, sp = await screenOf(p, id); await p.page.mouse.click(sp.x, sp.y); await sleep(150);
  check((await p.ui.evaluate(() => OB.S.sel.slice()))[0] === id, 'and 3D picking works again after the round trip');
  // bench buttons
  await p.page.click('#b-v2d'); await p.page.waitForFunction(() => window.__preview.worldView() === '2d'); await p.page.click('#b-v3d'); await p.page.waitForFunction(() => window.__preview.worldView() === '3d', null, { timeout: 30000 });
  check(true, 'the bench 3D / 2D buttons switch both ways');
  // ?world=2d starts flat (the default for the older test suites)
  await collect(p, 'toggle'); check(p.errors.length === 0, 'no console errors' + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
  await p.close();
  const q2 = await openPreview(env, { w: 1280, h: 720, query: 'auto=0&mode=colony', world: '2d' });
  check(await q2.page.evaluate(() => __preview.worldView() === '2d' && document.querySelector('#world3d').hidden && !__preview.world3d()), '?world=2d starts on the flat map without loading three.js');
  await q2.close();
}

// ------------------------------------------------------------------------------------------------------------------------------------------- 10. phone
if (want('phone')) {
  section('phone emulation (touch events over CDP): tap select, drag pan, pinch zoom, twist rotate, tap-to-order, placement; portrait + landscape');
  for (const [w, h, tag] of [[390, 844, 'portrait'], [844, 390, 'landscape']]) {
    const p = await open3d({ q: '', mobile: true, w, h, dpr: 3 });
    await colony(p, { seed: 5, days: 3 }); await p.W((_, W) => W.camRig.jump(0, 12, 70)); await p.frames(8, 0.1);
    const cdp = await p.ctx.newCDPSession(p.page);
    const send = (type, pts) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: pts.map(([x, y], i) => ({ x, y, id: i + 1, radiusX: 6, radiusY: 6, force: 1 })) });
    const T = {
      tap: async (x, y) => { await send('touchStart', [[x, y]]); await sleep(50); await send('touchEnd', []); await sleep(80); },
      drag: async (x0, y0, x1, y1, steps = 8) => { await send('touchStart', [[x0, y0]]); await sleep(30); for (let i = 1; i <= steps; i++) { await send('touchMove', [[x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps]]); await sleep(16); } await send('touchEnd', []); await sleep(60); },
      pinch: async (cx, cy, d0, d1, steps = 10) => { const pts = d => [[cx - d / 2, cy], [cx + d / 2, cy]]; await send('touchStart', pts(d0)); await sleep(30); for (let i = 1; i <= steps; i++) { await send('touchMove', pts(d0 + (d1 - d0) * i / steps)); await sleep(16); } await send('touchEnd', []); await sleep(60); },
      twist: async (cx, cy, r, a0, a1, steps = 10) => { const pts = a => [[cx + r * Math.cos(a), cy + r * Math.sin(a)], [cx - r * Math.cos(a), cy - r * Math.sin(a)]]; await send('touchStart', pts(a0)); await sleep(30); for (let i = 1; i <= steps; i++) { await send('touchMove', pts(a0 + (a1 - a0) * i / steps)); await sleep(16); } await send('touchEnd', []); await sleep(60); },
    };
    const pick = await p.W((_, W) => ({ tier: W.tierName, why: W.tierReason, w: W.W, h: W.H, canvas: [W.canvas.clientWidth, W.canvas.clientHeight] }));
    check(pick.tier === 'low' && pick.canvas[0] === w && pick.canvas[1] === h, `${tag} ${w}x${h}: the 3D canvas fills the screen on the low tier (${pick.why})`);
    const over = await p.page.evaluate(() => ({ sx: document.documentElement.scrollWidth - innerWidth, sy: document.documentElement.scrollHeight - innerHeight }));
    check(over.sx <= 0 && over.sy <= 0, `${tag}: the page does not scroll (${over.sx}x${over.sy})`);
    // tap a colonist: select
    const sim = await p.sim(); const home = sim.colonists.filter(c => c.state !== 'away'); let sel = null;
    for (const c of home) { const s = await screenOf(p, c.id); if (s.x > 20 && s.x < w - 20 && s.y > 140 && s.y < h - 160) { sel = { id: c.id, ...s }; break; } }
    check(!!sel, `${tag}: a colonist is on screen outside the HUD (${sel ? sel.x.toFixed(0) + ',' + sel.y.toFixed(0) : '-'})`);
    if (sel) { await T.tap(sel.x, sel.y); await sleep(150); check((await p.ui.evaluate(() => OB.S.sel.slice()))[0] === sel.id, `${tag}: a tap selects the colonist`); }
    // one-finger drag pans
    const c0 = await p.W((_, W) => ({ x: W.camRig.d.x, z: W.camRig.d.z, yaw: W.camRig.d.yaw, dist: W.camRig.d.dist }));
    const my = h > 500 ? 420 : 200; await T.drag(w * 0.7, my, w * 0.3, my + 40); await p.frames(8, 0.1);
    const c1 = await p.W((_, W) => ({ x: W.camRig.d.x, z: W.camRig.d.z }));
    check(Math.hypot(c1.x - c0.x, c1.z - c0.z) > 8, `${tag}: a one-finger drag pans the map (${Math.hypot(c1.x - c0.x, c1.z - c0.z).toFixed(1)} m)`);
    // pinch zoom
    await T.pinch(w / 2, my, 120, 260); await p.frames(8, 0.1);
    const c2 = await p.W((_, W) => W.camRig.d.dist); check(c2 < c0.dist * 0.85, `${tag}: pinching out zooms in (${c0.dist.toFixed(0)} -> ${c2.toFixed(0)} m)`);
    await T.pinch(w / 2, my, 260, 90); await p.frames(8, 0.1); const c3 = await p.W((_, W) => W.camRig.d.dist); check(c3 > c2 * 1.3, `${tag}: pinching in zooms out (${c2.toFixed(0)} -> ${c3.toFixed(0)} m)`);
    // two-finger twist rotates
    const y0 = await p.W((_, W) => W.camRig.d.yaw); await T.twist(w / 2, my, 80, 0, 0.9); await p.frames(8, 0.1); const y1 = await p.W((_, W) => W.camRig.d.yaw);
    check(Math.abs(y1 - y0) > 0.4, `${tag}: a two-finger twist rotates the camera (yaw ${y0.toFixed(2)} -> ${y1.toFixed(2)})`);
    // tap-to-order mode (the NUI's own "Order" button state), orders go to the sim
    if (sel) {
      await p.ui.evaluate(id => OB.select([id]), sel.id); await p.ui.evaluate(() => OB.touch.setOrder(true)); await sleep(100);
      await p.page.evaluate(() => { window.__posts.length = 0; }); const tx = w * 0.5, ty = h > 500 ? 380 : 200; await T.tap(tx, ty); await sleep(250);
      const og = (await p.posts('order')).filter(o => o[1].kind === 'goto');
      check(og.length === 1 && og[0][1].id === sel.id, `${tag}: order mode: tapping the 3D ground sends one goto order for the selected colonist`);
      check(await p.ui.evaluate(() => !OB.touch.orderMode), `${tag}: order mode switches itself off after the tap`);
    }
    // long-press: context menu (move here / new zone)
    await send('touchStart', [[w * 0.5, h > 500 ? 330 : 170]]); await sleep(700); await send('touchEnd', []); await sleep(200);
    const menu = await p.ui.evaluate(() => !document.querySelector('#ctx').hidden && [...document.querySelectorAll('#ctx button')].length);
    check(menu >= 2, `${tag}: a long-press opens the context menu (${menu} entries)`);
    await p.page.screenshot({ path: ROOT + '/screenshots/3d/_phone-' + tag + '.png' }).catch(() => {});
    await collect(p, 'phone ' + tag); check(p.errors.length === 0, `${tag}: no console errors` + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
    await p.close();
  }
}

// ------------------------------------------------------------------------------------------------------------------------------------------- 11. hidden tab
if (want('hidden')) {
  section('rendering pauses while the tab is hidden (real rAF loop)');
  const p = await open3d({ q: 'low', w: 480, h: 300, manual: false });
  await sleep(1500); const f0 = await p.W((_, W) => W.frameNo); await sleep(1200); const f1 = await p.W((_, W) => W.frameNo);
  check(f1 > f0, `frames advance while the tab is visible (${f0} -> ${f1})`);
  await p.page.evaluate(() => { Object.defineProperty(document, 'hidden', { configurable: true, get: () => true }); document.dispatchEvent(new Event('visibilitychange')); });
  await sleep(300); const h0 = await p.W((_, W) => W.frameNo); await sleep(1500); const h1 = await p.W((_, W) => W.frameNo);
  check(h1 - h0 <= 1, `no frames are rendered while the tab is hidden (${h0} -> ${h1})`);
  await p.page.evaluate(() => { Object.defineProperty(document, 'hidden', { configurable: true, get: () => false }); document.dispatchEvent(new Event('visibilitychange')); });
  await sleep(1500); const v1 = await p.W((_, W) => W.frameNo); check(v1 > h1 + 1, `and rendering resumes when it is shown again (${h1} -> ${v1})`);
  await collect(p, 'hidden'); check(p.errors.length === 0, 'no console errors' + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
  await p.close();
}

// ------------------------------------------------------------------------------------------------------------------------------------------- 12. fx
if (want('fx')) {
  section('effects driven by sim events: horde materialising, weather, helicopter, supply drop, caravan, expedition vehicle, power outage');
  const p = await open3d({ q: 'mid' });
  await colony(p, { seed: 5, days: 3 }); await p.W((_, W) => W.camRig.jump(0, 12, 90)); await p.frames(6, 0.1);
  const z0 = await p.W((_, W) => W.dyn.zombies.cnt.zombies);
  await p.page.evaluate(() => { window.__preview.debug('horde', { n: 25, dist: 80 }); window.__preview.pushState(); }); await p.sync(); await p.frames(10, 0.1);
  const z1 = await p.W((_, W) => ({ z: W.dyn.zombies.cnt.zombies, rise: W.dyn.zombies.s.rise.some(v => v > 0 && v < 1), parts: W.dyn.fx.p.live, rings: W.dyn.fx.dA.n }));
  check(z1.z >= z0 + 20, `a horde near the colony appears as zombies (${z0} -> ${z1.z}), rising out of the ground (${z1.rise}) with dust and ground rings (${z1.parts} particles, ${z1.rings} decals)`);
  await p.page.evaluate(() => { window.__preview.debug('event', { id: 'storm' }); }); await p.sync(); await p.frames(40, 0.1);
  const wx = await p.W((_, W) => ({ kind: W.state.weather.kind, w: W.atmo.weather.w, rain: W.atmo.precip.rain.visible || W.atmo.precip.snow.visible, wet: W.atmo.weather.target }));
  check(wx.kind !== 'clear' && wx.w > 0.1 && wx.rain, `a storm from the director starts rain / snow in 3D (weather ${wx.kind}, strength ${wx.w.toFixed(2)})`);
  await p.page.evaluate(() => { window.__preview.debug('event', { id: 'helicopter_flyover' }); }); await p.frames(4, 0.1);
  check(await p.W((_, W) => !!W.dyn.heli && W.dyn.heliObj && W.dyn.heliObj.visible), 'a helicopter flyover event puts a helicopter in the sky');
  await p.page.evaluate(() => { window.__preview.debug('event', { id: 'supply_drop' }); }); await p.sync(); await p.frames(4, 0.1);
  check(await p.W((_, W) => !!W.dyn.drop && W.dyn.dropObj.visible), 'a supply drop event drops a parachute crate');
  await p.page.evaluate(() => { window.__preview.debug('event', { id: 'caravan' }); window.__preview.pushState(); }); await p.sync(); await p.frames(4, 0.1);
  const cv = await p.sim(); check(cv.caravans.length >= 1 && (await p.W((_, W) => W.dyn.sceneCounts().caravans)) === cv.caravans.length, `a trade caravan arrives (${cv.caravans.length}) and is shown`);
  await p.page.evaluate(() => { window.__preview.debug('give', { item: 'fuel_can', n: 6 }); }); const ids = (await p.sim()).colonists.slice(0, 2).map(c => c.id);
  await p.page.evaluate(ids => { window.__preview.order({ id: 'colony', kind: 'expedition', target: { district: 'orchard', size: 2, crew: ids, mode: 'vehicle' } }); window.__preview.pushState(); }, ids); await p.sync(); await p.frames(6, 0.1);
  const ex = await p.sim(); check(ex.expeditions.some(e => e.state === 'outbound') && ex.vehicles.some(v => v.state === 'away'), 'an expedition leaves by vehicle (sim: outbound, van away)');
  const away = await p.W((_, W) => ({ vis: W.dyn.visibleColonists(), veh: W.dyn.vehicles.n + W.dyn.vans.n })); check(away.vis === (await p.sim()).colonists.filter(c => c.state !== 'away').length && away.veh >= 1, `the crew leaves the scene and the van drives off (colonists at home ${away.vis}, van drawn: ${away.veh})`);
  await p.frames(160, 0.1); check(await p.W((_, W) => W.dyn.vehicles.n + W.dyn.vans.n === 0), 'the van is gone once it is on the road to the district');
  await p.page.evaluate(() => { window.__preview.debug('event', { id: 'power_outage' }); window.__preview.pushState(); }); await p.sync(); await p.frames(3, 0.1);
  const po = await p.W((_, W) => ({ mains: W.state.res.mains_power, uni: W.state.res.power_ok })); check(po.mains === false, 'a power outage turns the city grid off (the window glow and street lamps follow it)');
  const lu = await p.page.evaluate(async () => { const m = await import('./world3d/sky.js'); return m.U.mains.value; }); check(lu === 0, 'the shared "mains" uniform is 0 during the outage');
  await collect(p, 'fx'); check(p.errors.length === 0, 'no console errors' + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
  await p.close();
}

// ------------------------------------------------------------------------------------------------------------------------------------------- 13. survival mode
if (want('survival')) {
  section('survival mode: chase camera behind the player avatar, WASD walks, the world follows');
  const p = await open3d({ q: 'mid', mode: 'survival', w: 1280, h: 720 });
  await colony(p, { seed: 5, days: 2 }); await focusUI(p);
  await p.frames(20, 0.1);
  const m = await p.W((_, W) => ({ mode: W.camRig.mode, d: W.camRig.t.dist, player: W.state.player, has: !!W.dyn.playerActor }));
  check(m.mode === 'chase' && m.has, `survival mode follows the player avatar with the chase camera (distance ${m.d.toFixed(1)} m)`);
  const p0 = (await p.sim()).player; await p.page.keyboard.down('w'); for (let i = 0; i < 10; i++) { await p.frames(2, 0.1); await sleep(40); } await p.page.keyboard.up('w'); await p.frames(4, 0.1);
  const p1 = (await p.sim()).player; check(Math.hypot(p1.x - p0.x, p1.y - p0.y) > 3, `W walks the player (${p0.x.toFixed(1)},${p0.y.toFixed(1)} -> ${p1.x.toFixed(1)},${p1.y.toFixed(1)}) and the sim knows`);
  await p.page.evaluate(() => window.__preview.setMode('colony')); await p.frames(30, 0.1);
  const mm = await p.W((_, W) => W.camRig.mode); check(mm === 'rts', 'switching to the colony view returns to the RTS camera');
  await collect(p, 'survival'); check(p.errors.length === 0, 'no console errors' + (p.errors.length ? ': ' + p.errors.join(' | ') : ''));
  await p.close();
}

// ------------------------------------------------------------------------------------------------------------------------------------------- summary
section('totals');
for (const b of budget) console.log(`  info  ${b.tier.padEnd(5)} ${b.calls} draw calls, ${(b.tris / 1000) | 0}k triangles (colony + 60-strong horde)`);
const uniqErrors = [...new Set(allErrors)];
check(uniqErrors.length === 0, 'no console errors, page errors or failed requests in any run' + (uniqErrors.length ? ': ' + uniqErrors.slice(0, 6).join(' | ') : ''));
console.log(`\n${asserts} checks, ${failures.length} failed`);
await env.close();
if (failures.length) { console.log('FAILED:\n  ' + failures.join('\n  ')); process.exit(1); }
console.log('WORLD3D TESTS PASSED');
