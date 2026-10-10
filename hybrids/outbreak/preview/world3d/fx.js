// Outbreak 3D: effects. Particles (smoke, fire, sparks, blood, dust, muzzle flashes) = two instanced billboard layers (alpha + additive) fed from a ring buffer;
// Decals = instanced flat quads on the ground (selection rings, order pings, zone outlines, placement ghost footprint, noise pulses, lamp / fire glow pools);
// Beams = vertical additive columns (far-horde beacons, flares); LightPool = a fixed set of real point lights handed to the nearest emitters.
// No allocation per frame: everything lives in typed arrays.
import * as THREE from 'three';
import { clamp, lerp, PI, TAU } from './util.js';
import { U } from './sky.js';

const PART_VERT = `attribute vec4 aPos; attribute vec4 aCol; varying vec4 vC; varying vec2 vUv;
void main(){ vec4 mv = viewMatrix * vec4(aPos.xyz, 1.0); mv.xy += position.xy * aPos.w; gl_Position = projectionMatrix * mv; vC = aCol; vUv = position.xy + 0.5; }`;
const PART_FRAG = `uniform float uAdd; uniform float uLight; varying vec4 vC; varying vec2 vUv;
void main(){ vec2 q = vUv - 0.5; float d = length(q) * 2.0; float a = smoothstep(1.0, 0.0, d); a *= a; a *= 0.82 + 0.18 * sin(atan(q.y, q.x) * 3.0 + vC.a * 7.0);
  if (a < 0.003 || vC.a < 0.002) discard;
  if (uAdd > 0.5) gl_FragColor = vec4(vC.rgb * a * vC.a, 1.0); else gl_FragColor = vec4(vC.rgb * uLight, a * vC.a); }`;

