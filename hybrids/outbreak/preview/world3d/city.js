// Outbreak 3D: the procedural settlement. Instance lists are generated once per seed (blocks, houses, towers, ruins, trees, lamps, cars, props, landmarks);
// each list is drawn through a streamed InstancedMesh pool that always holds the nearest N instances to the camera focus, so the draw-call count is
// constant and distant detail drops out inside the fog. Building windows (day glass / night glow), roofs and grime are procedural shader code on one
// shared material per building type: no textures. Original art; GLB towers / props from the cloned library are optional (models.js) with fallbacks.
import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';
import { clamp, lerp, sstep, rng, hash2, noise2, fbm2, PI, TAU } from './util.js';
import { U } from './sky.js';
import { GRID, ROAD_W, patch, GLSL_NOISE } from './terrain.js';
import { bake } from './models.js';

// ---------------------------------------------------------------------------------------------------------------- instance lists
// stride: x y z rot sx sy sz r g b p0 p1 p2 p3
export const STRIDE = 14;
export class InstList {
  constructor(name) { this.name = name; this.a = []; this.n = 0; this.d = null; this.cells = new Map(); this._qk = ''; this._q = null; }
  add(x, y, z, rot, sx, sy, sz, col, p0 = 0, p1 = 0, p2 = 0, p3 = 0) {
    const c = col || _white; this.a.push(x, y, z, rot, sx, sy, sz, c.r, c.g, c.b, p0, p1, p2, p3); this.n++; return this.n - 1;
  }
  finalize() {
    this.d = new Float32Array(this.a); this.a = null; this.cells.clear();
    for (let i = 0; i < this.n; i++) { const k = Math.floor(this.d[i * STRIDE] / 128) * 8192 + Math.floor(this.d[i * STRIDE + 2] / 128); let c = this.cells.get(k); if (!c) this.cells.set(k, c = []); c.push(i); }
    return this;
  }
  // indices of the instances within R of (fx, fz), nearest first
  query(fx, fz, R) {
    const key = Math.round(fx / 8) + ',' + Math.round(fz / 8) + ',' + R; if (key === this._qk) return this._q;
    const out = [], dist = [], r2 = R * R, c0 = Math.floor((fx - R) / 128), c1 = Math.floor((fx + R) / 128), z0 = Math.floor((fz - R) / 128), z1 = Math.floor((fz + R) / 128), d = this.d;
    for (let cx = c0; cx <= c1; cx++) for (let cz = z0; cz <= z1; cz++) { const c = this.cells.get(cx * 8192 + cz); if (!c) continue; for (const i of c) { const dx = d[i * STRIDE] - fx, dz = d[i * STRIDE + 2] - fz, q = dx * dx + dz * dz; if (q <= r2) { out.push(i); dist.push(q); } } }
    const ord = out.map((_, k) => k).sort((a, b) => dist[a] - dist[b]); const res = new Int32Array(ord.length); for (let k = 0; k < ord.length; k++) res[k] = out[ord[k]];
    this._qk = key; this._q = res; return res;
  }
}
const _white = new THREE.Color(1, 1, 1);

