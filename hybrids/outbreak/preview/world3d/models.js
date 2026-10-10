// Outbreak 3D: optional GLB models (PRIVATE USE ONLY, see hybrids/outbreak/THIRD_PARTY.md). Every model has a procedural fallback in the callers:
// if a file fails to load, `get(name)` returns null and the scene builds its own geometry instead.
// BORROWED-PRIVATE: the files under preview/vendor/models/ come from cloned repos (see THIRD_PARTY.md for source path + licence per file).
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import * as SkeletonUtils from 'three/addons/utils/SkeletonUtils.js';

export class Models {
  constructor(base = 'vendor/models/') { this.base = base; this.loader = new GLTFLoader(); this.gltf = {}; this.failed = {}; this.bytes = 0; }
  async load(names, onProgress) {
    let done = 0;
    await Promise.all(names.map(async n => {
      try { this.gltf[n] = await this.loader.loadAsync(this.base + n + '.glb'); } catch (e) { this.failed[n] = String(e && e.message || e); console.warn('[outbreak 3d] model "' + n + '" failed, using the procedural fallback:', this.failed[n]); }
      done++; if (onProgress) onProgress(done, names.length);
    }));
  }
  has(n) { return !!this.gltf[n]; }
  scene(n) { return this.gltf[n] ? this.gltf[n].scene : null; }
  clone(n) { return this.gltf[n] ? SkeletonUtils.clone(this.gltf[n].scene) : null; }
}

// Bake every mesh of `root` (world transforms applied) into standalone geometries, scaled so the whole thing is `height` tall (or by `scale`),
// base centred on the origin. Returns [{ geometry, material, name }] ready for InstancedMesh. Optionally filter by node name.
export function bake(root, { height = 0, scale = 0, rotY = 0, filter = null, center = true, flip = false } = {}) {
  root.updateMatrixWorld(true);
  const box = new THREE.Box3(), tmp = new THREE.Box3(), items = [];
  root.traverse(o => {
    if (!o.isMesh || (filter && !filter(o))) return;
    const g = o.geometry.clone(); g.applyMatrix4(o.matrixWorld);
    g.computeBoundingBox(); tmp.copy(g.boundingBox); box.union(tmp);
    items.push({ geometry: g, material: o.material, name: o.name || (o.parent && o.parent.name) || '' });
  });
  if (!items.length) return [];
  const size = box.getSize(new THREE.Vector3()), c = box.getCenter(new THREE.Vector3());
  const k = scale || (height ? height / Math.max(1e-6, size.y) : 1);
  const m = new THREE.Matrix4().makeRotationY(rotY).multiply(new THREE.Matrix4().makeScale(k, k, k)).multiply(new THREE.Matrix4().makeTranslation(center ? -c.x : 0, -box.min.y, center ? -c.z : 0));
  for (const it of items) { it.geometry.applyMatrix4(m); if (it.geometry.attributes.uv1) it.geometry.deleteAttribute('uv1'); it.geometry.computeBoundingSphere(); }
  items.size = size.clone().multiplyScalar(k);
  return items;
}
