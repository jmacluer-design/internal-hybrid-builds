// Outbreak 3D: procedural world layout (urban density field from the sim's districts, heights, street lattice, highways), terrain ring meshes,
// road ribbons and the sea. Everything is generated from the sim seed + the catalog's district list: original, deterministic, no assets.
// World axes: three x = sim x (east), three z = -sim y (north is -z), y up. The base is the origin.
import * as THREE from 'three';
import { clamp, lerp, sstep, rng, fbm2, noise2, hash2, hashStr, PI } from './util.js';
import { U } from './sky.js';

export const GRID = 96;          // street lattice pitch (m)
export const ROAD_W = 11;        // street width (m)
const DEFAULT_DISTRICTS = [
  { id: 'orchard', kind: 'residential', x: 520, y: 300, radius: 260, danger: 1 }, { id: 'old_town', kind: 'mixed', x: -420, y: 380, radius: 240, danger: 2 },
  { id: 'mill_flats', kind: 'residential', x: -760, y: -520, radius: 300, danger: 2 }, { id: 'millworks', kind: 'industrial', x: -300, y: -900, radius: 220, danger: 2 },
  { id: 'precinct', kind: 'police', x: 760, y: 640, radius: 180, danger: 3 }, { id: 'dockside', kind: 'industrial', x: -1150, y: 820, radius: 320, danger: 3 },
  { id: 'depot', kind: 'fuel', x: 260, y: -640, radius: 160, danger: 2 }, { id: 'hollow_mall', kind: 'commercial', x: 980, y: -740, radius: 280, danger: 3 },
  { id: 'saint_anne', kind: 'medical', x: 340, y: 1180, radius: 200, danger: 4 }, { id: 'foundry', kind: 'industrial', x: -1500, y: -300, radius: 330, danger: 4 },
  { id: 'reservoir', kind: 'rural', x: 1700, y: 900, radius: 400, danger: 1 }, { id: 'airfield', kind: 'military', x: 1900, y: -1500, radius: 380, danger: 5 },
];
const KIND_W = { residential: 0.62, mixed: 0.95, industrial: 0.7, police: 0.8, fuel: 0.45, commercial: 0.9, medical: 0.8, rural: 0.2, military: 0.3 };

