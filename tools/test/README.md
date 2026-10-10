# Headless test tools

Playwright (+ Chromium, WebGL via swiftshader) harness used to verify the browser games without a GPU, a controller or a headset.

    cd tools/test && npm install        # three@0.169.0 (served offline for the games' importmap) + iwer (Meta's WebXR emulator)
    node gp-test.mjs  ../../games/<game>.html   # simulated Xbox/PS pad against the gamepad shim (must exit 0)
    node shelf-test.mjs /tmp                      # shelf renders, archive section, no "undefined"
    node xr-smoke.mjs                             # emulated Quest 3 WebXR session: headset pose + thumbstick + trigger

`harness.mjs` API: `launch(file,{w,h,root})` -> `click/hold/press/mouse/padEvent/dbg/shot/eval/errors/close`.
Assumes Playwright at /opt/node-tools/node_modules/playwright and Chromium at /opt/pw-browsers (the cloud sandbox); edit the two paths at the top of harness.mjs elsewhere.
IWER control ids are `thumbstick`, `trigger`, ... (not `xr-standard-*`); the emulated runtime needs `installRuntime({ forceInstall: true })` because headless Chromium already has a native (unsupported) `navigator.xr`.
    node perf-measure.mjs games/parkcraft.html?hq games/webcraft.html   # draw calls, triangles, JS ms/frame, texture MB per game (WebGL counters injected, no game changes)
