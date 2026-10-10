# Touch controls (phone as the player's own controller)

`tools/touch-shim.js` puts on-screen controls on a game page so a phone can play it directly. It feeds the **same inputs** as the keyboard,
the phone-as-gamepad page (`pad.html`) and the gamepad shim: `keys` (a `Set`), `padFire(down)`, `padPlace(down)`, `padLook(dx,dy)`, `padMenu()`.
No game logic is touched. `tools/inject_touch.py` pastes it into a game, idempotently, between `// <touch-shim>` / `// </touch-shim>` markers,
right after the `// </gamepad-shim>` block.

    python3 tools/inject_touch.py games/foo.html [games/bar.html ...]    # (re)insert; also makes sure the viewport meta has user-scalable=no + maximum-scale=1
    python3 tools/inject_touch.py --check games/*.html                  # up to date / STALE / MISSING
    python3 tools/inject_touch.py --remove games/foo.html               # strip it again

## Behaviour

| Rule | How |
|---|---|
| Only on touch devices | `matchMedia('(pointer: coarse)')` (and `maxTouchPoints > 0`, so TV browsers that claim coarse stay clean) **or** the first `touchstart`. `?touch` in the URL / `localStorage ib_touch.force` forces it on (desktop debugging, mouse acts as one finger). |
| Hidden when a pad is connected | any `navigator.getGamepads()` entry that is connected and not `xr-standard`; back as soon as it disconnects. |
| Hidden while WebXR presents | `navigator.xr.requestSession` is wrapped once; any non-`inline` session hides the controls until its `end` event. `window.__xrPresenting` is honoured too. |
| Only while playing | hidden whenever `#menu`, `#dead`, `#pause` or `#loadsplash` (plus `profile.overlays`) is displayed (MutationObserver + a 250 ms safety tick). Held keys/touches are released on every hide, on `blur` and on `visibilitychange`. |
| Big start target | if `#cta` / `#cta2` is visible but not fully on screen (souls64's menu card is taller than a landscape phone) a floating start button mirrors it. |
| Pointer lock | a mouse feature. While it is held, Chromium reports `clientX/Y = 0` for touch pointer events, and phones have no use for it, so on touch devices `requestPointerLock()` is made to fail (a `pointerlockerror` event, no promise). All five games already handle that (`noLock` / `lockFailed`: look comes from `padLook`, no pause-on-unlock). Desktop is untouched (the wrapper calls the real API unless the shim is active). If a hybrid device already holds a lock when the first finger lands, the shim exits it (the game pauses; tap resume). |
| No zoom/scroll/long-press | `touch-action:none` on every control, `touchstart` is cancelled on them (this also stops the compat `mousedown/mouseup/click` that games listen to on `window`), `gesture*`/`touchmove` cancelled while visible, `contextmenu` + `selectstart` blocked, `overscroll-behavior:none`. Viewport: `user-scalable=no` (patched in by the injector and again at runtime if missing). Orientation is never locked. |
| Fullscreen | one `requestFullscreen` on the first touch tap (inside the gesture); the gear panel has a Fullscreen toggle. |
| Haptics | `navigator.vibrate(8)` on button/gear/menu down where supported (not iOS). |
| Portrait | a "Rotate to landscape to play" pill (dismissable) on touch devices; the controls still work in portrait. |

## Controls

* **Move**: dynamic stick in the left 40% of the screen (pad.html's stick logic): the base appears where the thumb lands, offset is clamped to the radius (about 57 px) and mapped to `w/a/s/d` with the same hysteresis as `pad.html` (on at .38, off at .22). Back is `s`.
* **Look**: dragging anywhere else (not on a button) is a floating right stick that calls `padLook(dx,dy)` with values in [-1,1] (response curve |v|^1.5, games ignore |v| < 0.12). Releasing sends `padLook(0,0)`. **Drag from FIRE** also drives look while FIRE stays down (hold-to-swing + aim with one thumb).
* **Action fan** (bottom-right, mirrors when left-handed): three thumb-rest buttons (big one in the middle), the rest on an outer arc. All buttons are at least 56 px (the size slider is capped so the fan never runs into the MENU row); they are placed from the safe-area insets (pages with `viewport-fit=cover` get `env(safe-area-inset-*)`; blockshot and souls64 have it, the other three do not, so there env() is 0).
* **Modifier column** (left edge, in the band between the top-left and bottom-left HUD blocks): toggles (`SPRINT`/`CREEP`/`SNEAK`/`BOOST`, tap on / tap off, lit dot) and one-shots. A lit toggle stays on until tapped again or the controls hide.
* **MENU** (top-right): `padMenu()`. Colossus and souls64 only pause on it (one tap; souls64 shows its Resume menu); webcraft, blockshot and parkcraft abandon the run, so it needs a second tap within 2 s ("QUIT?").
* **Gear**: size, opacity, look speed, left-handed, invert look Y, Sound (sends `M`), Fullscreen, Reset. Persisted in `localStorage['ib_touch']` (`{size,opacity,sens,left,invY}`); changing them re-lays the controls out immediately.
* A key tap is held at least 60 ms so games that poll `keys` once per physics step cannot miss it.
* Everything is DOM/CSS moved with `transform`; there is no rAF loop and no canvas. Work happens per input event and on a 4 Hz state check.

## Per-game mapping

(Labels are the game's own terms from its `#menu` cheat-sheet. "key" = what lands in `keys`.)

| Control | colossus | webcraft | blockshot | souls64 | parkcraft (ride / build) |
|---|---|---|---|---|---|
| Move stick | WASD (S in swing = reel in) | WASD | WASD (double-tap-up = sprint still works) | WASD | WASD (build: fly) |
| Look drag | yes | yes | yes | yes | yes |
| FIRE (drag = look) | SWING (hold) | SWING (hold) | FIRE | PUNCH | PUSH / PLACE |
| ALT | ZIP (also mash with FIRE when grabbed) | ZIP | AIM / place | GRAB (throw) | BRAKE / REMOVE |
| JUMP `' '` | JUMP | JUMP | JUMP | JUMP | OLLIE (hold = crouch) / UP |
| `z` | DIVE | DIVE | RELOAD | CROUCH POUND | GRAB MANUAL / PREV piece |
| `j` | YANK (hold) | YANK | NEXT slot | (FIRE covers it) | FLIP / NEXT piece |
| `e` | (ALT covers it) | (ALT covers it) | STRIKE | INTERACT | BUILD / RIDE |
| `q` | RESPAWN | RESPAWN | FRAG | RECENTER | RESPAWN / ROTATE |
| `shift` (toggle) | SPRINT | SPRINT | SPRINT | CREEP | DOWN (build, hold) |
| other | | | SNEAK `c` (toggle), PREV `arrowleft` (outer arc, next to NEXT) | | BOOST `control` (build, toggle) |
| M mute | gear > Sound | same | same | same | same |
| Esc / pause | MENU (1 tap, pause) | MENU (2 taps, back to menu) | MENU (2 taps, back to menu) | MENU (1 tap, pause + Resume menu) | MENU (2 taps, back to menu) |

Not given their own button, and why:

* blockshot hotbar digits `1`-`9` and wheel: **NEXT / PREV** cycle through every slot (including collected blocks), so every slot is reachable.
* parkcraft piece keys `1`-`9 0 -` and wheel: **NEXT / PREV** (build mode) cycle all pieces. `Tab` = `E` (BUILD).
* souls64 `J`/`K` duplicate **PUNCH**/**GRAB**; `Tab`/`R` duplicates (colossus `R` = `Q`, webcraft `R` = `Q`) are covered by the same buttons; `Esc` and `P` = MENU.