export class Particles {
  constructor(scene, cap) {
    this.cap = cap; this.head = 0; this.hi = 0;
    const f = n => new Float32Array(cap * n);
    this.px = f(1); this.py = f(1); this.pz = f(1); this.vx = f(1); this.vy = f(1); this.vz = f(1); this.age = f(1).fill(9); this.life = f(1).fill(1); this.s0 = f(1); this.s1 = f(1);
    this.cr = f(1); this.cg = f(1); this.cb = f(1); this.ca = f(1); this.grav = f(1); this.drag = f(1); this.layer = new Uint8Array(cap);
    this.layers = [];
    for (const add of [false, true]) {
      const g = new THREE.InstancedBufferGeometry(); g.setAttribute('position', new THREE.Float32BufferAttribute([-0.5, -0.5, 0, 0.5, -0.5, 0, 0.5, 0.5, 0, -0.5, 0.5, 0], 3)); g.setIndex([0, 1, 2, 0, 2, 3]);
      const pos = new THREE.InstancedBufferAttribute(new Float32Array(cap * 4), 4), col = new THREE.InstancedBufferAttribute(new Float32Array(cap * 4), 4); pos.setUsage(THREE.DynamicDrawUsage); col.setUsage(THREE.DynamicDrawUsage);
      g.setAttribute('aPos', pos); g.setAttribute('aCol', col); g.instanceCount = 0;
      const m = new THREE.ShaderMaterial({ vertexShader: PART_VERT, fragmentShader: PART_FRAG, transparent: true, depthWrite: false, blending: add ? THREE.AdditiveBlending : THREE.NormalBlending, uniforms: { uAdd: { value: add ? 1 : 0 }, uLight: { value: 1 } }, fog: false });
      const mesh = new THREE.Mesh(g, m); mesh.frustumCulled = false; mesh.renderOrder = add ? 11 : 10; scene.add(mesh); this.layers.push({ g, pos, col, mesh, n: 0 });
    }
    this.live = 0;
  }
  // layer 0 alpha (smoke, dust, blood), 1 additive (fire, sparks, flashes)
  spawn(layer, x, y, z, vx, vy, vz, life, s0, s1, r, g, b, a, grav = 0, drag = 0.5) {
    const i = this.head; this.head = (this.head + 1) % this.cap; if (i >= this.hi) this.hi = i + 1;
    this.px[i] = x; this.py[i] = y; this.pz[i] = z; this.vx[i] = vx; this.vy[i] = vy; this.vz[i] = vz; this.age[i] = 0; this.life[i] = life; this.s0[i] = s0; this.s1[i] = s1;
    this.cr[i] = r; this.cg[i] = g; this.cb[i] = b; this.ca[i] = a; this.grav[i] = grav; this.drag[i] = drag; this.layer[i] = layer;
  }
  smoke(x, y, z, s = 1, dark = 0.4) { const r = Math.random; this.spawn(0, x + (r() - 0.5) * 0.4 * s, y, z + (r() - 0.5) * 0.4 * s, (r() - 0.5) * 0.5 + 0.35, 1.2 + r() * 0.8, (r() - 0.5) * 0.5 + 0.2, 3.2 + r() * 2.2, 0.5 * s, 3.2 * s, dark, dark, dark * 1.05, 0.55, -0.05, 0.25); }
  fire(x, y, z, s = 1) { const r = Math.random; this.spawn(1, x + (r() - 0.5) * 0.3 * s, y, z + (r() - 0.5) * 0.3 * s, (r() - 0.5) * 0.3, 1.0 + r() * 0.9, (r() - 0.5) * 0.3, 0.55 + r() * 0.35, 0.5 * s, 0.1 * s, 1.0, 0.45 + r() * 0.25, 0.1, 0.9, -0.2, 0.3); }
  ember(x, y, z) { const r = Math.random; this.spawn(1, x, y, z, (r() - 0.5) * 1.2, 1.4 + r() * 1.6, (r() - 0.5) * 1.2, 1.2 + r(), 0.07, 0.02, 1.0, 0.6, 0.2, 1.0, -1.2, 0.2); }
  spark(x, y, z, n = 5, s = 1) { const r = Math.random; for (let i = 0; i < n; i++) this.spawn(1, x, y, z, (r() - 0.5) * 7 * s, r() * 5 * s, (r() - 0.5) * 7 * s, 0.25 + r() * 0.3, 0.12, 0.02, 1.0, 0.8, 0.4, 1.0, -14, 0.5); }
  blood(x, y, z, n = 6, up = 3) { const r = Math.random; for (let i = 0; i < n; i++) this.spawn(0, x, y, z, (r() - 0.5) * 4, r() * up, (r() - 0.5) * 4, 0.5 + r() * 0.5, 0.14, 0.2, 0.42, 0.02, 0.03, 0.85, -12, 0.4); }
  dust(x, y, z, n = 6, s = 1, c = 0.5) { const r = Math.random; for (let i = 0; i < n; i++) this.spawn(0, x + (r() - 0.5) * s, y, z + (r() - 0.5) * s, (r() - 0.5) * 2 * s, 0.4 + r() * 0.8, (r() - 0.5) * 2 * s, 0.9 + r() * 0.9, 0.5 * s, 2.0 * s, c * 0.95, c * 0.88, c * 0.78, 0.35, -0.2, 0.9); }
  muzzle(x, y, z, dx, dz) { this.spawn(1, x, y, z, dx * 2, 0.1, dz * 2, 0.07, 0.9, 0.4, 1.0, 0.85, 0.5, 1.0, 0, 0.2); this.spawn(1, x + dx * 0.3, y, z + dz * 0.3, dx * 3, 0.1, dz * 3, 0.05, 0.5, 0.2, 1.0, 0.95, 0.7, 1.0, 0, 0.2); }
  update(dt, night) {
    const n = this.hi; let k0 = 0, k1 = 0; const L0 = this.layers[0], L1 = this.layers[1], A0 = L0.pos.array, C0 = L0.col.array, A1 = L1.pos.array, C1 = L1.col.array;
    for (let i = 0; i < n; i++) {
      const age = this.age[i]; if (age >= this.life[i]) continue;
      this.age[i] = age + dt; const t = (age + dt) / this.life[i]; if (t >= 1) continue;
      const d = Math.exp(-this.drag[i] * dt); this.vx[i] *= d; this.vz[i] *= d; this.vy[i] = this.vy[i] * d + this.grav[i] * dt;
      this.px[i] += this.vx[i] * dt; this.py[i] += this.vy[i] * dt; this.pz[i] += this.vz[i] * dt;
      const s = this.s0[i] + (this.s1[i] - this.s0[i]) * t, a = this.ca[i] * (t < 0.12 ? t / 0.12 : 1 - (t - 0.12) / 0.88);
      if (this.layer[i] === 0) { const o = k0 * 4; A0[o] = this.px[i]; A0[o + 1] = this.py[i]; A0[o + 2] = this.pz[i]; A0[o + 3] = s; C0[o] = this.cr[i]; C0[o + 1] = this.cg[i]; C0[o + 2] = this.cb[i]; C0[o + 3] = a; k0++; }
      else { const o = k1 * 4; A1[o] = this.px[i]; A1[o + 1] = this.py[i]; A1[o + 2] = this.pz[i]; A1[o + 3] = s; C1[o] = this.cr[i]; C1[o + 1] = this.cg[i]; C1[o + 2] = this.cb[i]; C1[o + 3] = a; k1++; }
    }
    L0.g.instanceCount = k0; L1.g.instanceCount = k1; L0.pos.needsUpdate = L0.col.needsUpdate = L1.pos.needsUpdate = L1.col.needsUpdate = true; this.live = k0 + k1;
    L0.mesh.material.uniforms.uLight.value = lerp(1, 0.22, night);
  }
}

