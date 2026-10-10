// Outbreak 3D: everything that changes with the sim. `sync(state)` (a few times a second) mirrors the Lua state into scene objects: colonist actors, building kits,
// zones / piles / vehicles / caravans, hordes (-> ZombieField), raids, the player; `update(dt)` animates them (smoothing, poses, particles, selection rings, labels).
// Input helpers (pick, ground point) live here too, because only this module knows what is on screen.
import * as THREE from 'three';
import { clamp, lerp, damp, dampAng, angDiff, hashStr, hash2, rng, PI, TAU, sstep } from './util.js';
import { U } from './sky.js';
import { buildKits, KitSet } from './structures.js';
import { Particles, Decals, Beams, LightPool } from './fx.js';
import { ZombieField, ProcPeds, humanoidGeo } from './peds.js';
import { loadPrefabs, ColonistActor, colonistLook } from './colonists.js';
import { bake } from './models.js';
import { patch } from './terrain.js';

const FAC = { rustjaw: 0xff8a3d, hollow_choir: 0xb78cff, tallow: 0xf6d04d, cinder: 0xff5d6c, lantern: 0x35d39a };
const STATE_COL = { idle: 0x9aa7bd, working: 0x6ea8ff, sleeping: 0x8b7bff, guarding: 0x35d39a, drafted: 0xf6b44f, downed: 0xff5d6c, away: 0x5d6a80 };
const GARAGE = { x: 30, z: 20 }; // sim garage (30,-20) in three space
const c3 = hex => { const c = new THREE.Color(hex); return [c.r, c.g, c.b]; };
const _col = new THREE.Color();

// small instanced model set (vehicles, campfire GLB): parts share one matrix list
class SmallInst {
  constructor(parts, cap) {
    this.cap = cap; this.n = 0; this.group = new THREE.Group(); this.meshes = [];
    for (const p of parts) { const m = new THREE.InstancedMesh(p.geometry, p.material, cap); m.count = 0; m.frustumCulled = false; m.castShadow = true; m.receiveShadow = true; m.instanceColor = new THREE.InstancedBufferAttribute(new Float32Array(cap * 3), 3); this.group.add(m); this.meshes.push(m); }
  }
  begin() { this.n = 0; }
  put(x, y, z, rot, s, col) {
    if (this.n >= this.cap) return; const k = this.n++, c = Math.cos(rot), sn = Math.sin(rot);
    for (const m of this.meshes) {
      const M = m.instanceMatrix.array, o = k * 16; M[o] = c * s; M[o + 1] = 0; M[o + 2] = -sn * s; M[o + 3] = 0; M[o + 4] = 0; M[o + 5] = s; M[o + 6] = 0; M[o + 7] = 0; M[o + 8] = sn * s; M[o + 9] = 0; M[o + 10] = c * s; M[o + 11] = 0; M[o + 12] = x; M[o + 13] = y; M[o + 14] = z; M[o + 15] = 1;
      const C = m.instanceColor.array; if (col) { C[k * 3] = col[0]; C[k * 3 + 1] = col[1]; C[k * 3 + 2] = col[2]; } else { C[k * 3] = C[k * 3 + 1] = C[k * 3 + 2] = 1; }
    }
  }
  end() { for (const m of this.meshes) { m.count = this.n; m.instanceMatrix.needsUpdate = true; m.instanceColor.needsUpdate = true; } }
}

export class Dynamic {
  constructor(W) {
    this.W = W; this.st = null; this.cat = null; this.actors = new Map(); this.dying = []; this.sel = new Set(); this.primary = null; this.hover = null; this.ghost = null; this.pings = [];
    this.prevB = new Map(); this.stTime = 0; this.hordes = []; this.raids = []; this.alertT = 0; this.shake = 0; this.heli = null; this.drop = null; this.flares = [];
    this.fireT = 0; this.bColl = []; this.counts = {}; this.dragRect = null; this.labelsOn = true; this.vehState = new Map(); this.rndFx = rng(77);
  }
  async init() {
    const W = this.W, T = W.tier, scene = W.scene; this.group = new THREE.Group(); this.group.name = 'dynamic'; scene.add(this.group);
    this.kits = buildKits(); const caps = { floor: 220, wallPost: 200, wallSeg: 420, pallet: 120, pile: 80, door: 64, bed: 64, crate: 40, barricade: 80 };
    this.kitSet = new KitSet(this.kits, caps); this.group.add(this.kitSet.group);
    this.fx = { p: new Particles(scene, T.fx), dA: new Decals(scene, 700, false), dG: new Decals(scene, 200, true), beams: new Beams(scene, 80), lights: new LightPool(scene, T.lights) };
    this.zombies = new ZombieField(T, W.models, scene);
    this.raiders = new ProcPeds(28, { rifle: true, pants: 0x2b2d2f, skin: 0xb08a70, hair: 0x1c1a18, shirt: 0xffffff }, 1); scene.add(this.raiders.group);
    this.folk = new ProcPeds(20, { shirt: 0xffffff, pants: 0x35383f, skin: 0xc9a48a, hair: 0x2b2420 }, 0); scene.add(this.folk.group);
    this.hasGlbColonists = loadPrefabs(W.models);
    // vehicles (pickup GLB with a cargo box = van) + hatchback for caravans
    this.vehParts = this.buildVehicleParts(); this.vehicles = new SmallInst(this.vehParts.pickup, 8); this.group.add(this.vehicles.group);
    this.vans = new SmallInst(this.vehParts.van, 4); this.group.add(this.vans.group);
    this.cars = new SmallInst(this.vehParts.car, 8); this.group.add(this.cars.group);
    const cf = W.models && W.models.has('campfire') ? bake(W.models.scene('campfire'), { height: 0.75, scale: 0, center: true }) : null;
    if (cf && cf.length) { this.campGlb = new SmallInst(cf.map(p => ({ geometry: p.geometry, material: p.material.clone() })), 40); this.group.add(this.campGlb.group); }
    this.labelEls = new Map(); this.labelUsed = new Set();
    this.tmp = { px: new Float32Array(3), ground: new THREE.Vector3(), nz: new Float32Array(48) };
  }
  rebuildPools() { /* tier changed: the heavy pools (zombies, particles) are rebuilt lazily by the next init; keep it simple */ }
  setCatalog(cat) { this.cat = cat; }
  objectCount() { return this.counts.total || 0; }

