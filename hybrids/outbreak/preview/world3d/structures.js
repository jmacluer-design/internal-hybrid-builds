// Outbreak 3D: the colony's buildings. One merged, vertex-coloured geometry ("kit") per blueprint type, drawn through one InstancedMesh per type; walls and doors are
// built as connected segments between neighbouring posts. Construction shows as a scaffold: the part below the progress line is solid, the part above is a cyan
// grid (discard pattern, so it stays one opaque draw call). Damage darkens the parts; powered / blinking emissives follow the sim's power flags.
// Blueprints (data/blueprints.lua): floor wall door barricade bed campfire workbench stove generator watchtower crate rain_collector water_tank medical_bed lamp radio_mast.
import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';
import { PI, TAU, clamp, hashStr, hash2 } from './util.js';
import { patch, GLSL_NOISE } from './terrain.js';
import { U } from './sky.js';
import { colorize, strip, T } from './city.js';
import { bake } from './models.js';

const W = { wood: 0x8a6a45, wood2: 0x6e5236, wood3: 0x9a7a52, dark: 0x2a2d31, metal: 0x8a9096, metal2: 0x6a7076, rust: 0x8a5a3a, cloth: 0xc9ccd1, white: 0xdcdfdc, red: 0xc0392b, orange: 0xd9822b, blue: 0x3d5ca0, green: 0x3c7a4a, tarp: 0x4a6a80, black: 0x1b1d20, concrete: 0x8c8c88, rubber: 0x202124 };

function kit(h, build) {
  const parts = [];
  const bx = (w, hh, d, x, y, z, col, emit = 0, rx = 0, ry = 0, rz = 0) => { const g = new THREE.BoxGeometry(w, hh, d); if (rx || ry || rz) g.applyMatrix4(new THREE.Matrix4().makeRotationFromEuler(new THREE.Euler(rx, ry, rz))); parts.push(colorize(strip(T(g, x, y, z)), col, emit)); };
  const cy = (rt, rb, hh, x, y, z, col, seg = 10, emit = 0, rx = 0, rz = 0) => { const g = new THREE.CylinderGeometry(rt, rb, hh, seg); if (rx || rz) g.applyMatrix4(new THREE.Matrix4().makeRotationFromEuler(new THREE.Euler(rx, 0, rz))); parts.push(colorize(strip(T(g, x, y, z)), col, emit)); };
  const cone = (r, hh, x, y, z, col, seg = 8, flip = false) => { const g = new THREE.ConeGeometry(r, hh, seg); if (flip) g.rotateX(PI); parts.push(colorize(strip(T(g, x, y, z)), col)); };
  build({ bx, cy, cone });
  const g = mergeGeometries(parts), p = g.attributes.position, y01 = new Float32Array(p.count);
  for (let i = 0; i < p.count; i++) y01[i] = clamp(p.getY(i) / h, 0, 1);
  g.setAttribute('aY01', new THREE.BufferAttribute(y01, 1)); g.computeBoundingSphere();
  return { geo: g, h };
}