// A pool = one InstancedMesh per part of a model; fill() copies the chosen instances' matrices / colours / params.
export class Pool {
  constructor(parts, cap, { castShadow = true, receiveShadow = true, params = true } = {}) {
    this.cap = cap; this.meshes = []; this.count = 0; this.mat = new Float32Array(cap * 16); this.col = new Float32Array(cap * 3); this.par = new Float32Array(cap * 4); this.group = new THREE.Group();
    for (const p of parts) {
      const geo = p.geometry;
      if (params && !geo.attributes.aParams) { /* attribute added per mesh below */ }
      const g = geo.clone ? geo : geo; // geometries are baked per pool, safe to reuse the object
      const m = new THREE.InstancedMesh(g, p.material, cap);
      m.instanceMatrix.setUsage(THREE.DynamicDrawUsage); m.count = 0; m.frustumCulled = false; m.castShadow = castShadow; m.receiveShadow = receiveShadow;
      m.instanceColor = new THREE.InstancedBufferAttribute(new Float32Array(cap * 3), 3); m.instanceColor.setUsage(THREE.DynamicDrawUsage);
      if (params) { g.setAttribute('aParams', new THREE.InstancedBufferAttribute(new Float32Array(cap * 4), 4)); g.attributes.aParams.setUsage(THREE.DynamicDrawUsage); }
      m.name = p.name || 'pool'; this.group.add(m); this.meshes.push(m);
    }
  }
  fill(list, idx, from, to) {
    const n = Math.max(0, Math.min(this.cap, to - from, idx.length - from)), d = list.d, M = this.mat, C = this.col, P = this.par;
    for (let k = 0; k < n; k++) {
      const o = idx[from + k] * STRIDE, c = Math.cos(d[o + 3]), s = Math.sin(d[o + 3]), sx = d[o + 4], sy = d[o + 5], sz = d[o + 6], b = k * 16;
      M[b] = c * sx; M[b + 1] = 0; M[b + 2] = -s * sx; M[b + 3] = 0; M[b + 4] = 0; M[b + 5] = sy; M[b + 6] = 0; M[b + 7] = 0; M[b + 8] = s * sz; M[b + 9] = 0; M[b + 10] = c * sz; M[b + 11] = 0;
      M[b + 12] = d[o]; M[b + 13] = d[o + 1]; M[b + 14] = d[o + 2]; M[b + 15] = 1;
      C[k * 3] = d[o + 7]; C[k * 3 + 1] = d[o + 8]; C[k * 3 + 2] = d[o + 9];
      P[k * 4] = d[o + 10]; P[k * 4 + 1] = d[o + 11]; P[k * 4 + 2] = d[o + 12]; P[k * 4 + 3] = d[o + 13];
    }
    for (const m of this.meshes) {
      m.instanceMatrix.array.set(M.subarray(0, n * 16)); m.instanceMatrix.needsUpdate = true;
      m.instanceColor.array.set(C.subarray(0, n * 3)); m.instanceColor.needsUpdate = true;
      const pa = m.geometry.attributes.aParams; if (pa) { pa.array.set(P.subarray(0, n * 4)); pa.needsUpdate = true; }
      m.count = n;
    }
    this.count = n; return n;
  }
  dispose() { for (const m of this.meshes) { m.dispose(); } }
}

// ---------------------------------------------------------------------------------------------------------------- procedural geometry
export function colorize(g, hex, emit = 0, fol = 0) {
  const c = new THREE.Color(hex), n = g.attributes.position.count, a = new Float32Array(n * 3), e = new Float32Array(n).fill(emit), f = new Float32Array(n).fill(fol);
  for (let i = 0; i < n; i++) { a[i * 3] = c.r; a[i * 3 + 1] = c.g; a[i * 3 + 2] = c.b; }
  g.setAttribute('color', new THREE.BufferAttribute(a, 3)); g.setAttribute('aEmit', new THREE.BufferAttribute(e, 1)); g.setAttribute('aFol', new THREE.BufferAttribute(f, 1)); return g;
}
export const strip = g => { g = g.index ? g.toNonIndexed() : g; for (const k of Object.keys(g.attributes)) if (!['position', 'normal', 'uv', 'color', 'aEmit', 'aFol'].includes(k)) g.deleteAttribute(k); if (!g.attributes.uv) g.setAttribute('uv', new THREE.BufferAttribute(new Float32Array(g.attributes.position.count * 2), 2)); return g; };
export const T = (g, x, y, z) => g.translate(x, y, z);