  buildVehicleParts() {
    const M = this.W.models, out = { pickup: [], van: [], car: [] };
    const fallback = (col, len) => { const g = new THREE.BoxGeometry(2.0, 1.2, len); g.translate(0, 0.9, 0); return [{ geometry: g, material: new THREE.MeshStandardMaterial({ color: col, roughness: 0.7 }) }]; };
    if (M && M.has('pickup')) {
      const parts = bake(M.scene('pickup'), { height: 1.75, center: true });
      if (parts.length) {
        // make the model face +z (headlights at the front)
        const hl = parts.find(p => p.material && /head/i.test(p.material.name || '')); let flip = false;
        if (hl) { const bb = new THREE.Box3().setFromBufferAttribute(hl.geometry.attributes.position); const all = new THREE.Box3(); for (const p of parts) all.union(new THREE.Box3().setFromBufferAttribute(p.geometry.attributes.position)); flip = (bb.min.z + bb.max.z) / 2 < (all.min.z + all.max.z) / 2; }
        const mk = () => parts.map(p => { const g = p.geometry.clone(); if (flip) g.rotateY(PI); return { geometry: g, material: p.material.clone() }; });
        out.pickup = mk(); const vp = mk(); const cargo = new THREE.BoxGeometry(2.15, 1.55, 2.5); cargo.translate(0, 1.55, flip ? 0.2 : -0.6); vp.push({ geometry: cargo, material: new THREE.MeshStandardMaterial({ color: 0xd8dad6, roughness: 0.6, metalness: 0.2 }) }); out.van = vp;
      }
    }
    if (!out.pickup.length) { out.pickup = fallback(0x3b6aa0, 4.6); out.van = fallback(0xd8dad6, 4.8); }
    if (M && M.has('hatchback')) { const parts = bake(M.scene('hatchback'), { height: 1.4, center: true }); out.car = parts.map(p => ({ geometry: p.geometry, material: p.material.clone() })); }
    if (!out.car.length) out.car = fallback(0xa83232, 3.8);
    for (const set of Object.values(out)) for (const p of set) { p.material.metalness = Math.min(p.material.metalness || 0, 0.3); if (p.material.transmission) p.material.transmission = 0; }
    return out;
  }

  // ------------------------------------------------------------------------------------------------ state mirror
  sync(st) {
    const W = this.W, first = !this.st; this.st = st; this.stTime = performance.now();
    if (st.res) { U.mains.value = st.res.mains_power === false ? 0 : 1; U.lamps.value = st.res.mains_power === false ? 0 : 1; }
    this.bIndex = new Map((st.buildings || []).map(b => [b.id, b])); this.syncBuildings(st); this.syncColonists(st); this.hordes = st.hordes || []; this.raids = st.raids || []; this.syncMisc(st);
    this.counts = { colonists: this.visibleColonists(), zombies: this.zombies.count(), hordes: this.hordes.length, raiders: this.raidersN || 0, buildings: this.kitCounts(), piles: (st.piles || []).length, zones: (st.zones || []).length, caravans: (st.caravans || []).length };
    this.counts.total = this.counts.colonists + this.counts.zombies;
    if (first) this.snap = true;
  }
  visibleColonists() { let n = 0; for (const a of this.actors.values()) if (a.root.visible) n++; return n; }
  kitCounts() { const c = this.kitSet.counts(); let built = 0, planned = 0; for (const [id, v] of this.prevB) { if (v.state === 'built') built++; else planned++; } return { built, planned, byType: c }; }

  syncBuildings(st) {
    const K = this.kitSet, W = this.W, gen = W.gen, seen = new Set(), now = performance.now(); K.clear();
    const list = st.buildings || [], nodes = [];
    for (const b of list) {
      const x = b.x, z = -b.y, y = gen.heightAt(x, z), built = b.state === 'built', hp = b.hp_max ? b.hp / b.hp_max : 1, h = hash2(Math.round(x * 7), Math.round(z * 7), hashStr(b.id) & 0xffff);
      const prog = built ? 1 : clamp(b.pct / 100, 0.03, 0.96), seed = (hashStr(b.id) % 997) / 997; seen.add(b.id);
      const prev = this.prevB.get(b.id);
      if (!prev) { if (!built) this.pings.push({ x, z, t: 0, kind: 'place', col: [0.3, 0.9, 1.0] }); else if (this.st && this.prevCount > 0) this.pings.push({ x, z, t: 0, kind: 'built', col: [0.3, 1, 0.6] }); }
      else if (prev.state !== 'built' && built) { this.pings.push({ x, z, t: 0, kind: 'built', col: [0.3, 1.0, 0.6] }); for (let i = 0; i < 3; i++) this.fx.p.dust(x, y + 0.4, z, 5, 1.6, 0.55); this.fx.p.spark(x, y + 1.0, z, 12, 0.8); }
      else if (built && prev.hp - hp > 0.03) { this.fx.p.spark(x, y + 1.2, z, 6, 0.7); this.fx.p.dust(x, y + 0.8, z, 3, 1.2, 0.5); }
      const rec = { x, y, z, rot: 0, prog, pow: 0, hp, seed, col: [1, 1, 1] };
      switch (b.bp) {
        case 'wall': case 'watchtower': nodes.push({ b, rec, x, z }); if (b.bp === 'watchtower') { rec.rot = Math.floor(h * 4) * PI / 2; rec.pow = 1; K.add('watchtower', rec); } break;
        case 'door': nodes.push({ b, rec, x, z }); break;
        case 'floor': rec.rot = 0; K.add('floor', rec); break;
        case 'bed': case 'medical_bed': rec.rot = Math.floor(h * 4) * PI / 2; if (b.bp === 'bed') { const hue = (hashStr(b.id) % 360) / 360; _col.setHSL(hue, 0.3, 0.62); rec.col = [_col.r * 1.3, _col.g * 1.3, _col.b * 1.3]; } rec.pow = b.powered ? 1 : 0; K.add(b.bp, rec); break;
        case 'campfire': rec.rot = h * TAU; rec.pow = built ? 1 : 0; if (!(built && this.campGlb)) K.add('campfire', rec); break;
        case 'workbench': case 'stove': rec.rot = Math.floor(h * 4) * PI / 2; rec.pow = b.powered ? 1 : 0; K.add(b.bp, rec); break;
        case 'generator': rec.rot = Math.floor(h * 4) * PI / 2; rec.pow = b.powered ? 1 : 0; K.add('generator', rec); break;
        case 'crate': rec.rot = (h - 0.5) * 0.5; K.add('crate', rec); break;
        case 'lamp': rec.rot = h * TAU; rec.pow = b.powered ? 1 : 0; K.add('lamp', rec); break;
        case 'radio_mast': rec.rot = h * TAU; rec.pow = b.powered ? 1 : 0; K.add('radio_mast', rec); break;
        case 'barricade': rec.rot = Math.floor(h * 8) * PI / 4; K.add('barricade', rec); break;
        default: rec.rot = Math.floor(h * 4) * PI / 2; if (K.recs[b.bp]) K.add(b.bp, rec);
      }
      this.prevB.set(b.id, { state: b.state, hp, x, z, bp: b.bp, y, rot: rec.rot });
    }
    for (const [id, p] of this.prevB) if (!seen.has(id)) { // destroyed or cancelled
      if (p.state === 'built' && this.prevCount > 0) { this.fx.p.dust(p.x, p.y + 0.8, p.z, 10, 2.4, 0.5); this.fx.p.spark(p.x, p.y + 1, p.z, 14, 1); for (let i = 0; i < 6; i++) this.fx.p.smoke(p.x, p.y + 0.6, p.z, 1.4, 0.3); this.shake = Math.max(this.shake, 0.25); this.pings.push({ x: p.x, z: p.z, t: 0, kind: 'lost', col: [1, 0.3, 0.2] }); }
      this.prevB.delete(id);
    }
    this.prevCount = list.length;
    // wall segments between neighbouring posts; doors take the direction of their wall neighbour
    const link = (a, b) => Math.hypot(a.x - b.x, a.z - b.z) < 3.3, N = nodes.length, deg = new Int16Array(N), nb = new Int16Array(N).fill(-1);
    for (let i = 0; i < N; i++) for (let j = i + 1; j < N; j++) {
      const a = nodes[i], b = nodes[j]; if (!link(a, b)) continue; deg[i]++; deg[j]++; if (nb[i] < 0) nb[i] = j; if (nb[j] < 0) nb[j] = i;
      if (a.b.bp === 'watchtower' && b.b.bp === 'watchtower') continue;
      const dx = b.x - a.x, dz = b.z - a.z, d = Math.hypot(dx, dz), seg = { x: (a.x + b.x) / 2, y: (a.rec.y + b.rec.y) / 2, z: (a.z + b.z) / 2, rot: Math.atan2(-dz, dx), sx: Math.max(0.2, d - 0.32), prog: Math.min(a.rec.prog, b.rec.prog), hp: (a.rec.hp + b.rec.hp) / 2, seed: (a.rec.seed + b.rec.seed) / 2, col: [1, 1, 1] };
      if (a.b.bp !== 'door' && b.b.bp !== 'door') K.add('wallSeg', seg); else { seg.sx = Math.max(0.2, d - 1.2); if (a.b.bp === 'door' && b.b.bp === 'door') seg.sx = 0.01; K.add('wallSeg', seg); }
    }
    for (let i = 0; i < N; i++) {
      const n = nodes[i], r = n.rec, bp = n.b.bp, o = nb[i] >= 0 ? nodes[nb[i]] : null, rot = o ? Math.atan2(-(o.z - n.z), o.x - n.x) : Math.floor(hash2(Math.round(n.x * 3), Math.round(n.z * 3), 5) * 2) * PI / 2;
      if (bp === 'wall') { K.add('wallPost', Object.assign({}, r, { rot: 0 })); if (deg[i] === 0) K.add('wallSeg', { x: n.x, y: r.y, z: n.z, rot, sx: 1.6, prog: r.prog, hp: r.hp, seed: r.seed, col: [1, 1, 1] }); }
      else if (bp === 'door') { r.rot = rot; K.add('door', r); }
    }
  }

