/* mta-bridge.js : lets the UNCHANGED vanilla Outbreak page (copied from fivem/outbreak/ui by mta/tools/sync_ui.sh) run inside an MTA:SA CEF browser.
   Loaded by ui/mta.html BEFORE js/core.js, so the override below is in place before the page makes its first call.

   page -> game : the page talks to the game with  fetch('https://outbreak/<callback>', { method: 'POST', body: JSON })  (the FiveM NUI convention, see
                  OB.post in js/core.js). MTA has no such scheme, so window.fetch is wrapped: calls to https://<resource>/<name> become
                      mta.triggerEvent('outbreak:ui', '<name>', '<the JSON body as a string>')
                  which the Lua client (client/ui.lua) receives as a local event whose `source` is the browser element, and answers the page's promise with {"ok":true}.
                  (mta.triggerEvent only takes simple values, so the payload travels as a JSON string and is decoded in Lua.)
   game -> page : Lua calls executeBrowserJavascript(browser, "window.dispatchEvent(new MessageEvent('message',{data:<json>}))"), which is exactly what js/main.js
                  listens for ({action, data}); nothing to wrap here. window.__obMta exposes counters for the tests and for debugging in the dev tools.
   Everything else (fetch to other URLs, pages opened outside MTA) behaves as before. No network, no CDN. */
(function () {
  'use strict';
  var EVENT = 'outbreak:ui';
  var RESOURCE = 'outbreak';
  var URL_RE = /^https?:\/\/([^\/?#]+)\/([A-Za-z0-9_\-]+)\/?(?:[?#].*)?$/;
  var nativeFetch = typeof window.fetch === 'function' ? window.fetch.bind(window) : null;
  var stats = { posted: 0, dropped: 0, lastName: '', hasMta: false };
  var warned = false;

  window.GetParentResourceName = function () { return RESOURCE; };

  function hasMta() { return !!(window.mta && typeof window.mta.triggerEvent === 'function'); }

  function reply(obj) {
    var body = JSON.stringify(obj);
    if (typeof Response === 'function') return Promise.resolve(new Response(body, { status: 200, headers: { 'Content-Type': 'application/json' } }));
    return Promise.resolve({ ok: true, status: 200, json: function () { return Promise.resolve(obj); }, text: function () { return Promise.resolve(body); } });
  }

  window.fetch = function (input, init) {
    var url = typeof input === 'string' ? input : (input && input.url) || '';
    var m = URL_RE.exec(url);
    if (!m || m[1] !== RESOURCE) {
      if (nativeFetch) return nativeFetch(input, init);
      return Promise.reject(new TypeError('fetch is not available in this browser'));
    }
    var body = '{}';
    if (init && typeof init.body === 'string') body = init.body;
    stats.hasMta = hasMta();
    if (stats.hasMta) {
      try { window.mta.triggerEvent(EVENT, m[2], body); stats.posted++; stats.lastName = m[2]; }
      catch (e) { stats.dropped++; if (window.console) console.error('[mta-bridge] triggerEvent failed', e); }
    } else {
      stats.dropped++;
      if (!warned && window.console) { warned = true; console.warn('[mta-bridge] window.mta.triggerEvent is missing: this page is not running inside an MTA browser; UI callbacks are dropped'); }
    }
    return reply({ ok: true });
  };

  window.__obMta = stats;
})();