export function unitBox() { const g = new THREE.BoxGeometry(1, 1, 1); g.translate(0, 0.5, 0); return g; }
export function gableGeo(wallFrac = 0.72) {
  // body (box to wallFrac) + roof prism (ridge along x) with small eaves; non-indexed with flat normals
  const w = 0.5, e = 0.04, wf = wallFrac, P = [], N = [], uv = [];
  const quad = (a, b, c, d, n) => { for (const v of [a, b, c, a, c, d]) { P.push(...v); N.push(...n); uv.push(0, 0); } };
  const tri = (a, b, c, n) => { for (const v of [a, b, c]) { P.push(...v); N.push(...n); uv.push(0, 0); } };
  // walls
  quad([-w, 0, w], [w, 0, w], [w, wf, w], [-w, wf, w], [0, 0, 1]); quad([w, 0, -w], [-w, 0, -w], [-w, wf, -w], [w, wf, -w], [0, 0, -1]);
  quad([w, 0, w], [w, 0, -w], [w, wf, -w], [w, wf, w], [1, 0, 0]); quad([-w, 0, -w], [-w, 0, w], [-w, wf, w], [-w, wf, -w], [-1, 0, 0]);
  // gable ends
  tri([w, wf, w], [w, wf, -w], [w, 1, 0], [1, 0, 0]); tri([-w, wf, -w], [-w, wf, w], [-w, 1, 0], [-1, 0, 0]);
  // roof (slopes to +z / -z)
  const rz = w + e, rx = w + e, len = Math.hypot(rz, 1 - wf), sn = [0, rz / len, (1 - wf) / len];
  quad([-rx, wf - 0.02, rz], [rx, wf - 0.02, rz], [rx, 1, 0], [-rx, 1, 0], [0, sn[1], sn[2]]);
  quad([rx, wf - 0.02, -rz], [-rx, wf - 0.02, -rz], [-rx, 1, 0], [rx, 1, 0], [0, sn[1], -sn[2]]);
  const g = new THREE.BufferGeometry(); g.setAttribute('position', new THREE.Float32BufferAttribute(P, 3)); g.setAttribute('normal', new THREE.Float32BufferAttribute(N, 3)); g.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
  return g;
}
export function treeBroadGeo() { // unit tree: 1 m tall, authored so scale = height
  const parts = [];
  parts.push(colorize(strip(T(new THREE.CylinderGeometry(0.035, 0.05, 0.46, 6), 0, 0.23, 0)), 0x5a4030));
  const blob = (x, y, z, r, c) => { const g = strip(new THREE.IcosahedronGeometry(r, 0)); const p = g.attributes.position; for (let i = 0; i < p.count; i++) { const k = 1 + (hash2(Math.round(p.getX(i) * 100), Math.round(p.getY(i) * 100), Math.round(p.getZ(i) * 100)) - 0.5) * 0.22; p.setXYZ(i, p.getX(i) * k, p.getY(i) * k * 0.9, p.getZ(i) * k); } g.translate(x, y, z); g.computeVertexNormals(); return colorize(g, c, 0, 1); };
  parts.push(blob(0, 0.66, 0, 0.3, 0x3f6a2c), blob(0.17, 0.52, 0.06, 0.2, 0x4a7a32), blob(-0.15, 0.55, -0.08, 0.21, 0x366028), blob(0.02, 0.84, 0.03, 0.2, 0x55843a));
  return mergeGeometries(parts);
}
export function treePineGeo() {
  const parts = [colorize(strip(T(new THREE.CylinderGeometry(0.025, 0.04, 0.3, 5), 0, 0.15, 0)), 0x4e382a)];
  for (let i = 0; i < 4; i++) { const r = 0.26 - i * 0.052, h = 0.36 - i * 0.03; parts.push(colorize(strip(T(new THREE.ConeGeometry(r, h, 7), 0, 0.3 + i * 0.19 + h / 2, 0)), i % 2 ? 0x2c5230 : 0x24472a, 0, 1)); }
  return mergeGeometries(parts);
}
export function lampGeo() { // unit: 1 = 7 m tall pole with an arm; head is emissive
  const parts = [];
  parts.push(colorize(strip(T(new THREE.CylinderGeometry(0.011, 0.016, 1, 6), 0, 0.5, 0)), 0x2c3036));
  parts.push(colorize(strip(T(new THREE.BoxGeometry(0.16, 0.012, 0.012), 0.08, 0.995, 0)), 0x2c3036));
  parts.push(colorize(strip(T(new THREE.BoxGeometry(0.075, 0.012, 0.035), 0.17, 0.985, 0)), 0xffe0a0, 1));
  parts.push(colorize(strip(T(new THREE.BoxGeometry(0.085, 0.01, 0.045), 0.17, 0.996, 0)), 0x3a3e44));
  return mergeGeometries(parts);
}
export function carGeo() { // 4.3 x 1.45 x 1.8 m sedan, body white (tinted per instance), glass / wheels dark
  const parts = [];
  parts.push(colorize(strip(T(new THREE.BoxGeometry(4.3, 0.75, 1.8), 0, 0.72, 0)), 0xffffff));
  parts.push(colorize(strip(T(new THREE.BoxGeometry(2.2, 0.62, 1.64), -0.25, 1.38, 0)), 0xffffff));
  parts.push(colorize(strip(T(new THREE.BoxGeometry(2.0, 0.5, 1.7), -0.25, 1.38, 0)), 0x16202a));
  for (const [x, z] of [[1.4, 0.88], [1.4, -0.88], [-1.4, 0.88], [-1.4, -0.88]]) parts.push(colorize(strip(T(new THREE.CylinderGeometry(0.34, 0.34, 0.26, 10).rotateX(PI / 2), x, 0.34, z)), 0x101114));
  parts.push(colorize(strip(T(new THREE.BoxGeometry(0.06, 0.16, 1.5), 2.16, 0.82, 0)), 0xffe9b0, 0.35)); parts.push(colorize(strip(T(new THREE.BoxGeometry(0.06, 0.14, 1.5), -2.16, 0.82, 0)), 0xb02020, 0.12));
  return mergeGeometries(parts);
}
export function barrelGeo() { return mergeGeometries([colorize(strip(T(new THREE.CylinderGeometry(0.3, 0.3, 0.9, 10), 0, 0.45, 0)), 0xffffff), colorize(strip(T(new THREE.CylinderGeometry(0.31, 0.31, 0.04, 10), 0, 0.5, 0)), 0x2a2a2a), colorize(strip(T(new THREE.CylinderGeometry(0.31, 0.31, 0.04, 10), 0, 0.2, 0)), 0x2a2a2a)]); }
export function containerGeo() { const g = colorize(strip(T(new THREE.BoxGeometry(6, 2.6, 2.4), 0, 1.3, 0)), 0xffffff); const ribs = []; for (let i = -2; i <= 2; i++) { ribs.push(colorize(strip(T(new THREE.BoxGeometry(0.12, 2.5, 2.46), i * 1.1, 1.3, 0)), 0xcfcfcf)); } return mergeGeometries([g, ...ribs]); }
export function dumpsterGeo() { return mergeGeometries([colorize(strip(T(new THREE.BoxGeometry(2.0, 1.2, 1.1), 0, 0.7, 0)), 0xffffff), colorize(strip(T(new THREE.BoxGeometry(2.05, 0.08, 1.15), 0, 1.34, 0)), 0x222426)]); }
export function barrierGeo() { return mergeGeometries([colorize(strip(T(new THREE.BoxGeometry(2.4, 0.9, 0.5), 0, 0.45, 0)), 0xa8a8a2), colorize(strip(T(new THREE.BoxGeometry(2.4, 0.5, 0.8), 0, 0.25, 0)), 0x9a9a94)]); }
export function fenceGeo() { const p = []; for (const x of [-0.5, 0.5]) p.push(colorize(strip(T(new THREE.BoxGeometry(0.07, 1.5, 0.07), x, 0.75, 0)), 0x6f6a60)); for (const y of [0.45, 0.95, 1.4]) p.push(colorize(strip(T(new THREE.BoxGeometry(1, 0.06, 0.04), 0, y, 0)), 0x8a857a)); for (let i = 0; i < 5; i++) p.push(colorize(strip(T(new THREE.BoxGeometry(0.012, 1.3, 0.012), -0.4 + i * 0.2, 0.7, 0)), 0x9aa0a4)); return mergeGeometries(p); }
export function chimneyGeo() { return mergeGeometries([colorize(strip(T(new THREE.CylinderGeometry(0.34, 0.5, 1, 10), 0, 0.5, 0)), 0xffffff), colorize(strip(T(new THREE.CylinderGeometry(0.36, 0.36, 0.04, 10), 0, 0.97, 0)), 0x2a1e1a)]); }
export function tankGeo() { return mergeGeometries([colorize(strip(T(new THREE.CylinderGeometry(1, 1, 1, 14), 0, 0.5, 0)), 0xffffff), colorize(strip(T(new THREE.CylinderGeometry(1.01, 1.01, 0.03, 14), 0, 0.5, 0)), 0x444a50)]); }
export function canopyGeo() { const p = [colorize(strip(T(new THREE.BoxGeometry(1, 0.06, 1), 0, 0.97, 0)), 0xffffff, 0), colorize(strip(T(new THREE.BoxGeometry(1.01, 0.03, 1.01), 0, 0.95, 0)), 0xdd3030, 0.25)]; for (const [x, z] of [[-0.42, -0.4], [0.42, -0.4], [-0.42, 0.4], [0.42, 0.4]]) p.push(colorize(strip(T(new THREE.BoxGeometry(0.03, 0.95, 0.03), x, 0.475, z)), 0x9a9a9a)); return mergeGeometries(p); }