// ------------------------------------------------------------------------------------------------------------------ ground decals
const DECAL_VERT = `attribute vec4 aRing; varying vec2 vUv; varying vec4 vR; varying vec2 vSize; varying vec3 vCol;
void main(){ vUv = uv; vR = aRing; vSize = vec2(length(instanceMatrix[0].xyz), length(instanceMatrix[2].xyz)); vCol = instanceColor; gl_Position = projectionMatrix * viewMatrix * modelMatrix * instanceMatrix * vec4(position, 1.0); }`;
const DECAL_FRAG = `uniform float uAdd; uniform float uTime; varying vec2 vUv; varying vec4 vR; varying vec2 vSize; varying vec3 vCol;
void main(){
  vec2 q = (vUv - 0.5) * 2.0; float th = vR.x, al = vR.y, dash = vR.z, mode = vR.w; float a = 0.0;
  if (mode < 0.5) { float d = length(q); float R = vSize.x * 0.5; float w = th / R; a = smoothstep(1.0 - w - 0.02, 1.0 - w + 0.01, d) * smoothstep(1.0 + 0.012, 1.0 - 0.008, d);
    if (dash > 0.01) { float ang = atan(q.y, q.x) / 6.2831853 * 6.2831853 * R; a *= step(0.5, fract(ang / dash + uTime * 0.1)); } }
  else if (mode < 1.5) { float d = length(q); a = smoothstep(1.0, 0.0, d); a *= a; }
  else { vec2 m = (1.0 - abs(q)) * vSize * 0.5; float e = min(m.x, m.y); a = smoothstep(th + 0.04, th - 0.04, e) * step(0.0, e); if (dash > 0.01) { float s = (abs(q.x) > abs(q.y)) ? q.y * vSize.y * 0.5 : q.x * vSize.x * 0.5; a *= step(0.5, fract((s + (abs(q.x) > abs(q.y) ? 0.0 : 3.0)) / dash)); } a += step(0.0, e) * 0.06 * step(th, 10.0) * (dash > 0.01 ? 1.0 : 0.0); }
  a *= al; if (a < 0.004) discard;
  if (uAdd > 0.5) gl_FragColor = vec4(vCol * a, 1.0); else gl_FragColor = vec4(vCol, a);
}`;
export class Decals {
  constructor(scene, cap, add) {
    this.cap = cap; this.n = 0;
    const g = new THREE.PlaneGeometry(1, 1).rotateX(-PI / 2); this.ringAttr = new THREE.InstancedBufferAttribute(new Float32Array(cap * 4), 4); this.ringAttr.setUsage(THREE.DynamicDrawUsage); g.setAttribute('aRing', this.ringAttr);
    const m = new THREE.ShaderMaterial({ vertexShader: DECAL_VERT, fragmentShader: DECAL_FRAG, transparent: true, depthWrite: false, blending: add ? THREE.AdditiveBlending : THREE.NormalBlending, uniforms: { uAdd: { value: add ? 1 : 0 }, uTime: U.time }, fog: false, polygonOffset: true, polygonOffsetFactor: -4, polygonOffsetUnits: -4 });
    m.defines = {}; this.mesh = new THREE.InstancedMesh(g, m, cap); this.mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage); this.mesh.instanceColor = new THREE.InstancedBufferAttribute(new Float32Array(cap * 3), 3); this.mesh.instanceColor.setUsage(THREE.DynamicDrawUsage);
    this.mesh.count = 0; this.mesh.frustumCulled = false; this.mesh.renderOrder = add ? 4 : 3; scene.add(this.mesh);
  }
  begin() { this.n = 0; }
  // mode 0 ring (thickness m, dash length m), 1 soft disc, 2 rectangle outline (w x d metres)
  put(x, y, z, sx, sz, rot, r, g, b, alpha, thick, dash, mode) {
    if (this.n >= this.cap) return; const i = this.n++, M = this.mesh.instanceMatrix.array, o = i * 16, c = Math.cos(rot), s = Math.sin(rot);
    M[o] = c * sx; M[o + 1] = 0; M[o + 2] = -s * sx; M[o + 3] = 0; M[o + 4] = 0; M[o + 5] = 1; M[o + 6] = 0; M[o + 7] = 0; M[o + 8] = s * sz; M[o + 9] = 0; M[o + 10] = c * sz; M[o + 11] = 0; M[o + 12] = x; M[o + 13] = y; M[o + 14] = z; M[o + 15] = 1;
    const C = this.mesh.instanceColor.array; C[i * 3] = r; C[i * 3 + 1] = g; C[i * 3 + 2] = b; const R = this.ringAttr.array; R[i * 4] = thick; R[i * 4 + 1] = alpha; R[i * 4 + 2] = dash; R[i * 4 + 3] = mode;
  }
  ring(x, y, z, radius, r, g, b, alpha, thick = 0.18, dash = 0) { this.put(x, y, z, radius * 2, radius * 2, 0, r, g, b, alpha, thick, dash, 0); }
  disc(x, y, z, radius, r, g, b, alpha) { this.put(x, y, z, radius * 2, radius * 2, 0, r, g, b, alpha, 0, 0, 1); }
  rect(x, y, z, w, d, rot, r, g, b, alpha, thick = 0.12, dash = 0) { this.put(x, y, z, w, d, rot, r, g, b, alpha, thick, dash, 2); }
  end() { const m = this.mesh; m.count = this.n; m.instanceMatrix.needsUpdate = true; m.instanceColor.needsUpdate = true; this.ringAttr.needsUpdate = true; }
}

