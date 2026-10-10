// Outbreak 3D world: a real three.js scene driven by the live Lua sim state (colonists, buildings, hordes, raids, vehicles, weather, the sim clock).
// Entry point for the browser preview: `const W = await createWorld3D({ canvas, labels, ... })`, then feed it `W.setState(view)` / `W.onEvents([...])`.
// Everything is original procedural art; the optional GLB models (preview/vendor/models, PRIVATE USE ONLY, see THIRD_PARTY.md) always have procedural fallbacks.
// Layout: world3d/ = util, tiers, sky, terrain, city(gen), peds, colonists, structures, fx, camera, ui (preview-shell integration).
import * as THREE from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { ShaderPass } from 'three/addons/postprocessing/ShaderPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { clamp, lerp, damp, sstep, hashStr, PI } from './world3d/util.js';
import { TIERS, TIER_ORDER, pickTier, gpuInfo } from './world3d/tiers.js';
import { Atmosphere, U } from './world3d/sky.js';
import { WorldGen, buildTerrain, buildRoads, buildSea } from './world3d/terrain.js';
import { City } from './world3d/citygen.js';
import { Models } from './world3d/models.js';
import { CameraRig } from './world3d/camera.js';
import { Dynamic } from './world3d/dynamic.js';

// colour grade + vignette (adapted from games/shatterworld.html GradeShader, trimmed): runs on the HDR frame before tone mapping
const GradeShader = {
  uniforms: { tDiffuse: { value: null }, uVig: { value: 0.34 }, uSat: { value: 1.08 }, uCon: { value: 1.05 }, uAspect: { value: 1.78 }, uTime: U.time, uShadow: { value: new THREE.Color(0.93, 0.97, 1.06) }, uHigh: { value: new THREE.Color(1.06, 1.0, 0.92) }, uDmg: { value: 0 } },
  vertexShader: 'varying vec2 vUv; void main(){ vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }',
  fragmentShader: `uniform sampler2D tDiffuse; uniform float uVig; uniform float uSat; uniform float uCon; uniform float uAspect; uniform float uTime; uniform vec3 uShadow; uniform vec3 uHigh; uniform float uDmg; varying vec2 vUv;
    float ign(vec2 p){ return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))); }
    void main(){ vec3 c = texture2D(tDiffuse, vUv).rgb; vec2 cc = vUv - 0.5;
      float l = dot(c, vec3(0.2126, 0.7152, 0.0722)); c = mix(vec3(l), c, uSat); c *= mix(uShadow, uHigh, smoothstep(0.0, 0.9, l)); c = max((c - 0.18) * uCon + 0.18, 0.0);
      vec2 q = cc * vec2(1.0, 1.0 / max(uAspect, 0.5)) * 1.5; float v = 1.0 - dot(q, q); c *= mix(1.0, smoothstep(0.0, 1.0, clamp(v, 0.0, 1.0)), uVig);
      c += (ign(gl_FragCoord.xy + uTime * 60.0) - 0.5) * 0.004; c = mix(c, c * vec3(1.0, 0.7, 0.7), uDmg); gl_FragColor = vec4(c, 1.0); }`,
};

