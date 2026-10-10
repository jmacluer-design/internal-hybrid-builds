import { launch } from './harness.mjs';
const file = process.argv[2];
const g = await launch(file);
await g.wait(900);
// fake an Xbox-style standard-mapping pad (what Chrome/Safari expose for Xbox + DualSense)
await g.eval(() => {
  const mk = () => ({ pressed:false, value:0 });
  window.__fp = { connected:true, id:'Xbox Wireless Controller (STANDARD GAMEPAD Vendor: 045e)', axes:[0,0,0,0], buttons:Array.from({length:17},mk) };
  navigator.getGamepads = () => [window.__fp, null, null, null];
  window.__set = (i,on)=>{ window.__fp.buttons[i]={pressed:on,value:on?1:0}; };
  window.__axes = (a,b,c,d)=>{ window.__fp.axes=[a,b,c,d]; };
});
const held = async () => (await g.eval(() => window.__gpDbg())).held.slice().sort().join(',');
const menuShown = () => g.eval(() => { const el=document.getElementById('menu'); const s=getComputedStyle(el);
  return s.display!=='none'&&s.visibility!=='hidden'&&+s.opacity>0.01&&el.getClientRects().length>0; });
const R = [];
const ok = (name, cond, extra='') => { R.push(cond); console.log((cond?'PASS':'FAIL'), name, extra); };
ok('menu visible at load', await menuShown());
await g.eval(()=>window.__set(0,true)); await g.wait(120); await g.eval(()=>window.__set(0,false)); await g.wait(300);
ok('A on menu starts the game (menu hidden)', !(await menuShown()));
await g.eval(()=>window.__axes(1,0,0,0)); await g.wait(120); ok('left stick right -> d', (await held())==='d', await held());
await g.eval(()=>window.__axes(-1,0,0,0)); await g.wait(120); ok('left stick left -> a', (await held())==='a', await held());
await g.eval(()=>window.__axes(0,-1,0,0)); await g.wait(120); ok('left stick up -> w', (await held())==='w', await held());
await g.eval(()=>window.__axes(0,1,0,0)); await g.wait(120); ok('left stick down -> s', (await held())==='s', await held());
await g.eval(()=>window.__axes(0.1,0.1,0,0)); await g.wait(120); ok('inside deadzone -> nothing', (await held())==='', await held());
await g.eval(()=>window.__axes(0,0,0,0));
for (const [i,k] of [[0,' '],[1,'z'],[2,'j'],[3,'e'],[4,'q'],[5,'shift'],[12,'arrowup'],[15,'arrowright']]) {
  await g.eval(([i])=>window.__set(i,true),[i]); await g.wait(100); const h1=await held();
  await g.eval(([i])=>window.__set(i,false),[i]); await g.wait(100); const h2=await held();
  ok(`button ${i} -> '${k}' and released`, h1===k && h2==='', `down=${h1} up=${h2}`);
}
await g.eval(()=>window.__axes(0.5,0,0,0)); await g.wait(100);
await g.eval(()=>{ navigator.getGamepads=()=>[null,null,null,null]; window.dispatchEvent(new Event('gamepaddisconnected')); }); await g.wait(150);
ok('disconnect releases everything', (await held())==='', await held());
console.log('errors:', JSON.stringify(g.errors));
await g.close();
process.exit(R.every(Boolean) && g.errors.length===0 ? 0 : 1);