  syncColonists(st) {
    const seen = new Set(); this.threatPos = this.findThreat(st);
    for (const c of st.colonists || []) {
      seen.add(c.id); let a = this.actors.get(c.id);
      if (!a) {
        const look = colonistLook(c.id); const wk = c.weapon && this.cat && this.cat.items[c.weapon] && this.cat.items[c.weapon].weapon;
        a = new ColonistActor(c.id, look, wk ? (wk.kind === 'ranged' ? 'rifle' : 'melee') : 'rifle'); a.px = c.x; a.pz = -c.y; a.yaw = (hashStr(c.id) % 628) / 100; a.vel = 0; a.lastX = a.px; a.lastZ = a.pz; a.fresh = true; this.actors.set(c.id, a); this.W.scene.add(a.root);
        if (!this.snap) { this.fx.p.dust(a.px, 0.3, a.pz, 6, 1.4, 0.55); this.pings.push({ x: a.px, z: a.pz, t: 0, kind: 'join', col: [0.4, 0.8, 1] }); }
      }
      a.c = c; a.tx = c.x; a.tz = -c.y; if (this.cat && c.weapon && this.cat.items[c.weapon]) { const wk = this.cat.items[c.weapon].weapon; a.weaponKind = wk && wk.kind === 'ranged' ? 'rifle' : 'melee'; }
    }
    for (const [id, a] of this.actors) if (!seen.has(id)) {
      this.actors.delete(id);
      const dead = (st.dead || []).find(d => d.id === id); a.deadT = 0; a.downPose = true; if (dead || true) { this.dying.push(a); this.fx.p.blood(a.px, 0.8, a.pz, 14, 4); }
    }
  }
  findThreat(st) { // nearest hostile to the base: horde in assault/seek within 160, any raid within 160
    let best = null, bd = 1e9; const test = (x, z) => { const d = Math.hypot(x, z); if (d < bd) { bd = d; best = { x, z, d }; } };
    for (const h of st.hordes || []) if (h.state === 'assault' || h.state === 'seek' || Math.hypot(h.x, h.y) < 130) test(h.x, -h.y);
    for (const r of st.raids || []) test(r.x, -r.y);
    return best && best.d < 190 ? best : null;
  }
  syncMisc(st) { this.W.atmo && 0; }

  // ------------------------------------------------------------------------------------------------ events from the host
  onEvents(list) {
    for (const ev of list || []) {
      switch (ev.type) {
        case 'spawn_horde': this.pings.push({ x: ev.pos.x, z: -ev.pos.y, t: 0, kind: 'horde', col: [1, 0.2, 0.15] }); break;
        case 'building_destroyed': break;
        case 'loot_spawn': if (ev.source === 'supply_drop' && ev.pos) this.startDrop(ev.pos.x, -ev.pos.y); break;
        case 'play_alert': if (ev.kind === 'helicopter') this.startHeli(); else if (ev.kind === 'raid_incoming') this.flares.push({ t: 0, x: 0, z: 0, col: [1, 0.6, 0.2] }); break;
        case 'weather': this.W.atmo.setWeather(ev.kind); break;
        case 'colonist_died': this.pings.push({ x: ev.pos.x, z: -ev.pos.y, t: 0, kind: 'lost', col: [1, 0.2, 0.2] }); break;
        default: break;
      }
    }
  }
  startHeli() { const a = this.rndFx() * TAU; this.heli = { t: 0, a, life: 14 }; }
  startDrop(x, z) { this.drop = { x, z, t: 0 }; }

  // ------------------------------------------------------------------------------------------------ per frame
  update(dt, focus) {
    const W = this.W, st = this.st, fx = this.fx, gen = W.gen, night = U.night.value, camT = W.camRig.t; this.t = (this.t || 0) + dt;
    fx.dA.begin(); fx.dG.begin(); fx.beams.begin(); fx.lights.begin(); this.vehicles.begin(); this.vans.begin(); this.cars.begin(); if (this.campGlb) this.campGlb.begin(); this.folk.begin();
    if (st) {
      this.updateActors(dt, focus, night); this.updateHordes(dt, focus, night); this.updateRaids(dt); this.updateBuildingsFx(dt, focus, night); this.updateZonesPiles(dt, night); this.updateVehicles(dt, focus); this.updateAmbient(dt, night, focus);
    }
    this.updateOverlays(dt, focus, night);
    this.vehicles.end(); this.vans.end(); this.cars.end(); if (this.campGlb) this.campGlb.end(); this.folk.end();
    this.kitSet.flush(); fx.dA.end(); fx.dG.end(); fx.beams.end(); fx.lights.end(); fx.p.update(dt, night);
    if (this.shake > 0.01) { W.camRig.shake = Math.max(W.camRig.shake, this.shake * 0.5); this.shake *= 0.92; }
  }
  groundY(x, z) { return this.W.gen.heightAt(x, z); }

