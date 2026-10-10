// Outbreak 3D: colonists. Skinned mannequin rigs (colonist.glb, PRIVATE USE, see THIRD_PARTY.md) driven by procedural poses: walk / run / idle / hammer / cook /
// carry / guard / aim / tend / eat / sleep / downed. Colour per colonist comes from a zone attribute (skin / shirt / trousers / shoes / hair) computed once from the
// rest-pose vertices, so the grey mannequin becomes a person with their own clothes. If the model is missing, a procedural humanoid is used instead (simple poses).
import * as THREE from 'three';
import * as SkeletonUtils from 'three/addons/utils/SkeletonUtils.js';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';
import { clamp, lerp, damp, dampAng, angDiff, hashStr, hash2, rng, PI, TAU } from './util.js';
import { patch } from './terrain.js';
import { humanoidGeo } from './peds.js';

const RIGHT = new THREE.Vector3(-1, 0, 0), UP = new THREE.Vector3(0, 1, 0), FWD = new THREE.Vector3(0, 0, 1);
const SHIRTS = ['#c0392b', '#2e86c1', '#27ae60', '#e0a21b', '#8e44ad', '#16a085', '#d35400', '#d6457f', '#5d6d7e', '#b7950b', '#1abc9c', '#e8e0d0', '#7c8f3a', '#3b5bdb'].map(h => new THREE.Color(h));
const PANTS = ['#2f3b52', '#4a4034', '#33363b', '#5a5144', '#27323f', '#3e4a3a'].map(h => new THREE.Color(h));
const SKINS = ['#e8c4a4', '#d9a77f', '#bd8560', '#8d5b3d', '#6b4430', '#f0d2b8'].map(h => new THREE.Color(h));
const HAIRS = ['#1f1a17', '#3a2a1c', '#6b4a2b', '#b08d57', '#2c2c30', '#7a3b22', '#d8d4c8'].map(h => new THREE.Color(h));
const SHOES = new THREE.Color('#1d1c1e');
export const colonistLook = id => { const h = hashStr(id); return { shirt: SHIRTS[h % SHIRTS.length], pants: PANTS[(h >> 3) % PANTS.length], skin: SKINS[(h >> 6) % SKINS.length], hair: HAIRS[(h >> 9) % HAIRS.length], female: ((h >> 12) & 1) === 1, scale: 0.97 + ((h >> 14) % 9) * 0.01 }; };

const _q = new THREE.Quaternion(), _q2 = new THREE.Quaternion(), _q3 = new THREE.Quaternion(), _m = new THREE.Matrix4(), _m2 = new THREE.Matrix4(), _m3 = new THREE.Matrix4(), _v = new THREE.Vector3(), _s = new THREE.Vector3(), _p0 = new THREE.Vector3();
const qa = (axis, a, out) => out.setFromAxisAngle(axis, a);

