// touch-shim v1: on-screen touch controls -> the SAME inputs as keyboard + phone pad + gamepad shim.
// Pasted verbatim inside each game's module <script> by tools/inject_touch.py (needs the contract globals: keys, padFire, padPlace, padLook, padMenu).
// Borrowed / ported (see tools/TOUCH.md "Borrowed"):
//   pad.html (own)            stick -> w/a/s/d hysteresis (on .38 / off .22), bindBtn pointer-capture buttons, release-everything-on-blur, look value shape
//   gamepad-shim.js (own)     typeof-guarded calls into the contract globals, "shown()" overlay test, held-key bookkeeping, look response curve (pow 1.6 -> 1.5)
//   meta-quest/projectflowerbed src/js/lib/objects/MobileControls.js (MIT, Copyright (c) Meta Platforms, Inc. and affiliates):
//                             dynamic joystick idea: pad re-centres where the thumb lands, offset clamped to the pad radius and normalised to [-1,1],
//                             visual moved with translate() only. Rewritten here for per-pointer multi-touch (the original tracks a single touch).
// Layout (landscape): left 40% = dynamic move stick, the rest = look drag, action fan bottom-right (mirrors when left-handed), modifiers in a left column,
// MENU + gear top-right. Pure DOM/CSS, updated per input event only (no rAF loop, no canvas). Settings live in localStorage['ib_touch'].
// Per-game button sets: PROFILES below (keyed by window.__gameId); a game may override with window.__touchProfile = {...} before this block.
(function(){
  if(window.__touch) return;
  const doc=document, win=window, nav=navigator;
  const clamp=(v,a,b)=>v<a?a:v>b?b:v;
  const call=(f,...a)=>{ if(typeof f==='function') f(...a); };
  const cnt={fireDown:0,fireUp:0,placeDown:0,placeUp:0,look:0,menu:0}, lastLook=[0,0];   // exposed through __touch.state().calls (tests / debugging)
  const gFire=v=>{ if(v) cnt.fireDown++; else cnt.fireUp++; call(typeof padFire==='function'?padFire:null,v); };
  const gPlace=v=>{ if(v) cnt.placeDown++; else cnt.placeUp++; call(typeof padPlace==='function'?padPlace:null,v); };
  const gLook=(x,y)=>{ cnt.look++; lastLook[0]=x; lastLook[1]=y; call(typeof padLook==='function'?padLook:null,x,y); };
  const gMenu=()=>{ cnt.menu++; call(typeof padMenu==='function'?padMenu:null); };

  // ------------------------------------------------------------------ per-game profiles
  // button: {id,label,t:'key'|'fire'|'place',k,mode:'hold'|'toggle',side:'R'|'L',ring:1,big,drag,only}
  //   ring 1 = the three thumb-rest buttons (list order = slot: centre, up, left); other right-side buttons go on the outer arc; side 'L' = left column (modifiers).
  //   drag: dragging the finger while it rests on the button also drives look, so hold-to-swing + aim works with one thumb.
  //   label may be {_:'x',build:'y'}; only:'build' shows the button in that game mode only (profile.mode() returns the current mode name).
  //   menuQuit: padMenu abandons the run (webcraft, blockshot, parkcraft), so the MENU button needs a second tap within 2 s; colossus and souls64 only pause (souls64 shows its Resume menu).
  //   fanLift: px to raise the action fan (clears a bottom-right HUD block); utilX: px the MENU/gear pair sits left of the right edge (clears a top-right HUD block).
  const K=(id,label,k,o)=>Object.assign({id,label,t:'key',k},o||{});
  const FIRE=(label,o)=>Object.assign({id:'fire',label,t:'fire',ring:1,drag:true},o||{});
  const ALT=(label,o)=>Object.assign({id:'alt',label,t:'place',ring:1},o||{});
  const JUMP=(label,o)=>Object.assign({id:'jump',label:label||'JUMP',t:'key',k:' ',ring:1},o||{});
  const PROFILES={
    colossus:{ menuQuit:false, buttons:[ FIRE('SWING',{big:1}), JUMP(), ALT('ZIP'), K('dive','DIVE','z'), K('yank','YANK','j'),
      K('sprint','SPRINT','shift',{side:'L',mode:'toggle'}), K('respawn','RESPAWN','q',{side:'L'}) ] },
    webcraft:{ menuQuit:true, utilX:118, buttons:[ FIRE('SWING',{big:1}), JUMP(), ALT('ZIP'), K('dive','DIVE','z'), K('yank','YANK','j'),
      K('sprint','SPRINT','shift',{side:'L',mode:'toggle'}), K('respawn','RESPAWN','q',{side:'L'}) ] },
    blockshot:{ menuQuit:true, fanLift:30, buttons:[ FIRE('FIRE',{big:1}), JUMP(), ALT('AIM'), K('reload','RELOAD','z'), K('frag','FRAG','q'), K('strike','STRIKE','e'), K('next','NEXT','j'),
      K('sprint','SPRINT','shift',{side:'L',mode:'toggle'}), K('sneak','SNEAK','c',{side:'L',mode:'toggle'}), K('prev','PREV','arrowleft',{side:'L'}) ] },
    souls64:{ menuQuit:false, buttons:[ FIRE('PUNCH',{big:1}), JUMP(), ALT('GRAB'), K('crouch','CROUCH\nPOUND','z'), K('use','INTERACT','e'),
      K('creep','CREEP','shift',{side:'L',mode:'toggle'}), K('recenter','RECENTER','q',{side:'L'}) ] },
    parkcraft:{ menuQuit:true, utilX:118,
      mode:()=>{ const e=doc.getElementById('vMode'); return e&&/build/i.test(e.textContent)?'build':'ride'; },
      buttons:[ JUMP({_:'OLLIE',build:'UP'},{big:1}), FIRE({_:'PUSH',build:'PLACE'}), ALT({_:'BRAKE',build:'REMOVE'}),
        K('j','FLIP','j',{label:{_:'FLIP',build:'NEXT'}}), K('z','GRAB\nMANUAL','z',{label:{_:'GRAB\nMANUAL',build:'PREV'}}),
        K('e','BUILD','e',{label:{_:'BUILD',build:'RIDE'}}), K('q','RESPAWN','q',{label:{_:'RESPAWN',build:'ROTATE'}}),
        K('down','DOWN','shift',{side:'L',only:'build'}), K('boost','BOOST','control',{side:'L',only:'build',mode:'toggle'}) ] },
  };
  // fallback for a game without a profile: the same controls pad.html has
  const DEFAULT={ menuQuit:true, buttons:[ FIRE('FIRE',{big:1}), JUMP(), ALT('ALT'), K('j','J','j'), K('z','Z','z'), K('e','E','e'), K('q','Q','q'), K('shift','SHIFT','shift',{side:'L',mode:'toggle'}) ] };
  const prof=win.__touchProfile||PROFILES[win.__gameId]||DEFAULT;
  const OV=['menu','dead','pause','loadsplash'].concat(prof.overlays||[]);   // while any of these is showing the game is not being played

  // ------------------------------------------------------------------ settings (localStorage['ib_touch'])
  const LS='ib_touch', DEF={size:1,opacity:.62,sens:1,left:false,invY:false,force:false}, RANGE={size:[.85,1.5],opacity:[.25,1],sens:[.5,2.5]};
  const S=Object.assign({},DEF);
  try{ const o=JSON.parse(localStorage.getItem(LS)||'{}'); for(const k in DEF){ if(typeof o[k]===typeof DEF[k]) S[k]=o[k]; } }catch(e){}
  for(const k in RANGE) S[k]=clamp(+S[k]||DEF[k],RANGE[k][0],RANGE[k][1]);
  const saveS=()=>{ try{ localStorage.setItem(LS,JSON.stringify(S)); }catch(e){} };

  // ------------------------------------------------------------------ state
  const mm=q=>{ try{ return !!win.matchMedia&&win.matchMedia(q).matches; }catch(e){ return false; } };
  let sawTouch=false, forced=S.force||/[?&#]touch(=1|&|$)/.test(location.search+location.hash), gp=false, xrN=0, vis=false, uiMode='', panelOpen=false, started=false, fsTried=false, rotHide=false;
  // TV browsers can report pointer:coarse but have no touch points, so require touch support as well
  const coarse=()=>mm('(pointer: coarse)')&&((nav.maxTouchPoints|0)>0||'ontouchstart' in win);
  const isActive=()=>coarse()||sawTouch||forced;
  const okPtr=e=>e.button<=0&&(e.pointerType!=='mouse'||forced);
  const held=Object.create(null), pressed=new Set();          // keys we set; release fns of every live control (all freed on blur / hide / pause)
  const setKey=(k,on)=>{ if(typeof keys==='undefined') return;
    if(on){ if(!held[k]||!keys.has(k)){ held[k]=1; keys.add(k); } } else if(held[k]){ held[k]=0; keys.delete(k); } };
  const buzz=()=>{ try{ if(nav.vibrate) nav.vibrate(8); }catch(e){} };
  const MINHOLD=60;     // ms: a tap shorter than one physics step would be missed by games that poll keys
  const st={id:null,x0:0,y0:0}, lo={id:null,x0:0,y0:0,from:''};  // move stick / look drag pointer state
  let u=60, Rs=56, Rl=72, mir=1, W=0, Hh=0; const defS={x:0,y:0};

  // ------------------------------------------------------------------ DOM + CSS
  const CSS=`
#ibt{position:fixed;inset:0;z-index:99990;display:none;pointer-events:none;-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;touch-action:none;-webkit-tap-highlight-color:transparent;
  font:700 11px/1.12 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;letter-spacing:.05em;color:#fff;--o:.62}
#ibt.on{display:block}
#ibt *{box-sizing:border-box;-webkit-user-select:none;user-select:none;touch-action:none}
.ibt-z{position:absolute;top:0;bottom:0;pointer-events:auto}
.ibt-b,.ibt-u{position:absolute;left:0;top:0;border-radius:50%;display:flex;align-items:center;justify-content:center;text-align:center;white-space:pre;pointer-events:auto;
  background:rgba(18,22,30,.42);border:2px solid rgba(255,255,255,.62);box-shadow:0 0 0 1px rgba(0,0,0,.4),inset 0 0 14px rgba(255,255,255,.07);text-shadow:0 1px 2px #000,0 0 3px #000;opacity:var(--o)}
.ibt-b.sm{font-size:9.5px;letter-spacing:.02em}
.ibt-b.on,.ibt-u.on{background:rgba(255,196,64,.5);border-color:#ffd470}
.ibt-b.tg::after{content:'';position:absolute;top:7px;right:9px;width:7px;height:7px;border-radius:50%;background:rgba(255,255,255,.35)}
.ibt-b.tg.on::after{background:#fff;box-shadow:0 0 6px #fff}
.ibt-u{border-radius:12px;font-size:11px}
.ibt-sb,.ibt-lb{position:absolute;left:0;top:0;border-radius:50%;border:2px solid rgba(255,255,255,.55);background:rgba(255,255,255,.06);pointer-events:none;opacity:0}
#ibt.hint .ibt-sb{animation:ibtring 5s ease-out both}
.ibt-sb.act,.ibt-lb.act{opacity:var(--o)!important;animation:none!important;background:rgba(255,255,255,.1)}
.ibt-lb{border-style:dashed}
.ibt-lb:not(.act){display:none}
.ibt-sk{position:absolute;left:50%;top:50%;border-radius:50%;background:rgba(255,255,255,.4);border:2px solid #fff;pointer-events:none}
.ibt-t{position:absolute;pointer-events:none;opacity:0;font-size:10px;letter-spacing:.18em;text-shadow:0 1px 3px #000}
#ibt.hint .ibt-t{animation:ibtfade 5s ease-out both}
@keyframes ibtring{0%{opacity:0}12%{opacity:calc(var(--o)*.7)}70%{opacity:calc(var(--o)*.5)}100%{opacity:0}}
@keyframes ibtfade{0%{opacity:0}12%{opacity:calc(var(--o) + .3)}70%{opacity:calc(var(--o) + .2)}100%{opacity:0}}
.ibt-bd{position:absolute;inset:0;pointer-events:auto;display:none;background:rgba(0,0,0,.25)}
.ibt-panel{position:absolute;display:none;pointer-events:auto;width:min(340px,calc(100vw - 24px));max-height:calc(100vh - 16px);overflow:auto;padding:10px 12px;border-radius:12px;
  background:rgba(14,18,26,.94);border:1px solid rgba(255,255,255,.3);font-weight:600;letter-spacing:.03em}
.ibt-panel,.ibt-panel *{touch-action:manipulation}
#ibt.ps .ibt-bd,#ibt.ps .ibt-panel{display:block}
.ibt-panel .h{display:flex;justify-content:space-between;align-items:center;margin-bottom:6px;font-size:12px;letter-spacing:.12em}
.ibt-panel .r{display:flex;align-items:center;gap:8px;min-height:36px;font-size:12px}
.ibt-panel .r span:first-child{flex:0 0 92px}
.ibt-panel input[type=range]{flex:1;min-width:0;height:28px;accent-color:#ffc440}
.ibt-panel input[type=checkbox]{width:22px;height:22px;accent-color:#ffc440}
.ibt-panel .v{flex:0 0 34px;text-align:right;opacity:.8}
.ibt-panel .bt{display:flex;gap:8px;margin-top:6px}
.ibt-panel button{flex:1;min-height:40px;border-radius:8px;border:1px solid rgba(255,255,255,.4);background:rgba(255,255,255,.1);color:#fff;font:inherit;font-size:12px}
.ibt-panel button:active{background:rgba(255,196,64,.5)}
#ibt-rot{position:fixed;left:50%;top:max(8px,env(safe-area-inset-top));transform:translateX(-50%);z-index:99991;display:none;align-items:center;gap:10px;padding:8px 12px;border-radius:20px;
  background:rgba(14,18,26,.92);border:1px solid rgba(255,196,64,.7);color:#fff;font:600 12px/1.2 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;letter-spacing:.03em;max-width:calc(100vw - 16px)}
#ibt-rot.on{display:flex}
#ibt-rot i{font-style:normal;font-size:20px}
#ibt-rot b{padding:4px 10px;font-size:18px;line-height:1}
#ibt-go{position:fixed;left:50%;bottom:max(10px,env(safe-area-inset-bottom));transform:translateX(-50%);z-index:99992;display:none;min-height:56px;min-width:200px;max-width:calc(100vw - 24px);padding:12px 22px;border-radius:30px;
  align-items:center;justify-content:center;background:#e8a42a;color:#1a1204;border:2px solid #fff3d0;box-shadow:0 4px 18px rgba(0,0,0,.6);font:800 16px/1.1 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;letter-spacing:.06em;text-transform:uppercase;touch-action:manipulation;-webkit-user-select:none;user-select:none}
#ibt-go.on{display:flex}
#ibt-go:active{background:#ffd470}
html.ibt-active,html.ibt-active body{overscroll-behavior:none}
`;
  const stl=doc.createElement('style'); stl.textContent=CSS; doc.head.appendChild(stl);
  const h=(cls,parent,txt,tag)=>{ const e=doc.createElement(tag||'div'); if(cls) e.className=cls; if(txt!=null) e.textContent=txt; if(parent) parent.appendChild(e); return e; };
  const root=h('',doc.body); root.id='ibt'; root.setAttribute('aria-hidden','true');
  const zMove=h('ibt-z',root), zLook=h('ibt-z',root);           // move zone / look zone (sides swap when left-handed)
  const sb=h('ibt-sb',root), sk=h('ibt-sk',sb);                 // dynamic stick base + knob
  const lb=h('ibt-lb',root), lk=h('ibt-sk',lb);                 // look ring (only while dragging)
  const tMove=h('ibt-t',root,'MOVE'), tLook=h('ibt-t',root,'LOOK');
  const btns=prof.buttons.map(b=>({b,el:h('ibt-b'+(b.mode==='toggle'?' tg':''),root),lab:null,shown:true,tog:false,release:null}));
  const uMenu=h('ibt-u',root,'MENU'), uGear=h('ibt-u',root,'\u2699');
  const bd=h('ibt-bd',root), panel=h('ibt-panel',root);
  const go=h('',doc.body); go.id='ibt-go';   // floating start button, only when the menu / retry button is not reachable on screen (tall card on a short phone)
  const rot=h('',doc.body); rot.id='ibt-rot'; h('',rot,'\u21BB','i'); h('',rot,'Rotate your phone to landscape to play','span'); const rotX=h('',rot,'\u00D7','b');
  // settings panel
  const row=lab=>{ const r=h('r',panel); h('',r,lab,'span'); return r; };
  const ph=h('h',panel); h('',ph,'TOUCH CONTROLS','span'); const pX=h('',ph,'\u00D7','b'); pX.style.cssText='font-size:22px;padding:2px 10px';
  const rng=(key,lab,step)=>{ const r=row(lab), i=h('',r,null,'input'); i.type='range'; i.min=RANGE[key][0]; i.max=RANGE[key][1]; i.step=step; i.value=S[key];
    const v=h('v',r,'','span'); const upd=()=>{ v.textContent=(+i.value).toFixed(2); }; upd();
    i.addEventListener('input',()=>{ S[key]=+i.value; upd(); saveS(); layout(); }); i._sync=()=>{ i.value=S[key]; upd(); }; return i; };
  const chk=(key,lab)=>{ const r=row(lab), i=h('',r,null,'input'); i.type='checkbox'; i.checked=!!S[key];
    i.addEventListener('change',()=>{ S[key]=i.checked; saveS(); layout(); }); i._sync=()=>{ i.checked=!!S[key]; }; return i; };
  const ctl=[rng('size','Button size',.05), rng('opacity','Opacity',.05), rng('sens','Look speed',.05), chk('left','Left-handed'), chk('invY','Invert look Y')];
  const pb=h('bt',panel); const bSnd=h('',pb,'Sound (M)','button'), bFs=h('',pb,'Fullscreen','button'), bRs=h('',pb,'Reset','button');

  // ------------------------------------------------------------------ geometry (computed on resize / settings / mode change, never per frame)
  const probe=h('',doc.body); probe.style.cssText='position:fixed;left:0;top:0;width:0;height:0;visibility:hidden;pointer-events:none;padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)';
  const insets=()=>{ const c=getComputedStyle(probe); return {t:parseFloat(c.paddingTop)||0,r:parseFloat(c.paddingRight)||0,b:parseFloat(c.paddingBottom)||0,l:parseFloat(c.paddingLeft)||0}; };
  const tr=(el,x,y)=>{ el.style.transform='translate('+Math.round(x)+'px,'+Math.round(y)+'px)'; };
  const put=(el,cx,cy,d)=>{ el.style.width=el.style.height=d+'px'; tr(el,cx-d/2,cy-d/2); };
  const modeName=()=>{ try{ return typeof prof.mode==='function'?String(prof.mode()||''):''; }catch(e){ return ''; } };
  const labelOf=(b,m)=>typeof b.label==='object'?(b.label[m]||b.label._):b.label;
  const S1=[[.95,1.05],[.05,2.3],[2.3,.3]];   // ring 1 slots: [dx from the anchor toward the screen centre, dy up], in button units (slot 0 = big thumb-rest button)
  function layout(){
    W=win.innerWidth; Hh=win.innerHeight; const I=insets(), mn=Math.min(W,Hh);
    u=Math.max(56,Math.round(clamp(mn*.155,56,76)*S.size));
    { const cap=Math.floor((Hh-I.t-I.b-(prof.fanLift||0)-6)/5.65); u=Math.max(56,Math.min(u,cap)); }   // the fan (outer arc top = ~4.7 u + lift) must stay below the MENU/gear row (~1 u + 6 px)
    Rs=Math.round(clamp(u*.95,52,78)); Rl=Math.round(72/S.sens);
    const m=Math.max(10,Math.round(u*.2)); mir=S.left?-1:1;
    const eT=mir>0?I.r:I.l, eO=mir>0?I.l:I.r;                       // safe-area inset on the thumb side / the other side
    const ax=eT+m+u/2, ay=I.b+m+u/2;                                // fan anchor, measured from the thumb-side edge and the bottom
    const X=d=>mir>0?W-d:d, Y=d=>Hh-d;
    uiMode=modeName();
    const ring1=[], ring2=[], left=[];
    btns.forEach(o=>{ const b=o.b; o.shown=!b.only||b.only===uiMode; const lab=labelOf(b,uiMode);
      if(lab!==o.lab){ o.lab=lab; o.el.textContent=lab; o.el.classList.toggle('sm',lab.length>6||lab.indexOf('\n')>=0); }
      o.el.style.display=o.shown?'':'none'; if(!o.shown) return; (b.side==='L'?left:(b.ring===1?ring1:ring2)).push(o); });
    const lift=prof.fanLift||0;
    ring1.forEach((o,i)=>{ const s=S1[Math.min(i,2)], d=Math.round(u*(o.b.big?1.28:1)); put(o.el,X(ax+s[0]*u),Y(ay+lift+s[1]*u),d); });
    const n2=ring2.length, r2=3.55*u;                                // outer arc around the anchor
    ring2.forEach((o,i)=>{ const a=(n2<2?38:n2===2?(i?64:14):6+i*72/(n2-1))*Math.PI/180; put(o.el,X(ax+r2*Math.cos(a)),Y(ay+lift+r2*Math.sin(a)),u); });
    const lx=mir>0?eO+m+u/2:W-eO-m-u/2, gap=Math.round(u*.14);       // modifier column: HUD-free left band, on the non-thumb edge
    left.forEach((o,i)=>put(o.el,lx,Hh*.33+u/2+i*(u+gap),u));
    defS.x=mir>0?eO+m+u+8+Rs:W-eO-m-u-8-Rs; defS.y=Math.round(Hh*.55);   // idle stick ring (hint only): beside the column, clear of the corner HUD blocks
    sb.style.width=sb.style.height=2*Rs+'px'; sb.style.margin=(-Rs)+'px 0 0 '+(-Rs)+'px';
    const kr=Math.round(Rs*.42); sk.style.width=sk.style.height=2*kr+'px'; sk.style.margin=(-kr)+'px 0 0 '+(-kr)+'px';
    lb.style.width=lb.style.height=2*Rl+'px'; lb.style.margin=(-Rl)+'px 0 0 '+(-Rl)+'px';
    const lr=Math.round(Rl*.3); lk.style.width=lk.style.height=2*lr+'px'; lk.style.margin=(-lr)+'px 0 0 '+(-lr)+'px';
    if(st.id===null) tr(sb,defS.x,defS.y);
    tr(tMove,defS.x-22,defS.y-Rs-18); tr(tLook,mir>0?W*.58:W*.18,Hh*.4);
    const zw=Math.round(W*.4);                                      // move zone = 40% on the non-thumb side, look zone = the rest
    zMove.style.width=zw+'px'; zMove.style.left=mir>0?'0':(W-zw)+'px';
    zLook.style.width=(W-zw)+'px'; zLook.style.left=mir>0?zw+'px':'0';
    const ub=Math.max(44,Math.round(u*.78)), ux=W-I.r-m-(prof.utilX||0)-ub/2, uy=I.t+m+ub/2, mw=Math.round(ub*1.45);   // MENU + gear, top-right, >=44 px targets
    uGear.style.width=uGear.style.height=ub+'px'; tr(uGear,ux-ub/2,uy-ub/2); uGear.style.fontSize=Math.round(ub*.5)+'px';
    uMenu.style.width=mw+'px'; uMenu.style.height=ub+'px'; tr(uMenu,ux-ub/2-8-mw,uy-ub/2);
    panel.style.left=Math.max(8,Math.round((W-Math.min(340,W-24))/2))+'px'; panel.style.top=Math.max(8,Math.round(I.t+8))+'px';
    root.style.setProperty('--o',S.opacity);
  }

  // ------------------------------------------------------------------ left dynamic stick (pad.html stick + hysteresis; Meta MobileControls relocate / clamp / normalise)
  const axis=(neg,pos,v)=>{ setKey(neg,held[neg]?v<-.22:v<-.38); setKey(pos,held[pos]?v>.22:v>.38); };
  function stickMove(e){
    let dx=(e.clientX-st.x0)/Rs, dy=(e.clientY-st.y0)/Rs; const m=Math.hypot(dx,dy); if(m>1){ dx/=m; dy/=m; }
    tr(sk,dx*Rs*.58,dy*Rs*.58); axis('a','d',dx); axis('w','s',dy);
  }
  function stickEnd(){ if(st.id===null) return; st.id=null; pressed.delete(stickEnd); sb.classList.remove('act'); tr(sk,0,0); ['a','d','w','s'].forEach(k=>setKey(k,false)); tr(sb,defS.x,defS.y); }
  // ------------------------------------------------------------------ look drag: same value shape as pad.html's right stick -> padLook (games ignore |v|<0.12)
  const lookV=(dx,dy)=>{ const f=v=>{ const a=Math.abs(v); return a<.04?0:Math.sign(v)*Math.pow(a,1.5); }; gLook(f(dx),S.invY?-f(dy):f(dy)); };
  function lookMove(e){
    let dx=(e.clientX-lo.x0)/Rl, dy=(e.clientY-lo.y0)/Rl; const m=Math.hypot(dx,dy); if(m>1){ dx/=m; dy/=m; }
    tr(lk,dx*Rl*.7,dy*Rl*.7); lookV(dx,dy);
  }
  function lookEnd(){ if(lo.id===null) return; lo.id=null; lo.from=''; pressed.delete(lookEnd); lb.classList.remove('act'); gLook(0,0); }
  function lookStart(e,from,x0,y0){ if(lo.id!==null) lookEnd(); lo.id=e.pointerId; lo.from=from; lo.x0=x0; lo.y0=y0; pressed.add(lookEnd); tr(lb,x0,y0); tr(lk,0,0); lb.classList.add('act'); }
  const noTouch=e=>{ e.preventDefault(); };   // cancelling touchstart also suppresses the compat mouse events (games listen to window 'mousedown')
  [zMove,zLook].forEach(z=>{
    const isMove=z===zMove; z.addEventListener('touchstart',noTouch,{passive:false});
    z.addEventListener('pointerdown',e=>{ if(!okPtr(e)||(isMove?st.id:lo.id)!==null) return; e.preventDefault(); try{ z.setPointerCapture(e.pointerId); }catch(_){}
      if(isMove){ st.id=e.pointerId; st.x0=e.clientX; st.y0=e.clientY; pressed.add(stickEnd); tr(sb,st.x0,st.y0); sb.classList.add('act'); stickMove(e); } else lookStart(e,'zone',e.clientX,e.clientY); });
    z.addEventListener('pointermove',e=>{ if(isMove){ if(e.pointerId===st.id) stickMove(e); } else if(e.pointerId===lo.id&&lo.from==='zone') lookMove(e); });
    const up=e=>{ if(isMove){ if(e.pointerId===st.id) stickEnd(); } else if(e.pointerId===lo.id&&lo.from==='zone') lookEnd(); };
    z.addEventListener('pointerup',up); z.addEventListener('pointercancel',up); z.addEventListener('lostpointercapture',up);
  });

  // ------------------------------------------------------------------ buttons (pad.html bindBtn: pointer capture, min hold, released on blur / hide)
  function bindBtn(o){
    const el=o.el, b=o.b; let pid=null, t0=0, tmr=0, dx0=0, dy0=0, dragging=false;
    const send=on=>{ if(b.t==='fire') gFire(on); else if(b.t==='place') gPlace(on); else setKey(b.k,on); };
    const up=()=>{ if(pid===null) return; pid=null; pressed.delete(up); if(dragging&&lo.from===b.id) lookEnd(); dragging=false; el.classList.remove('on');
      const w=MINHOLD-(performance.now()-t0); if(w>0){ clearTimeout(tmr); tmr=setTimeout(()=>{ tmr=0; send(false); },w); } else send(false); };
    o.release=()=>{ if(pid!==null){ pid=null; pressed.delete(up); } if(dragging&&lo.from===b.id) lookEnd(); dragging=false; clearTimeout(tmr); tmr=0;
      el.classList.remove('on'); o.tog=false; send(false); };
    el.addEventListener('touchstart',noTouch,{passive:false});
    el.addEventListener('pointerdown',e=>{
      if(!okPtr(e)||pid!==null) return; e.preventDefault(); try{ el.setPointerCapture(e.pointerId); }catch(_){}
      buzz(); if(b.mode==='toggle'){ o.tog=!o.tog; el.classList.toggle('on',o.tog); send(o.tog); return; }
      pid=e.pointerId; t0=performance.now(); dx0=e.clientX; dy0=e.clientY; clearTimeout(tmr); tmr=0; el.classList.add('on'); pressed.add(up); send(true); });
    el.addEventListener('pointermove',e=>{ if(e.pointerId!==pid||!b.drag) return;
      if(!dragging){ if(Math.hypot(e.clientX-dx0,e.clientY-dy0)<14) return; dragging=true; lookStart(e,b.id,dx0,dy0); }
      if(lo.id===e.pointerId&&lo.from===b.id) lookMove(e); });
    const end=e=>{ if(e.pointerId===pid) up(); }; el.addEventListener('pointerup',end); el.addEventListener('pointercancel',end); el.addEventListener('lostpointercapture',end);
  }
  btns.forEach(bindBtn);

  // MENU: where padMenu quits the run (4 of 5 games) a second tap within 2 s is required; colossus pauses, so it takes one tap
  let menuArm=0, menuTmr=0; const menuTxt=uMenu.textContent;
  const menuReset=()=>{ menuArm=0; clearTimeout(menuTmr); uMenu.textContent=menuTxt; uMenu.classList.remove('on'); };
  [uMenu,uGear,bd].forEach(e=>e.addEventListener('touchstart',noTouch,{passive:false}));
  uMenu.addEventListener('pointerdown',e=>{ if(!okPtr(e)) return; e.preventDefault(); buzz();
    if(prof.menuQuit&&!menuArm){ menuArm=1; uMenu.textContent='QUIT?'; uMenu.classList.add('on'); clearTimeout(menuTmr); menuTmr=setTimeout(menuReset,2000); return; }
    menuReset(); releaseAll(); gMenu(); });
  function openPanel(on){ panelOpen=on; if(on){ releaseAll(); ctl.forEach(c=>c._sync()); } root.classList.toggle('ps',on); }
  uGear.addEventListener('pointerdown',e=>{ if(!okPtr(e)) return; e.preventDefault(); buzz(); openPanel(!panelOpen); });
  bd.addEventListener('pointerdown',e=>{ e.preventDefault(); openPanel(false); });
  pX.addEventListener('click',()=>openPanel(false));
  bRs.addEventListener('click',()=>{ Object.assign(S,DEF,{force:S.force}); saveS(); ctl.forEach(c=>c._sync()); layout(); });
  const keyEv=(type,k)=>{ try{ win.dispatchEvent(new KeyboardEvent(type,{key:k,bubbles:true})); }catch(e){} };
  bSnd.addEventListener('click',()=>{ keyEv('keydown','m'); keyEv('keyup','m'); });   // every game handles M (mute) from a window keydown listener
  bFs.addEventListener('click',()=>fullscreen(true));
  rotX.addEventListener('pointerdown',e=>{ e.preventDefault(); rotHide=true; rot.classList.remove('on'); });

  function releaseAll(){ [...pressed].forEach(f=>f()); pressed.clear(); btns.forEach(o=>o.release&&o.release()); stickEnd(); lookEnd();
    Object.keys(held).forEach(k=>setKey(k,false)); gLook(0,0); gFire(false); gPlace(false); menuReset(); }

  // ------------------------------------------------------------------ visibility: touch device, no gamepad, no XR session, only while playing
  const shown=el=>{ if(!el) return false; const s=getComputedStyle(el); return s.display!=='none'&&s.visibility!=='hidden'&&el.getClientRects().length>0; };
  const playing=()=>{ for(let i=0;i<OV.length;i++) if(shown(doc.getElementById(OV[i]))) return false; return true; };
  const padPresent=()=>{ try{ if(!nav.getGamepads) return false; const gs=nav.getGamepads(); for(let i=0;i<gs.length;i++){ const g=gs[i]; if(g&&g.connected&&g.mapping!=='xr-standard') return true; } }catch(e){} return false; };
  let hintT=0;
  function sync(){
    const active=isActive(); gp=padPresent();
    const want=active&&!gp&&xrN===0&&!win.__xrPresenting&&playing();
    doc.documentElement.classList.toggle('ibt-active',active);
    if(active&&!started){ started=true; fixViewport(); noLock(); layout(); }
    if(want!==vis){ vis=want; root.classList.toggle('on',vis); guard(vis);
      if(!vis){ releaseAll(); openPanel(false); }
      else { layout(); root.classList.remove('hint'); void root.offsetWidth; root.classList.add('hint'); clearTimeout(hintT); hintT=setTimeout(()=>root.classList.remove('hint'),5200); } }
    else if(vis&&modeName()!==uiMode){ releaseAll(); layout(); }       // game mode changed (parkcraft ride <-> build): relabel + re-slot
    rot.classList.toggle('on',active&&win.innerHeight>win.innerWidth&&!rotHide&&!xrN);
    assist(active&&!gp&&!xrN&&!vis);
    if(win.innerHeight<=win.innerWidth) rotHide=false;
  }
  // a menu / retry card taller than the screen leaves #cta / #cta2 off-screen: mirror it in one big tap target (disappears once the real button is in view)
  let goTgt=null;
  function assist(can){
    let t=null;
    if(can) for(const id of ['cta','cta2']){ const e=doc.getElementById(id); if(e&&!e.disabled&&shown(e)){ const r=e.getBoundingClientRect();
      if(r.bottom>win.innerHeight-2||r.top<0||r.right>win.innerWidth||r.left<0){ t=e; break; } } }
    if(t!==goTgt){ goTgt=t; go.classList.toggle('on',!!t); if(t) go.textContent='\u25B6  '+(t.textContent||'START').trim().slice(0,28); }
  }
  go.addEventListener('click',()=>{ if(goTgt) goTgt.click(); });
  // Pointer lock is for a mouse. While it is held, touch pointer events report clientX/Y = 0 (seen in Chromium), and a phone has no use for it, so on touch devices
  // requestPointerLock becomes "denied": a pointerlockerror event, no promise. Every game already handles that (noLock / lockFailed): look comes from padLook, no pause-on-unlock.
  let lockOff=false;
  function noLock(){ if(lockOff) return; lockOff=true; try{ const P=Element.prototype, orig=P.requestPointerLock; if(!orig) return;
    P.requestPointerLock=function(){ if(!isActive()) return orig.apply(this,arguments); setTimeout(()=>{ try{ doc.dispatchEvent(new Event('pointerlockerror',{bubbles:true})); }catch(e){} },0); }; }catch(e){} }
  function fixViewport(){ try{ let m=doc.querySelector('meta[name=viewport]'); if(!m){ m=doc.createElement('meta'); m.name='viewport'; m.content='width=device-width,initial-scale=1'; doc.head.appendChild(m); }
    if(!/user-scalable\s*=\s*(no|0)/.test(m.content)) m.content+=',user-scalable=no'; if(!/maximum-scale/.test(m.content)) m.content+=',maximum-scale=1'; }catch(e){} }
  function fullscreen(toggle){ try{ if(doc.fullscreenElement||doc.webkitFullscreenElement){ if(toggle&&doc.exitFullscreen) doc.exitFullscreen(); return; }
    const el=doc.documentElement, f=el.requestFullscreen||el.webkitRequestFullscreen; if(f){ const p=f.call(el,{navigationUI:'hide'}); if(p&&p.catch) p.catch(()=>{}); } }catch(e){} }

  // first touch marks the device as touch (shows the overlay on hybrid laptops) + one fullscreen request inside the user gesture
  win.addEventListener('touchstart',()=>{ if(!sawTouch){ sawTouch=true; sync(); if(doc.pointerLockElement){ try{ doc.exitPointerLock(); }catch(e){} } } },{capture:true,passive:true});
  win.addEventListener('pointerup',e=>{ if(e.pointerType==='touch'&&!fsTried&&isActive()){ fsTried=true; fullscreen(false); } },true);
  // no zoom / scroll / long-press menus while the controls are up (listeners exist only while visible, so menus keep native scrolling)
  const onTM=e=>{ if(!(e.target.closest&&e.target.closest('.ibt-panel'))) e.preventDefault(); }, onStop=e=>{ e.preventDefault(); };
  function guard(on){ const m=on?'addEventListener':'removeEventListener';
    doc[m]('touchmove',onTM,{passive:false}); doc[m]('contextmenu',onStop,true); doc[m]('selectstart',onStop,true);
    ['gesturestart','gesturechange','gestureend'].forEach(t=>doc[m](t,onStop,{passive:false})); }
  win.addEventListener('blur',releaseAll); doc.addEventListener('visibilitychange',()=>{ if(doc.hidden) releaseAll(); });
  win.addEventListener('gamepadconnected',sync); win.addEventListener('gamepaddisconnected',sync);
  win.addEventListener('resize',()=>{ if(started) layout(); sync(); }); win.addEventListener('orientationchange',()=>{ if(started) layout(); sync(); });
  // WebXR: wrap requestSession once so an immersive session hides the overlay (Quest Browser etc.) until it ends
  try{ const xr=nav.xr; if(xr&&xr.requestSession&&!xr.__ibt){ const rs=xr.requestSession.bind(xr); xr.__ibt=1;
    xr.requestSession=function(mode){ const p=rs.apply(null,arguments); if(mode==='inline') return p;
      return p.then(s=>{ xrN++; sync(); try{ s.addEventListener('end',()=>{ xrN=Math.max(0,xrN-1); sync(); },{once:true}); }catch(e){} return s; }); }; } }catch(e){}
  // overlay changes: observe the overlay elements (instant) + a slow safety tick (also covers gamepad connect and game-mode changes)
  try{ const mo=new MutationObserver(sync); OV.forEach(id=>{ const e=doc.getElementById(id); if(e) mo.observe(e,{attributes:true,attributeFilter:['class','style','hidden']}); }); }catch(e){}
  setInterval(sync,250);

  // ------------------------------------------------------------------ debug / test hook
  win.__touch={ version:1, profile:prof, settings:S,
    state:()=>({ active:isActive(), visible:vis, gamepad:gp, xr:xrN, mode:uiMode, held:Object.keys(held).filter(k=>held[k]), stick:st.id!==null, look:lo.id!==null, panel:panelOpen, u, Rs, Rl, left:S.left, calls:Object.assign({},cnt), lastLook:lastLook.slice() }),
    rects:()=>btns.filter(o=>o.shown).map(o=>{ const r=o.el.getBoundingClientRect(); return {id:o.b.id,label:o.lab,x:r.left,y:r.top,w:r.width,h:r.height}; }),
    set:(k,v)=>{ S[k]=v; saveS(); ctl.forEach(c=>c._sync()); layout(); }, force:on=>{ forced=!!on; sync(); }, refresh:sync, releaseAll };
  sync();
})();