  // ---- colonists
  poseFor(a, c, moving, threatNear) {
    if (c.downed) return 'down'; if (c.state === 'sleeping') return 'sleep';
    if (c.drafted || c.state === 'guarding' || c.job === 'guard') return threatNear ? 'aim' : 'guard';
    const j = c.job, carryJ = j === 'haul' || j === 'deliver' || j === 'unload' || j === 'refuel';
    if (moving) return carryJ ? 'carry' : 'walk';
    switch (j) { case 'build': case 'repair': case 'craft': return 'hammer'; case 'cook': return 'cook'; case 'haul': case 'deliver': case 'unload': case 'refuel': return 'carry'; case 'tend': case 'medicate': case 'feed': case 'amputate': return 'medic'; case 'eat': case 'drink': return 'eat'; case 'wander': case 'binge': return 'stagger'; default: return 'idle'; }
  }
  nearestBuilding(x, z, r, pred) { let best = null, bd = r * r; for (const [id, p] of this.prevB) { if (pred && !pred(p)) continue; const d = (p.x - x) ** 2 + (p.z - z) ** 2; if (d < bd) { bd = d; best = p; } } return best; }
  updateActors(dt, focus, night) {
    const W = this.W, st = this.st, fx = this.fx, T = this.threatPos; this.fireT -= dt; let fired = false;
    const near = this.nearestBuilding;
    for (const a of this.actors.values()) {
      const c = a.c; if (!c) continue;
      const away = c.state === 'away'; a.root.visible = !away; if (away) continue;
      let tx = a.tx, tz = a.tz, bedY = 0, bedRot = null;
      if (c.state === 'sleeping') { const bed = near.call(this, tx, tz, 7, p => p.bp === 'bed' || p.bp === 'medical_bed'); if (bed) { tx = bed.x; tz = bed.z; bedY = 0.5; bedRot = bed.rot; } }
      const dx = tx - a.px, dz = tz - a.pz, dist = Math.hypot(dx, dz);
      if (dist > 140 || a.fresh) { a.px = tx; a.pz = tz; a.fresh = false; }
      else if (dist > 0.02) { const vmax = dist > 10 ? 11 : dist > 2.5 ? 4.6 : 2.0, sp = Math.min(dist * 2.8, vmax), step = Math.min(dist, sp * dt); a.px += dx / dist * step; a.pz += dz / dist * step; const v = step / Math.max(dt, 1e-4); a.vel = damp(a.vel || 0, v, 8, dt); if (v > 0.5) a.yaw = dampAng(a.yaw, Math.atan2(dx, dz), 9, dt); }
      else a.vel = damp(a.vel || 0, 0, 8, dt);
      const moving = a.vel > 0.9, threatNear = !!(T && T.d < 120);
      const pose = this.poseFor(a, c, moving, threatNear);
      // facing
      if (!moving) {
        let fyaw = null;
        if (pose === 'sleep' && bedRot != null) fyaw = bedRot;
        else if (pose === 'aim' && T) fyaw = Math.atan2(T.x - a.px, T.z - a.pz);
        else if (pose === 'guard') fyaw = Math.atan2(a.px, a.pz);
        else if (pose === 'hammer' || pose === 'cook' || pose === 'carry' || pose === 'medic') { const b = this.nearestBuilding(a.px, a.pz, 5.5, pose === 'cook' ? (p => p.bp === 'campfire' || p.bp === 'stove') : null); if (b) fyaw = Math.atan2(b.x - a.px, b.z - a.pz); }
        if (fyaw != null) a.yaw = dampAng(a.yaw, fyaw, pose === 'sleep' ? 20 : 6, dt);
      }
      a.animate(dt, a.vel, pose, 0);
      const gy = this.groundY(a.px, a.pz) + (pose === 'sleep' ? bedY : 0);
      a.root.position.set(a.px, gy, a.pz); a.root.rotation.y = a.yaw;
      // muzzle flashes: armed guards shoot at the nearest zombie while a siege is going on
      if ((pose === 'aim') && a.weaponKind === 'rifle' && T && T.d < 110 && this.fireT <= 0 && Math.random() < 0.4) {
        fired = true; const mp = a.muzzle; fx.p.muzzle(mp.x, mp.y, mp.z, Math.sin(a.yaw), Math.cos(a.yaw)); fx.p.spark(mp.x + Math.sin(a.yaw) * 0.4, mp.y, mp.z + Math.cos(a.yaw) * 0.4, 2, 0.4);
        fx.lights.put(mp.x, mp.y + 0.3, mp.z, 0xffc070, 18, 26); a.flash = 0.08;
        const nz = this.zombies.nearest(a.px, a.pz, 24, this.tmp.nz); if (nz) { let bi = 0, bd = 1e9; for (let i = 0; i < nz; i++) { const q = (this.tmp.nz[i * 2] - a.px) ** 2 + (this.tmp.nz[i * 2 + 1] - a.pz) ** 2; if (q < bd) { bd = q; bi = i; } } fx.p.blood(this.tmp.nz[bi * 2], 1.1, this.tmp.nz[bi * 2 + 1], 3, 2.5); }
        this.pings.push({ x: a.px + Math.sin(a.yaw) * 6, z: a.pz + Math.cos(a.yaw) * 6, t: 0, kind: 'noise', col: [1, 0.85, 0.5], r: 5 + Math.random() * 3 });
      }
      // selection / state rings
      const sel = this.sel.has(c.id), hov = this.hover && this.hover.kind === 'colonist' && this.hover.id === c.id, prim = this.primary === c.id;
      const sc = STATE_COL[c.downed ? 'downed' : c.drafted ? 'drafted' : c.state] || 0x9aa7bd; _col.setHex(sc);
      fx.dA.ring(a.px, gy + 0.14, a.pz, 0.62, _col.r, _col.g, _col.b, 0.55, 0.07);
      if (sel) { const p = prim ? [1, 0.83, 0.54] : [1, 1, 1]; fx.dA.ring(a.px, gy + 0.15, a.pz, 0.95 + 0.04 * Math.sin(this.t * 4), p[0], p[1], p[2], 0.95, 0.1); }
      if (hov && !sel) fx.dA.ring(a.px, gy + 0.15, a.pz, 0.9, 0.9, 0.95, 1, 0.7, 0.07);
      if (c.drafted) fx.dA.ring(a.px, gy + 0.15, a.pz, 1.2, 1, 0.7, 0.3, 0.6, 0.06, 0.6);
      if (c.downed || c.bleeding > 0.05) { if (Math.random() < dt * 3) fx.p.blood(a.px, gy + 0.3, a.pz, 1, 0.6); }
      // blob shadow when the shadow map is off
      if (W.tier.shadow === 0) fx.dA.put(a.px, gy + 0.1, a.pz, 1.1, 0.7, a.yaw, 0, 0, 0, 0.35, 0, 0, 1);
    }
    // corpses of colonists that died: lie there a while, then sink
    for (let i = this.dying.length - 1; i >= 0; i--) {
      const a = this.dying[i]; a.deadT += dt; if (a.deadT > 25) { this.W.scene.remove(a.root); a.dispose(); this.dying.splice(i, 1); continue; }
      a.animate(dt, 0, 'down', 0); a.root.visible = true; a.setColor(_col.setRGB(0.55, 0.5, 0.5)); a.root.position.set(a.px, this.groundY(a.px, a.pz) - Math.max(0, a.deadT - 20) * 0.2, a.pz); a.root.rotation.y = a.yaw;
    }
    if (fired) this.fireT = 0.09 + Math.random() * 0.2;
  }