export class WorldGen {
  constructor(seed, districts, base) {
    this.seed = (seed | 0) || 1;
    this.rnd = rng(this.seed * 7919 + 13);
    this.base = base || { x: 0, y: 0, radius: 70 };
    this.districts = (districts && districts.length ? districts : DEFAULT_DISTRICTS).map(d => ({ id: d.id, kind: d.kind, name: d.name, danger: d.danger || 2, x: d.x, z: -d.y, r: d.radius, w: KIND_W[d.kind] || 0.6 }));
    this.sx = this.seed & 0xffff;
    this.roads = []; this.hwPts = new Map(); this.hwList = [];
    this.compoundR = 95;
    this._buildHighways();
  }
  // urban density 0..1 (0 = wilderness): union of the districts' discs (soft edges) + a suburb ring around the base
  density(x, z) {
    let d = 0;
    for (const q of this.districts) {
      const dx = x - q.x, dz = z - q.z, t = Math.sqrt(dx * dx + dz * dz) / q.r;
      if (t < 1.35) { const k = (t < 0.25 ? 1 : 1 - (t - 0.25) / 1.1) * q.w; if (k > d) d = k; }
    }
    const db = Math.hypot(x, z), sub = (1 - sstep(130, 560, db)) * 0.5 * sstep(70, 150, db);
    d = Math.max(d, sub);
    const n = noise2(x * 0.004 + 9, z * 0.004 - 4, this.sx); // ragged edges
    return clamp(d * (0.78 + 0.5 * n), 0, 1);
  }
  nearestDistrict(x, z) {
    let best = null, bd = 1e18;
    for (const q of this.districts) { const dx = x - q.x, dz = z - q.z, d = (dx * dx + dz * dz) / (q.r * q.r); if (d < bd) { bd = d; best = q; } }
    return { d: best, t: Math.sqrt(bd) };
  }
  heightAt(x, z) {
    const urb = clamp(this.density(x, z) * 2.4, 0, 1);
    const macro = fbm2(x * 0.0011 + 3.1, z * 0.0011 - 1.7, 4, this.sx);
    let hills = Math.max((macro - 0.40) * 2.1, 0);
    hills += (fbm2(x * 0.006 - 7, z * 0.006 + 2, 3, this.sx + 5) - 0.5) * 0.22;
    let h = hills * 52 * (1 - urb);
    const u = (-x - z) / 1.4142; // towards the north-west: the harbour
    const sea = sstep(1380, 1900, u); h = lerp(h, -9, sea);
    h *= sstep(150, 340, Math.hypot(x, z)); // the colony ground is flat
    return h;
  }
  // ----------------------------------------------------------------------------------------------- highways between districts
  _buildHighways() {
    const pts = [{ x: 0, z: 0 }].concat(this.districts.map(d => ({ x: d.x, z: d.z })));
    const edges = new Set(), add = (a, b) => { const k = a < b ? a + ',' + b : b + ',' + a; edges.add(k); };
    for (let i = 0; i < pts.length; i++) {
      const ds = pts.map((p, j) => ({ j, d: j === i ? 1e18 : Math.hypot(p.x - pts[i].x, p.z - pts[i].z) })).sort((a, b) => a.d - b.d);
      add(i, ds[0].j); if (i === 0 || ds[1].d < 900) add(i, ds[1].j);
    }
    const r = rng(this.seed * 31 + 5);
    for (const k of edges) {
      const [a, b] = k.split(',').map(Number), A = pts[a], B = pts[b];
      const len = Math.hypot(B.x - A.x, B.z - A.z), n = Math.max(6, Math.ceil(len / 28));
      const nx = -(B.z - A.z) / len, nz = (B.x - A.x) / len, bend = (r() - 0.5) * len * 0.16, ph = r() * 6;
      let line = [];
      for (let i = 0; i <= n; i++) {
        const t = i / n, off = Math.sin(t * PI) * bend + Math.sin(t * 9 + ph) * 5;
        line.push({ x: lerp(A.x, B.x, t) + nx * off, z: lerp(A.z, B.z, t) + nz * off });
      }
      line = line.filter(p => Math.hypot(p.x, p.z) > this.compoundR + 8); if (line.length < 3) continue; // roads stop at the colony fence
      this.hwList.push(line);
      for (const p of line) { const ck = Math.floor(p.x / 40) * 4096 + Math.floor(p.z / 40); (this.hwPts.get(ck) || this.hwPts.set(ck, []).get(ck)).push(p); }
    }
  }
  nearHighway(x, z, rad) {
    const cx = Math.floor(x / 40), cz = Math.floor(z / 40), rr = rad * rad;
    for (let i = -1; i <= 1; i++) for (let j = -1; j <= 1; j++) { const l = this.hwPts.get((cx + i) * 4096 + (cz + j)); if (l) for (const p of l) { const dx = p.x - x, dz = p.z - z; if (dx * dx + dz * dz < rr) return true; } }
    return false;
  }
  // ----------------------------------------------------------------------------------------------- street lattice
  // lattice node (i, j) sits at ((i + .5) G, (j + .5) G); edge exists when the density at its midpoint is high enough and it is outside the colony compound
  nodePos(i, j) { return { x: (i + 0.5) * GRID, z: (j + 0.5) * GRID }; }
  hasEdge(i, j, horizontal) {
    const a = this.nodePos(i, j), b = horizontal ? this.nodePos(i + 1, j) : this.nodePos(i, j + 1);
    const mx = (a.x + b.x) / 2, mz = (a.z + b.z) / 2;
    if (Math.hypot(mx, mz) < this.compoundR + 20) return false;
    const d = this.density(mx, mz);
    return d > 0.2 + 0.18 * hash2(i, j, this.sx + (horizontal ? 1 : 2));
  }
  buildLattice(limit = 2300) {
    const n = Math.ceil(limit / GRID), edges = [];
    for (let i = -n; i <= n; i++) for (let j = -n; j <= n; j++) {
      for (const hz of [true, false]) if (this.hasEdge(i, j, hz)) {
        const a = this.nodePos(i, j), b = hz ? this.nodePos(i + 1, j) : this.nodePos(i, j + 1);
        const mx = (a.x + b.x) / 2, mz = (a.z + b.z) / 2, d = this.density(mx, mz);
        edges.push({ x0: a.x, z0: a.z, x1: b.x, z1: b.z, kind: d > 0.7 && hash2(i, j, 77) > 0.5 ? 1 : 0, w: ROAD_W });
      }
    }
    this.roads = edges; return edges;
  }
}