export function buildKits() {
  const K = {};
  K.floor = kit(0.14, ({ bx }) => { for (let i = 0; i < 4; i++) bx(0.5, 0.12, 2.0, -0.75 + i * 0.5, 0.06, 0, i % 2 ? W.wood : W.wood3); bx(2.0, 0.03, 0.08, 0, 0.12, -0.7, W.wood2); bx(2.0, 0.03, 0.08, 0, 0.12, 0.7, W.wood2); });
  K.bed = kit(0.8, ({ bx }) => {
    for (const x of [-0.46, 0.46]) for (const z of [-0.92, 0.92]) bx(0.08, 0.3, 0.08, x, 0.15, z, W.wood2);
    bx(1.0, 0.1, 2.0, 0, 0.34, 0, W.wood); bx(0.94, 0.16, 1.92, 0, 0.47, 0, W.cloth); bx(0.9, 0.06, 1.2, 0, 0.58, 0.32, 0xa4b4c8); bx(0.5, 0.12, 0.3, 0, 0.6, -0.72, W.white);
    bx(1.0, 0.5, 0.08, 0, 0.55, -0.98, W.wood2); bx(1.0, 0.3, 0.06, 0, 0.45, 0.98, W.wood2);
  });
  K.campfire = kit(0.7, ({ bx, cy }) => {
    for (let i = 0; i < 9; i++) { const a = i / 9 * TAU; bx(0.3, 0.2, 0.26, Math.cos(a) * 0.62, 0.1, Math.sin(a) * 0.62, i % 2 ? 0x77746c : 0x5c5a55, 0, 0.1, a, 0.1); }
    for (let i = 0; i < 5; i++) { const a = i / 5 * TAU + 0.4; bx(0.09, 0.09, 0.9, Math.cos(a) * 0.14, 0.3, Math.sin(a) * 0.14, i % 2 ? 0x4a3524 : 0x5a4330, 0, -0.9, -a + PI / 2, 0); }
    cy(0.28, 0.28, 0.06, 0, 0.05, 0, 0x201a16, 8, 4);
  });
  K.workbench = kit(1.5, ({ bx, cy }) => {
    bx(1.8, 0.1, 0.8, 0, 0.9, 0, W.wood3); for (const x of [-0.82, 0.82]) for (const z of [-0.32, 0.32]) bx(0.1, 0.88, 0.1, x, 0.44, z, W.wood2);
    bx(1.7, 0.06, 0.7, 0, 0.35, 0, W.wood2); bx(1.8, 0.7, 0.06, 0, 1.25, -0.42, W.metal2); bx(0.22, 0.2, 0.2, -0.6, 1.06, 0.1, W.dark); bx(0.3, 0.08, 0.2, 0.3, 0.99, 0.1, W.metal);
    for (let i = 0; i < 5; i++) bx(0.05, 0.3 - i * 0.03, 0.03, -0.7 + i * 0.35, 1.2, -0.37, i % 2 ? W.red : W.metal, 0);
    bx(0.14, 0.12, 0.14, 0.75, 1.5, -0.3, 0xfff2c0, 1); bx(0.05, 0.4, 0.05, 0.75, 1.3, -0.3, W.dark); bx(0.1, 0.06, 0.08, 0.7, 0.97, 0.3, W.black, 3);
  });
  K.stove = kit(1.1, ({ bx, cy }) => {
    bx(1.4, 0.92, 0.9, 0, 0.46, 0, W.metal); bx(1.42, 0.06, 0.92, 0, 0.94, 0, W.dark); bx(1.0, 0.5, 0.04, 0, 0.42, 0.46, W.dark); bx(0.8, 0.06, 0.04, 0, 0.72, 0.47, W.metal2);
    for (const [x, z] of [[-0.35, -0.2], [0.35, -0.2], [-0.35, 0.2], [0.35, 0.2]]) { cy(0.2, 0.2, 0.025, x, 0.97, z, W.black, 12); cy(0.17, 0.17, 0.02, x, 0.985, z, 0x802010, 12, 4); }
    for (let i = 0; i < 4; i++) cy(0.035, 0.035, 0.05, -0.45 + i * 0.3, 0.8, 0.47, W.metal2, 6, 0, PI / 2); bx(1.2, 0.3, 0.06, 0, 1.12, -0.44, W.metal2); bx(0.08, 0.05, 0.02, 0.5, 1.1, -0.4, W.black, 3);
  });
  K.generator = kit(1.5, ({ bx, cy }) => {
    bx(1.6, 0.14, 0.95, 0, 0.12, 0, W.black); bx(1.5, 0.75, 0.9, 0, 0.55, 0, W.orange); bx(1.52, 0.06, 0.92, 0, 0.94, 0, 0x9a5a1c); bx(0.5, 0.5, 0.6, -0.4, 0.55, 0.46, W.dark); cy(0.07, 0.07, 1.0, 0.55, 1.4, 0.2, W.metal2, 8); cy(0.1, 0.1, 0.06, 0.55, 1.92, 0.2, W.black, 8);
    cy(0.22, 0.22, 0.5, 0.0, 1.1, -0.1, W.red, 10); bx(0.4, 0.24, 0.05, 0.3, 0.7, 0.47, W.black); bx(0.06, 0.06, 0.02, 0.2, 0.72, 0.5, W.red, 3); bx(0.06, 0.06, 0.02, 0.4, 0.72, 0.5, W.green, 3); for (const x of [-0.6, 0.6]) bx(0.1, 0.18, 0.9, x, 0.25, 0, W.metal2);
  });
  K.watchtower = kit(6.6, ({ bx, cy, cone }) => {
    for (const x of [-0.9, 0.9]) for (const z of [-0.9, 0.9]) bx(0.2, 4.4, 0.2, x, 2.2, z, W.wood2);
    for (const y of [1.2, 2.6]) { bx(1.9, 0.09, 0.09, 0, y, -0.9, W.wood); bx(1.9, 0.09, 0.09, 0, y, 0.9, W.wood); bx(0.09, 0.09, 1.9, -0.9, y, 0, W.wood); bx(0.09, 0.09, 1.9, 0.9, y, 0, W.wood); }
    for (const z of [-0.9, 0.9]) { bx(0.07, 2.9, 0.07, 0, 1.9, z, W.wood, 0, 0, 0, 0.62); bx(0.07, 2.9, 0.07, 0, 1.9, z, W.wood, 0, 0, 0, -0.62); }
    bx(2.4, 0.16, 2.4, 0, 4.5, 0, W.wood3); for (const s of [-1, 1]) { bx(2.4, 0.9, 0.08, 0, 5.0, s * 1.16, W.wood2); bx(0.08, 0.9, 2.4, s * 1.16, 5.0, 0, W.wood2); }
    for (const x of [-1.05, 1.05]) for (const z of [-1.05, 1.05]) bx(0.12, 2.0, 0.12, x, 5.5, z, W.wood2); bx(2.8, 0.1, 2.8, 0, 6.5, 0, W.metal2, 0, 0, 0, 0.0); cone(2.1, 0.5, 0, 6.8, 0, W.metal2, 4);
    bx(0.3, 0.22, 0.45, 0.8, 5.55, 0.5, W.dark); bx(0.18, 0.14, 0.05, 0.8, 5.55, 0.74, 0xfff6d0, 1);
    for (let i = 0; i < 12; i++) bx(0.5, 0.05, 0.06, 0, 0.3 + i * 0.36, 1.0, W.wood2); bx(0.06, 4.4, 0.06, -0.22, 2.2, 1.0, W.wood2); bx(0.06, 4.4, 0.06, 0.22, 2.2, 1.0, W.wood2);
    for (const x of [-0.7, 0, 0.7]) bx(0.55, 0.3, 0.3, x, 5.18, -1.0, 0x9a8a6a);
  });
  K.crate = kit(1.15, ({ bx }) => {
    bx(1.4, 1.0, 1.1, 0, 0.5, 0, W.wood); for (const x of [-0.65, 0.65]) bx(0.12, 1.02, 1.12, x, 0.5, 0, W.wood2); for (const y of [0.1, 0.5, 0.9]) bx(1.42, 0.07, 1.12, 0, y, 0, W.wood2);
    bx(1.5, 0.1, 1.2, 0, 1.04, 0, W.wood3); bx(0.5, 0.05, 0.02, 0, 0.6, 0.57, W.red);
  });
  K.rain_collector = kit(1.9, ({ bx, cy, cone }) => {
    for (const x of [-0.9, 0.9]) for (const z of [-0.9, 0.9]) cy(0.05, 0.06, 1.8, x, 0.9, z, W.wood2, 6);
    cone(1.15, 0.5, 0, 1.55, 0, W.tarp, 4, true); cy(0.55, 0.5, 0.95, 0, 0.5, 0, W.blue, 12); cy(0.56, 0.56, 0.05, 0, 0.8, 0, W.metal2, 12); cy(0.56, 0.56, 0.05, 0, 0.2, 0, W.metal2, 12); cy(0.08, 0.08, 0.5, 0, 1.2, 0, W.metal, 6);
  });
  K.water_tank = kit(3.6, ({ bx, cy, cone }) => {
    for (const x of [-0.8, 0.8]) for (const z of [-0.8, 0.8]) cy(0.07, 0.08, 1.8, x, 0.9, z, W.metal2, 6);
    for (const y of [0.6, 1.4]) { bx(1.7, 0.07, 0.07, 0, y, -0.8, W.metal2); bx(1.7, 0.07, 0.07, 0, y, 0.8, W.metal2); bx(0.07, 0.07, 1.7, -0.8, y, 0, W.metal2); bx(0.07, 0.07, 1.7, 0.8, y, 0, W.metal2); }
    cy(1.0, 1.0, 1.7, 0, 2.65, 0, 0x6a7c8a, 18); for (const y of [2.1, 2.65, 3.2]) cy(1.03, 1.03, 0.08, 0, y, 0, W.rust, 18); cone(1.05, 0.4, 0, 3.7, 0, W.metal2, 18); cy(0.12, 0.12, 2.6, 1.0, 1.3, 0.2, W.metal, 6); cy(0.16, 0.16, 0.12, 1.0, 0.7, 0.2, W.red, 8, 0, 0, PI / 2);
  });
  K.medical_bed = kit(2.1, ({ bx, cy }) => {
    for (const x of [-0.46, 0.46]) for (const z of [-0.92, 0.92]) cy(0.04, 0.04, 0.45, x, 0.22, z, W.metal, 6);
    bx(1.0, 0.08, 2.0, 0, 0.5, 0, W.white); bx(0.94, 0.14, 1.9, 0, 0.6, 0, 0xe8ecec); bx(0.5, 0.1, 0.3, 0, 0.7, -0.7, W.white); bx(1.0, 0.7, 0.07, 0, 0.8, -1.0, W.white); bx(0.34, 0.1, 0.02, 0, 0.95, -0.96, W.red); bx(0.1, 0.34, 0.02, 0, 0.95, -0.96, W.red);
    cy(0.025, 0.025, 1.9, 0.75, 0.95, -0.55, W.metal, 6); bx(0.2, 0.01, 0.01, 0.75, 1.9, -0.55, W.metal); bx(0.12, 0.2, 0.05, 0.75, 1.75, -0.55, 0xb8d8f0); bx(0.34, 0.26, 0.2, -0.78, 0.92, -0.4, W.dark); bx(0.26, 0.16, 0.02, -0.78, 0.94, -0.28, 0x30ff80, 3);
  });
  K.lamp = kit(3.6, ({ bx, cy }) => { cy(0.07, 0.1, 3.2, 0, 1.6, 0, W.dark, 6); bx(0.7, 0.07, 0.07, 0.3, 3.2, 0, W.dark); bx(0.4, 0.07, 0.3, 0.6, 3.2, 0, 0xfff2c0, 1); bx(0.46, 0.05, 0.36, 0.6, 3.27, 0, W.dark); cy(0.14, 0.16, 0.12, 0, 0.06, 0, W.concrete, 8); });
  K.radio_mast = kit(16, ({ bx, cy, cone }) => {
    const legs = [[0, 0.9], [-0.78, -0.45], [0.78, -0.45]];
    for (const [x, z] of legs) cy(0.04, 0.06, 15, x * 0.7, 7.5, z * 0.7, W.metal, 6);
    for (let i = 0; i < 12; i++) { const y = 0.6 + i * 1.25, s = 0.7 * (1 - i * 0.045); for (let k = 0; k < 3; k++) { const a = legs[k], b = legs[(k + 1) % 3]; const mx = (a[0] + b[0]) / 2 * s, mz = (a[1] + b[1]) / 2 * s, dx = (b[0] - a[0]) * s, dz = (b[1] - a[1]) * s, l = Math.hypot(dx, dz); bx(l, 0.04, 0.04, mx, y, mz, W.metal2, 0, 0, -Math.atan2(dz, dx), 0); } }
    cy(0.3, 0.3, 0.4, 0, 0.2, 0, W.concrete, 6); cone(0.55, 0.3, 0.5, 11.2, 0.3, W.white, 14); cy(0.03, 0.03, 1.4, 0, 15.6, 0, W.metal, 5); bx(0.16, 0.16, 0.16, 0, 16.4, 0, W.red, 2); bx(0.7, 0.05, 0.05, 0.2, 14.3, 0, W.metal2); bx(0.5, 0.45, 0.3, 0, 1.0, 0.9, W.dark);
  });
  K.barricade = kit(1.6, ({ bx, cy }) => {
    bx(0.14, 1.6, 0.14, -0.9, 0.8, 0, W.wood2, 0, 0, 0, 0.35); bx(0.14, 1.6, 0.14, 0.9, 0.8, 0, W.wood2, 0, 0, 0, -0.35); bx(0.14, 1.7, 0.14, 0, 0.8, 0.05, W.wood2, 0, 0, 0, 0.0);
    for (let i = 0; i < 4; i++) bx(2.0, 0.16, 0.07, 0, 0.35 + i * 0.32, 0.08 * (i % 2 ? 1 : -1), i % 2 ? W.wood : W.wood3, 0, 0, 0, (i - 1.5) * 0.04);
    for (let i = -3; i <= 3; i++) bx(0.04, 0.3, 0.04, i * 0.27, 1.5, 0, W.metal, 0, 0.5);
    bx(1.8, 0.1, 0.06, 0, 0.12, -0.15, 0xa09070); for (const x of [-0.7, 0.7]) cy(0.32, 0.32, 0.22, x, 0.12, 0.3, W.rubber, 10, 0, PI / 2, 0);
  });
  K.door = kit(2.5, ({ bx }) => {
    for (const x of [-0.95, 0.95]) bx(0.24, 2.5, 0.28, x, 1.25, 0, W.wood2); bx(2.14, 0.22, 0.3, 0, 2.4, 0, W.wood2);
    bx(1.66, 2.1, 0.1, 0, 1.08, 0, 0x7a8086); for (const y of [0.35, 1.05, 1.75]) bx(1.7, 0.1, 0.14, 0, y, 0, W.metal2); bx(0.08, 0.3, 0.14, 0.6, 1.1, 0.05, W.black); bx(0.5, 0.5, 0.02, 0, 1.4, 0.08, W.rust);
  });
  K.wallPost = kit(2.7, ({ bx }) => { bx(0.3, 2.6, 0.3, 0, 1.3, 0, W.wood2); bx(0.4, 0.1, 0.4, 0, 2.62, 0, W.metal2); bx(0.12, 0.35, 0.12, 0, 2.8, 0, W.metal, 0, 0, 0, 0.0); });
  K.wallSeg = kit(2.4, ({ bx }) => { bx(1.0, 2.2, 0.2, 0, 1.2, 0, 0xffffff); bx(1.0, 0.14, 0.26, 0, 2.28, 0, W.metal2); bx(1.0, 0.1, 0.26, 0, 0.1, 0, W.concrete); });
  K.pile = kit(0.8, ({ bx }) => { bx(0.7, 0.5, 0.6, -0.15, 0.25, 0.05, W.wood, 0, 0, 0.2, 0); bx(0.5, 0.4, 0.5, 0.35, 0.2, -0.15, 0x8a7a55, 0, 0, -0.4, 0); bx(0.5, 0.3, 0.4, 0.05, 0.65, -0.05, W.green, 0, 0, 0.7, 0); bx(0.2, 0.1, 0.2, 0.35, 0.45, 0.1, 0xffe39a, 1); });
  K.pallet = kit(1.0, ({ bx }) => { bx(1.0, 0.12, 1.0, 0, 0.06, 0, W.wood2); bx(0.85, 0.5, 0.8, 0, 0.4, 0, 0x8a6a45); bx(0.4, 0.3, 0.38, -0.2, 0.84, 0.1, 0x6a7c5a); bx(0.3, 0.26, 0.4, 0.25, 0.82, -0.1, 0xa09070); });
  return K;
}

