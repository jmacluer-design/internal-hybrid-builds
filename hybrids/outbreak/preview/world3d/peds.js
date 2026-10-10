// Outbreak 3D: instanced pedestrians. ZombieField draws every zombie of every visible horde through one set of InstancedMeshes (the zombie GLB's five parts, or a
// procedural body if the model is missing); the shamble (legs, bob, sway, lean), the rise-from-the-ground spawn and the death fall are vertex-shader animation
// driven by one per-instance vec4, so the cost per zombie is a handful of floats. ProcPeds does the same for procedural humanoids (raiders, traders, the player,
// fallback colonists). No per-frame allocation: slots live in typed arrays.
import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';
import { clamp, lerp, rng, hash2, hashStr, PI, TAU, damp, dampAng, angDiff } from './util.js';
import { patch } from './terrain.js';
import { U } from './sky.js';
import { bake } from './models.js';

const ANIM_VERT_HEAD = 'attribute vec4 aAnim; attribute float aPart; uniform float uLegs; uniform float uArms; uniform float uHands;';
// aAnim = (phase, amplitude, mode 0 walk / 1 rise / 2 fall, t); hips at y=0.93, shoulders at y=1.42. Object space, +z forward, +x = character left.
const ANIM_VERT = `{
  vec3 p = transformed; float ph = aAnim.x, amp = aAnim.y, mode = aAnim.z, tt = aAnim.w;
  float part = aPart; float hipY = 0.93, shY = 1.42;
  bool leg = uLegs > 0.5 ? true : (part > 0.5 && part < 2.5);
  if (leg) { float side = (uLegs > 0.5) ? sign(p.x) : (part < 1.5 ? 1.0 : -1.0); float a = sin(ph + (side > 0.0 ? 0.0 : 3.14159)) * 0.62 * amp * (uLegs > 0.5 ? smoothstep(hipY, 0.3, p.y) : 1.0);
    float yy = p.y - hipY; float ny = hipY + yy * cos(a) + p.z * sin(a); float nz = p.z * cos(a) - yy * sin(a); p.y = ny; p.z = nz; p.y += max(0.0, sin(ph + (side > 0.0 ? 0.0 : 3.14159))) * 0.05 * amp; }
  bool arm = part > 2.5;
  if (arm && uArms < 0.5) { float side = part < 3.5 ? 1.0 : -1.0; float a = -sin(ph + (side > 0.0 ? 0.0 : 3.14159)) * 0.55 * amp; float yy = p.y - shY; float ny = shY + yy * cos(a) + p.z * sin(a); float nz = p.z * cos(a) - yy * sin(a); p.y = ny; p.z = nz; }
  if (uHands > 0.5) { p.z += sin(ph * 2.0 + p.x * 4.0) * 0.07 * (0.35 + amp); p.y += sin(ph * 1.5) * 0.03; }
  p.y += abs(sin(ph)) * 0.035 * amp; p.x += sin(ph) * 0.05 * amp * clamp(p.y, 0.0, 1.8);
  if (!leg) { float yy = clamp(p.y - hipY, 0.0, 1.0); p.z += yy * (0.05 + 0.07 * amp); }
  if (mode > 0.5 && mode < 1.5) { p.y -= (1.0 - smoothstep(0.0, 1.0, tt)) * 1.9; p.z += (1.0 - tt) * 0.2 * p.y; }
  if (mode > 1.5) { float f = smoothstep(0.0, 1.0, min(tt, 1.0)) * 1.5; float yy = p.y; float ny = yy * cos(f) + p.z * sin(f); float nz = p.z * cos(f) - yy * sin(f); p.y = ny; p.z = nz; p.y -= max(0.0, tt - 1.0) * 0.5; }
  transformed = p;
}`;