// ------------------------------------------------------------------------------------------------------------------ prefab (one per gender)
function zoneOf(x, y, z, H) { // rest-pose coordinates relative to the figure's centre line; 0 skin 1 shirt 2 trousers 3 shoes 4 hair
  const f = y / H;
  if (f < 0.075) return 3;
  if (f < 0.515) return Math.abs(x) > 0.215 && f > 0.4 ? 0 : 2;
  if (f < 0.7 && Math.abs(x) > 0.2) return f < 0.58 ? 0 : 1;
  if (f < 0.795) return Math.abs(x) > 0.3 ? 0 : 1;
  if (f < 0.845) return Math.abs(x) > 0.24 ? 1 : 1;
  if (f < 0.885) return 0;
  if (f > 0.945 && (z < 0.02 || f > 0.975)) return 4;
  return 0;
}
class Prefab {
  constructor(src, gender) {
    this.root = src; this.gender = gender;
    src.updateMatrixWorld(true);
    this.mesh = null; this.bones = {}; src.traverse(o => { if (o.isSkinnedMesh) this.mesh = o; });
    this.skinnedBones = this.mesh.skeleton.bones;
    const find = re => this.skinnedBones.find(b => re.test(b.name));
    const names = { back: /^Back/, hip: /^Hip/, thighR: /^Thigh.*Right/, thighL: /^Thigh.*Left/, shinR: /^Shin.*Right/, shinL: /^Shin.*Left/, footR: /^Foot.*Right/, footL: /^Foot.*Left/, toesR: /^Toes.*Right/, upperR: /^Upperarm.*Right/, upperL: /^Upperarm.*Left/, foreR: /^Forearm.*Right/, foreL: /^Forearm.*Left/, handR: /^Hand.*Right/, handL: /^Hand.*Left/, head: /^Head/ };
    this.idx = {}; for (const [k, re] of Object.entries(names)) { const b = find(re); this.idx[k] = b ? this.skinnedBones.indexOf(b) : -1; }
    this.ok = Object.values(this.idx).every(i => i >= 0);
    // rest data per bone: parent's rest world quaternion (P), local rest quaternion / position
    this.rest = {}; const wq = new THREE.Quaternion();
    for (const [k, i] of Object.entries(this.idx)) { const b = this.skinnedBones[i]; b.parent.getWorldQuaternion(wq); this.rest[k] = { P: wq.clone(), Pinv: wq.clone().invert(), lq: b.quaternion.clone(), lp: b.position.clone(), world: b.matrixWorld.clone() }; }
    const bk = this.skinnedBones[this.idx.back];
    this.rootInv = bk.parent.matrixWorld.clone().invert();
    const tl = this.skinnedBones[this.idx.thighL], tr = this.skinnedBones[this.idx.thighR]; this.pelvis = new THREE.Vector3().addVectors(tl.getWorldPosition(new THREE.Vector3()), tr.getWorldPosition(new THREE.Vector3())).multiplyScalar(0.5);
    // forward axis check (toes in front of ankles)
    const t = this.skinnedBones[this.idx.toesR] ? this.skinnedBones[this.idx.toesR].getWorldPosition(new THREE.Vector3()).z : 0, f = this.skinnedBones[this.idx.footR].getWorldPosition(new THREE.Vector3()).z; this.forwardOk = t >= f - 0.001;
    // figure box + centre line (rest pose), zone attribute
    const g = this.mesh.geometry, n = g.attributes.position.count, zone = new Float32Array(n), box = new THREE.Box3(), p = new THREE.Vector3();
    const pts = []; for (let i = 0; i < n; i++) { this.mesh.getVertexPosition(i, p); pts.push(p.clone()); box.expandByPoint(p); }
    const cx = (this.pelvis.x), H = box.max.y - box.min.y;
    for (let i = 0; i < n; i++) { const q = pts[i]; zone[i] = zoneOf(q.x - cx, q.y - box.min.y, q.z - this.pelvis.z, H); }
    g.setAttribute('aZone', new THREE.BufferAttribute(zone, 1));
    this.height = H; this.cx = cx; this.cz = this.pelvis.z; this.footY = box.min.y;
  }
}
let PREFAB = {};
export function loadPrefabs(models) {
  PREFAB = {};
  if (!models || !models.has('colonist')) return false;
  try {
    for (const [gender, re] of [['male', /Male/i], ['female', /Female/i]]) {
      const scene = models.clone('colonist'), drop = [];
      scene.traverse(o => { const isF = /Female/i.test(o.name), isM = /Male/i.test(o.name) && !isF; if ((o.isSkinnedMesh && ((gender === 'male') ? isF : isM)) || (o.isBone === undefined && !o.isSkinnedMesh && /Arm$/i.test(o.name) && ((gender === 'male') ? /^Female/i.test(o.name) : /^Male/i.test(o.name)))) drop.push(o); });
      for (const o of drop) o.parent && o.parent.remove(o);
      scene.position.set(0, 0, 0); scene.updateMatrixWorld(true);
      const pf = new Prefab(scene, gender); if (!pf.ok) { console.warn('[outbreak 3d] colonist rig bones missing for', gender); continue; } PREFAB[gender] = pf;
    }
  } catch (e) { console.warn('[outbreak 3d] colonist prefab failed:', e); PREFAB = {}; }
  return !!(PREFAB.male || PREFAB.female);
}

