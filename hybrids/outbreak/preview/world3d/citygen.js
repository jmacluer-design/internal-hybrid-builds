// Outbreak 3D: settlement generator + the City object that owns the streamed pools. See city.js for the pool / material machinery.
// One pass over the street lattice produces every instance list (houses, shops, offices, tower blocks, ruins, trees, lamps, cars, props, landmarks);
// the sim's own district list decides what each place looks like (residential, mixed, industrial, commercial, medical, police, fuel, rural, military).
import * as THREE from 'three';
import { clamp, lerp, rng, hash2, hashStr, fbm2, noise2, PI, TAU, sstep } from './util.js';
import { GRID, ROAD_W } from './terrain.js';
import { U } from './sky.js';
import { bake } from './models.js';
import {
  InstList, Pool, unitBox, gableGeo, treeBroadGeo, treePineGeo, lampGeo, carGeo, barrelGeo, containerGeo, dumpsterGeo, barrierGeo, fenceGeo, chimneyGeo, tankGeo, canopyGeo,
  makeBuildingMaterial, makeVertexMaterial, patchTowerMaterial,
} from './city.js';

const C = h => new THREE.Color(h);
const PAL = {
  house: ['#c9b9a0', '#b8a58b', '#d4c9b0', '#a89c8c', '#9aa5a0', '#c4a89a', '#8f9aa6', '#b0a090', '#d9d2c0', '#a9b4a3', '#c8b27a', '#9a8f86'].map(C),
  brick: ['#8a4f3f', '#7a4638', '#9a5a45', '#6f4a40'].map(C),
  concrete: ['#9a9a96', '#8c8f92', '#a5a59f', '#7f8388', '#b0aea6'].map(C),
  industrial: ['#7d8791', '#8a8f86', '#6f7a85', '#a1823f', '#6b7570'].map(C),
  white: ['#d8dcd8', '#cfd6d4', '#c9ceca'].map(C),
  mall: ['#c8c3b5', '#b9b8b0'].map(C),
  car: ['#a83232', '#2e4f8a', '#d8d4c8', '#3a3f45', '#8a8f94', '#c9a227', '#2f6a4a', '#7a2f55', '#c7c9cc', '#5a3a2a'].map(C),
  container: ['#a33a2d', '#2d5a8a', '#3a7a4a', '#b08a2e', '#6a6f74', '#8a4a2a', '#c8c3b5'].map(C),
  barrel: ['#3d5ca0', '#a63a2e', '#4f6a3a', '#7a7a78', '#b08a2e'].map(C),
};
const DARK = new THREE.Color(0.32, 0.3, 0.29);
const pickC = (arr, r) => arr[Math.floor(r() * arr.length) % arr.length];
const tint = (c, f, out = new THREE.Color()) => out.copy(c).multiplyScalar(f);