  // ---- zombies
  updateHordes(dt, focus, night) {
    const W = this.W, fx = this.fx, st = this.st, z = this.zombies;
    const wallR = bearing => { let r = 0; const cx = Math.cos(bearing), cz = Math.sin(bearing); for (const [id, p] of this.prevB) { if (p.bp !== 'wall' && p.bp !== 'barricade' && p.bp !== 'door' && p.bp !== 'watchtower') continue; const d = Math.hypot(p.x, p.z); const ang = Math.atan2(p.z, p.x); if (Math.abs(angDiff(ang, bearing)) < 0.7 && d > r) r = d; } return r > 0 ? r : 42; };
    z.update(dt, this.hordes, { x: focus.x, z: focus.z }, wallR, (x, zz) => this.groundY(x, zz));
    for (const ev of z.events) { if (ev.type === 'spawn') { if (Math.random() < 0.5) fx.p.dust(ev.x, this.groundY(ev.x, ev.z) + 0.2, ev.z, 3, 1.4, 0.4); } else if (ev.type === 'kill') { fx.p.blood(ev.x, 0.9, ev.z, 5, 3); fx.p.dust(ev.x, 0.3, ev.z, 2, 1, 0.5); } }
    z.events.length = 0;
    // hordes: ground pulse, attraction line, beacon for the far ones
    for (const h of this.hordes) {
      const x = h.x, zz = -h.y, d = Math.hypot(x - focus.x, zz - focus.z), y = this.groundY(x, zz), assault = h.state === 'assault', seek = h.state === 'seek', R = 4 + Math.sqrt(h.size) * 2.2;
      const k = 0.55 + 0.45 * Math.sin(this.t * (assault ? 6 : 2.2) + hashStr(h.id));
      fx.dA.ring(x, y + 0.2, zz, R * (0.9 + 0.12 * k), 1, assault ? 0.15 : 0.28, 0.2, 0.38 + 0.2 * k, assault ? 0.5 : 0.3, 2.5);
      if (seek) { const hx = h.hx, hz = -h.hy, l = 75 + 25 * Math.sin(this.t * 3); fx.dA.put(x + hx * (R + l / 2), y + 0.2, zz + hz * (R + l / 2), l, 2.2, Math.atan2(-hz, hx), 1, 0.4, 0.2, 0.6, 0.4, 3, 2); }
      if (d > 140) fx.beams.put(x, y, zz, 55 + Math.sqrt(h.size) * 12, 1, 0.22, 0.14, 7 + Math.sqrt(h.size) * 1.2);
      if (assault && Math.random() < dt * 5) { const b = this.nearestBuilding(x, zz, 30, p => p.bp === 'wall' || p.bp === 'barricade' || p.bp === 'door'); if (b) { fx.p.dust(b.x, b.y + 1, b.z, 2, 1.0, 0.5); if (Math.random() < 0.35) fx.p.spark(b.x, b.y + 1.2, b.z, 3, 0.5); } }
    }
  }
  // ---- raiders
  updateRaids(dt) {
    const fx = this.fx, st = this.st, rp = this.raiders; rp.begin(); this.raidersN = 0;
    for (const r of this.raids) {
      const x = r.x, z = -r.y, n = Math.min(r.count, 12), col = _col.setHex(FAC[r.faction] || 0xff5d6c), key = r.id; let H = this.raidState || (this.raidState = new Map()), S = H.get(key);
      if (!S) { S = { pts: [], t: 0 }; for (let i = 0; i < 14; i++) S.pts.push({ x: x + (Math.random() - 0.5) * 12, z: z + (Math.random() - 0.5) * 12, ph: Math.random() * TAU, yaw: 0 }); H.set(key, S); }
      const assault = r.state === 'assault' || Math.hypot(x, z) < 90, dir = Math.atan2(-x, -z);
      for (let i = 0; i < n; i++) {
        const p = S.pts[i], tx = x + Math.cos(i * 2.4) * (3 + i * 0.7), tz = z + Math.sin(i * 2.4) * (3 + i * 0.7), dx = tx - p.x, dz = tz - p.z, d = Math.hypot(dx, dz), sp = Math.min(d * 2, d > 20 ? 30 : 4.2) * (assault ? 0.35 : 1);
        if (d > 0.3) { p.x += dx / d * sp * dt; p.z += dz / d * sp * dt; p.yaw = dampAng(p.yaw, assault ? dir : Math.atan2(dx, dz), 6, dt); } p.ph += dt * (3 + sp * 0.6);
        const idx = rp.add(p.x, this.groundY(p.x, p.z), p.z, p.yaw, 1.0, col, p.ph, Math.min(1, sp / 3)); this.raidersN++;
        if (assault && Math.random() < dt * 0.9) { const mx = p.x + Math.sin(p.yaw) * 0.8, mz = p.z + Math.cos(p.yaw) * 0.8; fx.p.muzzle(mx, this.groundY(mx, mz) + 1.3, mz, Math.sin(p.yaw), Math.cos(p.yaw)); fx.lights.put(mx, 2, mz, 0xffb060, 12, 20); }
      }
      fx.dA.ring(x, this.groundY(x, z) + 0.2, z, 7 + n * 0.4, col.r, col.g, col.b, 0.55, 0.25, 2);
      fx.beams.put(x, this.groundY(x, z), z, 40, col.r, col.g, col.b, 4);
    }
    rp.end();
  }
  // ---- buildings: fire, smoke, glows, noise rings
  updateBuildingsFx(dt, focus, night) {
    const fx = this.fx, t = this.t, camD = this.W.camRig.t.dist, st = this.st;
    if (this.campGlb) { /* campfire models are drawn below */ }
    let lightN = 0;
    for (const [id, p] of this.prevB) {
      if (p.state !== 'built') continue; const dx = p.x - focus.x, dz = p.z - focus.z, d2 = dx * dx + dz * dz; if (d2 > 420 * 420) continue;
      const bp = p.bp;
      if (bp === 'campfire') {
        if (this.campGlb) this.campGlb.put(p.x, p.y, p.z, hash2(Math.round(p.x * 3), Math.round(p.z * 3), 4) * TAU, 1.15, null);
        if (Math.random() < dt * 22) fx.p.fire(p.x, p.y + 0.35, p.z, 1.1); if (Math.random() < dt * 5) fx.p.smoke(p.x, p.y + 1.1, p.z, 0.8, 0.32); if (Math.random() < dt * 4) fx.p.ember(p.x, p.y + 0.6, p.z);
        const fl = 0.8 + 0.4 * Math.sin(t * 13 + p.x) * Math.sin(t * 7.3); fx.dG.disc(p.x, p.y + 0.2, p.z, 7.5 * fl, 1.0, 0.5, 0.18, 0.55 * (0.5 + 0.5 * night)); fx.lights.put(p.x, p.y + 1.2, p.z, 0xff8a3a, (14 + 8 * fl) * (0.4 + 0.6 * night), 30);
      } else if (bp === 'generator') {
        const rec = p; if (this.isPowered(id)) { if (Math.random() < dt * 6) fx.p.smoke(p.x + 0.8, p.y + 2.0, p.z + 0.3, 0.7, 0.28); fx.dA.ring(p.x, p.y + 0.2, p.z, 9 + 6 * ((t * 0.5) % 1), 1, 0.65, 0.25, 0.5 * (1 - (t * 0.5) % 1), 0.15); }
      } else if (bp === 'lamp') {
        if (this.isPowered(id)) { fx.dG.disc(p.x + 0.5, p.y + 0.15, p.z, 6.5, 1.0, 0.82, 0.5, 0.62 * (0.3 + 0.7 * night)); }
      } else if (bp === 'workbench' || bp === 'stove') { if (this.isPowered(id)) fx.dG.disc(p.x, p.y + 0.15, p.z, 3.2, 1.0, 0.8, 0.5, 0.3 * (0.2 + 0.8 * night)); }
      else if (bp === 'watchtower') { const a = t * 0.7 + p.x; if (night > 0.3) fx.dG.disc(p.x + Math.cos(a) * 14, p.y + 0.15, p.z + Math.sin(a) * 14, 8, 1.0, 0.95, 0.75, 0.35 * night); }
      else if (bp === 'radio_mast') { if (this.isPowered(id) && Math.random() < dt * 0.4) fx.dA.ring(p.x, p.y + 0.2, p.z, 3, 0.4, 0.9, 1, 0.8, 0.2); }
      else if (bp === 'medical_bed' && night > 0.4) fx.dG.disc(p.x, p.y + 0.15, p.z, 2.4, 0.6, 1.0, 0.8, 0.22);
      // smoke from badly damaged buildings
      if (p.hp < 0.35 && Math.random() < dt * 4) fx.p.smoke(p.x, p.y + 1.4, p.z, 1.1, 0.2);
    }
  }
  isPowered(id) { const b = this.st && this.st.buildings && this.bIndex && this.bIndex.get(id); return b ? b.powered : false; }
  // ---- zones / piles
  updateZonesPiles(dt, night) {
    const st = this.st, fx = this.fx, K = this.kitSet;
    for (const z of st.zones || []) {
      const side = Math.sqrt(z.tiles) * 4.2, x = z.x, zz = -z.y, y = this.groundY(x, zz), main = !!z.main, col = main ? [0.49, 0.65, 1] : [0.49, 0.88, 0.76];
      fx.dA.rect(x, y + 0.13, zz, side, side, 0, col[0], col[1], col[2], 0.9, 0.12, 1.2);
      const used = z.cap ? clamp(z.w / z.cap, 0, 1) : 0, n = Math.min(9, Math.ceil(used * 9)), cols = 3;
      for (let i = 0; i < n; i++) { const gx = (i % cols - 1) * Math.min(1.6, side / 3.2), gz = (Math.floor(i / cols) - 1) * Math.min(1.6, side / 3.2); K.addT('pallet', { x: x + gx, y, z: zz + gz, rot: (hashStr(z.id + i) % 7) * 0.1, prog: 1, hp: 1, seed: i / 9, col: [1, 1, 1] }); }
    }
    for (const p of st.piles || []) { const x = p.x, zz = -p.y, y = this.groundY(x, zz); K.addT('pile', { x, y, z: zz, rot: (hashStr(p.id) % 628) / 100, prog: 1, hp: 1, seed: 0, col: [1, 1, 1] }); fx.dG.disc(x, y + 0.2, zz, 3, 1.0, 0.85, 0.5, 0.18 + 0.12 * Math.sin(this.t * 3 + x)); }
  }
  // ---- vehicles / caravans
  updateVehicles(dt, focus) {
    const st = this.st, cat = this.cat, fx = this.fx, gen = this.W.gen, t = this.t;
    for (const v of st.vehicles || []) {
      let S = this.vehState.get(v.id); if (!S) { S = { phase: v.state, t: 0, x: GARAGE.x - 10, z: GARAGE.z + 11, hide: false }; this.vehState.set(v.id, S); }
      const x = (st.expeditions || []).find(e => e.vehicle === v.id), away = v.state === 'away' || (x && (x.state === 'outbound' || x.state === 'looting' || x.state === 'returning'));
      const phase = away ? (x ? x.state : 'outbound') : 'home';
      if (phase !== S.phase) { S.phase = phase; S.t = 0; }
      S.t += dt;
      const d = x && cat ? cat.districts.find(q => q.id === x.district) : null, dirx = d ? d.x : 400, dirz = d ? -d.y : 0, L = Math.hypot(dirx - GARAGE.x, dirz - GARAGE.z) || 1, ux = (dirx - GARAGE.x) / L, uz = (dirz - GARAGE.z) / L, far = 360;
      let px = GARAGE.x - 10, pz = GARAGE.z + 11, yaw = PI / 2, show = true, speed = 0;
      if (phase === 'outbound') { const k = clamp(S.t / 11, 0, 1); px = GARAGE.x + ux * far * k * k; pz = GARAGE.z + uz * far * k * k; yaw = Math.atan2(ux, uz); show = k < 1; speed = 8 + 20 * k; }
      else if (phase === 'looting') show = false;
      else if (phase === 'returning') { const k = clamp(S.t / 11, 0, 1), e = 1 - (1 - k) * (1 - k); px = GARAGE.x + ux * far * (1 - e); pz = GARAGE.z + uz * far * (1 - e); yaw = Math.atan2(-ux, -uz); speed = k < 1 ? 20 * (1 - k) + 4 : 0; if (k >= 1) { px = GARAGE.x - 10; pz = GARAGE.z + 11; yaw = PI / 2; } }
      if (show) {
        const y = gen.heightAt(px, pz); (v.kind === 'van' ? this.vans : this.vehicles).put(px, y, pz, yaw, 1, null);
        if (speed > 1) { if (Math.random() < dt * 12) fx.p.dust(px - Math.sin(yaw) * 2.5, y + 0.3, pz - Math.cos(yaw) * 2.5, 2, 1.3, 0.5); const nz = U.night.value; if (nz > 0.2) fx.dG.disc(px + Math.sin(yaw) * 8, y + 0.2, pz + Math.cos(yaw) * 8, 7, 1, 0.95, 0.75, 0.4 * nz); }
        else if (U.night.value > 0.3 && phase === 'home') fx.dG.disc(px + Math.sin(yaw) * 5, y + 0.2, pz + Math.cos(yaw) * 5, 4, 1, 0.9, 0.6, 0.12);
      }
    }
    for (const c of st.caravans || []) { const x = c.x, z = -c.y, y = gen.heightAt(x, z), col = _col.setHex(FAC[c.faction] || 0xf6d04d); this.cars.put(x + 3, y, z + 2, 0.5, 1, null); this.vehicles.put(x - 3, y, z - 1, -0.4, 1, null);
      for (let i = 0; i < 3; i++) this.folk.add(x + Math.cos(i * 2.1) * 3, y, z + Math.sin(i * 2.1) * 3, i * 2.1 + PI, 1, col, 0, 0); fx.dG.disc(x, y + 0.3, z, 9, 1, 0.8, 0.45, 0.4 * (0.3 + U.night.value)); fx.beams.put(x, y, z, 26, col.r, col.g, col.b, 3);
      fx.dA.rect(x, y + 0.14, z, 14, 10, 0.3, col.r, col.g, col.b, 0.6, 0.12, 1.5);
    }
  }
  // ---- player avatar + ambient (helicopter, drop, flares, expedition bits)
  updateAmbient(dt, night, focus) {
    const st = this.st, fx = this.fx; const p = st.player;
    if (p) {
      const pa = this.pa || (this.pa = { px: p.x, pz: -p.y, yaw: 0, ph: 0, walk: 0, vel: 0 }), tx = p.x, tz = -p.y, dx = tx - pa.px, dz = tz - pa.pz, d = Math.hypot(dx, dz);
      if (d > 60) { pa.px = tx; pa.pz = tz; } else if (d > 0.02) { const st2 = Math.min(d, Math.max(d * 4, 0.5) * dt * 3); pa.px += dx / d * st2; pa.pz += dz / d * st2; pa.vel = damp(pa.vel, st2 / Math.max(dt, 1e-4), 8, dt); if (pa.vel > 0.5) pa.yaw = dampAng(pa.yaw, Math.atan2(dx, dz), 8, dt); } else pa.vel = damp(pa.vel, 0, 8, dt);
      const x = pa.px, z = pa.pz, y = this.groundY(x, z); pa.ph += dt * (3 + pa.vel * 1.2);
      this.folk.add(x, y, z, pa.yaw, 1.0, _col.setHex(0x3fe0c5), pa.ph, clamp(pa.vel / 4, 0, 1)); fx.dA.ring(x, y + 0.2, z, 1.1 + 0.15 * Math.sin(this.t * 3), 0.25, 0.9, 0.8, 0.8, 0.09); fx.dG.disc(x, y + 0.2, z, 3, 0.3, 1, 0.9, 0.25);
    }
    // pings
    for (let i = this.pings.length - 1; i >= 0; i--) {
      const pg = this.pings[i]; pg.t += dt; const life = pg.kind === 'noise' ? 1.4 : pg.kind === 'horde' ? 2.4 : 1.1; if (pg.t > life) { this.pings.splice(i, 1); continue; } const k = pg.t / life, y = this.groundY(pg.x, pg.z) + 0.2;
      fx.dA.ring(pg.x, y, pg.z, (pg.r || 1) * (pg.kind === 'noise' ? 3 + 18 * k : pg.kind === 'horde' ? 4 + 24 * k : 0.7 + 2.6 * k), pg.col[0], pg.col[1], pg.col[2], (1 - k) * (pg.kind === 'noise' || pg.kind === 'horde' ? 0.9 : 0.65), pg.kind === 'noise' ? 0.3 : 0.12);
      if (pg.kind === 'horde' && k < 0.3) fx.beams.put(pg.x, y, pg.z, 60 * (1 - k), 1, 0.2, 0.12, 6);
    }
    // helicopter flyover
    if (this.heli) {
      const h = this.heli; h.t += dt; if (h.t > h.life) this.heli = null; else { const k = h.t / h.life, d = 900 * (1 - 2 * k), ang = h.a, x = Math.cos(ang) * d + 40, z = Math.sin(ang) * d - 30, y = 90; this.heliPos = { x, y, z, yaw: ang + PI / 2 * (k < 0.5 ? 1 : -1) }; fx.dG.disc(x, this.groundY(x, z) + 0.3, z, 26, 0.9, 0.95, 1, 0.3 * (0.4 + night)); if (night > 0.2) fx.beams.put(x, 0, z, y, 0.7, 0.8, 1, 5); if (Math.random() < dt * 8) fx.p.dust(x, 4, z, 2, 3, 0.55); }
    }
    // supply drop: parachute crate falls, flare smoke
    if (this.drop) { const d = this.drop; d.t += dt; const k = clamp(d.t / 8, 0, 1), y = this.groundY(d.x, d.z) + 120 * (1 - k * k); fx.beams.put(d.x, this.groundY(d.x, d.z), d.z, 90, 1, 0.5, 0.2, 3); fx.p.smoke(d.x, Math.max(y, 3), d.z, 1.6, 0.6); this.kitSet.addT('pile', { x: d.x, y: Math.max(y, this.groundY(d.x, d.z)), z: d.z, rot: d.t, prog: 1, hp: 1, seed: 0, col: [1, 1, 1] }); if (d.t > 20) this.drop = null; }
    for (let i = this.flares.length - 1; i >= 0; i--) { const f = this.flares[i]; f.t += dt; if (f.t > 3) this.flares.splice(i, 1); }
    // city ambience: chimney smoke + burning ruins near the camera
    const em = this.W.city.emit; this.emT = (this.emT || 0) + dt; if (this.emT > 0.12) { this.emT = 0; const fxp = fx.p, f = focus; for (let i = 0; i < em.length; i++) { const e = em[i], dx = e.x - f.x, dz = e.z - f.z; if (dx * dx + dz * dz > 520 * 520) continue; if (e.kind === 'fire') { fxp.fire(e.x, e.y, e.z, 1.6); if (Math.random() < 0.3) fxp.smoke(e.x, e.y + 1, e.z, 1.8, 0.2); fx.dG.disc(e.x, e.y - 2, e.z, 9, 1, 0.5, 0.2, 0.28 * (0.3 + night)); } else if (Math.random() < 0.5) fxp.smoke(e.x, e.y, e.z, e.s || 1.2, 0.3); } }
  }
  // ---- selection / ghost / drag overlays
  updateOverlays(dt, focus, night) {
    const W = this.W, fx = this.fx, st = this.st, g = this.ghost;
    // base rings
    if (st && st.base) { const y = this.groundY(0, 0); fx.dA.ring(0, y + 0.18, 0, st.base.radius, 0.25, 0.88, 0.77, 0.35, 0.35, 3); if (g && g.bp) fx.dA.ring(0, y + 0.18, 0, st.base.build_radius || 160, 0.96, 0.7, 0.3, 0.5, 0.5, 4); }
    // placement ghost: footprint + hologram of the kit
    if (g && g.bp && g.x != null) {
      const x = g.x, z = -g.y, y = this.groundY(x, z), ok = g.ok, c = ok ? [0.2, 0.9, 0.6] : [1, 0.3, 0.35];
      fx.dA.rect(x, y + 0.2, z, 2.1, 2.1, 0, c[0], c[1], c[2], 0.95, 0.1); fx.dA.disc(x, y + 0.2, z, 2.4, c[0], c[1], c[2], 0.25);
      const K = this.kitSet, name = g.bp === 'wall' ? 'wallPost' : g.bp;
      if (this.kits[name]) K.addT(name, { x, y, z, rot: 0, prog: 0.0, pow: 0, hp: 1, seed: 0.5, col: ok ? [0.6, 1, 0.9] : [1, 0.5, 0.5] });
    }
    // hover ring on buildings / zones
    const h = this.hover; if (h && h.kind === 'building') { const p = this.prevB.get(h.id); if (p) fx.dA.rect(p.x, p.y + 0.22, p.z, 2.6, 2.6, 0, 1, 1, 1, 0.8, 0.09); }
    this.updateLabels(dt, focus);
  }
  setSelection(ids, primary) { this.sel = new Set(ids); this.primary = primary || (ids && ids[ids.length - 1]) || null; }
  setHover(h) { this.hover = h; }
  setGhost(g) { this.ghost = g; }
  addPing(x, y, col) { this.pings.push({ x, z: -y, t: 0, kind: 'order', col: col || [1, 0.83, 0.54] }); }