// ------------------------------------------------------------------------------------------------------------------ material patching helper
// Injects code into a stock three material (keeps lights, shadows, fog and tone mapping working).
export function patch(mat, o) {
  mat.onBeforeCompile = shader => {
    Object.assign(shader.uniforms, o.uniforms || {});
    shader.vertexShader = shader.vertexShader.replace('#include <common>', '#include <common>\n' + (o.vHead || ''))
      .replace('#include <begin_vertex>', '#include <begin_vertex>\n' + (o.vMain || ''));
    shader.fragmentShader = shader.fragmentShader.replace('#include <common>', '#include <common>\n' + (o.fHead || ''));
    if (o.fColor) shader.fragmentShader = shader.fragmentShader.replace('#include <color_fragment>', '#include <color_fragment>\n' + o.fColor);
    if (o.fRough) shader.fragmentShader = shader.fragmentShader.replace('#include <roughnessmap_fragment>', '#include <roughnessmap_fragment>\n' + o.fRough);
    if (o.fEmit) shader.fragmentShader = shader.fragmentShader.replace('#include <emissivemap_fragment>', '#include <emissivemap_fragment>\n' + o.fEmit);
    if (o.fFinal) shader.fragmentShader = shader.fragmentShader.replace('#include <dithering_fragment>', o.fFinal + '\n#include <dithering_fragment>');
    mat.userData.shader = shader;
  };
  mat.customProgramCacheKey = () => o.key || 'patched';
  return mat;
}

export const GLSL_NOISE = `
float h21(vec2 p){ p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float vn(vec2 p){ vec2 i = floor(p), f = fract(p); f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0); return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), f.x), mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), f.x), f.y); }
float fbm3(vec2 p){ const mat2 R = mat2(0.80, 0.60, -0.60, 0.80); float a = 0.5, s = 0.0; for (int i = 0; i < 4; i++) { s += a * vn(p); p = R * p * 2.03 + 17.1; a *= 0.5; } return s / 0.9375; }
`;

// ------------------------------------------------------------------------------------------------------------------ terrain
function ringGeometry(gen, half, step, holeHalf) {
  // square ring of cells [-half, half]^2 minus [-holeHalf, holeHalf]^2 (holeHalf = 0 -> full square), with skirts on every boundary edge
  const n = Math.round((half * 2) / step), idx = [], pos = [], map = new Int32Array((n + 1) * (n + 1)).fill(-1);
  const vid = (i, j) => {
    const k = i * (n + 1) + j; if (map[k] >= 0) return map[k];
    const x = -half + i * step, z = -half + j * step; map[k] = pos.length / 3; pos.push(x, gen.heightAt(x, z), z); return map[k];
  };
  const inHole = (i, j) => { if (!holeHalf) return false; const x0 = -half + i * step, z0 = -half + j * step; return x0 >= -holeHalf - 1e-6 && x0 + step <= holeHalf + 1e-6 && z0 >= -holeHalf - 1e-6 && z0 + step <= holeHalf + 1e-6; };
  const edgeCells = [];
  for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) {
    if (inHole(i, j)) continue;
    const a = vid(i, j), b = vid(i + 1, j), c = vid(i + 1, j + 1), d = vid(i, j + 1);
    idx.push(a, d, b, b, d, c);
    // boundary edge (outer border or next to the hole): skirt
    if (j === 0) edgeCells.push([a, b]); if (j === n - 1) edgeCells.push([d, c]); if (i === 0) edgeCells.push([a, d]); if (i === n - 1) edgeCells.push([b, c]);
    if (holeHalf) { if (inHole(i - 1, j)) edgeCells.push([a, d]); if (inHole(i + 1, j)) edgeCells.push([b, c]); if (inHole(i, j - 1)) edgeCells.push([a, b]); if (inHole(i, j + 1)) edgeCells.push([d, c]); }
  }
  const nBase = pos.length / 3, skirt = Math.max(6, step * 0.8), sm = new Map();
  const sv = v => { if (sm.has(v)) return sm.get(v); const id = pos.length / 3; pos.push(pos[v * 3], pos[v * 3 + 1] - skirt, pos[v * 3 + 2]); sm.set(v, id); return id; };
  for (const [a, b] of edgeCells) { const a2 = sv(a), b2 = sv(b); idx.push(a, b, a2, b, b2, a2, a, a2, b, b, a2, b2); } // both windings: visible from either side
  const P = new Float32Array(pos), N = new Float32Array(pos.length);
  // normals from the height function (central differences)
  for (let v = 0; v < nBase; v++) {
    const x = P[v * 3], z = P[v * 3 + 2], e = Math.max(1, step * 0.5);
    const hx = gen.heightAt(x + e, z) - gen.heightAt(x - e, z), hz = gen.heightAt(x, z + e) - gen.heightAt(x, z - e);
    const nx = -hx, ny = 2 * e, nz = -hz, l = Math.hypot(nx, ny, nz); N[v * 3] = nx / l; N[v * 3 + 1] = ny / l; N[v * 3 + 2] = nz / l;
  }
  for (let v = nBase; v < pos.length / 3; v++) { N[v * 3 + 1] = 1; }
  const g = new THREE.BufferGeometry(); g.setAttribute('position', new THREE.BufferAttribute(P, 3)); g.setAttribute('normal', new THREE.BufferAttribute(N, 3)); g.setIndex(idx);
  g.computeBoundingSphere(); return g;
}

