// gamepad shim v1: standard-mapping pads (Xbox / DualSense / DualShock / Switch Pro) -> the same inputs as keyboard + phone pad.
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
  const pick=()=>{ for(const g of navigator.getGamepads()) if(g&&g.connected) return g; return null; };
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
  function frame(){
    const g=pick();
    if(g){
      const b=i=>{ const x=g.buttons[i]; return !!x&&(x.pressed||x.value>0.4); };
      // sticks (radial deadzone)
      const dz=(x,y)=>{ const m=Math.hypot(x,y); if(m<DZ) return [0,0]; const s=(Math.min(m,1)-DZ)/(1-DZ)/m; return [x*s,y*s]; };
      const [lx,ly]=dz(g.axes[0]||0,g.axes[1]||0);
      axisKeys('a','d',lx); axisKeys('w','s',ly);
      const [rx,ry]=dz(g.axes[2]||0,g.axes[3]||0);
      const cv=v=>Math.sign(v)*Math.pow(Math.abs(v),1.6); // finer aim near centre
      if(rx||ry){ lookLive=true; call(typeof padLook==='function'?padLook:null,cv(rx),cv(ry)); }
      else if(lookLive){ lookLive=false; call(typeof padLook==='function'?padLook:null,0,0); }
      // face / shoulder buttons -> keys
      setKey(' ',b(0)); setKey('z',b(1)); setKey('j',b(2)); setKey('e',b(3));
      setKey('q',b(4)||b(11)); setKey('shift',b(5)||b(10));
      setKey('arrowup',b(12)); setKey('arrowdown',b(13)); setKey('arrowleft',b(14)); setKey('arrowright',b(15));
      // triggers -> primary / secondary
      edge('rt',b(7),()=>{ call(typeof padFire==='function'?padFire:null,true); window.__rumble(0.0,0.25,45); },()=>call(typeof padFire==='function'?padFire:null,false));
      edge('lt',b(6),()=>call(typeof padPlace==='function'?padPlace:null,true),()=>call(typeof padPlace==='function'?padPlace:null,false));
      // A also confirms on start / retry screens; Start confirms there, pauses in game
      edge('a',b(0),()=>{ if(!click('cta')) click('cta2'); });
      edge('start',b(9),()=>{ if(!click('cta') && !click('cta2')) call(typeof padMenu==='function'?padMenu:null); });
      edge('select',b(8),()=>call(typeof padMenu==='function'?padMenu:null));
    }
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
})();
