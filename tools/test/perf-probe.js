// injected before page scripts: counts WebGL work per animation frame without touching game code
(() => {
  const S = window.__perf = { hist: [], cur: { calls: 0, tris: 0, instDraws: 0, t0: 0 }, texBytes: 0, progs: 0, w: 0, h: 0, frames: 0 };
  const TRI = (mode, n) => mode === 4 ? n / 3 : (mode === 5 || mode === 6) ? Math.max(0, n - 2) : 0;
  for (const C of [window.WebGLRenderingContext, window.WebGL2RenderingContext]) {
    if (!C) continue; const P = C.prototype;
    const wrapDraw = (name, cnt, inst) => { const o = P[name]; if (!o) return;
      P[name] = function (...a) { const c = S.cur; c.calls++; const n = a[cnt] | 0, k = inst >= 0 ? (a[inst] | 0) : 1; if (inst >= 0) c.instDraws++;
        c.tris += TRI(a[0], n) * k; S.w = this.drawingBufferWidth; S.h = this.drawingBufferHeight; return o.apply(this, a); }; };
    wrapDraw('drawArrays', 2, -1); wrapDraw('drawElements', 1, -1); wrapDraw('drawRangeElements', 3, -1);
    wrapDraw('drawArraysInstanced', 2, 3); wrapDraw('drawElementsInstanced', 1, 4);
    const t2 = P.texImage2D; P.texImage2D = function (...a) { let w = 0, h = 0;
      if (a.length >= 9) { w = a[3]; h = a[4]; } else { const s = a[5]; w = s && (s.videoWidth || s.width) || 0; h = s && (s.videoHeight || s.height) || 0; }
      if (a[1] === 0) S.texBytes += w * h * 4 * 1.33; return t2.apply(this, a); };
    if (P.texStorage2D) { const ts = P.texStorage2D; P.texStorage2D = function (t, l, f, w, h) { S.texBytes += w * h * 4 * (l > 1 ? 1.33 : 1); return ts.apply(this, arguments); }; }
    const cp = P.createProgram; P.createProgram = function () { S.progs++; return cp.apply(this, arguments); };
  }
  const raf = window.requestAnimationFrame.bind(window);
  window.requestAnimationFrame = cb => raf(ts => {
    const S2 = window.__perf, prev = S2.cur;
    if (prev.t0) { prev.js = prev.jsEnd - prev.t0; S2.hist.push(prev); if (S2.hist.length > 240) S2.hist.shift(); }
    S2.cur = { calls: 0, tris: 0, instDraws: 0, t0: performance.now() }; S2.frames++;
    try { return cb(ts); } finally { S2.cur.jsEnd = performance.now(); }
  });
})();