// ------------------------------------------------------------------------------------------------------------------ generation
export function generateCity(gen, tier) {
  const L = {}; for (const n of ['house', 'box', 'towerA', 'towerB', 'towerC', 'towerD', 'ruinGlb', 'treeB', 'treeP', 'lamp', 'car', 'barrel', 'container', 'dumpster', 'barrier', 'fence', 'chimney', 'tank', 'canopy', 'rock', 'bush', 'tower']) L[n] = new InstList(n);
  const emit = [], labels = [];
  const seed = gen.sx;
  const lim = 2300, N = Math.ceil(lim / GRID);
  const H = GRID / 2 - ROAD_W / 2 - 3.4; // block half-extent (interior)
  const towerKeys = ['towerA', 'towerB', 'towerC', 'towerD'];
  const gY = (x, z) => gen.heightAt(x, z);

  function addBuilding(list, x, z, rot, w, h, d, col, style, lit, dmg, wallFrac) {
    const y = gY(x, z);
    list.add(x, y - 0.4, z, rot, w, h + 0.4, d, col, hash2(Math.round(x), Math.round(z), seed), style, lit, dmg);
  }
  const ruinify = (r, danger, kind) => (r() < clamp(0.05 + danger * 0.075, 0, 0.45) * (kind === 'rural' ? 0.5 : 1));

  function house(r, x, z, rot, danger, lit) {
    const w = r.range(9, 13), d = r.range(8, 11), floors = r() < 0.38 ? 2 : 1, wall = floors === 2 ? 5.9 : 3.0, tot = wall / 0.72;
    const ruin = ruinify(r, danger, '');
    const col = ruin ? tint(pickC(PAL.house, r), 0.55) : (r() < 0.22 ? pickC(PAL.brick, r) : pickC(PAL.house, r));
    addBuilding(L.house, x, z, rot, w, ruin ? tot * r.range(0.55, 0.85) : tot, d, col, 0, ruin ? 0.05 : lit, ruin ? r.range(0.35, 0.8) : 0);
    if (ruin && r() < 0.18) emit.push({ x, y: gY(x, z) + 4, z, kind: r() < 0.45 ? 'fire' : 'smoke', s: 1 });
    if (r() < 0.3) { const gx = x + Math.cos(rot) * (w / 2 + 3.2), gz = z - Math.sin(rot) * (w / 2 + 3.2); addBuilding(L.box, gx, gz, rot, 3.6, 2.8, 5.2, tint(pickC(PAL.concrete, r), 0.9), 0, 0.2, 0); } // garage
  }
  function boxB(r, x, z, rot, w, h, d, palette, style, danger, lit, kind) {
    const ruin = ruinify(r, danger, kind), col = ruin ? tint(pickC(palette, r), 0.5) : pickC(palette, r);
    addBuilding(L.box, x, z, rot, w, ruin ? h * r.range(0.4, 0.72) : h, d, col, style, ruin ? 0.04 : lit, ruin ? r.range(0.4, 0.85) : 0);
    if (ruin && r() < 0.22) emit.push({ x, y: gY(x, z) + h * 0.4, z, kind: r() < 0.4 ? 'fire' : 'smoke', s: 1 });
    return ruin;
  }
  function tree(r, x, z, s) {
    const y = gY(x, z); if (y < 0.3 && y > -50) return; // not in the sea / on the beach
    if (r() < 0.22 + (y > 14 ? 0.5 : 0)) L.treeP.add(x, y - 0.15, z, r() * TAU, s * 0.55, s * r.range(0.9, 1.35), s * 0.55, null, r(), 1);
    else L.treeB.add(x, y - 0.15, z, r() * TAU, s, s * r.range(0.9, 1.2), s, new THREE.Color().setHSL(0.26 + (r() - 0.5) * 0.06, 0.08 + r() * 0.1, 0.86 + r() * 0.3), r());
  }
  function car(r, x, z, rot, wreck) {
    const y = gY(x, z), col = wreck ? tint(pickC(PAL.car, r), 0.35) : pickC(PAL.car, r);
    L.car.add(x, y, z, rot + (wreck ? (r() - 0.5) * 0.5 : 0), 1, 1, 1, col, r(), wreck ? 1 : 0);
  }
  function lamp(x, z, rot) { L.lamp.add(x, gY(x, z), z, rot, 1, 6.8, 1, null, 0); }

  // ---------------------------------------------------------------- blocks
  for (let i = -N; i <= N; i++) for (let j = -N; j <= N; j++) {
    const cx = (i + 1) * GRID, cz = (j + 1) * GRID, dd = gen.density(cx, cz);
    if (dd < 0.15) continue;
    if (Math.hypot(cx, cz) < gen.compoundR + 38) continue;
    if (gen.nearHighway(cx, cz, 32)) continue;
    const r = rng(hash2(i, j, seed) * 4294967296 | 0), { d: dist, t } = gen.nearestDistrict(cx, cz);
    let kind = dist ? dist.kind : 'residential'; const danger = dist ? dist.danger : 1;
    if (Math.hypot(cx, cz) < 560 && t > 1.1) kind = 'residential';
    if (dd > 0.45 && Math.hypot(cx, cz) < 560 && kind === 'residential' && r() < 0.18) kind = 'mixed';
    const lit = clamp(0.18 + 0.3 * r() + (dd > 0.6 ? 0.2 : 0), 0.1, 0.65);
    // parks
    if (r() < 0.07 && kind !== 'industrial' && kind !== 'military') { for (let k = 0; k < 16; k++) tree(r, cx + r.range(-H, H), cz + r.range(-H, H), r.range(8, 13)); continue; }
    if (kind === 'residential' || kind === 'rural' || (kind === 'mixed' && dd < 0.5)) {
      const rural = kind === 'rural' || dd < 0.24;
      if (rural) { if (r() < 0.5) { house(r, cx + r.range(-20, 20), cz + r.range(-20, 20), r() * TAU, danger, lit); if (r() < 0.6) boxB(r, cx + r.range(-30, 30), cz + r.range(-30, 30), r() * PI, 15, 7, 9, [C('#8a4a3a'), C('#7a5a3a')], 2, danger, 0.05, 'rural'); } for (let k = 0; k < 7; k++) tree(r, cx + r.range(-H, H), cz + r.range(-H, H), r.range(7, 12)); continue; }
      const nS = 4;
      for (let side = 0; side < 4; side++) {
        const ang = side * PI / 2, dx = Math.round(Math.cos(ang)), dz = Math.round(Math.sin(ang)); // outward normal of this side
        const tx = -dz, tz = dx; // along the side
        for (let k = 0; k < nS; k++) {
          if (r() < 0.17) continue;
          const off = -29.25 + k * 19.5, inset = 7.5 + 5;
          const x = cx + dx * (H - inset) + tx * off + r.range(-1.2, 1.2), z = cz + dz * (H - inset) + tz * off + r.range(-1.2, 1.2);
          house(r, x, z, side % 2 === 0 ? PI / 2 : 0, danger, lit);
          if (r() < 0.55) tree(r, x + dx * -9 + r.range(-3, 3), z + dz * -9 + r.range(-3, 3), r.range(6, 10));
        }
      }
      for (let k = 0; k < 4; k++) tree(r, cx + r.range(-14, 14), cz + r.range(-14, 14), r.range(6, 10));
    } else if (kind === 'industrial') {
      const nb = r.int(1, 2);
      for (let k = 0; k < nb; k++) { const w = r.range(36, 60), d = r.range(22, 34), x = cx + (nb === 1 ? 0 : (k ? 1 : -1) * 20) + r.range(-6, 6), z = cz + r.range(-18, 18); boxB(r, x, z, r() < 0.5 ? 0 : PI / 2, w, r.range(8, 12), d, PAL.industrial, 2, danger, 0.1, kind); }
      for (let k = 0; k < r.int(2, 5); k++) { const x = cx + r.range(-H, H), z = cz + r.range(-H, H); L.container.add(x, gY(x, z), z, r.int(0, 3) * PI / 2, 1, 1, 1, pickC(PAL.container, r), r()); if (r() < 0.4) L.container.add(x, gY(x, z) + 2.6, z, r.int(0, 3) * PI / 2, 1, 1, 1, pickC(PAL.container, r), r()); }
      for (let k = 0; k < r.int(2, 6); k++) { const x = cx + r.range(-H, H), z = cz + r.range(-H, H); L.barrel.add(x, gY(x, z), z, 0, 1, 1, 1, pickC(PAL.barrel, r)); }
      if (r() < 0.45) { const x = cx + r.range(-30, 30), z = cz + r.range(-30, 30), rr = r.range(4, 7); L.tank.add(x, gY(x, z), z, 0, rr, r.range(8, 14), rr, tint(pickC(PAL.industrial, r), 1.1)); }
      if ((dist && (dist.id === 'foundry' || dist.id === 'millworks')) && r() < 0.45) { const x = cx + r.range(-30, 30), z = cz + r.range(-30, 30), h = r.range(28, 46); L.chimney.add(x, gY(x, z), z, 0, 3.4, h, 3.4, tint(pickC(PAL.brick, r), 0.9)); emit.push({ x, y: gY(x, z) + h, z, kind: 'smoke', s: 2.4, tall: true }); }
    } else if (kind === 'commercial') {
      if (r() < 0.42) { // mall + parking
        boxB(r, cx, cz - 10, 0, 62, 11, 34, PAL.mall, 1, danger, 0.28, kind);
        for (let row = 0; row < 2; row++) for (let k = 0; k < 11; k++) { if (r() < 0.45) car(r, cx - 30 + k * 6, cz + 20 + row * 8, 0, r() < 0.2); }
        for (let k = -2; k <= 2; k++) lamp(cx + k * 14, cz + 17, PI / 2);
      } else mixedBlock(r, cx, cz, dd, danger, lit, kind);
    } else if (kind === 'medical') {
      for (let k = 0; k < 3; k++) boxB(r, cx + (k - 1) * 26, cz + r.range(-6, 6), 0, 22, r.range(10, 20), 24, PAL.white, 3, danger, 0.4, kind);
      for (let k = 0; k < 8; k++) car(r, cx - 28 + k * 8, cz + 31, 0, r() < 0.2);
    } else if (kind === 'police') {
      boxB(r, cx, cz, 0, 38, 12, 24, PAL.concrete, 1, danger, 0.5, kind); for (let k = 0; k < 6; k++) car(r, cx - 24 + k * 9, cz + 24, 0, r() < 0.25);
      for (let k = -3; k <= 3; k++) L.barrier.add(cx + k * 2.5 + 40, gY(cx + k * 2.5 + 40, cz + 32), cz + 32, 0, 1, 1, 1, null);
    } else if (kind === 'fuel') {
      L.canopy.add(cx, gY(cx, cz), cz, 0, 22, 5.6, 11, null); addBuilding(L.box, cx + 22, cz - 12, 0, 12, 3.8, 8, pickC(PAL.white, r), 1, 0.4, 0);
      for (let k = 0; k < 3; k++) L.tank.add(cx - 22 + k * 6, gY(cx, cz), cz - 24, 0, 2.2, 2.6, 2.2, C('#a0a4a8'));
      for (let k = 0; k < 3; k++) car(r, cx - 8 + k * 7, cz + 4, PI / 2, r() < 0.4);
    } else if (kind === 'military') {
      for (let k = 0; k < 2; k++) boxB(r, cx + (k - 0.5) * 44, cz + r.range(-10, 10), 0, 40, 12, 26, [C('#7a8070'), C('#858a78')], 2, danger, 0.1, kind);
      for (let k = 0; k < 6; k++) L.barrel.add(cx + r.range(-H, H), 0, cz + r.range(-H, H), 0, 1, 1, 1, C('#4f5a3a'));
    } else mixedBlock(r, cx, cz, dd, danger, lit, kind);
  }
  function mixedBlock(r, cx, cz, dd, danger, lit, kind) {
    const nL = dd > 0.72 ? 2 : 3, lot = (H * 2) / nL;
    for (let a = 0; a < nL; a++) for (let b = 0; b < nL; b++) {
      const x = cx - H + lot * (a + 0.5), z = cz - H + lot * (b + 0.5);
      if (r() < 0.06) { for (let k = 0; k < 3; k++) tree(r, x + r.range(-8, 8), z + r.range(-8, 8), r.range(7, 11)); continue; }
      const tall = dd > 0.78 && r() < 0.34, fw = lot - r.range(3, 7), fd = lot - r.range(3, 7);
      if (tall && L.tower && r() < 0.5) { L[towerKeys[r.int(0, 3)]].add(x, gY(x, z) - 0.2, z, r.int(0, 3) * PI / 2, 1, 1, 1, null, r()); continue; }
      const h = 7 + Math.pow(r(), 2) * (tall ? 62 : 14) + (dd > 0.85 ? 8 : 0);
      boxB(r, x, z, 0, fw, h, fd, r() < 0.4 ? PAL.brick : PAL.concrete, h > 24 ? 3 : 1, danger, lit + 0.12, kind);
      if (r() < 0.25) L.dumpster.add(x + fw / 2 + 1.6, gY(x, z), z, PI / 2, 1, 1, 1, C('#3a5a3a'));
    }
  }

  // ---------------------------------------------------------------- street furniture along the lattice
  for (const e of gen.roads) {
    const len = Math.hypot(e.x1 - e.x0, e.z1 - e.z0), dx = (e.x1 - e.x0) / len, dz = (e.z1 - e.z0) / len, nx = -dz, nz = dx, r = rng(hash2(Math.round(e.x0), Math.round(e.z0), seed + 3) * 4294967296 | 0);
    const mx = (e.x0 + e.x1) / 2, mz = (e.z0 + e.z1) / 2, { d: dist } = gen.nearestDistrict(mx, mz), dd = gen.density(mx, mz), danger = dist ? dist.danger : 1;
    for (let s = 14; s < len - 12; s += 20) {
      const px = e.x0 + dx * s, pz = e.z0 + dz * s, side = r() < 0.5 ? 1 : -1;
      if (r() < 0.5 * (1 - dd * 0.5)) tree(r, px + nx * side * (ROAD_W / 2 + 2.3), pz + nz * side * (ROAD_W / 2 + 2.3), r.range(5.5, 8.5));
    }
    for (let s = 20; s < len - 16; s += 42) { const side = ((Math.round(s / 42) + Math.round(e.x0 / GRID)) & 1) ? 1 : -1, px = e.x0 + dx * s + nx * side * (ROAD_W / 2 + 1.1), pz = e.z0 + dz * s + nz * side * (ROAD_W / 2 + 1.1); lamp(px, pz, Math.atan2(-(-nz * side), -nx * side)); }
    for (let s = 12; s < len - 12; s += 14) if (r() < 0.2 + danger * 0.03) {
      const side = r() < 0.5 ? 1 : -1, px = e.x0 + dx * s + nx * side * (ROAD_W / 2 - 1.8), pz = e.z0 + dz * s + nz * side * (ROAD_W / 2 - 1.8);
      car(r, px, pz, Math.atan2(-dz, dx) + (side < 0 ? PI : 0) * 0 + (r() < 0.5 ? 0 : PI), r() < 0.12 + danger * 0.04);
    }
    if (danger >= 3 && r() < 0.18) { const s = r.range(18, len - 18); for (let k = -2; k <= 2; k++) { const px = e.x0 + dx * s + nx * k * 2.6, pz = e.z0 + dz * s + nz * k * 2.6; L.barrier.add(px, gY(px, pz), pz, Math.atan2(-dz, dx) + PI / 2, 1, 1, 1, null); } }
  }
  // highways: sparse wrecks + lamps-free
  for (const line of gen.hwList) { const r = rng(hash2(Math.round(line[0].x), Math.round(line[0].z), seed + 11) * 4294967296 | 0); for (let i = 3; i < line.length - 3; i += 3) if (r() < 0.2) { const a = line[i], b = line[i + 1], dx = b.x - a.x, dz = b.z - a.z, l = Math.hypot(dx, dz) || 1, side = r() < 0.5 ? 1 : -1; car(r, a.x + (-dz / l) * side * 3, a.z + (dx / l) * side * 3, Math.atan2(-dz, dx), r() < 0.5); } }

  // ---------------------------------------------------------------- wilderness: forests, rocks, bushes
  const rf = rng(seed * 101 + 7);
  const step = tier.name === 'low' ? 30 : 20;
  for (let x = -2300; x < 2300; x += step) for (let z = -2300; z < 2300; z += step) {
    const jx = x + (hash2(x, z, seed) - 0.5) * step, jz = z + (hash2(x, z, seed + 1) - 0.5) * step;
    if (Math.hypot(jx, jz) < gen.compoundR + 14) continue;
    const dd = gen.density(jx, jz); if (dd > 0.42) continue;
    const f = fbm2(jx * 0.0042 + 5, jz * 0.0042 - 3, 3, seed), p = clamp((f - 0.46) * 3.4, 0, 1) * (1 - dd * 2.2) + (dd < 0.2 ? 0.05 : 0);
    if (hash2(x, z, seed + 2) > p) continue;
    if (gen.nearHighway(jx, jz, 12)) continue;
    const y = gen.heightAt(jx, jz); if (y < 0.4) continue;
    if (hash2(x, z, seed + 3) < 0.05) { L.rock.add(jx, y - 0.2, jz, rf() * TAU, rf.range(0.8, 2.6), rf.range(0.6, 1.6), rf.range(0.8, 2.6), new THREE.Color().setHSL(0.1, 0.04, 0.3 + rf() * 0.12)); continue; }
    if (hash2(x, z, seed + 4) < 0.1) { L.bush.add(jx, y - 0.1, jz, rf() * TAU, rf.range(0.9, 1.7), rf.range(0.7, 1.2), rf.range(0.9, 1.7), new THREE.Color().setHSL(0.25 + rf() * 0.05, 0.3, 0.2 + rf() * 0.1)); continue; }
    tree(rf, jx, jz, rf.range(7, 14));
  }

  // ---------------------------------------------------------------- the colony compound: garage, fence ring, wrecks, lamps (the base gets its own buildings from the sim)
  { const rc = rng(seed * 13 + 1), gx = 30, gz = 20;
    addBuilding(L.box, gx, gz, 0, 16, 5.2, 10, C('#8a8e90'), 2, 0.5, 0);
    for (let a = 0; a < TAU; a += TAU / 150) { if (rc() < 0.34) continue; const R = gen.compoundR - 5 + rc.range(-1, 1); L.fence.add(Math.cos(a) * R, gY(Math.cos(a) * R, Math.sin(a) * R), Math.sin(a) * R, -a + PI / 2, 4, 1, 1, null); }
    for (let k = 0; k < 7; k++) { const a = rc() * TAU, R = rc.range(58, 82); car(rc, Math.cos(a) * R, Math.sin(a) * R, rc() * TAU, true); }
    for (let k = 0; k < 8; k++) { const a = k * TAU / 8 + 0.2, R = 62; lamp(Math.cos(a) * R, Math.sin(a) * R, a + PI); }
    for (let k = 0; k < 14; k++) { const a = rc() * TAU, R = rc.range(40, 85); L.barrel.add(Math.cos(a) * R, 0, Math.sin(a) * R, 0, 1, 1, 1, pickC(PAL.barrel, rc)); }
    for (let k = 0; k < 4; k++) { const a = rc() * TAU, R = rc.range(30, 80); L.dumpster.add(Math.cos(a) * R, 0, Math.sin(a) * R, rc() * TAU, 1, 1, 1, C('#3a5a3a')); }
    for (let k = 0; k < 10; k++) { const a = rc() * TAU, R = rc.range(62, 90); L.rock.add(Math.cos(a) * R, 0, Math.sin(a) * R, rc() * TAU, rc.range(0.5, 1.4), rc.range(0.4, 0.9), rc.range(0.5, 1.4), new THREE.Color().setHSL(0.1, 0.04, 0.34)); }
  }
  // a few free-standing ruins (GLB shell) in the outskirts of the suburbs
  { const rr = rng(seed * 17 + 5); for (let k = 0; k < 60; k++) { const a = rr() * TAU, R = rr.range(170, 900), x = Math.cos(a) * R, z = Math.sin(a) * R; if (gen.density(x, z) > 0.6 || gen.nearHighway(x, z, 26)) continue; L.ruinGlb.add(x, gY(x, z) - 0.1, z, rr() * TAU, 6, 6, 6, null, rr()); } }
  for (const q of gen.districts) labels.push({ id: q.id, name: q.name || q.id, x: q.x, z: q.z, danger: q.danger, kind: q.kind });
  for (const n of Object.keys(L)) L[n].finalize();
  return { L, emit, labels };
}

