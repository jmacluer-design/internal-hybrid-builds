// Quality tiers for the Outbreak 3D world. Auto-pick: desktop GPU -> high, laptop / integrated GPU -> mid, phone / software GL -> low.
// Ported in spirit from games/shatterworld.html (QUALITY table + applyQuality): the same knobs (pixel ratio, shadow map, bloom, msaa, particle cap).
// `pool` = capacity of each streamed instance pool (nearest N instances are drawn), `peds` = zombie instance cap, `models` = which GLB models load.
export const TIERS = {
  high: {
    name: 'high', dpr: 2, shadow: 2048, shadowR: 64, bloom: 1, bloomScale: 0.5, msaa: 4, post: true,
    grid: { l0: 2.5, l1: 10, l2: 40 }, view: 1600, fx: 2600, rain: 2200, lights: 6, zombies: 420, zombieGlb: 90, treesGlb: 150, colonistSkin: true,
    pool: { house: 1100, box: 800, tower: 10, tree: 1700, lamp: 420, car: 150, prop: 520, ruin: 36 },
    models: ['zombie', 'colonist', 'pickup', 'hatchback', 'campfire', 'ruin', 'watertower', 'apartment_a', 'apartment_b', 'apartment_c', 'apartment_d', 'props'],
    roadsTex: 2048, clouds: 1, windows: 1, grass: 1, minFrameDpr: 0.7,
  },
  mid: {
    name: 'mid', dpr: 1.5, shadow: 1024, shadowR: 56, bloom: 1, bloomScale: 0.35, msaa: 0, post: true,
    grid: { l0: 3.5, l1: 14, l2: 56 }, view: 1200, fx: 1400, rain: 1200, lights: 3, zombies: 260, zombieGlb: 48, treesGlb: 60, colonistSkin: true,
    pool: { house: 700, box: 520, tower: 8, tree: 1000, lamp: 260, car: 90, prop: 320, ruin: 24 },
    models: ['zombie', 'colonist', 'pickup', 'hatchback', 'campfire', 'ruin', 'watertower', 'apartment_a', 'apartment_b', 'apartment_c', 'apartment_d', 'props'],
    roadsTex: 1024, clouds: 1, windows: 1, grass: 0.6, minFrameDpr: 0.6,
  },
  low: {
    name: 'low', dpr: 1, shadow: 0, shadowR: 0, bloom: 0, bloomScale: 0.25, msaa: 0, post: false,
    grid: { l0: 5, l1: 20, l2: 80 }, view: 800, fx: 600, rain: 500, lights: 0, zombies: 110, zombieGlb: 14, treesGlb: 0, colonistSkin: true,
    pool: { house: 300, box: 220, tower: 4, tree: 420, lamp: 100, car: 36, prop: 140, ruin: 10 },
    models: ['zombie', 'colonist', 'pickup', 'campfire', 'apartment_b', 'apartment_c'],
    roadsTex: 512, clouds: 0, windows: 1, grass: 0.25, minFrameDpr: 0.5,
  },
};
export const TIER_ORDER = ['high', 'mid', 'low'];
const ALIAS = { medium: 'mid', med: 'mid', hi: 'high', lo: 'low' };

export function gpuInfo(gl) {
  try { const e = gl.getExtension('WEBGL_debug_renderer_info'); return e ? String(gl.getParameter(e.UNMASKED_RENDERER_WEBGL) || '') : String(gl.getParameter(gl.RENDERER) || ''); } catch (e) { return ''; }
}
export function isPhone() {
  const mm = s => !!(window.matchMedia && matchMedia(s).matches);
  const coarse = mm('(pointer: coarse)') && mm('(hover: none)');
  return coarse || Math.min(screen.width, screen.height) < 600 || /Android|iPhone|iPad|Mobile/i.test(navigator.userAgent || '');
}
// returns { tier, auto, reason }
export function pickTier(gpu, query) {
  const q = (query || '').toLowerCase();
  const forced = ALIAS[q] || q;
  if (TIERS[forced]) return { tier: forced, auto: false, reason: 'query' };
  let saved = null; try { saved = localStorage.getItem('ob.quality'); } catch (e) { /* storage blocked */ }
  saved = ALIAS[saved] || saved;
  if (TIERS[saved]) return { tier: saved, auto: false, reason: 'saved' };
  if (isPhone()) return { tier: 'low', auto: true, reason: 'phone' };
  const g = (gpu || '').toLowerCase();
  if (/swiftshader|llvmpipe|software|softpipe|basic render/.test(g)) return { tier: 'low', auto: true, reason: 'software GL' };
  const cores = navigator.hardwareConcurrency || 4, mem = navigator.deviceMemory || 8;
  if (/intel|uhd|iris|vega|apple|adreno|mali|powervr|radeon graphics|microsoft/.test(g) || cores <= 4 || mem <= 4) return { tier: 'mid', auto: true, reason: 'integrated / laptop' };
  return { tier: 'high', auto: true, reason: 'discrete GPU' };
}
export function webglOk() {
  try { const c = document.createElement('canvas'); const gl = c.getContext('webgl2'); if (!gl) return null; const info = gpuInfo(gl); const lose = gl.getExtension('WEBGL_lose_context'); if (lose) lose.loseContext(); return info || 'webgl2'; } catch (e) { return null; }
}
