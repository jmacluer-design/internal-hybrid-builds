// gamepad shim v1 (+ __gpPoll hook for XR loops): standard-mapping pads (Xbox / DualSense / DualShock / Switch Pro) -> the same inputs as keyboard + phone pad.
// Pasted verbatim inside each game's module <script> (needs the contract globals: keys, padFire, padPlace, padLook, padMenu).
// Mapping (Xbox name / PlayStation name):
//   left stick = WASD   right stick = look   A/Cross = jump   X/Square = J   B/Circle = Z   Y/Triangle = E
//   RT/R2 = primary (fire)   LT/L2 = secondary (ADS / place / zip)   LB/L1 = Q   RB/R1 and L3 = Shift   R3 = Q
//   D-pad = arrow keys   Start/Options = confirm on menu screens, pause/back-to-menu in game   Select/Create = back to menu
// Browser quirk: the pad is invisible to the page until you press any button once.
(function(){
  if(!navigator.getGamepads) return;
  const DZ=0.16, held=new Set(), was={};
  const toast=(()=>{ let el,t; return msg=>{
    if(!el){ el=document.createElement('div');
      el.style.cssText='position:fixed;left:50%;top:14px;transform:translateX(-50%);z-index:99999;padding:7px 14px;border-radius:8px;'+
        'background:rgba(10,12,20,.86);color:#cfe;font:12px ui-monospace,monospace;border:1px solid #3a5;pointer-events:none;transition:opacity .4s;';
      document.body.appendChild(el); }
    el.textContent=msg; el.style.opacity=1; clearTimeout(t); t=setTimeout(()=>{ el.style.opacity=0; },2600); }; })();
  const setKey=(k,on)=>{ if(on){ if(!held.has(k)){ held.add(k); keys.add(k); } } else if(held.has(k)){ held.delete(k); keys.delete(k); } };
  const axisKeys=(neg,pos,v)=>{ setKey(neg, held.has(neg)? v<-0.22 : v<-0.38); setKey(pos, held.has(pos)? v>0.22 : v>0.38); };
  const shown=el=>{ if(!el) return false; const s=getComputedStyle(el);
    return s.display!=='none'&&s.visibility!=='hidden'&&+s.opacity>0.01&&el.getClientRects().length>0; };
  const click=id=>{ const el=document.getElementById(id); if(shown(el)){ el.click(); return true; } return false; };
  const edge=(name,on,down,up)=>{ if(on&&!was[name]){ was[name]=1; down&&down(); } else if(!on&&was[name]){ was[name]=0; up&&up(); } };
  const call=(f,...a)=>{ if(typeof f==='function') f(...a); };
  const pick=()=>{ const gs=navigator.getGamepads(); for(let i=0;i<gs.length;i++){ const g=gs[i]; if(g&&g.connected&&g.mapping!=='xr-standard') return g; } return null; };
  let lookLive=false;
  function releaseAll(){ [...held].forEach(k=>setKey(k,false)); Object.keys(was).forEach(k=>{ if(was[k]) edge(k,false,null,()=>{}); });
    if(lookLive){ lookLive=false; call(typeof padLook==='function'?padLook:null,0,0); }
    if(typeof padFire==='function') padFire(false); if(typeof padPlace==='function') padPlace(false); }
  addEventListener('gamepadconnected',e=>toast('controller connected: '+String(e.gamepad.id).replace(/\s*\(.*$/,'').slice(0,42)));
  addEventListener('gamepaddisconnected',()=>{ releaseAll(); toast('controller disconnected'); });
  addEventListener('blur',releaseAll);
  window.__rumble=(strong,weak,ms)=>{ const g=pick(), a=g&&g.vibrationActuator;
    if(a&&a.playEffect) a.playEffect('dual-rumble',{duration:ms||80,strongMagnitude:strong||0,weakMagnitude:weak||0}).catch(()=>{}); };
  window.__gpDbg=()=>({ connected:!!pick(), held:[...held] });
  // hot path is allocation-free (it also runs every XR frame): shared scratch + static edge callbacks
  const _dz=[0,0]; let cur=null;
  const bb=i=>{ const x=cur.buttons[i]; return !!x&&(x.pressed||x.value>0.4); };
  const dz=(x,y)=>{ const m=Math.hypot(x,y); if(m<DZ){ _dz[0]=0; _dz[1]=0; return _dz; } const s=(Math.min(m,1)-DZ)/(1-DZ)/m; _dz[0]=x*s; _dz[1]=y*s; return _dz; };
  const cv=v=>Math.sign(v)*Math.pow(Math.abs(v),1.6); // finer aim near centre
  const onRtDown=()=>{ call(typeof padFire==='function'?padFire:null,true); window.__rumble(0.0,0.25,45); }, onRtUp=()=>call(typeof padFire==='function'?padFire:null,false);
  const onLtDown=()=>call(typeof padPlace==='function'?padPlace:null,true), onLtUp=()=>call(typeof padPlace==='function'?padPlace:null,false);
  const onA=()=>{ if(!click('cta')) click('cta2'); }, onStart=()=>{ if(!click('cta') && !click('cta2')) call(typeof padMenu==='function'?padMenu:null); }, onSelect=()=>call(typeof padMenu==='function'?padMenu:null);
  function poll(){
    const g=pick();
    if(g){
      cur=g; const b=bb;
      // sticks (radial deadzone)
      let d=dz(g.axes[0]||0,g.axes[1]||0); const lx=d[0], ly=d[1];
      axisKeys('a','d',lx); axisKeys('w','s',ly);
      d=dz(g.axes[2]||0,g.axes[3]||0); const rx=d[0], ry=d[1];
      if(rx||ry){ lookLive=true; call(typeof padLook==='function'?padLook:null,cv(rx),cv(ry)); }
      else if(lookLive){ lookLive=false; call(typeof padLook==='function'?padLook:null,0,0); }
      // face / shoulder buttons -> keys
      setKey(' ',b(0)); setKey('z',b(1)); setKey('j',b(2)); setKey('e',b(3));
      setKey('q',b(4)||b(11)); setKey('shift',b(5)||b(10));
      setKey('arrowup',b(12)); setKey('arrowdown',b(13)); setKey('arrowleft',b(14)); setKey('arrowright',b(15));
      // triggers -> primary / secondary
      edge('rt',b(7),onRtDown,onRtUp);
      edge('lt',b(6),onLtDown,onLtUp);
      // A also confirms on start / retry screens; Start confirms there, pauses in game
      edge('a',b(0),onA);
      edge('start',b(9),onStart);
      edge('select',b(8),onSelect);
    }
  }
  function frame(){ poll(); requestAnimationFrame(frame); }
  window.__gpPoll=poll; // window rAF does not run while an immersive session is presenting (Quest Browser): the game's XR loop calls this every XR frame
  requestAnimationFrame(frame);
})();
