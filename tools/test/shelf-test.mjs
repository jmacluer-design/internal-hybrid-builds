import { launch } from './harness.mjs';
const out = process.argv[2];
const g = await launch('/home/user/internal-hybrid-builds/index.html', { w: 1100, h: 700 });
await g.wait(800);
const r = await g.eval(() => ({
  active: document.querySelectorAll('#listing .artifact-card').length,
  note: (document.querySelector('#listing p')||{}).textContent || null,
  archived: [...document.querySelectorAll('#archiveListing .artifact-card')].map(c => c.querySelector('strong').textContent + ' -> ' + c.querySelector('.artifact-kicker').textContent),
  count: document.getElementById('count').textContent,
  archiveOpen: document.getElementById('archiveBox').open,
  undefinedText: document.body.innerText.includes('undefined'),
}));
console.log(JSON.stringify(r, null, 1));
await g.eval(() => { document.getElementById('archiveBox').open = true; });
await g.wait(200); await g.shot(out + '/shelf-archive.png');
console.log('errors:', JSON.stringify(g.errors));
await g.close();