// ---------------------------------------------------------------------------------------------------------------- materials
const WINDOW_HEAD = `
varying vec4 vP; varying vec3 vM; varying vec3 vON; varying vec3 vSc; uniform float uNight; uniform float uMains; uniform float uWallFrac; uniform float uTime; uniform float uWet;
${GLSL_NOISE}
float hh(vec3 p){ return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453); }
`;
export function makeBuildingMaterial(wallFrac = 1) {
  const m = new THREE.MeshStandardMaterial({ color: 0xffffff, roughness: 0.92, metalness: 0.02 });
  patch(m, {
    key: 'bld' + wallFrac,
    vHead: 'attribute vec4 aParams; varying vec4 vP; varying vec3 vM; varying vec3 vON; varying vec3 vSc;',
    vMain: `vec3 sc = vec3(1.0);\n#ifdef USE_INSTANCING\n sc = vec3(length(instanceMatrix[0].xyz), length(instanceMatrix[1].xyz), length(instanceMatrix[2].xyz));\n#endif\n vSc = sc; vM = position * sc; vON = normal; vP = aParams;`,
    fHead: WINDOW_HEAD,
    fColor: `
      vec3 emitB = vec3(0.0);
      {
        vec3 n = normalize(vON); float seed = vP.x, style = vP.y, litP = vP.z, dmg = vP.w; float y = vM.y;
        bool roof = n.y > 0.3; float wallH = vSc.y * uWallFrac;
        if (roof) {
          vec3 rc = hh(vec3(floor(seed * 100.0), 1.0, 2.0)) < 0.5 ? vec3(0.19, 0.18, 0.19) : vec3(0.34, 0.2, 0.15);
          if (uWallFrac < 0.99) { float k = floor(hh(vec3(floor(seed * 100.0), 3.0, 4.0)) * 4.0); rc = k < 1.0 ? vec3(0.3, 0.21, 0.18) : k < 2.0 ? vec3(0.2, 0.22, 0.25) : k < 3.0 ? vec3(0.34, 0.24, 0.17) : vec3(0.19, 0.25, 0.21); }
          else rc = mix(vec3(0.15, 0.15, 0.16), rc * 0.7, step(0.7, hh(vec3(floor(seed * 100.0), 5.0, 6.0))));
          rc *= 0.8 + 0.4 * vn(vM.xz * 0.9 + seed * 30.0);
          diffuseColor.rgb = rc * (1.0 - dmg * 0.5);
        } else if (abs(n.y) < 0.5) {
          bool xface = abs(n.x) > 0.5; float u = (xface ? vM.z : vM.x) + seed * 9.0; float halfLen = (xface ? vSc.z : vSc.x) * 0.5;
          float floorH = style < 0.5 ? 3.0 : style < 1.5 ? 3.6 : style < 2.5 ? 4.6 : 3.9; float winW = style < 0.5 ? 3.2 : style < 1.5 ? 3.0 : style < 2.5 ? 5.2 : 2.6;
          float fy = floor(y / floorH), fv = fract(y / floorH), cu = floor(u / winW), fu = fract(u / winW);
          vec2 lo = vec2(0.3, 0.3), hi = vec2(0.7, 0.8);
          if (style > 2.5 && style < 3.5) { lo = vec2(0.04, 0.2); hi = vec2(0.96, 0.82); }
          else if (style > 1.5 && style < 2.5) { lo = vec2(0.12, 0.5); hi = vec2(0.88, 0.86); }
          else if (style > 0.5 && style < 1.5) { lo = vec2(0.14, 0.26); hi = vec2(0.86, 0.8); if (fy < 0.5) { lo = vec2(0.06, 0.1); hi = vec2(0.94, 0.88); } }
          float inW = step(lo.x, fu) * step(fu, hi.x) * step(lo.y, fv) * step(fv, hi.y);
          inW *= step(1.1, halfLen - abs(xface ? vM.z : vM.x)) * step(y, wallH - 0.8) * step(0.5, y);
          if (style > 1.5 && style < 2.5) inW *= step(4.0, y);
          float lit = step(hh(vec3(cu, fy, floor(seed * 97.0))), litP * uNight * uMains);
          float broken = step(0.82, hh(vec3(cu + 3.0, fy, floor(seed * 53.0)))) * (0.4 + dmg);
          vec3 base = diffuseColor.rgb;
          float grime = smoothstep(2.8, 0.0, y) * 0.35 + (1.0 - vn(vec2(u * 0.6, y * 0.06))) * 0.1;
          base *= 1.0 - grime; base *= 0.9 + 0.2 * vn(vec2(u, y) * 0.35);
          base *= 1.0 - 0.1 * smoothstep(0.1, 0.0, fv) * (1.0 - inW);
          base = mix(base, vec3(0.04), dmg * 0.7 * step(0.5, vn(vM.xz * 0.5 + y * 0.3)));
          vec3 glass = fogColor * 0.3 + vec3(0.035, 0.045, 0.06); glass = mix(glass, vec3(0.02), broken);
          diffuseColor.rgb = mix(base, glass, inW);
          float emitK = inW * lit * (1.0 - broken * 0.85);
          vec3 warm = mix(vec3(1.0, 0.68, 0.32), vec3(0.62, 0.78, 1.0), step(0.78, hh(vec3(cu, fy, 9.0)))); emitB = warm * emitK * 1.5;
          if (dmg > 0.0) { float cut = vSc.y * uWallFrac * (1.0 - 0.0 * dmg); }
        }
      }`,
    fRough: 'roughnessFactor = mix(roughnessFactor, 0.4, uWet * 0.6);',
    fEmit: 'totalEmissiveRadiance += emitB;',
    uniforms: { uNight: U.night, uMains: U.mains, uWallFrac: { value: wallFrac }, uTime: U.time, uWet: U.wet },
  });
  return m;
}
// vertex-coloured props / trees / lamps / cars: instanceColor tints, aEmit lights up at night (lamps, tail lights), aFol follows the season
export function makeVertexMaterial({ lamp = false, lite = false } = {}) {
  const m = new THREE.MeshStandardMaterial({ color: 0xffffff, vertexColors: true, roughness: 0.85, metalness: 0.05 });
  patch(m, {
    key: 'vtx' + (lamp ? 'L' : ''),
    vHead: 'attribute float aEmit; attribute float aFol; varying float vEmit; varying float vFol; varying float vTopY;',
    vMain: 'vEmit = aEmit; vFol = aFol; vTopY = normal.y;',
    fHead: 'varying float vEmit; varying float vFol; varying float vTopY; uniform vec4 uSeason; uniform float uNight; uniform float uLamps; uniform float uWet;',
    fColor: `{ vec3 s = mix(vec3(1.0), uSeason.rgb, vFol); diffuseColor.rgb *= s; diffuseColor.rgb = mix(diffuseColor.rgb, vec3(0.86, 0.9, 0.95), uSeason.w * vFol * smoothstep(0.1, 0.8, vTopY) * 0.85); }`,
    fEmit: `totalEmissiveRadiance += vEmit * (${lamp ? 'vec3(1.0, 0.86, 0.55) * 3.2 * uNight * uLamps' : 'vec3(1.0, 0.8, 0.5) * 1.4 * uNight'});`,
    uniforms: { uSeason: U.season, uNight: U.night, uLamps: U.lamps, uWet: U.wet },
  });
  return m;
}
// GLB apartment blocks: keep their texture; dark glass pixels glow at night (hash per window cell)
export function patchTowerMaterial(mat) {
  mat = mat.clone(); mat.roughness = 0.9; mat.metalness = 0; if (mat.map) mat.map.anisotropy = 4;
  patch(mat, {
    key: 'tower',
    vHead: 'varying vec3 vWPt;', vMain: 'vec4 wq_ = vec4(transformed, 1.0);\n#ifdef USE_INSTANCING\n wq_ = instanceMatrix * wq_;\n#endif\n vWPt = (modelMatrix * wq_).xyz;',
    fHead: `varying vec3 vWPt; uniform float uNight; uniform float uMains; ${GLSL_NOISE}\nfloat hh3(vec3 p){ return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453); }`,
    fColor: `float lumT = dot(diffuseColor.rgb, vec3(0.3, 0.59, 0.11)); float winT = smoothstep(0.34, 0.1, lumT);
      float cellT = hh3(vec3(floor((vWPt.x + vWPt.z) * 0.62), floor(vWPt.y / 3.1), 3.0)); vec3 emitT = vec3(1.0, 0.7, 0.36) * winT * step(cellT, 0.38 * uNight * uMains) * 1.5;
      diffuseColor.rgb *= 0.9;`,
    fEmit: 'totalEmissiveRadiance += emitT;',
    uniforms: { uNight: U.night, uMains: U.mains },
  });
  return mat;
}