function animPatch(mat, o = {}) {
  const m = mat.clone(); m.roughness = 0.9; m.metalness = 0;
  patch(m, { key: 'ped' + (o.legs ? 'L' : '') + (o.hands ? 'H' : '') + (o.arms || 0) + (o.vcol ? 'V' : '') + (o.emissive ? 'E' : ''), vHead: ANIM_VERT_HEAD, vMain: ANIM_VERT,
    fHead: 'uniform float uNight;', fColor: o.tint ? 'diffuseColor.rgb *= ' + o.tint + ';' : '', fEmit: o.emissive ? 'totalEmissiveRadiance += ' + o.emissive + ';' : '',
    uniforms: { uLegs: { value: o.legs ? 1 : 0 }, uArms: { value: o.arms || 0 }, uHands: { value: o.hands ? 1 : 0 }, uNight: U.night } });
  return m;
}

// ------------------------------------------------------------------------------------------------------------------ procedural humanoid
const part = (g, id, col) => { g = g.index ? g.toNonIndexed() : g; for (const k of Object.keys(g.attributes)) if (!['position', 'normal', 'uv'].includes(k)) g.deleteAttribute(k); const n = g.attributes.position.count, c = new Float32Array(n * 3), a = new Float32Array(n).fill(id), k = new THREE.Color(col); for (let i = 0; i < n; i++) { c[i * 3] = k.r; c[i * 3 + 1] = k.g; c[i * 3 + 2] = k.b; } g.setAttribute('color', new THREE.BufferAttribute(c, 3)); g.setAttribute('aPart', new THREE.BufferAttribute(a, 1)); return g; };
// opts: { shirt, pants, skin, hair, reach: arms forward, rifle: arms forward + rifle, height }
export function humanoidGeo({ shirt = 0xffffff, pants = 0x3b3f46, skin = 0xc9a48a, hair = 0x2b2420, reach = false, rifle = false, boots = 0x1c1c1e } = {}) {
  const P = [];
  const box = (w, h, d, x, y, z, id, col) => { const g = new THREE.BoxGeometry(w, h, d); g.translate(x, y, z); P.push(part(g, id, col)); };
  const cyl = (rt, rb, h, x, y, z, id, col, seg = 8) => { const g = new THREE.CylinderGeometry(rt, rb, h, seg); g.translate(x, y, z); P.push(part(g, id, col)); };
  box(0.44, 0.58, 0.24, 0, 1.16, 0, 0, shirt); box(0.4, 0.2, 0.22, 0, 0.9, 0, 0, pants);
  const head = new THREE.SphereGeometry(0.115, 10, 8); head.scale(0.95, 1.12, 1.0); head.translate(0, 1.64, 0.01); P.push(part(head, 0, skin));
  const cap = new THREE.SphereGeometry(0.12, 10, 6, 0, TAU, 0, PI * 0.5); cap.scale(1, 0.9, 1.04); cap.translate(0, 1.66, 0); P.push(part(cap, 0, hair));
  cyl(0.045, 0.05, 0.1, 0, 1.51, 0, 0, skin, 6);
  for (const s of [1, -1]) {
    const id = s > 0 ? 1 : 2;
    cyl(0.085, 0.07, 0.46, s * 0.11, 0.68, 0, id, pants); cyl(0.065, 0.06, 0.44, s * 0.11, 0.24, 0, id, pants); box(0.1, 0.07, 0.24, s * 0.11, 0.035, 0.05, id, boots);
    const aid = s > 0 ? 3 : 4;
    if (reach) { const u = new THREE.CylinderGeometry(0.05, 0.045, 0.3, 6); u.rotateX(PI / 2.2); u.translate(s * 0.25, 1.33, 0.12); P.push(part(u, aid, shirt)); const f = new THREE.CylinderGeometry(0.042, 0.035, 0.3, 6); f.rotateX(PI / 2.05); f.translate(s * 0.25, 1.3, 0.4); P.push(part(f, aid, skin)); }
    else if (rifle) { const u = new THREE.CylinderGeometry(0.05, 0.045, 0.3, 6); u.rotateX(PI / 3); u.translate(s * 0.24, 1.3, 0.1); P.push(part(u, aid, shirt)); const f = new THREE.CylinderGeometry(0.042, 0.035, 0.28, 6); f.rotateX(PI / 2.1); f.translate(s * 0.17 * (s > 0 ? 1 : 0.2), 1.27, 0.3); P.push(part(f, aid, skin)); }
    else { cyl(0.05, 0.045, 0.3, s * 0.27, 1.3, 0, aid, shirt, 6); cyl(0.042, 0.035, 0.3, s * 0.27, 1.02, 0, aid, skin, 6); }
  }
  if (rifle) { box(0.05, 0.07, 0.75, 0.04, 1.27, 0.38, 0, 0x2a2d30); box(0.04, 0.12, 0.1, 0.04, 1.2, 0.3, 0, 0x2a2d30); }
  return mergeGeometries(P);
}

