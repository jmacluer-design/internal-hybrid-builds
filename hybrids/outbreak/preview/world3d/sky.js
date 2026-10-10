// Outbreak 3D: atmosphere = sky dome (gradient, sun, moon, stars, clouds), sun/moon/hemisphere lights, fog, rain / snow streaks and lightning.
// Palette keyframes are keyed on the sim clock hour so the 3D view agrees with the HUD (dawn 5-7, day 7-19, dusk 19-21, night 21-5).
// Sky shader adapted from games/shatterworld.html (skyBase gradient + sun glow + lit fbm clouds + hash stars): our own shelf code, simplified.
import * as THREE from 'three';
import { clamp, lerp, sstep, damp, PI } from './util.js';

// uniforms shared by every material that reacts to time of day / power / weather
export const U = {
  time: { value: 0 },
  night: { value: 0 },      // 0 day .. 1 night: window glow, lamps, headlights
  lamps: { value: 1 },      // street lamps on (mains up and dark)
  mains: { value: 1 },      // city power up (windows glow only with mains)
  wet: { value: 0 },        // rain wetness 0..1 (darker, glossier ground)
  sunDir: { value: new THREE.Vector3(0.4, 0.8, 0.4) },
  sunCol: { value: new THREE.Color(1, 0.9, 0.7) },
  season: { value: new THREE.Vector4(1, 1, 1, 0) }, // rgb foliage tint, w = snow cover 0..1
  focus: { value: new THREE.Vector3() },
};

// hour -> look. zen/mid/hor sky colours, sun colour + intensity, hemisphere sky/ground + intensity, fog colour + density, exposure
const K = (h, o) => Object.assign({ h }, o);
const KEYS = [
  K(0,    { zen: 0x03061a, mid: 0x0a1233, hor: 0x16203f, sun: 0x000000, sunI: 0,    hs: 0x2a3f7a, hg: 0x10141f, hi: 0.78, fog: 0x0d1432, fd: 0.00125, ex: 1.2,  stars: 1,   moon: 0.62 }),
  K(4.5,  { zen: 0x040822, mid: 0x0e1840, hor: 0x1d2650, sun: 0x000000, sunI: 0,    hs: 0x2a3f7a, hg: 0x10141f, hi: 0.78, fog: 0x101a3c, fd: 0.00125, ex: 1.2,  stars: 1,   moon: 0.5 }),
  K(5.6,  { zen: 0x1a2a66, mid: 0x5a4a82, hor: 0xe08a70, sun: 0xff8a4a, sunI: 0.6,  hs: 0x6b7db8, hg: 0x2a2a30, hi: 0.7,  fog: 0x6a5470, fd: 0.0012,  ex: 1.12, stars: 0.4, moon: 0.2 }),
  K(6.5,  { zen: 0x2f5ec4, mid: 0xc08a9a, hor: 0xffb070, sun: 0xffb27a, sunI: 1.9,  hs: 0x9bb4ec, hg: 0x4a4030, hi: 0.78, fog: 0xe0b090, fd: 0.001,   ex: 1.04, stars: 0,   moon: 0 }),
  K(8,    { zen: 0x2f6fd4, mid: 0x86b8ee, hor: 0xf3dcb8, sun: 0xfff0d2, sunI: 3.0,  hs: 0x9cc2ff, hg: 0x6a6048, hi: 0.82, fog: 0xc6d8e6, fd: 0.00082, ex: 1.0,  stars: 0,   moon: 0 }),
  K(12.5, { zen: 0x2a6ccf, mid: 0x78b0ec, hor: 0xcfe4f4, sun: 0xfff6e2, sunI: 3.5,  hs: 0x9cc6ff, hg: 0x78704f, hi: 0.86, fog: 0xbcd2e6, fd: 0.00075, ex: 1.0,  stars: 0,   moon: 0 }),
  K(17,   { zen: 0x2f66c0, mid: 0x92b8e4, hor: 0xf4dbb0, sun: 0xffe2aa, sunI: 3.0,  hs: 0x9cb8f0, hg: 0x6e6244, hi: 0.82, fog: 0xd2d2d6, fd: 0.00085, ex: 1.02, stars: 0,   moon: 0 }),
  K(19,   { zen: 0x32529c, mid: 0xcc8a8e, hor: 0xffa062, sun: 0xff9a52, sunI: 2.1,  hs: 0xa8a8dc, hg: 0x4e4234, hi: 0.76, fog: 0xe8a888, fd: 0.001,   ex: 1.06, stars: 0,   moon: 0 }),
  K(20.2, { zen: 0x1b2c68, mid: 0x7a4c7c, hor: 0xff6a48, sun: 0xff7440, sunI: 0.95, hs: 0x6a6ab0, hg: 0x2e2630, hi: 0.68, fog: 0x8a5068, fd: 0.0012,  ex: 1.12, stars: 0.2, moon: 0.2 }),
  K(21.4, { zen: 0x0a1242, mid: 0x262a62, hor: 0x713a5c, sun: 0xff5030, sunI: 0.12, hs: 0x3a4a8c, hg: 0x161824, hi: 0.72, fog: 0x2c2650, fd: 0.0013,  ex: 1.18, stars: 0.8, moon: 0.45 }),
  K(23,   { zen: 0x03061a, mid: 0x0a1233, hor: 0x16203f, sun: 0x000000, sunI: 0,    hs: 0x2a3f7a, hg: 0x10141f, hi: 0.78, fog: 0x0d1432, fd: 0.00125, ex: 1.2,  stars: 1,   moon: 0.62 }),
  K(24,   { zen: 0x03061a, mid: 0x0a1233, hor: 0x16203f, sun: 0x000000, sunI: 0,    hs: 0x2a3f7a, hg: 0x10141f, hi: 0.78, fog: 0x0d1432, fd: 0.00125, ex: 1.2,  stars: 1,   moon: 0.62 }),
];
const COLS = ['zen', 'mid', 'hor', 'sun', 'hs', 'hg', 'fog'];
const NUMS = ['sunI', 'hi', 'fd', 'ex', 'stars', 'moon'];
for (const k of KEYS) for (const c of COLS) k[c] = new THREE.Color(k[c]);