  // ------------------------------------------------------------------------------------------------ labels (DOM, below the NUI iframe)
  updateLabels(dt, focus) {
    const W = this.W, host = W.labels; if (!host || !this.labelsOn) { if (host) host.style.display = 'none'; return; } host.style.display = '';
    const used = this.labelUsed; used.clear(); const cr = W.camRig, wpx = W.W, hpx = W.H, out = this.tmp.px, st = this.st; if (!st) return;
    const put = (key, text, x, y, z, cls, extra) => { if (!cr.project(x, y, z, wpx, hpx, out)) return; if (out[0] < -50 || out[0] > wpx + 50 || out[1] < -30 || out[1] > hpx + 30) return; let el = this.labelEls.get(key); if (!el) { el = document.createElement('div'); el.className = 'w3d-label ' + cls; host.appendChild(el); this.labelEls.set(key, el); el._t = null; } if (el._t !== text) { el._t = text; el.textContent = text; } el.style.transform = 'translate(' + Math.round(out[0]) + 'px,' + Math.round(out[1]) + 'px) translate(-50%,-100%)'; el.style.display = ''; if (extra !== undefined) el.dataset.s = extra; used.add(key); };
    const dist = cr.t.dist, showAll = dist < 95;
    for (const a of this.actors.values()) { const c = a.c; if (!c || !a.root.visible) continue; const show = showAll || this.sel.has(c.id) || (this.hover && this.hover.id === c.id); if (!show) continue; const nick = (/"([^"]+)"/.exec(c.name) || [])[1] || String(c.name).split(' ')[0]; put('c' + c.id, nick, a.px, a.root.position.y + 2.15, a.pz, 'col' + (this.sel.has(c.id) ? ' sel' : ''), c.state); }
    if (dist > 70) for (const h of this.hordes) { const d = Math.hypot(h.x - focus.x, -h.y - focus.z); put('h' + h.id, '×' + h.size, h.x, this.groundY(h.x, -h.y) + 5, -h.y, 'horde' + (h.state === 'assault' ? ' hot' : ''), h.state); }
    if (dist > 160) for (const q of this.W.city.labels) { const d = Math.hypot(q.x - focus.x, q.z - focus.z); if (d < 1500) put('d' + q.id, q.name, q.x, 30, q.z, 'dist d' + q.danger); }
    for (const c of st.caravans || []) put('k' + c.id, c.name, c.x, this.groundY(c.x, -c.y) + 4, -c.y, 'cara');
    for (const [k, el] of this.labelEls) if (!used.has(k)) { if (el.style.display !== 'none') el.style.display = 'none'; }
    if (this.labelEls.size > 160) for (const [k, el] of this.labelEls) if (!used.has(k)) { el.remove(); this.labelEls.delete(k); }
  }

