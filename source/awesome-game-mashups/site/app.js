/* Progressive enhancement: all project links work without JavaScript. */
'use strict';
(() => {
  const grid = document.getElementById('catalogue');
  if (!grid) return;
  const cards = Array.from(grid.querySelectorAll('.project-card'));
  const fields = Object.fromEntries(['search','host','guest','status','sort','demo'].map(id => [id,document.getElementById(id)]));
  const clean = text => text.normalize('NFKD').toLocaleLowerCase().replace(/[\u0300-\u036f]/g,'');
  cards.forEach(card => {
    card.searchText = clean(card.dataset.search || card.textContent);
    card.guestNames = JSON.parse(card.dataset.guests);
  });
  const count = document.getElementById('result-count');
  const names = {search:'q',host:'host',guest:'guest',status:'status',sort:'sort',demo:'demo'};
  function readURL() {
    const params = new URLSearchParams(location.search);
    for (const [id,key] of Object.entries(names)) {
      if (id === 'demo') fields[id].checked = params.get(key) === '1';
      else fields[id].value = params.get(key) || (id === 'sort' ? 'name' : '');
    }
    if (!fields.sort.value) fields.sort.value = 'name';
  }
  function apply(write = true) {
    const terms = clean(fields.search.value.trim()).split(/\s+/).filter(Boolean);
    let matches = 0;
    cards.sort((a,b) => fields.sort.value === 'newest'
      ? b.dataset.added.localeCompare(a.dataset.added) || a.dataset.name.localeCompare(b.dataset.name)
      : a.dataset.name.localeCompare(b.dataset.name));
    const fragment = document.createDocumentFragment();
    for (const card of cards) {
      const selected = fields.status.value;
      const matchStatus = !selected || card.dataset.group === selected ||
        (['source-available','video-only'].includes(selected) && card.dataset.status.split(' ').includes(selected));
      card.hidden = !(terms.every(term => card.searchText.includes(term)) &&
        (!fields.host.value || fields.host.value === card.dataset.host) &&
        (!fields.guest.value || card.guestNames.includes(fields.guest.value)) && matchStatus &&
        (!fields.demo.checked || card.dataset.demo === 'true'));
      if (!card.hidden) matches++;
      fragment.appendChild(card);
    }
    grid.appendChild(fragment);
    count.textContent = `${matches} of ${cards.length} entries`;
    document.getElementById('no-results').hidden = matches !== 0;
    if (write) {
      const params = new URLSearchParams();
      for (const [id,key] of Object.entries(names)) {
        const value = id === 'demo' ? (fields[id].checked ? '1' : '') : fields[id].value.trim();
        if (value && !(id === 'sort' && value === 'name')) params.set(key,value);
      }
      const qs = params.toString();
      try { history.replaceState(null,'',location.pathname + (qs ? '?' + qs : '') + location.hash); }
      catch (error) { if (error.name !== 'SecurityError') throw error; }
    }
  }
  document.getElementById('filters').hidden = false;
  readURL(); apply(false);
  fields.search.addEventListener('input',() => apply());
  ['host','guest','status','sort','demo'].forEach(key => fields[key].addEventListener('change',() => apply()));
  document.getElementById('reset').addEventListener('click',() => {
    for (const [id,element] of Object.entries(fields)) {
      if (id === 'demo') element.checked = false;
      else element.value = id === 'sort' ? 'name' : '';
    }
    apply(); fields.search.focus();
  });
  window.addEventListener('popstate',() => { readURL(); apply(false); });
})();