export const SKY_VERT = `varying vec3 vDir; void main(){ vDir = position; vec4 p = projectionMatrix * modelViewMatrix * vec4(position, 1.0); gl_Position = p.xyww; }`;
export const SKY_FRAG = `
uniform vec3 uZen; uniform vec3 uMid; uniform vec3 uHor; uniform vec3 uGnd; uniform vec3 uSunDir; uniform vec3 uSunCol; uniform vec3 uMoonDir; uniform vec3 uMoonCol;
uniform float uStars; uniform float uCloud; uniform float uTime; uniform float uMoon; uniform float uFlash; uniform float uLite; uniform vec3 uCloudLit; uniform vec3 uCloudSh;
varying vec3 vDir;
float h21(vec2 p){ p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float h31(vec3 p){ p = fract(p * vec3(443.897, 441.423, 437.195)); p += dot(p, p.yzx + 19.19); return fract((p.x + p.y) * p.z); }
float vn(vec2 p){ vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f); return mix(mix(h21(i), h21(i + vec2(1, 0)), f.x), mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), f.x), f.y); }
float cfbm(vec2 p){ return uLite > 0.5 ? vn(p) * 0.62 + vn(p * 2.6 + 3.7) * 0.38 : vn(p) * 0.5 + vn(p * 2.03 + 3.1) * 0.27 + vn(p * 4.1 + 9.7) * 0.15 + vn(p * 8.3 + 1.9) * 0.08; }
void main(){
  vec3 d = normalize(vDir);
  float h = d.y, hh = clamp(h, 0.0, 1.0);
  vec3 c = hh < 0.28 ? mix(uHor, uMid, pow(hh / 0.28, 0.62)) : mix(uMid, uZen, pow((hh - 0.28) / 0.72, 0.8));
  c = mix(c, uGnd, smoothstep(0.0, -0.25, h));
  float sd = max(dot(d, uSunDir), 0.0);
  c += uSunCol * (pow(sd, 5.0) * 0.30 + pow(sd, 28.0) * 0.45 + pow(sd, 1600.0) * 14.0);
  c += uHor * exp(-max(h, 0.0) * 6.5) * 0.25;
  float md = max(dot(d, uMoonDir), 0.0);
  c += uMoonCol * (pow(md, 3000.0) * 9.0 * uMoon + pow(md, 60.0) * 0.18 * uMoon);
  if (uStars > 0.01 && h > -0.02) {
    vec3 q = floor(d * 210.0); float s = h31(q); float tw = 0.65 + 0.35 * sin(uTime * 2.3 + s * 60.0);
    float st = step(0.9965, s) * tw * (0.6 + 0.8 * h31(q + 7.3));
    c += vec3(0.9, 0.95, 1.0) * st * 2.2 * uStars * smoothstep(-0.02, 0.25, h);
    float band = vn(d.xz * 2.2 + d.y * 3.0) * vn(d.zx * 1.3 + 4.0); c += vec3(0.16, 0.2, 0.34) * pow(band, 2.4) * uStars * 0.7 * smoothstep(0.0, 0.4, h);
  }
  if (h > 0.0) {
    vec2 uv = d.xz / (h + 0.17) * 0.40 + vec2(uTime * 0.006, uTime * 0.0025);
    float n = cfbm(uv); float cov = 1.0 - uCloud; float dens = smoothstep(cov, cov + 0.24, n);
    float n2 = uLite > 0.5 ? n - 0.04 : cfbm(uv + uSunDir.xz * 0.045 / (h + 0.3));
    float lit = clamp((n - n2) * 4.5 + 0.62, 0.0, 1.0);
    vec3 cc = mix(uCloudSh, uCloudLit, lit);
    cc += uSunCol * pow(sd, 5.0) * 0.5 * (1.0 - dens * 0.4);
    c = mix(c, cc, dens * smoothstep(0.0, 0.2, h) * 0.92);
  }
  c += vec3(0.75, 0.82, 1.0) * uFlash * (0.35 + 0.65 * hh);
  gl_FragColor = vec4(c, 1.0);
  #include <tonemapping_fragment>
  #include <colorspace_fragment>
}`;

