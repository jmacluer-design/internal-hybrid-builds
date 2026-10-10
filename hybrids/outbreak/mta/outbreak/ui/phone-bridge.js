/* phone-bridge.js : the host contract of the UNCHANGED Outbreak page (copied from fivem/outbreak/ui by mta/tools/sync_ui.sh), implemented over HTTP polling, so a PHONE BROWSER can show and
   steer the colony of a real MTA:SA server with no GTA client. Loaded by ui/phone.html BEFORE js/core.js (like mta-bridge.js is by mta.html). It speaks to the one function the resource
   exports over HTTP (server/phone.lua phoneApi, reached through MTA's call interface: POST /<resource>/call/phoneApi with a JSON array body).

   page -> game : the page calls  fetch('https://outbreak/<callback>', { method: 'POST', body: JSON })  (js/core.js OB.post). window.fetch is wrapped: order, ui and place(commit) become
                      phoneApi("cb", sid, name, data)
                  in order, one request at a time; ready starts the handshake; the in-game client's camera / window callbacks (mode, screen, focus, mouse, key, close, place start / cancel and
                  the ui actions "screens") have no meaning for a phone and are answered locally.
   game -> page : phoneApi("ready", sid) returns the first messages (boot, mode, catalog, state), phoneApi("poll", sid, seq, gen) the ones since; each message is {action, data}, dispatched
                  as window.dispatchEvent(new MessageEvent('message', {data})), which is what js/main.js listens for. MTA's call interface answers synchronously (a request cannot be held
                  open), so this polls: about every 500 ms while the page is visible, every 5 s while hidden, with back-off after errors, and at once after a callback.
   MTA wraps the string phoneApi returns into a JSON array: the body is ["<json text>"]. A 401 means the login is missing or has no right: reload the page to be asked again.
   window.__phone exposes the connection state for the tests and the dev tools. No CDN, no network except the page's own server. */