// ------------------------------------------------------------------------------------------------------------------ shared instanced rig
class InstRig {
  constructor(parts, cap) {
    this.cap = cap; this.n = 0; this.meshes = []; this.group = new THREE.Group();
    this.matAttr = new THREE.InstancedBufferAttribute(new Float32Array(cap * 16), 16); this.matAttr.setUsage(THREE.DynamicDrawUsage);
    this.colAttr = new THREE.InstancedBufferAttribute(new Float32Array(cap * 3), 3); this.colAttr.setUsage(THREE.DynamicDrawUsage);
    this.animAttr = new THREE.InstancedBufferAttribute(new Float32Array(cap * 4), 4); this.animAttr.setUsage(THREE.DynamicDrawUsage);
    for (const p of parts) {
      const g = p.geometry; g.setAttribute('aAnim', this.animAttr); if (!g.attributes.aPart) g.setAttribute('aPart', new THREE.BufferAttribute(new Float32Array(g.attributes.position.count), 1));
      const m = new THREE.InstancedMesh(g, p.material, cap); m.instanceMatrix = this.matAttr; m.instanceColor = this.colAttr; m.count = 0; m.frustumCulled = false; m.castShadow = true; m.receiveShadow = false; m.name = p.name || 'ped';
      this.group.add(m); this.meshes.push(m);
    }
  }
  setCount(n) { this.n = n; for (const m of this.meshes) m.count = n; this.matAttr.needsUpdate = true; this.colAttr.needsUpdate = true; this.animAttr.needsUpdate = true; }
  // write instance k: position, yaw (0 = facing +z), uniform scale (sx for width, sy for height), tint, anim vec4
  set(k, x, y, z, yaw, sx, sy, r, g, b, ph, amp, mode, t) {
    const M = this.matAttr.array, c = Math.cos(yaw), s = Math.sin(yaw), o = k * 16;
    M[o] = c * sx; M[o + 1] = 0; M[o + 2] = -s * sx; M[o + 3] = 0; M[o + 4] = 0; M[o + 5] = sy; M[o + 6] = 0; M[o + 7] = 0; M[o + 8] = s * sx; M[o + 9] = 0; M[o + 10] = c * sx; M[o + 11] = 0; M[o + 12] = x; M[o + 13] = y; M[o + 14] = z; M[o + 15] = 1;
    const C = this.colAttr.array; C[k * 3] = r; C[k * 3 + 1] = g; C[k * 3 + 2] = b; const A = this.animAttr.array, a = k * 4; A[a] = ph; A[a + 1] = amp; A[a + 2] = mode; A[a + 3] = t;
  }
}

// ------------------------------------------------------------------------------------------------------------------ zombies
const KINDS = ['walker', 'runner', 'brute', 'screamer'];
const KIND = { walker: { s: 1.0, w: 1.0, v: 2.7, amp: 0.85, c: [0.9, 0.9, 0.88] }, runner: { s: 0.97, w: 0.92, v: 6.2, amp: 1.15, c: [1.0, 0.78, 0.74] }, brute: { s: 1.2, w: 1.42, v: 2.1, amp: 0.7, c: [0.68, 0.64, 0.6] }, screamer: { s: 1.02, w: 0.9, v: 3.6, amp: 0.95, c: [0.84, 0.95, 1.08] } };