// ------------------------------------------------------------------------------------------------------------------ material
export function makeKitMaterial(wall = false) {
  const m = new THREE.MeshStandardMaterial({ color: 0xffffff, vertexColors: true, roughness: 0.82, metalness: 0.1 });
  patch(m, {
    key: 'kit' + (wall ? 'W' : ''),
    vHead: 'attribute float aEmit; attribute float aY01; attribute vec4 aParams; varying float vEm; varying float vY; varying vec4 vKP; varying vec3 vKW; varying vec3 vKM; varying vec3 vKN;',
    vMain: `vEm = aEmit; vY = aY01; vKP = aParams; vec4 wl_ = vec4(transformed, 1.0); vec3 sc_ = vec3(1.0);
#ifdef USE_INSTANCING
 wl_ = instanceMatrix * wl_; sc_ = vec3(length(instanceMatrix[0].xyz), length(instanceMatrix[1].xyz), length(instanceMatrix[2].xyz));
#endif
 vKW = (modelMatrix * wl_).xyz; vKM = position * sc_; vKN = normal;`,
    fHead: `varying float vEm; varying float vY; varying vec4 vKP; varying vec3 vKW; varying vec3 vKM; varying vec3 vKN; uniform float uTime; uniform float uNight; uniform float uWet; ${GLSL_NOISE}`,
    fColor: `vec3 emitK = vec3(0.0);
    { float prog = vKP.x;
      ${wall ? `{ vec3 m = vKM; float pl = floor((m.x + 40.0) / 0.32); float row = fract((m.x + 40.0) / 0.32); float tone = fract(sin(pl * 12.9898 + vKP.w * 78.2) * 43758.5);
        vec3 wood = mix(vec3(0.43, 0.32, 0.21), vec3(0.58, 0.45, 0.30), tone); vec3 metal = mix(vec3(0.42, 0.45, 0.48), vec3(0.55, 0.36, 0.25), fract(tone * 7.0));
        float isMetal = step(0.78, fract(sin(floor((m.x + 40.0) / 1.1) * 4.7 + vKP.w * 9.1) * 951.7));
        vec3 c = mix(wood, metal, isMetal); c *= 0.8 + 0.4 * smoothstep(0.0, 0.1, row) * smoothstep(1.0, 0.9, row); c *= 0.82 + 0.3 * vn(vec2(m.x * 2.0, m.y * 3.0)); float brace = step(abs(m.y - 0.45), 0.08) + step(abs(m.y - 1.5), 0.08); c = mix(c, vec3(0.33, 0.25, 0.17), brace * 0.8);
        if (abs(vKN.z) > 0.5) diffuseColor.rgb = c * (vColor.r * 0.5 + 0.6); } ` : ''}
      if (vY > prog + 0.002) {
        vec3 g = fract(vKW * 1.5 + 0.5); float line = step(g.x, 0.09) + step(g.y, 0.09) + step(g.z, 0.09); if (line < 0.5) discard;
        diffuseColor.rgb = vec3(0.1, 0.5, 0.6); emitK += vec3(0.1, 0.8, 1.0) * 0.9;
      } else if (prog < 0.999) { float e = smoothstep(prog - 0.08, prog, vY); emitK += vec3(0.2, 0.9, 1.0) * e * 1.4; diffuseColor.rgb *= 0.9; }
      float hp = clamp(vKP.z, 0.0, 1.0); diffuseColor.rgb *= mix(0.42, 1.0, smoothstep(0.0, 0.55, hp)); diffuseColor.rgb = mix(diffuseColor.rgb, vec3(0.05, 0.04, 0.04), (1.0 - smoothstep(0.0, 0.4, hp)) * 0.35 * vn(vKW.xz * 1.6));
      float e = vEm;
      if (e > 0.5 && e < 1.5) emitK += vec3(1.0, 0.82, 0.5) * 3.0 * vKP.y * (0.25 + 0.75 * uNight);
      else if (e > 1.5 && e < 2.5) emitK += vec3(1.0, 0.12, 0.08) * 3.2 * step(0.5, fract(uTime * 0.9));
      else if (e > 2.5 && e < 3.5) emitK += mix(vec3(1.0, 0.12, 0.08), vec3(0.2, 1.0, 0.45), vKP.y) * 2.2;
      else if (e > 3.5) emitK += vec3(1.0, 0.45, 0.12) * (1.8 + 0.9 * sin(uTime * 9.0 + vKP.w * 40.0)) * vKP.y;
    }`,
    fEmit: 'totalEmissiveRadiance += emitK;', fRough: 'roughnessFactor = mix(roughnessFactor, 0.45, uWet * 0.5);',
    uniforms: { uTime: U.time, uNight: U.night, uWet: U.wet },
  });
  return m;
}