export function makeTerrainMaterial(gen) {
  const m = new THREE.MeshStandardMaterial({ color: 0xffffff, roughness: 0.96, metalness: 0 });
  const dc = gen.districts.map(d => `vec4(${d.x.toFixed(1)}, ${d.z.toFixed(1)}, ${d.r.toFixed(1)}, ${(KIND_W[d.kind] || 0.5).toFixed(2)})`);
  patch(m, {
    key: 'terrain',
    vHead: 'varying vec3 vWP; varying vec3 vWN;',
    vMain: 'vWP = (modelMatrix * vec4(transformed, 1.0)).xyz; vWN = normalize(mat3(modelMatrix) * normal);',
    fHead: `varying vec3 vWP; varying vec3 vWN; uniform vec4 uSeason; uniform float uWet; uniform float uTime; ${GLSL_NOISE}
      uniform vec2 uBaseC; uniform float uCompound;`,
    fColor: `{
      vec2 p = vWP.xz; vec3 N0 = normalize(vWN); float slope = 1.0 - clamp(N0.y, 0.0, 1.0);
      float dcam = length(vWP - cameraPosition); float detail = 1.0 - smoothstep(35.0, 320.0, dcam); float fine = 1.0 - smoothstep(12.0, 90.0, dcam);
      float macro = fbm3(p * 0.0026 + 11.0), meso = fbm3(p * 0.018), micro = mix(0.5, vn(p * 0.9) * 0.55 + vn(p * 3.7) * 0.45, detail), grain = mix(0.5, vn(p * 14.0), fine);
      vec3 grassA = vec3(0.115, 0.20, 0.07), grassB = vec3(0.235, 0.29, 0.10), dry = vec3(0.37, 0.31, 0.16), dirt = vec3(0.30, 0.22, 0.15), rock = vec3(0.33, 0.32, 0.30), sand = vec3(0.56, 0.50, 0.36);
      vec3 g = mix(grassA, grassB, smoothstep(0.28, 0.72, macro)); g = mix(g, dry, smoothstep(0.52, 0.86, meso) * 0.6); g = mix(g, grassA * 0.7, smoothstep(0.66, 0.86, fbm3(p * 0.045 + 3.0)) * 0.5);
      g *= uSeason.rgb; g *= 0.78 + 0.42 * micro; g *= 0.92 + 0.16 * grain;
      vec3 c = mix(g, dirt * (0.8 + 0.4 * micro), smoothstep(0.64, 0.82, fbm3(p * 0.011 + 4.0)) * 0.6);
      c = mix(c, rock * (0.8 + 0.4 * micro), smoothstep(0.3, 0.52, slope));
      float coast = smoothstep(1290.0, 1420.0, (-vWP.x - vWP.z) * 0.70711) * smoothstep(5.0, 0.0, vWP.y); c = mix(c, sand, coast * 0.9);
      float urb = 0.0;
      ${dc.map((d, i) => `{ vec4 q = ${d}; float t = length(p - q.xy) / q.z; urb = max(urb, (1.0 - smoothstep(0.15, 1.15, t)) * q.w); }`).join('\n      ')}
      vec3 paved = vec3(0.26, 0.26, 0.27) * (0.86 + 0.3 * micro); paved = mix(paved, paved * 0.78, smoothstep(0.4, 0.8, vn(p * 0.09)));
      c = mix(c, mix(dirt * 0.85, paved, 0.55), smoothstep(0.16, 0.5, urb) * 0.78);
      // the colony compound: a cracked concrete yard cut into 7.5 m slabs with weeds, stains, oil and a gravel apron
      float cd = length(p - uBaseC); float comp = 1.0 - smoothstep(uCompound - 8.0, uCompound + 3.0, cd), yard = 1.0 - smoothstep(uCompound - 26.0, uCompound - 8.0, cd);
      vec2 sp = p / 7.5, si = floor(sp), sf = fract(sp); float ed = min(min(sf.x, 1.0 - sf.x), min(sf.y, 1.0 - sf.y)) * 7.5;
      float joint = 1.0 - smoothstep(0.02, 0.1 + 0.06 * (1.0 - fine), ed);
      vec3 slab = vec3(0.30, 0.30, 0.295) * (0.84 + 0.22 * h21(si + 7.0)) * (0.88 + 0.18 * micro); slab *= 0.9 + 0.12 * fbm3(p * 0.25);
      float crack = 1.0 - smoothstep(0.0, 0.016 + 0.02 * (1.0 - detail), abs(fbm3(p * 0.55 + si * 1.7) - 0.5)); slab = mix(slab, vec3(0.1, 0.1, 0.1), crack * 0.55);
      slab = mix(slab, vec3(0.1, 0.095, 0.09), smoothstep(0.62, 0.82, fbm3(p * 0.06 + 9.0)) * 0.55); // oil / soot stains
      slab = mix(slab, vec3(0.16, 0.24, 0.09), (joint * 0.5 + crack * 0.7) * smoothstep(0.42, 0.7, fbm3(p * 0.3 + 5.0)) * 0.7); // weeds in the joints
      slab = mix(slab, vec3(0.04), joint * 0.55);
      vec3 gravel = vec3(0.30, 0.27, 0.235) * (0.78 + 0.4 * micro) * (0.9 + 0.2 * grain); gravel = mix(gravel, vec3(0.28, 0.27, 0.25), smoothstep(0.5, 0.8, vn(p * 0.2)));
      vec3 cyard = mix(gravel, slab, yard); c = mix(c, cyard, comp);
      float paint = step(abs(fract((p.x + 3.0) / 5.2) - 0.5), 0.024) * step(abs(p.y - 36.0), 14.0) * step(abs(p.x - 22.0), 28.0) * step(0.5, h21(si + 3.0)); c = mix(c, vec3(0.78, 0.72, 0.52), paint * yard * 0.5);
      c = mix(c, vec3(0.86, 0.9, 0.95) * (0.92 + 0.08 * micro), uSeason.w * smoothstep(-0.1, 0.35, N0.y) * (1.0 - comp * 0.55));
      c *= 1.0 - 0.32 * uWet * (0.4 + 0.6 * comp);
      diffuseColor.rgb = c;
    }`,
    fRough: 'roughnessFactor = mix(roughnessFactor, 0.55, uWet);',
    uniforms: { uSeason: U.season, uWet: U.wet, uTime: U.time, uBaseC: { value: new THREE.Vector2(0, 0) }, uCompound: { value: gen.compoundR } },
  });
  return m;
}