export class ZombieField {
  constructor(tier, models, scene) {
    this.tier = tier; this.cap = tier.zombies; this.scene = scene; this.glb = false;
    let parts = [];
    if (models && models.has('zombie')) {
      const baked = bake(models.scene('zombie'), { height: 1.74, center: false });
      if (baked.length) {
        // centre on the legs (the reaching arms would otherwise pull the body backwards) and note which parts are legs / hands
        const lg = baked.filter(b => /pants|boots/i.test(b.name)), bb = new THREE.Box3(); for (const b of lg) bb.union(b.geometry.boundingBox);
        const cx = (bb.min.x + bb.max.x) / 2, cz = (bb.min.z + bb.max.z) / 2;
        for (const b of baked) { b.geometry.translate(-cx, 0, -cz); b.geometry.computeBoundingBox(); }
        parts = baked.map(b => ({ geometry: b.geometry, name: b.name, material: animPatch(b.material, { legs: /pants|boots/i.test(b.name), hands: /hands/i.test(b.name) }) }));
        this.glb = true;
      }
    }
    if (!parts.length) { const g = humanoidGeo({ shirt: 0x6a7258, pants: 0x3a3a36, skin: 0x9aa58a, hair: 0x2a2a26, reach: true }); parts = [{ geometry: g, material: animPatch(new THREE.MeshStandardMaterial({ vertexColors: true }), { arms: 1, vcol: true }) }]; }
    this.rig = new InstRig(parts, this.cap + 40); this.group = this.rig.group; scene.add(this.group);
    const n = this.cap + 40;
    this.s = { used: new Uint8Array(n), hid: new Int32Array(n).fill(-1), kind: new Uint8Array(n), x: new Float32Array(n), z: new Float32Array(n), yaw: new Float32Array(n), ph: new Float32Array(n), v: new Float32Array(n), sc: new Float32Array(n), ox: new Float32Array(n), oz: new Float32Array(n), rise: new Float32Array(n), amp: new Float32Array(n), tint: new Float32Array(n), delay: new Float32Array(n) };
    this.free = []; for (let i = n - 1; i >= 0; i--) this.free.push(i);
    this.hordes = new Map(); this.corpses = []; this.cnt = { zombies: 0, hordes: 0, corpses: 0 }; this.dust = []; this.events = []; // events: { type:'spawn'|'kill', x, z }
    this.hidCounter = 0; this.rnd = rng(1234);
  }
  reset() { for (const h of this.hordes.values()) for (const k of h.slots) { this.s.used[k] = 0; this.free.push(k); } this.hordes.clear(); this.corpses.length = 0; }
  // hordes: state.hordes ; focus: {x,z} camera focus (three space) ; base: {x,z} ; wallR: radius of the outermost defences
  update(dt, hordes, focus, wallRFn, groundY) {
    const S = this.s, tier = this.tier;
    // distance-sorted allocation of the instance budget
    const list = hordes.map(h => ({ h, x: h.x, z: -h.y, d: Math.hypot(h.x - focus.x, -h.y - focus.z) })).sort((a, b) => a.d - b.d);
    let budget = this.cap; const seen = new Set();
    for (const it of list) {
      const h = it.h; seen.add(h.id);
      let want = it.d < 700 ? Math.min(h.size, tier.name === 'low' ? 26 : 56) : Math.min(h.size, 8);
      want = Math.min(want, budget); budget -= want;
      let H = this.hordes.get(h.id);
      if (!H) { H = { id: h.id, slots: [], x: it.x, z: it.z, born: performance.now(), seen: false, lastSize: h.size, state: h.state, wasMat: 0 }; this.hordes.set(h.id, H); }
      H.x = it.x; H.z = it.z; H.state = h.state; H.hx = h.hx; H.hz = -h.hy; H.mat = h.mat || 0; H.size = h.size; H.dist = it.d; H.mix = h.mix || { walker: h.size };
      const near = Math.hypot(it.x, it.z) < 420;
      // grow
      while (H.slots.length < want && this.free.length) {
        const k = this.free.pop(), r = this.rnd; S.used[k] = 1; S.hid[k] = this.hidCounter++;
        const kind = this.pickKind(H.mix, H.slots.length, h.size); S.kind[k] = kind; const K = KIND[KINDS[kind]];
        const rad = (2.5 + Math.sqrt(h.size) * 1.5) * Math.sqrt(r()), a = r() * TAU; S.ox[k] = Math.cos(a) * rad; S.oz[k] = Math.sin(a) * rad * 0.8;
        S.sc[k] = K.s * (0.93 + 0.14 * r()); S.v[k] = K.v * (0.8 + 0.4 * r()); S.amp[k] = K.amp; S.tint[k] = 0.72 + 0.28 * r(); S.ph[k] = r() * TAU; S.yaw[k] = Math.atan2(H.hx || 0, H.hz || 1);
        const first = !H.seen;
        if (first && near && (h.mat > 0 || h.src === 'wave' || it.d < 260)) { S.rise[k] = 0; S.delay[k] = r() * 1.6; this.events.push({ type: 'spawn', x: it.x + S.ox[k], z: it.z + S.oz[k] }); }
        else { S.rise[k] = 1; S.delay[k] = 0; }
        S.x[k] = it.x + S.ox[k] + (first ? 0 : (r() - 0.5) * 30); S.z[k] = it.z + S.oz[k] + (first ? 0 : (r() - 0.5) * 30);
        H.slots.push(k);
      }
      H.seen = true;
      // shrink (kills): the farthest-from-horde-centre slots fall
      while (H.slots.length > want) { const k = H.slots.pop(); this.kill(k, it.d < 520); }
      H.lastSize = h.size;
    }
    for (const [id, H] of this.hordes) if (!seen.has(id)) { for (const k of H.slots) this.kill(k, H.dist < 400 && H.state === 'assault'); this.hordes.delete(id); }
    // move
    const baseR = wallRFn;
    let n = 0, total = 0;
    for (const H of this.hordes.values()) {
      total += H.slots.length;
      const assault = H.state === 'assault', seek = H.state === 'seek';
      let cx = H.x, cz = H.z, wallR = 0;
      if (assault) { const bearing = Math.atan2(H.z, H.x); wallR = baseR(bearing); const d = Math.hypot(cx, cz); if (d < wallR + 3) { cx = Math.cos(bearing) * (wallR + 3.5); cz = Math.sin(bearing) * (wallR + 3.5); } }
      for (const k of H.slots) {
        let tx = cx + S.ox[k], tz = cz + S.oz[k];
        if (assault) { // press against the barrier: project to ring outside the walls
          const d = Math.hypot(tx, tz), b = Math.atan2(tz, tx), want = Math.max(wallR + 1.8, 0); if (d < want) { tx = Math.cos(b) * want; tz = Math.sin(b) * want; }
        }
        if (S.rise[k] < 1) { S.delay[k] -= dt; if (S.delay[k] <= 0) S.rise[k] = Math.min(1, S.rise[k] + dt / 1.5); }
        const dx = tx - S.x[k], dz = tz - S.z[k], dist = Math.hypot(dx, dz);
        let sp = Math.min(S.v[k] * (seek ? 1.35 : 1) * (assault ? 0.5 : 1), Math.max(0.2, dist * 1.4)); if (dist > 40) sp = Math.min(60, dist * 0.9); if (dist > 300) { S.x[k] = tx; S.z[k] = tz; sp = 0; }
        if (S.rise[k] < 1) sp = 0;
        if (dist > 0.4 && sp > 0.05) { S.x[k] += dx / dist * sp * dt; S.z[k] += dz / dist * sp * dt; S.yaw[k] = dampAng(S.yaw[k], Math.atan2(dx, dz), 5, dt); }
        else if (assault) S.yaw[k] = dampAng(S.yaw[k], Math.atan2(-S.x[k], -S.z[k]), 4, dt);
        const spd01 = clamp(sp / 4, 0, 1.4);
        S.ph[k] += dt * (assault && sp < 0.3 ? 5.5 : 2.4 + 1.6 * spd01 + (S.v[k] > 5 ? 3 : 0));
        const K = KIND[KINDS[S.kind[k]]], amp = assault && sp < 0.3 ? 0.55 + 0.25 * Math.sin(S.ph[k] * 0.7) : Math.max(0.28, spd01 * K.amp);
        const c = K.c, t = S.tint[k], y = groundY(S.x[k], S.z[k]);
        if (S.rise[k] <= 0 && S.delay[k] > 0) { continue; }
        this.rig.set(n++, S.x[k], y, S.z[k], S.yaw[k], S.sc[k] * (KIND[KINDS[S.kind[k]]].w > 1.1 ? K.w : 1), S.sc[k], c[0] * t, c[1] * t, c[2] * t, S.ph[k], amp, S.rise[k] < 1 ? 1 : 0, S.rise[k]);
      }
    }
    // corpses
    for (let i = this.corpses.length - 1; i >= 0; i--) {
      const c = this.corpses[i]; c.t += dt / 0.9; if (c.t > 7) { this.corpses.splice(i, 1); continue; }
      if (n < this.cap + 40) { const K = KIND[KINDS[c.kind]]; this.rig.set(n++, c.x, groundY(c.x, c.z), c.z, c.yaw, c.sc * K.w, c.sc, K.c[0] * 0.6, K.c[1] * 0.5, K.c[2] * 0.5, 0, 0, 2, c.t < 1 ? c.t : 1 + Math.max(0, c.t - 5)); }
    }
    this.rig.setCount(n); this.cnt.zombies = total; this.cnt.hordes = this.hordes.size; this.cnt.corpses = this.corpses.length; this.cnt.drawn = n;
  }
  pickKind(mix, i, size) {
    const w = mix.walker || 0, r = mix.runner || 0, b = mix.brute || 0, s = mix.screamer || 0, tot = w + r + b + s || 1; let f = ((i * 0.6180339887) % 1) * tot;
    if ((f -= w) < 0) return 0; if ((f -= r) < 0) return 1; if ((f -= b) < 0) return 2; return 3;
  }
  kill(k, show) {
    const S = this.s; if (show && this.corpses.length < 28) { this.corpses.push({ x: S.x[k], z: S.z[k], yaw: S.yaw[k], sc: S.sc[k], kind: S.kind[k], t: 0 }); this.events.push({ type: 'kill', x: S.x[k], z: S.z[k] }); }
    S.used[k] = 0; S.hid[k] = -1; this.free.push(k);
  }
  // positions of the visible zombies nearest to a point (for muzzle flashes / blood); returns count written into out [x,z,...]
  nearest(x, z, maxN, out) { let n = 0; const S = this.s; for (const H of this.hordes.values()) for (const k of H.slots) { if (n >= maxN) return n; const dx = S.x[k] - x, dz = S.z[k] - z; if (dx * dx + dz * dz < 160 * 160) { out[n * 2] = S.x[k]; out[n * 2 + 1] = S.z[k]; n++; } } return n; }
  count() { return this.cnt.zombies; }
}

// ------------------------------------------------------------------------------------------------------------------ procedural people pool (raiders, traders, player avatar)
export class ProcPeds {
  constructor(cap, geoOpts, arms) {
    this.cap = cap; const g = humanoidGeo(geoOpts);
    this.rig = new InstRig([{ geometry: g, material: animPatch(new THREE.MeshStandardMaterial({ vertexColors: true }), { arms: arms || 0, vcol: true }) }], cap); this.group = this.rig.group; this.n = 0;
  }
  begin() { this.n = 0; }
  add(x, y, z, yaw, scale, col, ph, amp) { if (this.n >= this.cap) return -1; this.rig.set(this.n, x, y, z, yaw, scale, scale, col.r, col.g, col.b, ph, amp, 0, 1); return this.n++; }
  end() { this.rig.setCount(this.n); }
}
