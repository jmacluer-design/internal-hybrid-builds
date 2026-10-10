// Outbreak 3D: camera rig. Overhead RTS camera (pan / zoom / rotate with smooth damping, tilt follows zoom) and a chase camera that follows a colonist (or the
// player). Both are the same spherical rig {target, dist, yaw, pitch, fov}: switching modes only changes the desired values, so transitions are smooth for free.
// Ground picking = ray vs terrain (plane first, refined against the height function).
import * as THREE from 'three';
import { clamp, lerp, sstep, damp, dampAng, angDiff, PI, TAU } from './util.js';

export class CameraRig {
  constructor(camera, heightAt) {
    this.cam = camera; this.heightAt = heightAt;
    this.mode = 'rts'; this.follow = null;                 // follow: { x, z, yaw } getter object (actor)
    this.t = { x: 0, z: 18, dist: 150, yaw: 0, pitch: 0.95, fov: 50, y: 0 };     // current (smoothed)
    this.d = { x: 0, z: 18, dist: 150, yaw: 0, pitch: 0.95, fov: 50 };           // desired
    this.userYaw = 0; this.keys = new Set(); this.speedMul = 1; this.shake = 0; this.dragging = false;
    this.minDist = 14; this.maxDist = 900; this.bounds = 2350; this.ray = new THREE.Raycaster(); this._v = new THREE.Vector3(); this._h = new THREE.Vector3(); this._ndc = new THREE.Vector2();
    this.moved = true; this.lastKey = '';
  }
  // ------------------------------------------------------------------------------------------------ input API (all in world metres / radians)
  setTarget(x, z, dist) { this.d.x = clamp(x, -this.bounds, this.bounds); this.d.z = clamp(z, -this.bounds, this.bounds); if (dist) this.d.dist = clamp(dist, this.minDist, this.maxDist); if (this.mode === 'chase') this.setMode('rts'); }
  jump(x, z, dist) { this.setTarget(x, z, dist); this.t.x = this.d.x; this.t.z = this.d.z; if (dist) this.t.dist = this.d.dist; }
  panRight(m) { const c = Math.cos(this.d.yaw), s = Math.sin(this.d.yaw); this.d.x = clamp(this.d.x + c * m, -this.bounds, this.bounds); this.d.z = clamp(this.d.z - s * m, -this.bounds, this.bounds); }
  panForward(m) { const c = Math.cos(this.d.yaw), s = Math.sin(this.d.yaw); this.d.x = clamp(this.d.x - s * m, -this.bounds, this.bounds); this.d.z = clamp(this.d.z - c * m, -this.bounds, this.bounds); }
  // drag-pan: move the focus so the ground point under the cursor stays under the cursor (metres per pixel at the focus distance)
  panPixels(dx, dy, viewH) {
    const mpp = 2 * this.t.dist * Math.tan(THREE.MathUtils.degToRad(this.t.fov) / 2) / Math.max(1, viewH); // metres per pixel at the focus
    const fy = 1 / Math.max(0.35, Math.sin(this.t.pitch));
    this.panRight(-dx * mpp); this.panForward(dy * mpp * fy);
    if (this.mode === 'chase') this.setMode('rts');
  }
  zoom(f) { if (this.mode === 'chase') { this.chaseDist = clamp((this.chaseDist || 7) * f, 2.6, 30); if (this.chaseDist > 24) this.setMode('rts', { dist: 60 }); } else this.d.dist = clamp(this.d.dist * f, this.minDist, this.maxDist); }
  rotate(dy) { if (this.mode === 'chase') this.userYaw += dy; else this.d.yaw += dy; }
  tilt(dp) { this.pitchBias = clamp((this.pitchBias || 0) + dp, -0.5, 0.45); }
  setMode(mode, o = {}) {
    if (mode === this.mode) { if (o.follow) this.follow = o.follow; return; }
    this.mode = mode;
    if (mode === 'chase') { this.follow = o.follow || this.follow; this.chaseDist = o.dist || 7.5; this.userYaw = 0; this.d.fov = 62; }
    else { this.follow = null; this.d.fov = 50; if (o.dist) this.d.dist = o.dist; else this.d.dist = Math.max(this.d.dist, 60); if (this.t) { this.d.x = this.t.x; this.d.z = this.t.z; } }
  }
  // ------------------------------------------------------------------------------------------------ per frame
  update(dt) {
    const d = this.d, t = this.t;
    if (this.mode === 'rts') {
      const k = this.keys; let f = 0, r = 0, ro = 0;
      if (k.has('w') || k.has('ArrowUp')) f += 1; if (k.has('s') || k.has('ArrowDown')) f -= 1; if (k.has('d') || k.has('ArrowRight')) r += 1; if (k.has('a') || k.has('ArrowLeft')) r -= 1;
      if (k.has('q')) ro -= 1; if (k.has('e')) ro += 1;
      const sp = t.dist * 1.05 * (k.has('shift') ? 2.4 : 1) * dt;
      if (f) this.panForward(f * sp); if (r) this.panRight(r * sp); if (ro) d.yaw += ro * 1.4 * dt;
      d.pitch = lerp(0.62, 1.12, sstep(25, 300, d.dist)) + (this.pitchBias || 0);
    } else if (this.follow) {
      const f = this.follow; d.x = f.x; d.z = f.z; d.dist = this.chaseDist || 7.5; d.pitch = 0.3 + (this.pitchBias || 0) * 0.5 + clamp((this.chaseDist - 6) * 0.01, 0, 0.1);
      const want = f.yaw + PI + this.userYaw; d.yaw = t.yaw + angDiff(t.yaw, want);
      if (Math.abs(this.userYaw) > 0 && !this.dragging) this.userYaw *= Math.exp(-0.5 * dt); // slowly swing back behind the colonist
    }
    const rate = this.mode === 'chase' ? 7 : 6.5;
    t.x = damp(t.x, d.x, rate, dt); t.z = damp(t.z, d.z, rate, dt); t.dist = damp(t.dist, d.dist, 5.2, dt); t.pitch = damp(t.pitch, d.pitch, 5, dt); t.fov = damp(t.fov, d.fov, 4, dt);
    t.yaw = this.mode === 'chase' ? dampAng(t.yaw, d.yaw, 5.5, dt) : t.yaw + (d.yaw - t.yaw) * (1 - Math.exp(-8 * dt));
    const gy = this.heightAt(t.x, t.z); t.y = damp(t.y, gy + (this.mode === 'chase' ? 1.55 : 0), 8, dt);
    this.apply();
  }
  apply() {
    const t = this.t, c = this.cam, cp = Math.cos(t.pitch), sp = Math.sin(t.pitch);
    c.position.set(t.x + Math.sin(t.yaw) * cp * t.dist, t.y + sp * t.dist, t.z + Math.cos(t.yaw) * cp * t.dist);
    const gy = this.heightAt(c.position.x, c.position.z) + 1.6; if (c.position.y < gy) c.position.y = gy;
    if (this.shake > 0.001) { c.position.x += (Math.random() - 0.5) * this.shake; c.position.y += (Math.random() - 0.5) * this.shake; this.shake *= 0.9; }
    c.lookAt(t.x, t.y + (this.mode === 'chase' ? 0.3 : 0), t.z); c.fov = t.fov; c.near = clamp(t.dist * 0.03, 0.25, 5); c.far = 7000; c.updateProjectionMatrix(); c.updateMatrixWorld(true);
  }
  // ------------------------------------------------------------------------------------------------ picking
  ndc(px, py, W, H) { this._ndc.set(px / W * 2 - 1, -(py / H) * 2 + 1); return this._ndc; }
  // ground point under a screen pixel (three space). Returns null if the ray points to the sky.
  groundAt(px, py, W, H, out) {
    this.ray.setFromCamera(this.ndc(px, py, W, H), this.cam); const o = this.ray.ray.origin, d = this.ray.ray.direction;
    if (d.y > -0.01) return null; let y = this.t.y, x = 0, z = 0;
    for (let i = 0; i < 4; i++) { const s = (y - o.y) / d.y; x = o.x + d.x * s; z = o.z + d.z * s; y = this.heightAt(x, z); }
    out = out || new THREE.Vector3(); return out.set(x, y, z);
  }
  // screen position of a world point (px); returns false when behind the camera
  project(x, y, z, W, H, out) { this._h.set(x, y, z).project(this.cam); out[0] = (this._h.x * 0.5 + 0.5) * W; out[1] = (-this._h.y * 0.5 + 0.5) * H; out[2] = this._h.z; return this._h.z < 1 && this._h.z > -1; }
  // metres covered by one screen pixel at distance `d` from the camera
  pxScale(d, H) { return 2 * d * Math.tan(THREE.MathUtils.degToRad(this.cam.fov) / 2) / Math.max(1, H); }
}