// ------------------------------------------------------------------------------------------------------------------ the City object
export class City {
  constructor(gen, tier, models) {
    this.gen = gen; this.tier = tier; this.models = models; this.group = new THREE.Group(); this.group.name = 'city';
    const t0 = performance.now(); const g = generateCity(gen, tier); this.L = g.L; this.emit = g.emit; this.labels = g.labels; this.genMs = performance.now() - t0;
    this.pools = {}; this.tmpGeo = {}; this.last = { x: 1e9, z: 1e9 }; this.build();
  }
  build() {
    const { tier, models: M, L } = this, P = tier.pool, add = (name, parts, cap, o) => { const p = new Pool(parts, Math.max(1, cap), o); this.pools[name] = p; this.group.add(p.group); return p; };
    const bm = makeBuildingMaterial(1), hm = makeBuildingMaterial(0.72), vm = makeVertexMaterial(), lm = makeVertexMaterial({ lamp: true });
    this.mats = { bm, hm, vm, lm };
    add('house', [{ geometry: gableGeo(0.72), material: hm }], P.house); add('box', [{ geometry: unitBox(), material: bm }], P.box);
    add('lamp', [{ geometry: lampGeo(), material: lm }], P.lamp, { castShadow: false, params: false });
    add('car', [{ geometry: carGeo(), material: vm }], P.car, { params: false });
    const pc = Math.ceil(P.prop / 3);
    add('barrel', [{ geometry: barrelGeo(), material: vm }], pc, { params: false }); add('container', [{ geometry: containerGeo(), material: vm }], pc, { params: false });
    add('dumpster', [{ geometry: dumpsterGeo(), material: vm }], Math.ceil(pc / 2), { params: false }); add('barrier', [{ geometry: barrierGeo(), material: vm }], pc, { params: false });
    add('fence', [{ geometry: fenceGeo(), material: vm }], 160, { params: false, castShadow: false }); add('chimney', [{ geometry: chimneyGeo(), material: vm }], 24, { params: false });
    add('tank', [{ geometry: tankGeo(), material: vm }], 40, { params: false }); add('canopy', [{ geometry: canopyGeo(), material: vm }], 12, { params: false });
    const rockG = new THREE.IcosahedronGeometry(1, 1); { const p = rockG.attributes.position; for (let i = 0; i < p.count; i++) { const k = 0.8 + 0.4 * hash2(Math.round(p.getX(i) * 50), Math.round(p.getY(i) * 50), Math.round(p.getZ(i) * 50)); p.setXYZ(i, p.getX(i) * k, p.getY(i) * k * 0.8, p.getZ(i) * k); } rockG.computeVertexNormals(); }
    add('rock', [{ geometry: rockG, material: new THREE.MeshStandardMaterial({ roughness: 1, flatShading: true }) }], Math.ceil(pc * 1.2), { params: false });
    const bushG = new THREE.IcosahedronGeometry(1, 1); { const p = bushG.attributes.position; for (let i = 0; i < p.count; i++) p.setY(i, Math.max(p.getY(i) * 0.75, -0.2) + 0.2); bushG.computeVertexNormals(); }
    add('bush', [{ geometry: bushG, material: new THREE.MeshStandardMaterial({ roughness: 1, flatShading: true }) }], Math.ceil(pc * 1.2), { params: false });
    // trees: GLB broadleaf near the camera (2 parts), simple procedural ones beyond; pines always procedural
    const treeParts = M && M.has('props') ? bake(M.scene('props'), { filter: o => /^tree/.test(o.name), height: 1 }) : [];
    if (treeParts.length >= 2 && tier.treesGlb > 0) {
      treeParts.sort((a, b) => a.geometry.boundingBox.max.y - b.geometry.boundingBox.max.y);
      const parts = treeParts.map((p, i) => ({ geometry: p.geometry, material: makeVertexMaterialFlat(i === 0 ? 0x5a4331 : 0x4d7a35, i === 1) }));
      add('treeNear', parts, tier.treesGlb, { params: false });
    } else this.pools.treeNear = null;
    add('treeFar', [{ geometry: treeBroadGeo(), material: vm }], Math.ceil(P.tree * 0.62), { params: false }); add('treePine', [{ geometry: treePineGeo(), material: vm }], Math.ceil(P.tree * 0.38), { params: false });
    // GLB tower blocks
    const spec = [['apartment_a', 26], ['apartment_b', 62], ['apartment_c', 24], ['apartment_d', 40]];
    spec.forEach(([n, h], i) => {
      if (!M || !M.has(n)) return;
      const parts = bake(M.scene(n), { height: h }).map(p => ({ geometry: p.geometry, material: patchTowerMaterial(p.material) }));
      if (parts.length) add('tower' + 'ABCD'[i], parts, P.tower);
    });
    if (M && M.has('ruin')) add('ruinGlb', bake(M.scene('ruin'), { height: 1 }).map(p => ({ geometry: p.geometry, material: patchPlain(p.material) })), Math.min(16, P.ruin), { params: false });
    // lamp light pools on the ground (additive decals)
    const quad = new THREE.PlaneGeometry(1, 1).rotateX(-PI / 2);
    const gm = new THREE.ShaderMaterial({ transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, uniforms: { uNight: U.night, uLamps: U.lamps }, vertexShader: 'varying vec2 vUv; void main(){ vUv = uv; vec4 p = instanceMatrix * vec4(position, 1.0); gl_Position = projectionMatrix * viewMatrix * modelMatrix * p; }',
      fragmentShader: 'varying vec2 vUv; uniform float uNight; uniform float uLamps; void main(){ float d = length(vUv - 0.5) * 2.0; float a = smoothstep(1.0, 0.0, d); a *= a; gl_FragColor = vec4(vec3(1.0, 0.72, 0.4) * a * 0.55 * uNight * uLamps, 1.0); }' });
    this.glow = new THREE.InstancedMesh(quad, gm, Math.max(1, P.lamp)); this.glow.count = 0; this.glow.frustumCulled = false; this.glow.renderOrder = 3; this.group.add(this.glow);
  }
  // refill pools around the focus when it has moved far enough (or when forced)
  update(fx, fz, force) {
    const dx = fx - this.last.x, dz = fz - this.last.z; if (!force && dx * dx + dz * dz < 36 * 36) return false;
    this.last.x = fx; this.last.z = fz; const R = Math.min(this.tier.view, 1700), { L, pools } = this, q = n => L[n].query(fx, fz, R);
    const idx = {}; for (const n of ['house', 'box', 'lamp', 'car', 'barrel', 'container', 'dumpster', 'barrier', 'fence', 'chimney', 'tank', 'canopy', 'rock', 'bush', 'ruinGlb', 'treeB', 'treeP', 'towerA', 'towerB', 'towerC', 'towerD']) idx[n] = q(n);
    for (const n of ['house', 'box', 'lamp', 'car', 'barrel', 'container', 'dumpster', 'barrier', 'fence', 'chimney', 'tank', 'canopy', 'rock', 'bush']) pools[n].fill(L[n], idx[n], 0, pools[n].cap);
    for (const n of ['A', 'B', 'C', 'D']) { const p = pools['tower' + n]; if (p) p.fill(L['tower' + n], idx['tower' + n], 0, p.cap); }
    if (pools.ruinGlb) pools.ruinGlb.fill(L.ruinGlb, idx.ruinGlb, 0, pools.ruinGlb.cap);
    const near = pools.treeNear ? pools.treeNear.cap : 0;
    if (pools.treeNear) pools.treeNear.fill(L.treeB, idx.treeB, 0, near);
    pools.treeFar.fill(L.treeB, idx.treeB, near, near + pools.treeFar.cap); pools.treePine.fill(L.treeP, idx.treeP, 0, pools.treePine.cap);
    // lamp light pools
    const gl = this.glow, n = Math.min(pools.lamp.count, gl.instanceMatrix.count), lm = pools.lamp.mat, A = gl.instanceMatrix.array;
    for (let k = 0; k < n; k++) { const b = k * 16, s = 12; A[b] = s; A[b + 1] = 0; A[b + 2] = 0; A[b + 3] = 0; A[b + 4] = 0; A[b + 5] = 1; A[b + 6] = 0; A[b + 7] = 0; A[b + 8] = 0; A[b + 9] = 0; A[b + 10] = s; A[b + 11] = 0; A[b + 12] = lm[b + 12] + lm[b] * 0.8; A[b + 13] = lm[b + 13] + 0.15; A[b + 14] = lm[b + 14] + lm[b + 2] * 0.8; A[b + 15] = 1; }
    gl.count = n; gl.instanceMatrix.needsUpdate = true;
    return true;
  }
  counts() { const o = {}; for (const [k, p] of Object.entries(this.pools)) if (p) o[k] = p.count; return o; }
  totalTris() { let t = 0; for (const p of Object.values(this.pools)) if (p) for (const m of p.meshes) t += m.count * (m.geometry.index ? m.geometry.index.count : m.geometry.attributes.position.count) / 3; return t; }
}
function makeVertexMaterialFlat(hex, foliage) {
  const m = new THREE.MeshStandardMaterial({ color: hex, roughness: 0.9, flatShading: false });
  if (foliage) { m.onBeforeCompile = s => { s.uniforms.uSeason = U.season; s.fragmentShader = s.fragmentShader.replace('#include <common>', '#include <common>\nuniform vec4 uSeason;').replace('#include <color_fragment>', '#include <color_fragment>\ndiffuseColor.rgb *= uSeason.rgb; diffuseColor.rgb = mix(diffuseColor.rgb, vec3(0.86, 0.9, 0.95), uSeason.w * 0.8);'); }; m.customProgramCacheKey = () => 'treefol'; }
  return m;
}
function patchPlain(mat) { mat = mat.clone(); mat.roughness = 0.95; mat.metalness = 0; return mat; }