// rain streak / snow flake vertex shader: positions wrap inside a box that follows the camera focus, so there is no per-frame CPU work
const PRECIP_VERT = `
uniform float uTime; uniform vec3 uCenter; uniform vec3 uBox; uniform vec3 uVel; uniform float uSnow; uniform float uAlpha;
attribute vec4 aSeed; varying float vA;
void main(){
  vec3 p = aSeed.xyz * uBox;
  vec3 v = uVel * (0.75 + 0.5 * aSeed.w);
  p += v * uTime;
  p = mod(p + uBox * 0.5, uBox) - uBox * 0.5;
  vec3 wp = uCenter + p;
  float tail = position.x; // 0 head, 1 tail (rain) ; snow uses a single point
  wp -= normalize(v) * tail * 0.75;
  vec4 mv = viewMatrix * vec4(wp, 1.0);
  gl_Position = projectionMatrix * mv;
  gl_PointSize = uSnow * (22.0 / max(1.0, -mv.z)) * (0.6 + aSeed.w);
  vA = uAlpha * (1.0 - tail * 0.7) * smoothstep(120.0, 20.0, -mv.z);
}`;
const PRECIP_FRAG = `uniform vec3 uColor; uniform float uSnow; varying float vA;
void main(){ float a = vA; if (uSnow > 0.5) { vec2 q = gl_PointCoord - 0.5; a *= smoothstep(0.5, 0.1, length(q)); } gl_FragColor = vec4(uColor, a); }`;