// ------------------------------------------------------------------------------------------------------------------ vertical beams (beacons)
export class Beams {
  constructor(scene, cap) {
    this.cap = cap; this.n = 0;
    const g = new THREE.InstancedBufferGeometry(); g.setAttribute('position', new THREE.Float32BufferAttribute([-0.5, 0, 0, 0.5, 0, 0, 0.5, 1, 0, -0.5, 1, 0], 3)); g.setIndex([0, 1, 2, 0, 2, 3]);
    this.a = new THREE.InstancedBufferAttribute(new Float32Array(cap * 4), 4); this.c = new THREE.InstancedBufferAttribute(new Float32Array(cap * 4), 4); this.a.setUsage(THREE.DynamicDrawUsage); this.c.setUsage(THREE.DynamicDrawUsage);
    g.setAttribute('aA', this.a); g.setAttribute('aC', this.c);
    const m = new THREE.ShaderMaterial({ transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, fog: false,
      vertexShader: `attribute vec4 aA; attribute vec4 aC; varying vec4 vC; varying float vY; uniform float uTime;
        void main(){ vec3 base = aA.xyz; vec3 toCam = cameraPosition - base; toCam.y = 0.0; vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), toCam) + vec3(1e-5)); vec3 p = base + right * position.x * aC.w + vec3(0.0, position.y * aA.w, 0.0);
          gl_Position = projectionMatrix * viewMatrix * vec4(p, 1.0); vC = aC; vY = position.y; }`,
      fragmentShader: 'varying vec4 vC; varying float vY; void main(){ float a = (1.0 - vY) * (1.0 - vY) * 0.9 + 0.1 * (1.0 - vY); gl_FragColor = vec4(vC.rgb * a * 0.75, 1.0); }' });
    this.mesh = new THREE.Mesh(g, m); this.mesh.frustumCulled = false; this.mesh.renderOrder = 12; scene.add(this.mesh); g.instanceCount = 0; this.g = g;
  }
  begin() { this.n = 0; }
  put(x, y, z, h, r, g, b, width) { if (this.n >= this.cap) return; const i = this.n++, A = this.a.array, C = this.c.array; A[i * 4] = x; A[i * 4 + 1] = y; A[i * 4 + 2] = z; A[i * 4 + 3] = h; C[i * 4] = r; C[i * 4 + 1] = g; C[i * 4 + 2] = b; C[i * 4 + 3] = width; }
  end() { this.g.instanceCount = this.n; this.a.needsUpdate = true; this.c.needsUpdate = true; }
}

// ------------------------------------------------------------------------------------------------------------------ real lights (few, handed to the nearest emitters)
export class LightPool {
  constructor(scene, n) { this.lights = []; for (let i = 0; i < n; i++) { const l = new THREE.PointLight(0xffa060, 0, 24, 1.6); l.castShadow = false; scene.add(l); this.lights.push(l); } this.n = 0; }
  begin() { this.n = 0; }
  put(x, y, z, color, intensity, range) { if (this.n >= this.lights.length) return; const l = this.lights[this.n++]; l.position.set(x, y, z); l.color.setHex(color); l.intensity = intensity; l.distance = range; }
  end() { for (let i = this.n; i < this.lights.length; i++) this.lights[i].intensity = 0; }
}