export function buildTerrain(gen, tier) {
  const g = new THREE.Group(), mat = makeTerrainMaterial(gen), { l0, l1, l2 } = tier.grid;
  const mk = (half, step, hole) => { const m = new THREE.Mesh(ringGeometry(gen, half, step, hole), mat); m.receiveShadow = true; m.frustumCulled = false; g.add(m); return m; };
  const r0 = Math.ceil(224 / l1) * l1, r1 = Math.ceil(960 / l2) * l2, r2 = Math.ceil(2800 / l2) * l2; // ring borders sit on the coarser ring's grid lines (no overlap, no z-fight)
  mk(r0, l0, 0); mk(r1, l1, r0); mk(r2, l2, r1);
  g.userData.material = mat; g.userData.extent = r2;
  return g;
}

// ------------------------------------------------------------------------------------------------------------------ sea (far north-west)
export function buildSea(gen) {
  const m = new THREE.ShaderMaterial({
    transparent: false, fog: true, lights: false,
    uniforms: THREE.UniformsUtils.merge([THREE.UniformsLib.fog, { uSun: U.sunDir, uSunCol: U.sunCol, uTime: U.time, uNight: U.night, uDeep: { value: new THREE.Color(0x0b2a3c) }, uShallow: { value: new THREE.Color(0x2c6a7a) } }]),
    vertexShader: `varying vec3 vWP;\n#include <fog_pars_vertex>\nvoid main(){ vWP = (modelMatrix * vec4(position, 1.0)).xyz; vec4 mvPosition = viewMatrix * vec4(vWP, 1.0); gl_Position = projectionMatrix * mvPosition;\n#include <fog_vertex>\n}`,
    fragmentShader: `varying vec3 vWP; uniform vec3 uSun; uniform vec3 uSunCol; uniform float uTime; uniform float uNight; uniform vec3 uDeep; uniform vec3 uShallow;\n${GLSL_NOISE}\n#include <fog_pars_fragment>
      void main(){
        vec2 p = vWP.xz; float t = uTime;
        float w = vn(p * 0.05 + vec2(t * 0.05, t * 0.03)) + vn(p * 0.17 - vec2(t * 0.08, 0.0)) * 0.5 + vn(p * 0.6 + vec2(0.0, t * 0.2)) * 0.25;
        vec3 N = normalize(vec3((vn(p * 0.5 + t * 0.1) - 0.5) * 0.28, 1.0, (vn(p * 0.5 - t * 0.12 + 5.0) - 0.5) * 0.28));
        vec3 V = normalize(cameraPosition - vWP); vec3 R = reflect(-V, N); float fr = 0.08 + 0.92 * pow(1.0 - clamp(dot(N, V), 0.0, 1.0), 4.0);
        vec3 body = mix(uShallow, uDeep, 0.55 + 0.3 * w); vec3 sky = mix(vec3(0.5, 0.62, 0.78), vec3(0.03, 0.05, 0.12), uNight);
        vec3 col = mix(body, sky, fr * 0.7); float sp = pow(max(dot(R, normalize(uSun)), 0.0), 140.0) * 6.0; col += uSunCol * sp;
        col *= mix(1.0, 0.25, uNight); gl_FragColor = vec4(col, 1.0);
        #include <tonemapping_fragment>
        #include <colorspace_fragment>
        #include <fog_fragment>
      }`,
  });
  const sea = new THREE.Mesh(new THREE.PlaneGeometry(9000, 9000, 1, 1).rotateX(-PI / 2), m); sea.position.y = -1.2; sea.frustumCulled = false; sea.renderOrder = -5;
  return sea;
}