export class Atmosphere {
  constructor(scene, tier, renderer) {
    this.scene = scene; this.tier = tier; this.renderer = renderer;
    const L = tier.clouds ? 0 : 1;
    this.cur = { zen: new THREE.Color(), mid: new THREE.Color(), hor: new THREE.Color(), sun: new THREE.Color(), hs: new THREE.Color(), hg: new THREE.Color(), fog: new THREE.Color(), sunI: 0, hi: 0.7, fd: 0.001, ex: 1, stars: 0, moon: 0 };
    this.gnd = new THREE.Color(); this.cloudLit = new THREE.Color(); this.cloudSh = new THREE.Color();
    this.skyMat = new THREE.ShaderMaterial({
      side: THREE.BackSide, depthWrite: false, fog: false, vertexShader: SKY_VERT, fragmentShader: SKY_FRAG,
      uniforms: { uZen: { value: this.cur.zen }, uMid: { value: this.cur.mid }, uHor: { value: this.cur.hor }, uGnd: { value: this.gnd }, uSunDir: U.sunDir, uSunCol: U.sunCol,
        uMoonDir: { value: new THREE.Vector3(0, -1, 0) }, uMoonCol: { value: new THREE.Color(0.75, 0.82, 1.0) }, uStars: { value: 0 }, uCloud: { value: 0.4 }, uTime: U.time, uMoon: { value: 0 }, uFlash: { value: 0 }, uLite: { value: L },
        uCloudLit: { value: this.cloudLit }, uCloudSh: { value: this.cloudSh } },
    });
    this.sky = new THREE.Mesh(new THREE.SphereGeometry(3000, 32, 18), this.skyMat); this.sky.frustumCulled = false; this.sky.renderOrder = -100; scene.add(this.sky);
    this.hemi = new THREE.HemisphereLight(0x9ec4ff, 0x6b5a3a, 0.8); scene.add(this.hemi);
    this.sun = new THREE.DirectionalLight(0xffe0b0, 3); scene.add(this.sun, this.sun.target);
    this.moon = new THREE.DirectionalLight(0x8fa8ff, 0.4); scene.add(this.moon, this.moon.target);
    scene.fog = new THREE.FogExp2(0x90a0b8, 0.0008);
    this.weather = { kind: 'clear', w: 0, target: 0 }; this.flash = 0; this.nextFlash = 8; this.flashPulse = 0;
    this.moonDir = new THREE.Vector3(); this.hourF = 12; this.sunElev = 1; this.daylight = 1;
    this.precip = null; this.setTier(tier);
    this._c = new THREE.Color();
  }
  setTier(tier) {
    this.tier = tier;
    this.skyMat.uniforms.uLite.value = tier.clouds ? 0 : 1;
    const on = tier.shadow > 0;
    this.sun.castShadow = on;
    if (on) {
      const s = this.sun.shadow; s.mapSize.set(tier.shadow, tier.shadow); if (s.map) { s.map.dispose(); s.map = null; }
      const R = tier.shadowR; Object.assign(s.camera, { left: -R, right: R, top: R, bottom: -R, near: 1, far: 260 }); s.camera.updateProjectionMatrix();
      s.bias = -0.0006; s.normalBias = 0.12;
    }
    if (this.precip) { this.scene.remove(this.precip.rain, this.precip.snow); this.precip.rain.geometry.dispose(); this.precip.snow.geometry.dispose(); }
    this.precip = this._makePrecip(tier.rain);
    this.scene.add(this.precip.rain, this.precip.snow);
  }
  _makePrecip(n) {
    const seeds = new Float32Array(n * 4 * 2), pos = new Float32Array(n * 3 * 2);
    for (let i = 0; i < n; i++) {
      const a = Math.random(), b = Math.random(), c = Math.random(), d = Math.random();
      for (let k = 0; k < 2; k++) { const o = (i * 2 + k) * 4; seeds[o] = a - 0.5; seeds[o + 1] = b - 0.5; seeds[o + 2] = c - 0.5; seeds[o + 3] = d; pos[(i * 2 + k) * 3] = k; }
    }
    const g = new THREE.BufferGeometry(); g.setAttribute('position', new THREE.BufferAttribute(pos, 3)); g.setAttribute('aSeed', new THREE.BufferAttribute(seeds, 4));
    const mkU = snow => ({ uTime: U.time, uCenter: { value: new THREE.Vector3() }, uBox: { value: new THREE.Vector3(70, 46, 70) }, uVel: { value: snow ? new THREE.Vector3(2.4, -3.2, 1.4) : new THREE.Vector3(5, -34, 3) }, uSnow: { value: snow ? 1 : 0 }, uAlpha: { value: 0 }, uColor: { value: new THREE.Color(snow ? 0xffffff : 0xb8c8e0) } });
    const rain = new THREE.LineSegments(g, new THREE.ShaderMaterial({ vertexShader: PRECIP_VERT, fragmentShader: PRECIP_FRAG, uniforms: mkU(false), transparent: true, depthWrite: false, fog: false }));
    const g2 = new THREE.BufferGeometry(); const sp = new Float32Array(n * 3), ss = new Float32Array(n * 4); for (let i = 0; i < n; i++) { ss[i * 4] = seeds[i * 8]; ss[i * 4 + 1] = seeds[i * 8 + 1]; ss[i * 4 + 2] = seeds[i * 8 + 2]; ss[i * 4 + 3] = seeds[i * 8 + 3]; }
    g2.setAttribute('position', new THREE.BufferAttribute(sp, 3)); g2.setAttribute('aSeed', new THREE.BufferAttribute(ss, 4));
    const snow = new THREE.Points(g2, new THREE.ShaderMaterial({ vertexShader: PRECIP_VERT, fragmentShader: PRECIP_FRAG, uniforms: mkU(true), transparent: true, depthWrite: false, fog: false }));
    rain.frustumCulled = false; snow.frustumCulled = false; rain.visible = false; snow.visible = false; rain.renderOrder = 20; snow.renderOrder = 20;
    return { rain, snow };
  }
  setWeather(kind) { this.weather.kind = kind || 'clear'; this.weather.target = kind === 'storm' ? 1 : kind === 'rain' ? 0.6 : 0; }
  // hourF 0..24; season = 'spring' | 'summer' | 'autumn' | 'winter'; focus = camera look-at point (shadow + precipitation follow it)
  update(dt, hourF, season, camera, focus) {
    this.hourF = hourF;
    const W = this.weather; W.w = damp(W.w, W.target, 0.35, dt);
    // keyframe interpolation
    let i = 0; while (i < KEYS.length - 2 && hourF >= KEYS[i + 1].h) i++;
    const a = KEYS[i], b = KEYS[i + 1], t = clamp((hourF - a.h) / Math.max(1e-6, b.h - a.h), 0, 1), c = this.cur;
    for (const k of COLS) c[k].copy(a[k]).lerp(b[k], t);
    for (const k of NUMS) c[k] = lerp(a[k], b[k], t);
    // weather: darker, greyer, foggier, less sun
    const w = W.w, grey = this._c.setRGB(0.42, 0.45, 0.5);
    if (w > 0.001) {
      const luma = c.sunI > 0 ? 1 : 0;
      c.zen.lerp(grey, 0.5 * w * (0.25 + 0.75 * luma)).multiplyScalar(1 - 0.25 * w * luma); c.mid.lerp(grey, 0.6 * w).multiplyScalar(1 - 0.2 * w * luma);
      c.hor.lerp(grey, 0.55 * w).multiplyScalar(1 - 0.15 * w * luma); c.fog.lerp(grey, 0.55 * w).multiplyScalar(1 - 0.2 * w * luma);
      c.sunI *= 1 - 0.72 * w; c.fd *= 1 + 1.8 * w; c.stars *= 1 - 0.85 * w; c.hi *= 1 + 0.12 * w; c.moon *= 1 - 0.5 * w;
    }
    // sun / moon arcs on the horizon plane: east at 06:00 -> south at noon -> west at 20:00 ; the moon is on the same arc 20:00 -> 06:00
    const sunT = (hourF - 6) / 14, moonT = ((hourF < 6 ? hourF + 24 : hourF) - 19.5) / 10.5;
    const sPhi = clamp(sunT, -0.2, 1.2) * PI, mPhi = clamp(moonT, -0.2, 1.2) * PI;
    const sEl = Math.sin(clamp(sunT, 0, 1) * PI) * 1.08 + (sunT < 0 || sunT > 1 ? -0.12 : 0), mEl = Math.sin(clamp(moonT, 0, 1) * PI) * 0.95 + (moonT < 0 || moonT > 1 ? -0.12 : 0);
    const sunDir = U.sunDir.value; sunDir.set(Math.cos(sPhi) * Math.cos(sEl * 0.9), Math.sin(sEl * 0.9) - 0.02, Math.sin(sPhi) * Math.cos(sEl * 0.9) * 0.9 + 0.12).normalize();
    this.moonDir.set(-Math.cos(mPhi) * 0.85, Math.sin(mEl * 0.9) - 0.02, Math.sin(mPhi) * 0.85 + 0.2).normalize();
    this.sunElev = sunDir.y;
    this.daylight = clamp((hourF - 5) / 2, 0, 1) * clamp((21 - hourF) / 2, 0, 1);
    const night = 1 - clamp(this.daylight * 1.15, 0, 1);
    U.night.value = night;
    U.sunCol.value.copy(c.sun);
    // seasonal tint (foliage rgb, snow cover)
    const se = U.season.value;
    if (season === 'winter') se.set(0.78, 0.82, 0.78, 1); else if (season === 'autumn') se.set(1.18, 0.78, 0.42, 0); else if (season === 'spring') se.set(0.95, 1.12, 0.9, 0); else se.set(1, 1, 1, 0);
    U.wet.value = clamp(w * 1.4, 0, 1);
    // flashes
    if (W.kind === 'storm') { this.nextFlash -= dt; if (this.nextFlash <= 0) { this.flash = 1; this.flashPulse = 2; this.nextFlash = 5 + Math.random() * 14; } }
    if (this.flash > 0) { this.flash = Math.max(0, this.flash - dt * 4.5); if (this.flash === 0 && this.flashPulse > 0) { this.flashPulse--; this.flash = 0.7; } }
    const fl = this.flash * this.flash;
    // apply
    this.gnd.copy(c.hor).multiplyScalar(0.55);
    this.cloudLit.copy(c.sun.r + c.sun.g + c.sun.b > 0.05 ? c.sun : c.hs).lerp(this._c.setRGB(1, 1, 1), 0.55).multiplyScalar(0.55 + 0.7 * this.daylight + 0.25);
    this.cloudSh.copy(c.mid).multiplyScalar(0.55);
    const su = this.skyMat.uniforms; su.uStars.value = c.stars; su.uMoon.value = c.moon; su.uMoonDir.value.copy(this.moonDir); su.uCloud.value = lerp(0.38, 0.86, w); su.uFlash.value = fl;
    this.hemi.color.copy(c.hs); this.hemi.groundColor.copy(c.hg); this.hemi.intensity = c.hi * (1 + 0.6 * fl);
    this.sun.color.copy(c.sun); this.sun.intensity = c.sunI * (1 + 0.5 * fl);
    this.moon.intensity = c.moon * 0.75 * clamp(this.moonDir.y * 3, 0, 1) * (1 - 0.5 * w); this.moon.position.copy(focus).addScaledVector(this.moonDir, 120); this.moon.target.position.copy(focus);
    this.sun.visible = c.sunI > 0.01; this.moon.visible = this.moon.intensity > 0.01;
    const R = this.tier.shadowR || 60, texel = (R * 2) / Math.max(this.tier.shadow, 512);
    const fx = Math.round(focus.x / texel) * texel, fz = Math.round(focus.z / texel) * texel; // snap to texels -> no shadow shimmer when the camera pans
    this.sun.position.set(fx + sunDir.x * 130, focus.y + sunDir.y * 130, fz + sunDir.z * 130); this.sun.target.position.set(fx, focus.y, fz); this.sun.target.updateMatrixWorld();
    this.sun.castShadow = this.tier.shadow > 0 && sunDir.y > 0.1;
    const fog = this.scene.fog; fog.color.copy(c.fog); fog.density = c.fd * (1 + 0.35 * clamp((camera.position.y - 60) / 200, -0.2, 0.5) * -1);
    if (this.renderer) this.renderer.toneMappingExposure = c.ex * (1 + 0.25 * fl);
    this.sky.position.copy(camera.position);
    // precipitation
    const snowy = season === 'winter';
    const P = this.precip, on = w > 0.05;
    P.rain.visible = on && !snowy; P.snow.visible = on && snowy;
    if (on) {
      const m = snowy ? P.snow.material : P.rain.material, u = m.uniforms;
      u.uCenter.value.copy(focus).setY(Math.max(focus.y, 0) + 14); u.uAlpha.value = (snowy ? 0.85 : 0.5) * w;
      u.uColor.value.copy(c.fog).lerp(this._c.setRGB(1, 1, 1), 0.55);
    }
    return this;
  }
}