export class World3D {
  constructor(o) {
    this.o = o; this.canvas = o.canvas; this.labels = o.labels || null; this.q = o.query || {};
    this.state = null; this.catalog = null; this.events = []; this.ready = false; this.running = false; this.manual = this.q.w3d === 'manual'; this.hidden = false; this.frameNo = 0; this.time = 0;
    this.stats = { calls: 0, triangles: 0, fps: 0, ms: 0, dpr: 1, scale: 1, tier: '', objects: 0 }; this.ema = 16; this.slowFor = 0; this.fastFor = 0; this.qScale = 1; this.hour = 12; this.pulls = 0;
  }
  async init(progress) {
    const o = this.o, canvas = this.canvas;
    const probe = document.createElement('canvas'); const pgl = probe.getContext('webgl2'); const gpu = pgl ? gpuInfo(pgl) : ''; if (pgl) { const e = pgl.getExtension('WEBGL_lose_context'); if (e) e.loseContext(); }
    this.gpu = gpu; const pick = pickTier(gpu, this.q.q); this.autoPick = pickTier(gpu, '', true); this.autoTier = this.autoPick.tier; this.tierName = pick.tier; this.tier = TIERS[pick.tier]; this.tierAuto = pick.auto; this.tierReason = pick.reason;
    const T = this.tier;
    const r = this.renderer = new THREE.WebGLRenderer({ canvas, antialias: !T.post && T.msaa === 0, alpha: false, powerPreference: 'high-performance', preserveDrawingBuffer: !!this.q.pdb });
    r.outputColorSpace = THREE.SRGBColorSpace; r.toneMapping = THREE.ACESFilmicToneMapping; r.toneMappingExposure = 1; r.shadowMap.enabled = T.shadow > 0; r.shadowMap.type = THREE.PCFSoftShadowMap; r.info.autoReset = false;
    r.setClearColor(0x0a0f1a, 1);
    this.scene = new THREE.Scene(); this.camera = new THREE.PerspectiveCamera(50, 16 / 9, 0.5, 7000);
    this.models = new Models(o.modelBase || 'vendor/models/');
    if (!this.q.nomodels) { if (progress) progress('models'); await this.models.load(T.models); }
    if (progress) progress('world');
    this.seed = (o.seed | 0) || 1; await this.buildWorld(this.seed, progress);
    this.camRig = new CameraRig(this.camera, (x, z) => this.gen.heightAt(x, z)); this.camRig.jump(0, 14, 120); this.camRig.t.pitch = this.camRig.d.pitch = 0.95;
    this.dyn = new Dynamic(this); await this.dyn.init();
    this.buildPost(); this.resize(true);
    this.ready = true; if (!this.manual) this.start();
    return this;
  }
  async buildWorld(seed, progress) {
    const T = this.tier, cat = this.catalog || this.o.catalog || null;
    this.gen = new WorldGen(seed, cat && cat.districts, cat && cat.tuning && cat.tuning.base);
    this.gen.buildLattice(2300);
    if (this.world) { this.scene.remove(this.world); this.world.traverse(o => { if (o.geometry) o.geometry.dispose(); }); }
    this.world = new THREE.Group(); this.world.name = 'world';
    this.atmo = this.atmo || new Atmosphere(this.scene, T, this.renderer);
    this.terrain = buildTerrain(this.gen, T); this.roads = buildRoads(this.gen, T); this.sea = buildSea(this.gen);
    this.world.add(this.terrain, this.roads, this.sea);
    this.city = new City(this.gen, T, this.models); this.world.add(this.city.group);
    this.scene.add(this.world); this.city.update(0, 0, true);
    this.worldSeed = seed;
  }
  buildPost() {
    const T = this.tier, r = this.renderer;
    if (this.composer) { this.composer.dispose(); this.composer = null; }
    if (!T.post) { r.toneMapping = THREE.ACESFilmicToneMapping; this.composer = null; return; }
    const pr = r.getPixelRatio(), W = this.W || 1280, H = this.H || 720;
    const rt = new THREE.WebGLRenderTarget(Math.max(2, Math.floor(W * pr)), Math.max(2, Math.floor(H * pr)), { type: THREE.HalfFloatType, samples: T.msaa });
    const c = this.composer = new EffectComposer(r, rt); c.setPixelRatio(pr); c.setSize(W, H);
    c.addPass(new RenderPass(this.scene, this.camera));
    this.bloom = new UnrealBloomPass(new THREE.Vector2(W * pr * T.bloomScale, H * pr * T.bloomScale), 0.4, 0.65, 0.92); this.bloom.enabled = !!T.bloom; c.addPass(this.bloom);
    this.grade = new ShaderPass(GradeShader); c.addPass(this.grade); c.addPass(new OutputPass());
  }
  setTier(name, silent) {
    if (!TIERS[name] || name === this.tierName) return; this.tierName = name; this.tier = TIERS[name]; const T = this.tier;
    this.renderer.shadowMap.enabled = T.shadow > 0; this.atmo.setTier(T); this.buildPost(); this.resize(true);
    // pools / terrain / zombie + particle caps depend on the tier: rebuild the static world and the dynamic layer on the next frame
    this.rebuild = true; if (this.onTier) this.onTier(name);
  }
  async rebuildAll() {
    this.rebuilding = true;
    try {
      if (!this.models.has('zombie') && this.tier.models.includes('zombie') && !this.models.failed.zombie) await this.models.load(this.tier.models.filter(n => !this.models.has(n) && !this.models.failed[n]));
      await this.buildWorld(this.worldSeed);
      const old = this.dyn, sel = old && { ids: [...old.sel], primary: old.primary }; if (old) old.dispose(); this.dyn = new Dynamic(this); await this.dyn.init(); if (this.catalog) this.dyn.setCatalog(this.catalog); if (this.state) this.dyn.sync(this.state); if (sel) this.dyn.setSelection(sel.ids, sel.primary);
      this.camRig.follow = null; if (this.camRig.mode === 'chase') this.camRig.setMode('rts', {});
    } finally { this.rebuilding = false; }
  }
  resize(force) {
    const c = this.canvas, host = c.parentElement || document.body, W = Math.max(2, host.clientWidth || innerWidth), H = Math.max(2, host.clientHeight || innerHeight);
    const dpr = Math.min(window.devicePixelRatio || 1, this.tier.dpr) * this.qScale; if (!force && W === this.W && H === this.H && Math.abs(dpr - (this.dpr || 0)) < 1e-3) return;
    this.W = W; this.H = H; this.dpr = dpr; this.renderer.setPixelRatio(dpr); this.renderer.setSize(W, H, false); c.style.width = W + 'px'; c.style.height = H + 'px';
    this.camera.aspect = W / H; this.camera.updateProjectionMatrix();
    if (this.composer) { this.composer.setPixelRatio(dpr); this.composer.setSize(W, H); } if (this.grade) this.grade.uniforms.uAspect.value = W / H;
    this.stats.dpr = dpr;
  }
  // ------------------------------------------------------------------------------------------------ sim feed
  setCatalog(cat) { this.catalog = cat; if (this.dyn) this.dyn.setCatalog(cat); }
  setState(st) {
    if (!st) return;
    if (this.dyn && this.state && (st.t < this.state.t - 5 || st.seed !== this.state.seed)) this.dyn.reset(); // a new game / a load: no destruction effects for the old colony
    this.state = st;
    if (st.seed && st.seed !== this.worldSeed && !this.rebuilding) { this.rebuilding = true; this.buildWorld(st.seed).then(() => { this.rebuilding = false; }); }
    if (this.dyn) this.dyn.sync(st);
    if (st.hour != null) this.hour = st.hour + (st.minute || 0) / 60;
  }
  onEvents(list) { if (this.dyn) this.dyn.onEvents(list); }
  setHour(h) { this.hourOverride = h; }
  // ------------------------------------------------------------------------------------------------ frame
  start() { if (this.running) return; this.running = true; this.last = performance.now(); const loop = now => { if (!this.running) return; this.raf = requestAnimationFrame(loop); if (document.hidden) { this.last = now; return; } const dt = Math.min(0.1, (now - this.last) / 1000); this.last = now; this.frame(dt, now); }; this.raf = requestAnimationFrame(loop); }
  stop() { this.running = false; if (this.raf) cancelAnimationFrame(this.raf); }
  frame(dt, now) {
    const t0 = performance.now(); this.frameNo++; this.time += dt; U.time.value = this.time;
    if (this.rebuild && !this.rebuilding) { this.rebuild = false; this.rebuildAll(); }
    if (this.rebuilding) { this.renderer.info.reset(); return; } // the world is being rebuilt (tier switch / new seed): skip the frame
    this.resize(false); if (this.preFrame) this.preFrame(dt);
    const st = this.state, hour = this.hourOverride != null ? this.hourOverride : this.hour;
    this.camRig.update(dt);
    const T = this.camRig.t, focus = this._focus || (this._focus = new THREE.Vector3()); focus.set(T.x, T.y, T.z);
    this.atmo.setWeather(st && st.weather ? st.weather.kind : 'clear');
    this.atmo.update(dt, hour, st ? st.season : 'summer', this.camera, focus);
    this.city.update(T.x, T.z, false);
    this.dyn.update(dt, focus);
    const night = U.night.value; if (this.bloom) { this.bloom.strength = lerp(0.26, 0.78, night); this.bloom.threshold = lerp(1.05, 0.82, night); }
    this.renderer.info.reset();
    if (this.composer) this.composer.render(dt); else this.renderer.render(this.scene, this.camera);
    const ri = this.renderer.info.render; this.stats.calls = ri.calls; this.stats.triangles = ri.triangles; this.stats.tier = this.tierName; this.stats.objects = this.dyn.objectCount();
    const ms = performance.now() - t0; this.stats.ms = ms; this.ema = this.ema * 0.92 + (dt * 1000) * 0.08; this.stats.fps = 1000 / Math.max(1, this.ema);
    if (!this.manual && this.tierAuto) this.governor(dt);
  }
  // adaptive resolution (colossus-style) then, as a last resort, a lower tier
  governor(dt) {
    if (this.frameNo < 30) return;
    if (this.ema > 28) { this.slowFor += dt; this.fastFor = 0; } else if (this.ema < 15) { this.fastFor += dt; this.slowFor = 0; } else { this.slowFor = this.fastFor = 0; }
    if (this.slowFor > 2.5) { this.slowFor = 0; if (this.qScale > this.tier.minFrameDpr + 0.01) { this.qScale = Math.max(this.tier.minFrameDpr, this.qScale - 0.15); this.resize(true); } else { const i = TIER_ORDER.indexOf(this.tierName); if (i < TIER_ORDER.length - 1) this.setTier(TIER_ORDER[i + 1]); } }
    else if (this.fastFor > 6 && this.qScale < 1) { this.fastFor = 0; this.qScale = Math.min(1, this.qScale + 0.1); this.resize(true); }
  }
  // test / debug hook: render one frame and read the canvas back (same task, so no preserveDrawingBuffer is needed). Returns luminance stats + a 16x9 signature.
  pixelStats(dt = 0.016) {
    this.frame(dt); const gl = this.renderer.getContext(), w = gl.drawingBufferWidth, h = gl.drawingBufferHeight, px = new Uint8Array(w * h * 4); gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, px);
    let sum = 0, sum2 = 0, n = 0; const sig = new Float32Array(16 * 9), cnt = new Float32Array(16 * 9), seen = new Set(); let r = 0, g = 0, b = 0;
    for (let y = 0; y < h; y += 2) for (let x = 0; x < w; x += 2) { const o = (y * w + x) * 4, l = 0.2126 * px[o] + 0.7152 * px[o + 1] + 0.0722 * px[o + 2]; sum += l; sum2 += l * l; n++; r += px[o]; g += px[o + 1]; b += px[o + 2]; const cell = Math.min(8, Math.floor((1 - y / h) * 9)) * 16 + Math.min(15, Math.floor(x / w * 16)); sig[cell] += l; cnt[cell]++; seen.add((px[o] >> 4) | ((px[o + 1] >> 4) << 4) | ((px[o + 2] >> 4) << 8)); }
    for (let i = 0; i < sig.length; i++) sig[i] = cnt[i] ? sig[i] / cnt[i] : 0; const mean = sum / n;
    return { w, h, mean, variance: sum2 / n - mean * mean, colours: seen.size, rgb: [r / n, g / n, b / n], sig: Array.from(sig) };
  }
  sigDiff(a, b) { let d = 0; for (let i = 0; i < a.length; i++) d += Math.abs(a[i] - b[i]); return d / a.length; }
  dispose() { this.stop(); this.renderer.dispose(); }
}
export async function createWorld3D(o, progress) { const w = new World3D(o); await w.init(progress); return w; }