(function () {
  'use strict';
  var RESOURCE = 'outbreak';
  var URL_RE = /^https?:\/\/([^\/?#]+)\/([A-Za-z0-9_\-]+)\/?(?:[?#].*)?$/;
  var m = /^\/([^\/]+)\//.exec(location.pathname);
  var API = '/' + (m ? m[1] : RESOURCE) + '/call/phoneApi';
  var nativeFetch = typeof window.fetch === 'function' ? window.fetch.bind(window) : null;
  var LOCAL = { mode: 1, screen: 1, focus: 1, mouse: 1, key: 1, close: 1 }; // the in-game client's camera and window business
  var FAST = 500, SLOW = 5000, TIMEOUT = 9000;

  function newSid() {
    try { var s = sessionStorage.getItem('outbreak.phone.sid'); if (s && /^[A-Za-z0-9_\-]{8,40}$/.test(s)) return s; } catch (e) { /* storage blocked */ }
    var a = '';
    try { var u = new Uint8Array(16); crypto.getRandomValues(u); for (var i = 0; i < u.length; i++) a += (u[i] < 16 ? '0' : '') + u[i].toString(16); } catch (e) { for (var j = 0; j < 32; j++) a += Math.floor(Math.random() * 16).toString(16); }
    try { sessionStorage.setItem('outbreak.phone.sid', a); } catch (e) { /* storage blocked */ }
    return a;
  }
  var st = window.__phone = { sid: newSid(), api: API, ready: false, connected: false, role: null, seq: 0, gen: 0, polls: 0, posts: 0, resyncs: 0, errors: 0, failStreak: 0, lastError: '', authFailed: false, hidden: false, queue: 0, lastStatus: null };
  window.GetParentResourceName = function () { return RESOURCE; };

  function dispatch(msg) { try { window.dispatchEvent(new MessageEvent('message', { data: msg })); } catch (e) { if (window.console) console.error('[phone-bridge] message failed', e); } }
  function toast(level, text) { dispatch({ action: 'toast', data: { level: level, text: text } }); }
  var lastToast = {};
  function toastOnce(key, level, text, ms) { var now = Date.now(); if (lastToast[key] && now - lastToast[key] < (ms || 6000)) return; lastToast[key] = now; toast(level, text); }
  function badge(text, warn) {
    var b = document.getElementById('preview-badge'); if (!b) return;
    b.textContent = text; b.hidden = false; b.style.color = warn ? '#ff9aa4' : ''; b.style.borderColor = warn ? 'rgba(255,93,108,.55)' : '';
  }

  // one request to phoneApi: resolves { ok, ... } (the decoded answer) or rejects with an Error (network, HTTP status, bad body)
  function call(op, a, b) {
    var body = JSON.stringify([op, st.sid, a === undefined ? null : a, b === undefined ? null : b]);
    var ctl = typeof AbortController === 'function' ? new AbortController() : null;
    var timer = ctl ? setTimeout(function () { ctl.abort(); }, TIMEOUT) : 0;
    st.posts++;
    return nativeFetch(API, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Outbreak-Phone': '1' }, body: body, cache: 'no-store', credentials: 'same-origin', signal: ctl ? ctl.signal : undefined })
      .then(function (r) {
        clearTimeout(timer);
        if (r.status === 401 || r.status === 403) { st.authFailed = true; var e = new Error('HTTP ' + r.status + ' (login required or not allowed)'); e.auth = true; throw e; }
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.text();
      })
      .then(function (t) {
        var arr;
        try { arr = JSON.parse(t); } catch (e) { throw new Error('not JSON: ' + String(t).slice(0, 60)); }
        var inner = Array.isArray(arr) ? arr[0] : arr;
        if (typeof inner === 'string') { try { inner = JSON.parse(inner); } catch (e) { throw new Error('bad answer: ' + inner.slice(0, 60)); } }
        if (!inner || typeof inner !== 'object') throw new Error('empty answer');
        return inner;
      }, function (e) { clearTimeout(timer); throw e; });
  }

  function accept(r) { // apply the bookkeeping + the messages of a successful answer
    if (r.seq !== undefined) st.seq = r.seq;
    if (r.gen !== undefined) st.gen = r.gen;
    if (r.role) st.role = r.role;
    if (r.status) st.lastStatus = r.status;
    if (r.msgs) for (var i = 0; i < r.msgs.length; i++) {
      var msg = r.msgs[i];
      if (msg && msg.action === 'boot' && msg.data) { st.account = msg.data.account; st.role = msg.data.role || st.role; }
      dispatch(msg);
    }
  }
  function setConnected(on) {
    if (on === st.connected) return;
    st.connected = on;
    if (on) { badge('LIVE · MTA SERVER', false); if (st.wasLost) toast('good', 'Reconnected to the server.'); st.wasLost = false; }
    else { st.wasLost = true; badge('OFFLINE · RETRYING', true); toastOnce('lost', 'warn', 'Connection to the server lost. Retrying...'); }
  }

  var timer = 0, busy = false, kick = false;
  function schedule(ms) { clearTimeout(timer); timer = setTimeout(tick, ms); }
  function delay() { if (st.failStreak) return Math.min(8000, FAST * Math.pow(2, st.failStreak)); return document.hidden ? SLOW : FAST; }
  function tick() {
    if (busy || st.authFailed) return;
    busy = true;
    var p = st.ready ? call('poll', st.seq, st.gen).then(function (r) {
      st.polls++;
      if (r.resync) { st.ready = false; st.resyncs++; kick = true; return; }
      if (r.ok === false) throw new Error(r.error || 'refused');
      accept(r); st.failStreak = 0; setConnected(true);
    }) : call('ready').then(function (r) {
      if (r.ok === false) throw new Error(r.error || 'refused');
      accept(r); st.ready = true; st.failStreak = 0; setConnected(true); flushQueue();
    });
    p.then(function () { busy = false; schedule(kick ? 0 : delay()); kick = false; }, function (e) {
      busy = false; st.errors++; st.lastError = String(e && e.message || e); st.failStreak++; if (e.auth) st.ready = false;
      if (e.auth) { setConnected(false); badge('LOGIN REQUIRED', true); toastOnce('auth', 'bad', 'The server refused the login. Reload this page to sign in again.', 60000); return; }
      if (st.failStreak >= 2) setConnected(false);
      schedule(delay());
    });
  }

  // ---- callbacks (page -> server): serial, in order
  var chain = Promise.resolve(), pending = [];
  function flushQueue() { var q = pending; pending = []; for (var i = 0; i < q.length; i++) send(q[i][0], q[i][1]); }
  function send(name, data) {
    st.queue++;
    chain = chain.then(function () {
      return call('cb', name, data).then(function (r) {
        st.queue--;
        if (r.resync) { st.ready = false; st.resyncs++; pending.push([name, data]); schedule(0); return; } // the server forgot this page (expired / evicted / restarted): sign in again, then send it
        if (r.ok === false) {
          if (r.error === 'read-only') toastOnce('ro', 'warn', 'This login is read-only: you can look at the colony but not change it.');
          else if (/rate/.test(r.error || '')) toastOnce('rate', 'warn', 'Too many commands at once, slow down.', 3000);
          else toastOnce('cb:' + r.error, 'warn', 'The server refused that: ' + r.error);
          return;
        }
        accept(r);
        schedule(120); // the sim answers an order with events (order_result): fetch them soon
      }, function (e) { st.queue--; st.errors++; st.lastError = String(e && e.message || e); if (e.auth) { st.authFailed = true; badge('LOGIN REQUIRED', true); } else toastOnce('cbfail', 'warn', 'Could not reach the server. That command was lost.'); });
    });
  }
  function onCallback(name, data) {
    if (LOCAL[name]) return;
    if (name === 'place' && data && data.op !== 'commit') return;
    if (name === 'ui' && data && data.name === 'screens') return;
    if (name === 'ready') { if (!st.ready) { schedule(0); } return; }
    if (name !== 'order' && name !== 'ui' && name !== 'place') return;
    if (!st.ready) { pending.push([name, data]); return; }
    send(name, data);
  }

  function reply(obj) {
    var body = JSON.stringify(obj);
    if (typeof Response === 'function') return Promise.resolve(new Response(body, { status: 200, headers: { 'Content-Type': 'application/json' } }));
    return Promise.resolve({ ok: true, status: 200, json: function () { return Promise.resolve(obj); }, text: function () { return Promise.resolve(body); } });
  }
  window.fetch = function (input, init) {
    var url = typeof input === 'string' ? input : (input && input.url) || '';
    var mm = URL_RE.exec(url);
    if (!mm || mm[1] !== RESOURCE) {
      if (nativeFetch) return nativeFetch(input, init);
      return Promise.reject(new TypeError('fetch is not available in this browser'));
    }
    var data = {};
    try { data = init && typeof init.body === 'string' ? JSON.parse(init.body) : {}; } catch (e) { data = {}; }
    onCallback(mm[2], data);
    return reply({ ok: true });
  };

  document.addEventListener('visibilitychange', function () { st.hidden = document.hidden; if (!document.hidden && st.ready) schedule(0); });
  window.addEventListener('online', function () { st.failStreak = 0; schedule(0); });
  // the page's own init posts `ready` (after every script has run), which starts the handshake; `load` is the fallback. Starting earlier could lose the first messages: the page's
  // message listener does not exist until js/main.js has run.
  window.addEventListener('load', function () { if (!st.ready && !busy) schedule(0); });
})();