function colonistMaterial(look) {
  const m = new THREE.MeshStandardMaterial({ color: 0xffffff, roughness: 0.82, metalness: 0 });
  const U_ = { uShirt: { value: look.shirt.clone() }, uPants: { value: look.pants.clone() }, uSkin: { value: look.skin.clone() }, uHair: { value: look.hair.clone() }, uShoes: { value: SHOES.clone() }, uTint: { value: new THREE.Color(1, 1, 1) } };
  patch(m, { key: 'colonist', vHead: 'attribute float aZone; varying float vZone;', vMain: 'vZone = aZone;', fHead: 'varying float vZone; uniform vec3 uShirt; uniform vec3 uPants; uniform vec3 uSkin; uniform vec3 uHair; uniform vec3 uShoes; uniform vec3 uTint;',
    fColor: `{ vec3 c = vZone < 0.5 ? uSkin : vZone < 1.5 ? uShirt : vZone < 2.5 ? uPants : vZone < 3.5 ? uShoes : uHair; float k = 0.9 + 0.1 * fract(sin(dot(vec3(vZone), vec3(12.9, 78.2, 37.7))) * 43758.5); diffuseColor.rgb = c * k * uTint; }`, uniforms: U_ });
  m.userData.u = U_; return m;
}

// ------------------------------------------------------------------------------------------------------------------ held items (shared geometries)
const HELD = {};
function heldGeo() {
  if (HELD.rifle) return HELD;
  const mk = (list) => { const gs = list.map(([g, col]) => { g = g.toNonIndexed(); for (const k of Object.keys(g.attributes)) if (k !== 'position' && k !== 'normal') g.deleteAttribute(k); const n = g.attributes.position.count, c = new Float32Array(n * 3), k = new THREE.Color(col); for (let i = 0; i < n; i++) { c[i * 3] = k.r; c[i * 3 + 1] = k.g; c[i * 3 + 2] = k.b; } g.setAttribute('color', new THREE.BufferAttribute(c, 3)); return g; }); return mergeGeometries(gs); };
  const B = (w, h, d, x, y, z) => new THREE.BoxGeometry(w, h, d).translate(x, y, z);
  HELD.rifle = mk([[B(0.05, 0.08, 0.72, 0, 0, 0.18), 0x25282b], [B(0.04, 0.14, 0.07, 0, -0.1, 0.08), 0x25282b], [B(0.045, 0.1, 0.26, 0, -0.03, -0.26), 0x5a4330], [B(0.02, 0.03, 0.18, 0, 0.06, 0.38), 0x25282b]]);
  HELD.blade = mk([[B(0.03, 0.05, 0.62, 0, 0, 0.34), 0xbfc4c8], [B(0.045, 0.07, 0.18, 0, 0, -0.06), 0x3a2c22]]);
  HELD.hammer = mk([[B(0.035, 0.035, 0.5, 0, 0, 0.1), 0x6a4b2e], [B(0.06, 0.07, 0.15, 0, 0, 0.36), 0x8a8f94]]);
  HELD.crate = mk([[B(0.46, 0.3, 0.36, 0, 0, 0), 0x8a6a42], [B(0.47, 0.04, 0.37, 0, 0.1, 0), 0x6b4f30], [B(0.47, 0.04, 0.37, 0, -0.1, 0), 0x6b4f30]]);
  HELD.cup = mk([[new THREE.CylinderGeometry(0.035, 0.03, 0.09, 8), 0xd8d4c8]]);
  HELD.mat = new THREE.MeshStandardMaterial({ vertexColors: true, roughness: 0.75, metalness: 0.15 });
  return HELD;
}