## Adding it to a new game (e.g. Shatterworld)

1. The game must already honour the pad contract (CONTRACT.md): top-level `keys` (Set or a Set subclass), `padFire/padPlace/padLook/padMenu`, overlays with ids `#menu` / `#dead`, `window.__gameId`.
2. `python3 tools/inject_touch.py games/new.html` (the block lands after the gamepad shim, inside the module script, so it sees those globals).
3. Add a profile: either a `PROFILES.<gameId>` entry in `touch-shim.js`, or define `window.__touchProfile = {...}` before the block. Without a profile you get the generic pad.html set (FIRE, JUMP, ALT, J, Z, E, Q, SHIFT toggle).

        {
          menuQuit: true,                 // padMenu leaves the run -> MENU needs a second tap (false if padMenu only pauses)
          fanLift: 0, utilX: 0,           // px: raise the fan / move MENU+gear left of the right edge to clear a bottom-right / top-right HUD block
          overlays: ['loadsplash'],       // extra element ids that mean "not playing"
          mode: () => 'ride',             // optional: current game mode name (re-labels / re-slots buttons when it changes)
          buttons: [                      // list order = slot order; ring:1 = thumb-rest slots (first = big), others go on the outer arc, side:'L' = left column
            {id:'fire', label:'FIRE', t:'fire', ring:1, big:1, drag:true},
            {id:'alt',  label:'AIM',  t:'place', ring:1},
            {id:'jump', label:'JUMP', t:'key', k:' ', ring:1},
            {id:'z',    label:{_:'RELOAD', build:'PREV'}, t:'key', k:'z'},
            {id:'shift',label:'SPRINT', t:'key', k:'shift', side:'L', mode:'toggle'},
            {id:'down', label:'DOWN', t:'key', k:'shift', side:'L', only:'build'},
          ]
        }