// ------------------------------------------------------------------------------------------------------------------ the layer
export class KitSet {
  constructor(kits, caps) {
    this.kits = kits; this.group = new THREE.Group(); this.mat = makeKitMaterial(false); this.wmat = makeKitMaterial(true); this.meshes = {}; this.recs = {};
    for (const [name, k] of Object.entries(kits)) {
      const cap = caps[name] || 64, g = k.geo, m = new THREE.InstancedMesh(g, name === 'wallSeg' ? this.wmat : this.mat, cap);
      g.setAttribute('aParams', new THREE.InstancedBufferAttribute(new Float32Array(cap * 4), 4)); m.instanceColor = new THREE.InstancedBufferAttribute(new Float32Array(cap * 3), 3);
      m.count = 0; m.frustumCulled = false; m.castShadow = true; m.receiveShadow = true; m.name = 'kit:' + name; this.group.add(m); this.meshes[name] = m; this.recs[name] = [];
    }
  }
  clear() { for (const k of Object.keys(this.recs)) this.recs[k].length = 0; }
  // rec: { x, y, z, rot, sx, sy, sz, col:[r,g,b], prog, pow, hp, seed }
  add(name, rec) { const l = this.recs[name]; if (l && l.length < this.meshes[name].instanceMatrix.count) l.push(rec); }
  flush() {
    for (const [name, m] of Object.entries(this.meshes)) {
      const l = this.recs[name], M = m.instanceMatrix.array, C = m.instanceColor.array, P = m.geometry.attributes.aParams.array;
      l.length = Math.min(l.length, m.instanceMatrix.count);
      for (let i = 0; i < l.length; i++) {
        const r = l[i], c = Math.cos(r.rot), s = Math.sin(r.rot), o = i * 16, sx = r.sx || 1, sy = r.sy || 1, sz = r.sz || 1;
        M[o] = c * sx; M[o + 1] = 0; M[o + 2] = -s * sx; M[o + 3] = 0; M[o + 4] = 0; M[o + 5] = sy; M[o + 6] = 0; M[o + 7] = 0; M[o + 8] = s * sz; M[o + 9] = 0; M[o + 10] = c * sz; M[o + 11] = 0; M[o + 12] = r.x; M[o + 13] = r.y; M[o + 14] = r.z; M[o + 15] = 1;
        const col = r.col || [1, 1, 1]; C[i * 3] = col[0]; C[i * 3 + 1] = col[1]; C[i * 3 + 2] = col[2]; P[i * 4] = r.prog == null ? 1 : r.prog; P[i * 4 + 1] = r.pow || 0; P[i * 4 + 2] = r.hp == null ? 1 : r.hp; P[i * 4 + 3] = r.seed || 0;
      }
      m.count = l.length; m.instanceMatrix.needsUpdate = true; m.instanceColor.needsUpdate = true; m.geometry.attributes.aParams.needsUpdate = true;
    }
  }
  counts() { const o = {}; for (const [k, l] of Object.entries(this.recs)) o[k] = l.length; return o; }
}