// ------------------------------------------------------------------------------------------------------------------ actor
const POSES = { // targets for the smoothed pose parameters; arms: [pitch, abduct, elbow]
  idle:   { lean: 0.02, crouch: 0, armR: [0.03, 0.05, 0.12], armL: [0.03, 0.05, 0.12], held: '' },
  walk:   { lean: 0.07, crouch: 0, armR: null, armL: null, held: '' },
  hammer: { lean: 0.30, crouch: 0.12, armR: [0.9, 0.1, 1.0], armL: [0.7, 0.15, 1.3], held: 'hammer' },
  cook:   { lean: 0.2, crouch: 0.05, armR: [0.75, 0.15, 1.2], armL: [0.6, 0.15, 1.3], held: '' },
  carry:  { lean: -0.04, crouch: 0.06, armR: [1.05, 0.05, 0.85], armL: [1.05, 0.05, 0.85], held: 'crate' },
  guard:  { lean: 0.03, crouch: 0, armR: [0.75, 0.0, 1.25], armL: [1.0, 0.1, 1.0], held: 'weapon' },
  aim:    { lean: 0.06, crouch: 0.1, armR: [1.45, 0.0, 0.25], armL: [1.4, 0.05, 0.55], held: 'weapon' },
  medic:  { lean: 0.5, crouch: 0.18, armR: [0.95, 0.1, 0.5], armL: [0.9, 0.1, 0.6], held: '' },
  eat:    { lean: 0.04, crouch: 0, armR: [0.5, 0.05, 2.0], armL: [0.05, 0.05, 0.15], held: 'cup' },
  stagger:{ lean: 0.22, crouch: 0.05, armR: [0.3, 0.3, 0.3], armL: [0.2, 0.3, 0.2], held: '' },
  sleep:  { lean: 0, crouch: 0, armR: [0.05, 0.1, 0.2], armL: [0.05, 0.1, 0.2], held: '', lie: -1 },
  down:   { lean: 0, crouch: 0, armR: [0.3, 0.7, 0.2], armL: [0.2, 0.7, 0.3], held: '', lie: 1 },
};
export class ColonistActor {
  constructor(id, look, weaponKind) {
    this.id = id; this.look = look; this.root = new THREE.Group(); this.root.name = 'colonist:' + id; this.mat = colonistMaterial(look); this.px = 0; this.pz = 0; this.yaw = 0; this.speed = 0; this.ph = hashStr(id) % 6;
    this.gait = 0; this.pose = { lean: 0, crouch: 0, armR: [0, 0, 0], armL: [0, 0, 0], lie: 0, headYaw: 0, headPitch: 0, twist: 0, roll: 0 }; this.poseName = 'idle'; this.t = Math.random() * 10; this.lieBlend = 0;
    this.prefab = PREFAB[look.female ? 'female' : 'male'] || PREFAB.male || PREFAB.female || null; this.glb = !!this.prefab; this.vis = true; this.hand = new THREE.Vector3(); this.muzzle = new THREE.Vector3();
    this.body = new THREE.Group(); this.root.add(this.body);
    if (this.prefab) {
      const clone = SkeletonUtils.clone(this.prefab.root); this.model = clone; this.model.traverse(o => { if (o.isSkinnedMesh) { this.mesh = o; o.material = this.mat; o.castShadow = true; o.receiveShadow = false; o.frustumCulled = false; } });
      const k = 1.76 / this.prefab.height * look.scale; this.k = k; this.body.add(clone); clone.scale.setScalar(k); clone.position.set(-this.prefab.cx * k, -this.prefab.footY * k, -this.prefab.cz * k);
      const sb = this.mesh.skeleton.bones; this.b = {}; for (const [key, i] of Object.entries(this.prefab.idx)) this.b[key] = sb[i];
      this.rootBone = this.b.back.parent;
    } else {
      const g = humanoidGeo({ shirt: look.shirt.getHex(), pants: look.pants.getHex(), skin: look.skin.getHex(), hair: look.hair.getHex() });
      const m = new THREE.Mesh(g, new THREE.MeshStandardMaterial({ vertexColors: true, roughness: 0.85 })); m.castShadow = true; this.body.add(m); this.mesh = m;
    }
    const H = heldGeo(); this.items = {};
    for (const key of ['rifle', 'blade', 'hammer', 'crate', 'cup']) { const m = new THREE.Mesh(H[key], H.mat); m.visible = false; m.castShadow = true; m.frustumCulled = false; this.root.add(m); this.items[key] = m; }
    this.heldNow = ''; this.weaponKind = weaponKind || 'rifle';
    this.root.userData.actor = this;
  }
  setPose(name) { this.poseName = name; }
  // advance animation. moving: speed (m/s), pose name chosen by the caller
  animate(dt, speed, poseName, aimYaw) {
    this.t += dt; const P = POSES[poseName] || POSES.idle, pose = this.pose, walkAmp = clamp(speed / 3.2, 0, 1.25);
    this.gait = damp(this.gait, walkAmp, 10, dt); this.ph += dt * (3.2 + this.gait * 5.2) * (this.gait > 0.05 ? 1 : 0.2);
    const keepArms = !P.armR || (this.gait > 0.22 && poseName !== 'carry' && poseName !== 'aim' && poseName !== 'guard');
    const g = this.gait, ph = this.ph, sw = Math.sin(ph);
    const R = poseName === 'hammer' && this.gait < 0.3 ? 0.9 + 0.75 * Math.max(0, Math.sin(this.t * 7.5)) : 0;
    const tgtR = keepArms ? [-sw * 0.55 * g + 0.03, 0.06, 0.15 + 0.5 * g] : [P.armR[0] + (poseName === 'hammer' ? -0.6 + (Math.sin(this.t * 7.5) * 0.5 + 0.5) * 1.5 : 0) + (poseName === 'cook' ? Math.sin(this.t * 3) * 0.15 : 0), P.armR[1], P.armR[2]];
    const tgtL = keepArms ? [sw * 0.55 * g + 0.03, 0.06, 0.15 + 0.5 * g] : [P.armL[0] + (poseName === 'cook' ? Math.cos(this.t * 3) * 0.12 : 0), P.armL[1], P.armL[2]];
    if (poseName === 'eat') tgtR[0] = 0.8 + Math.sin(this.t * 1.6) * 0.18;
    const lr = 9 * dt;
    for (let i = 0; i < 3; i++) { pose.armR[i] += (tgtR[i] - pose.armR[i]) * Math.min(1, lr); pose.armL[i] += (tgtL[i] - pose.armL[i]) * Math.min(1, lr); }
    const lean = P.lean + (poseName === 'hammer' ? Math.max(0, Math.sin(this.t * 7.5)) * 0.18 : 0) + g * 0.1 + (poseName === 'medic' ? Math.sin(this.t * 1.3) * 0.06 : 0);
    pose.lean += (lean - pose.lean) * Math.min(1, 8 * dt); pose.crouch += (P.crouch - pose.crouch) * Math.min(1, 6 * dt);
    pose.headYaw = damp(pose.headYaw, poseName === 'idle' || poseName === 'guard' ? Math.sin(this.t * 0.6 + this.ph * 0) * 0.7 * (poseName === 'guard' ? 1 : 0.5) : (aimYaw || 0) * 0.3, 3, dt);
    pose.headPitch = damp(pose.headPitch, poseName === 'medic' ? 0.4 : poseName === 'hammer' ? 0.3 : poseName === 'down' ? 0.5 : 0, 5, dt);
    pose.twist = damp(pose.twist, poseName === 'hammer' ? Math.sin(this.t * 7.5) * 0.12 : poseName === 'stagger' ? Math.sin(this.t * 2.2) * 0.2 : sw * 0.07 * g, 10, dt);
    pose.roll = damp(pose.roll, poseName === 'stagger' ? Math.sin(this.t * 1.7) * 0.16 : 0, 6, dt);
    const lie = P.lie || 0; this.lieBlend = damp(this.lieBlend, lie, 5, dt);
    this.applyBones(g, ph); this.applyHeld(P.held === 'weapon' ? (this.weaponKind === 'melee' ? 'blade' : 'rifle') : P.held, poseName, dt);
    // whole-body lie / crouch drop: lb < 0 sleeps on the back (-90 deg about X), lb > 0 lies face down (+90 deg); the body is re-centred on its length
    const lb = this.lieBlend, ab = Math.abs(lb);
    if (this.prefab) { this.body.rotation.set(lb * PI / 2, 0, 0); this.body.position.set(0, 0.22 * ab - pose.crouch * 0.36 * (1 - ab), -lb * 0.88); }
  }
  applyBones(g, ph) {
    const pf = this.prefab; if (!pf) { this.mesh.position.y = Math.abs(Math.sin(this.ph)) * 0.03 * g; this.mesh.rotation.x = this.pose.lean * 0.5; return; }
    const b = this.b, rest = pf.rest, pose = this.pose, cr = pose.crouch;
    // torso: rotate Back (and everything above) about the pelvis; pin Hip so the legs stay put
    qa(RIGHT, -pose.lean, _q); qa(UP, pose.twist, _q2); _q.premultiply(_q2); qa(FWD, pose.roll, _q2); _q.premultiply(_q2);
    _m.makeTranslation(pf.pelvis.x, pf.pelvis.y, pf.pelvis.z).multiply(_m2.makeRotationFromQuaternion(_q)).multiply(_m3.makeTranslation(-pf.pelvis.x, -pf.pelvis.y, -pf.pelvis.z));
    _m.multiply(rest.back.world); // new world of Back
    _m2.copy(pf.rootInv).multiply(_m).decompose(b.back.position, b.back.quaternion, _s);
    _m3.copy(_m).invert().multiply(rest.hip.world).decompose(b.hip.position, b.hip.quaternion, _s);
    const set = (key, dq) => { const r = rest[key], bone = b[key]; bone.quaternion.copy(r.Pinv).multiply(dq).multiply(r.P).multiply(r.lq); };
    const swing = Math.sin(ph) * 0.62 * g, swingL = -swing, tr = 1.0 * cr, knee = 1.9 * cr;
    const kneeR = -(0.12 * g + 0.95 * g * Math.max(0, -Math.sin(ph - 0.5)) * 0.9) - knee, kneeL = -(0.12 * g + 0.95 * g * Math.max(0, Math.sin(ph - 0.5)) * 0.9) - knee;
    qa(RIGHT, swing + tr, _q); set('thighR', _q); qa(RIGHT, swingL + tr, _q); set('thighL', _q);
    qa(RIGHT, kneeR, _q); set('shinR', _q); qa(RIGHT, kneeL, _q); set('shinL', _q);
    qa(RIGHT, -(swing + tr + kneeR) * 1.0 - 0.0, _q); set('footR', _q); qa(RIGHT, -(swingL + tr + kneeL), _q); set('footL', _q);
    const arm = (key, fore, hand, a, side) => { qa(FWD, -side * a[1], _q2); qa(RIGHT, a[0], _q); _q.premultiply(_q2); set(key, _q); qa(RIGHT, a[2], _q); set(fore, _q); };
    arm('upperR', 'foreR', 'handR', pose.armR, 1); arm('upperL', 'foreL', 'handL', pose.armL, -1);
    qa(UP, pose.headYaw, _q2); qa(RIGHT, -pose.headPitch, _q); _q.premultiply(_q2); set('head', _q);
  }
  applyHeld(kind, poseName, dt) {
    const it = this.items; for (const k of Object.keys(it)) it[k].visible = false;
    const key = kind === 'weapon' ? 'rifle' : kind; if (!key || !it[key]) return; const m = it[key]; m.visible = true;
    if (!this.prefab) { m.position.set(0, 1.2, 0.35); m.rotation.set(0, 0, 0); return; }
    this.root.updateMatrixWorld(true);
    const hb = this.b.handR; hb.getWorldPosition(_v); this.root.worldToLocal(_v); const hl = this.b.handL; hl.getWorldPosition(_p0); this.root.worldToLocal(_p0);
    m.position.copy(_v);
    if (key === 'rifle' || key === 'blade') { m.rotation.set(poseName === 'aim' ? -0.02 : 0.35, 0, 0); m.position.y += 0.02; m.position.z -= 0.05; m.updateMatrixWorld(true); if (key === 'rifle') this.muzzle.set(0, 0.05, 0.9).applyMatrix4(m.matrixWorld); }
    else if (key === 'hammer') { m.rotation.set(-0.5 + Math.sin(this.t * 7.5) * 0.7, 0, 0); m.position.y += 0.02; }
    else if (key === 'crate') { m.position.set(0, 1.12, 0.38); m.rotation.set(0, 0, 0); }
    else if (key === 'cup') { m.position.copy(_v); m.position.y += 0.06; }
    m.updateMatrixWorld(true);
  }
  setVisible(v) { this.root.visible = v; }
  setColor(tint) { this.mat.userData.u.uTint.value.copy(tint); }
  dispose() { this.mat.dispose(); }
}