4. Check the HUD: take a landscape screenshot at 844x390 with the controls up and move the fan / MENU pair (`fanLift`, `utilX`) off anything critical. Every game so far had HUD in at least three corners. The offsets are tuned for right-handed layout: HUD is not mirrored, so with "Left-handed" on, some HUD blocks (e.g. blockshot's minimap) can sit under the mirrored fan.
5. Game-side requirements that bit us: (a) overlays must be hidden with `display:none` (`.hidden`) so the shim can see them; (b) a game that quits to its menu from `padMenu` should keep `menuQuit:true`; (c) `window` `mousedown` handlers are safe (touch never produces them) but do not rely on `mousedown` for anything a phone must do.
6. Test with the Playwright mobile harness described below.

## Borrowed

| Source | Licence | What | Where |
|---|---|---|---|
| `pad.html` (this repo) | own | stick -> w/a/s/d hysteresis (.38 / .22), `bindBtn` pointer-capture buttons, release-everything-on-blur, look value shape, button set + labels | `touch-shim.js` stick/button/releaseAll code |
| `tools/gamepad-shim.js` (this repo) | own | typeof-guarded calls into the contract globals, `shown()` overlay test, held-key bookkeeping, finer-aim response curve | `touch-shim.js` helpers, visibility logic |
| `tools/inject_gamepad.py` (this repo) | own | marker-based idempotent injection | `inject_touch.py` |
| `meta-quest/projectflowerbed` `src/js/lib/objects/MobileControls.js` | MIT, (c) Meta Platforms, Inc. | dynamic joystick: pad re-centres at the touch, clamp to radius, normalise to [-1,1], visual moved with `translate()` only (rewritten for per-pointer multi-touch) | `touch-shim.js` stick / look code |

Written new: the overlay DOM/CSS, per-game profiles, layout (fan + modifier column + safe areas + mirror), look-from-button drag, the settings panel, floating start button, portrait hint, XR/gamepad hiding, the injector's viewport patch.
No searchable library repo had a usable multi-touch gamepad overlay (the Meta one is single-touch and unused upstream); no npm package was added (nipplejs is single-purpose and would have needed vendoring for four buttons of glue).

## Tests

Harness: `scratchpad/phone-pass/mh.mjs` (Playwright, iPhone-class mobile emulation 844x390, DPR 3 or 1, `isMobile` + `hasTouch`, real multi-touch through CDP `Input.dispatchTouchEvent`; note CDP `touchEnd` lists the points being *released*).
Suite: `phone-pass/touch-test.mjs <game> [dpr] [default|nolock|lockerr] [sections]`, run against the five edited copies. Debug hooks it uses: `__touch.state()` (visibility, held keys, stick/look live, call counters, last look value), `__touch.rects()`, `__touch.set()`.
Per game (default variant, 81-87 checks): overlay absent on desktop / hidden over `#menu` / shown after tapping start; geometry (>= 56 px, inside the screen, no overlaps) at default, 1.5x, 0.85x and left-handed; the 4 stick directions + diagonal + hysteresis + dead zone against the hero position; look drag -> `padLook` and the camera yaw/pitch (and invert-Y); JUMP / FIRE / ALT effects in the game; four fingers at once (stick + look + JUMP + FIRE) and lifting them one at a time; drag-from-FIRE look; every key button (held / toggle / 60 ms minimum hold); no compat mouse events reach the game; one fullscreen request; vibrate; swipe + pinch do not scroll or zoom; MENU (confirm / pause); settings panel by real touch (sliders, left-handed, persistence across reload); fake gamepad and fake WebXR session hide / restore the controls; run ends -> `#dead` -> touch retry -> `__save` wrote `ib_saves`; 10 s random multi-touch fuzz (finite `__dbg`, nothing stuck).
Variants: `nolock` (no `requestPointerLock` at all, like iOS) and `lockerr` (present but denied) additionally assert that a mouse-move moves the same camera field the touch look drives.
`phone-pass/shots.mjs`: landscape DPR 3, portrait hint + portrait play, 667x375 / 740x360 / 932x430 geometry, CDP safe-area insets (47 / 21 px) where the page has `viewport-fit=cover`.

Known limits: blockshot's 10 buttons do not fit a 568x320 (4-inch) screen; below 667x375 landscape is unsupported. Nothing here was run on a real phone (see the report's unverified list): iOS Safari `touch-action` / `gesturestart` handling, Android pointer-lock behaviour, real haptics, real fullscreen, notch insets, thumb ergonomics.