  // ------------------------------------------------------------------------------------------------ picking
  // returns { kind: 'colonist'|'building'|'raid'|'horde'|'zone'|'ground', id, bp?, point:{x,y} (sim coords) }
  pick(px, py, touch) {
    const W = this.W, cr = W.camRig, wpx = W.W, hpx = W.H, out = this.tmp.px, st = this.st; if (!st) return null;
    const scale = cr.pxScale(cr.t.dist, hpx), fat = touch ? 1.7 : 1;
    let best = null, bd = 1e9;
    for (const a of this.actors.values()) { if (!a.root.visible || !a.c) continue; if (!cr.project(a.px, a.root.position.y + 1.0, a.pz, wpx, hpx, out)) continue; const r = clamp(0.8 / Math.max(scale, 1e-3), 13, 46) * fat, d = Math.hypot(out[0] - px, out[1] - py); if (d < r && d < bd) { bd = d; best = { kind: 'colonist', id: a.id }; } }
    if (best) return Object.assign(best, { point: this.groundPoint(px, py) });
    for (const [id, p] of this.prevB) { const kit = this.kits[p.bp], hh = kit ? kit.h * 0.5 : 1; if (!cr.project(p.x, p.y + Math.min(hh, 2.4), p.z, wpx, hpx, out)) continue; const r = clamp(1.5 / Math.max(scale, 1e-3), 11, 64) * fat, d = Math.hypot(out[0] - px, out[1] - py); if (d < r && d < bd) { bd = d; best = { kind: 'building', id, bp: p.bp }; } }
    if (best) return Object.assign(best, { point: this.groundPoint(px, py) });
    for (const r of this.raids) { if (!cr.project(r.x, this.groundY(r.x, -r.y) + 1, -r.y, wpx, hpx, out)) continue; const d = Math.hypot(out[0] - px, out[1] - py), rr = clamp(8 / Math.max(scale, 1e-3), 18, 90); if (d < rr) return { kind: 'raid', id: r.id, point: this.groundPoint(px, py) }; }
    for (const h of this.hordes) { if (!cr.project(h.x, this.groundY(h.x, -h.y) + 1, -h.y, wpx, hpx, out)) continue; const d = Math.hypot(out[0] - px, out[1] - py), rr = clamp((4 + Math.sqrt(h.size) * 2.2) / Math.max(scale, 1e-3), 18, 140); if (d < rr) return { kind: 'horde', id: h.id, point: this.groundPoint(px, py) }; }
    const gp = this.groundPoint(px, py);
    if (gp) for (const z of st.zones || []) { const half = Math.sqrt(z.tiles) * 2.1; if (Math.abs(gp.x - z.x) < half && Math.abs(gp.y - z.y) < half) return { kind: 'zone', id: z.id, point: gp }; }
    return gp ? { kind: 'ground', point: gp } : null;
  }
  // ground point under a pixel in SIM coordinates ({x, y} with y = north)
  groundPoint(px, py) { const v = this.W.camRig.groundAt(px, py, this.W.W, this.W.H, this.tmp.ground); return v ? { x: v.x, y: -v.z } : null; }
  // screen box select: colonist ids whose projected position lies in the rectangle
  colonistsIn(x0, y0, x1, y1) { const W = this.W, cr = W.camRig, out = this.tmp.px, ids = []; const lx = Math.min(x0, x1), hx = Math.max(x0, x1), ly = Math.min(y0, y1), hy = Math.max(y0, y1); for (const a of this.actors.values()) { if (!a.root.visible || !a.c) continue; if (!cr.project(a.px, a.root.position.y + 1.0, a.pz, W.W, W.H, out)) continue; if (out[0] >= lx && out[0] <= hx && out[1] >= ly && out[1] <= hy) ids.push(a.id); } return ids; }
  actor(id) { return this.actors.get(id) || null; }
  // what is really in the scene (for tests): instances per building type, visible colonists, live zombies, ...
  sceneCounts() {
    const K = this.kitSet, b = {}; for (const [name, l] of Object.entries(K.recs)) { if (name === 'wallSeg' || name === 'pallet' || name === 'pile') continue; b[name === 'wallPost' ? 'wall' : name] = l.length; }
    b.campfire = (b.campfire || 0) + (this.campGlb ? this.campGlb.n : 0);
    const z = this.zombies, slots = {}; for (const [id, h] of z.hordes) slots[id] = h.slots.length;
    return { colonists: this.visibleColonists(), buildings: b, wallSegments: K.recs.wallSeg.length, zombies: z.cnt.zombies, zombieDrawn: z.cnt.drawn, hordes: z.hordes.size, hordeSlots: slots, raiders: this.raidersN || 0, piles: K.tr.pile ? (this.st.piles || []).length : 0, zones: (this.st.zones || []).length, vehiclesDrawn: this.vehicles.n + this.vans.n, caravans: (this.st.caravans || []).length };
  }
}