// ------------------------------------------------------------------------------------------------------------------ road ribbons
export function buildRoads(gen, tier) {
  const pos = [], uv = [], aux = [], idx = [];
  const step = tier.name === 'low' ? 32 : 16;
  const ribbon = (pts, w, kind) => {
    // pts: [{x,z}], cumulative length for v; two bands (asphalt + sidewalks) share the ribbon: u in [-1,1]
    let acc = 0; const total = pts.reduce((s, p, i) => s + (i ? Math.hypot(p.x - pts[i - 1].x, p.z - pts[i - 1].z) : 0), 0);
    const base = pos.length / 3;
    for (let i = 0; i < pts.length; i++) {
      const p = pts[i], a = pts[Math.max(0, i - 1)], b = pts[Math.min(pts.length - 1, i + 1)];
      let tx = b.x - a.x, tz = b.z - a.z; const tl = Math.hypot(tx, tz) || 1; tx /= tl; tz /= tl;
      if (i) acc += Math.hypot(p.x - pts[i - 1].x, p.z - pts[i - 1].z);
      const nx = -tz, nz = tx, half = w * 0.5 + (kind === 2 ? 0.6 : 3.2);
      for (const s of [-1, 1]) {
        const x = p.x + nx * half * s, z = p.z + nz * half * s;
        pos.push(x, gen.heightAt(x, z) + (kind === 2 ? 0.07 : 0.1), z); uv.push(s * (kind === 2 ? 1 : (w * 0.5 + 3.2) / (w * 0.5)) , acc); aux.push(total, kind, w);
      }
    }
    for (let i = 0; i < pts.length - 1; i++) { const a = base + i * 2; idx.push(a, a + 1, a + 2, a + 1, a + 3, a + 2); }
  };
  for (const e of gen.roads) {
    const len = Math.hypot(e.x1 - e.x0, e.z1 - e.z0), n = Math.max(1, Math.ceil(len / step)), pts = [];
    for (let i = 0; i <= n; i++) pts.push({ x: lerp(e.x0, e.x1, i / n), z: lerp(e.z0, e.z1, i / n) });
    ribbon(pts, e.w, e.kind);
  }
  for (const line of gen.hwList) {
    // resample the free-form polyline every ~20 m
    const pts = [];
    for (let i = 0; i < line.length; i++) pts.push(line[i]);
    ribbon(pts, 12, 2);
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3)); g.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2)); g.setAttribute('aRoad', new THREE.Float32BufferAttribute(aux, 3));
  g.setIndex(idx); g.computeVertexNormals(); g.computeBoundingSphere();
  const m = new THREE.MeshStandardMaterial({ color: 0xffffff, roughness: 0.9, metalness: 0, polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -2 });
  patch(m, {
    key: 'road',
    vHead: 'attribute vec3 aRoad; varying vec3 vRoad; varying vec2 vUvR; varying vec3 vWP2;',
    vMain: 'vRoad = aRoad; vUvR = uv; vWP2 = (modelMatrix * vec4(transformed, 1.0)).xyz;',
    fHead: `varying vec3 vRoad; varying vec2 vUvR; varying vec3 vWP2; uniform float uWet; uniform float uNight; ${GLSL_NOISE}`,
    fColor: `{
      float total = vRoad.x, kind = vRoad.y, w = vRoad.z, v = vUvR.y, u = vUvR.x; float au = abs(u);
      float fromEnd = min(v, total - v);
      bool curb = kind < 1.5 && au > 1.0 && fromEnd > 6.5;
      vec3 asphalt = mix(vec3(0.115, 0.118, 0.125), vec3(0.17, 0.17, 0.175), vn(vWP2.xz * 0.6)); asphalt *= 0.85 + 0.3 * vn(vWP2.xz * 2.4);
      asphalt = mix(asphalt, vec3(0.08, 0.085, 0.095), smoothstep(0.55, 0.85, vn(vWP2.xz * 0.12)) * 0.6); // patched / oily
      vec3 c = asphalt;
      float metres = au * (w * 0.5);
      // edge lines
      float edge = smoothstep(0.02, 0.0, abs(au - 0.92)) * step(au, 1.0) * step(6.5, fromEnd);
      c = mix(c, vec3(0.78, 0.76, 0.66), edge * 0.5 * step(0.3, vn(vWP2.xz * 0.7)));
      // centre dashes (kind 0 dashed, 1 double line, 2 highway dashed)
      float dash = step(0.5, fract(v / 8.0)) * step(8.0, fromEnd);
      float ctr = smoothstep(0.045, 0.02, au) * (kind > 0.5 && kind < 1.5 ? step(8.0, fromEnd) : dash);
      c = mix(c, vec3(0.86, 0.72, 0.28), ctr * 0.7 * step(0.2, vn(vWP2.xz * 0.9)));
      if (curb) { vec3 side = vec3(0.42, 0.41, 0.4) * (0.85 + 0.3 * vn(vWP2.xz * 1.3)); side *= 0.92 + 0.08 * step(0.5, fract(vWP2.x * 0.33)) * step(0.5, fract(vWP2.z * 0.33)); c = side; if (au < 1.025) c *= 0.55; }
      c *= 1.0 - 0.45 * uWet;
      diffuseColor.rgb = c;
    }`,
    fRough: 'roughnessFactor = mix(0.92, 0.28, uWet * 0.9);',
    uniforms: { uWet: U.wet, uNight: U.night },
  });
  const mesh = new THREE.Mesh(g, m); mesh.receiveShadow = true; mesh.frustumCulled = false;
  return mesh;
}
