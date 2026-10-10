// Private gate for the whole site (Cloudflare Pages Function, runs before every static asset).
// HTTP Basic Auth: password = Pages secret SITE_PASS; username must be one of the comma-separated names in Pages secret SITE_USER
// when that is set (case-insensitive; if SITE_USER is unset any username works). Fails CLOSED if SITE_PASS is missing.
// Same-origin fetches (pad -> /api/input, games -> /api/save) reuse the browser's cached credentials automatically.
//
// Rotate:  PATCH /accounts/<id>/pages/projects/internal-hybrid-builds  {"deployment_configs":{"production":{"env_vars":{"SITE_PASS":{"type":"secret_text","value":"<new>"},"SITE_USER":{"type":"secret_text","value":"<login email>"}}}}}
//          (or dashboard: Workers & Pages -> internal-hybrid-builds -> Settings -> Variables and Secrets), then redeploy.
//
// Second door (optional): Cloudflare Access email login. Put an Access app (one-time PIN, allowlisted emails) on the
// *.pages.dev hostname and set the secrets ACCESS_TEAM (team name, i.e. <team>.cloudflareaccess.com) and ACCESS_AUD
// (the app's Audience tag). A request carrying a valid Access JWT then passes without the password. Both unset = Access
// is ignored and nothing changes. The JWT is verified here (signature, audience, issuer, expiry), never just trusted.
// Setup: ACCESS.md.

const enc = new TextEncoder();

async function digest(s) {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(s)));
}

// constant-time compare of fixed-length digests
async function safeEqual(a, b) {
  const [x, y] = await Promise.all([digest(a), digest(b)]);
  let d = 0;
  for (let i = 0; i < x.length; i++) d |= x[i] ^ y[i];
  return d === 0;
}

function credsFrom(header) {
  if (!header.startsWith('Basic ')) return null;
  try {
    // atob yields a binary string; decode as UTF-8 so non-ASCII passwords match
    const raw = new TextDecoder().decode(Uint8Array.from(atob(header.slice(6).trim()), c => c.charCodeAt(0)));
    const i = raw.indexOf(':');
    return i < 0 ? null : { user: raw.slice(0, i), pass: raw.slice(i + 1) };
  } catch (_) { return null; }
}

// ---- Cloudflare Access JWT verification (RS256, keys from https://<team>.cloudflareaccess.com/cdn-cgi/access/certs)
const b64u = (str) => Uint8Array.from(atob(str.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(str.length / 4) * 4, '=')), c => c.charCodeAt(0));
let jwks = { team: '', at: 0, keys: [] };

async function accessKeys(team, force) {
  if (!force && jwks.team === team && Date.now() - jwks.at < 3600e3) return jwks.keys;
  if (jwks.team === team && Date.now() - jwks.at < 60e3) return jwks.keys; // don't hammer the certs endpoint
  const r = await fetch(`https://${team}.cloudflareaccess.com/cdn-cgi/access/certs`);
  if (!r.ok) throw new Error('certs ' + r.status);
  jwks = { team, at: Date.now(), keys: (await r.json()).keys || [] };
  return jwks.keys;
}

async function accessOk(request, env) {
  const jwt = request.headers.get('Cf-Access-Jwt-Assertion');
  if (!jwt || !env.ACCESS_TEAM || !env.ACCESS_AUD) return false;
  try {
    const [h, p, sig] = jwt.split('.');
    if (!h || !p || !sig) return false;
    const head = JSON.parse(new TextDecoder().decode(b64u(h)));
    if (head.alg !== 'RS256') return false;
    let jwk = (await accessKeys(env.ACCESS_TEAM, false)).find(k => k.kid === head.kid);
    if (!jwk) jwk = (await accessKeys(env.ACCESS_TEAM, true)).find(k => k.kid === head.kid); // key rotation
    if (!jwk) return false;
    const key = await crypto.subtle.importKey('jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
    if (!(await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, b64u(sig), enc.encode(h + '.' + p)))) return false;
    const c = JSON.parse(new TextDecoder().decode(b64u(p)));
    const now = Date.now() / 1000;
    const aud = Array.isArray(c.aud) ? c.aud : [c.aud];
    return aud.includes(env.ACCESS_AUD) && c.iss === `https://${env.ACCESS_TEAM}.cloudflareaccess.com` && typeof c.exp === 'number' && c.exp > now && !(c.nbf && c.nbf > now + 60);
  } catch (_) { return false; }
}

export async function onRequest({ request, env, next }) {
  if (!env.SITE_PASS) {
    return new Response('gate not configured', { status: 503, headers: { 'Cache-Control': 'no-store' } });
  }
  const given = credsFrom(request.headers.get('Authorization') || '');
  // evaluate both compares unconditionally so a wrong username and a wrong password take the same path
  const passOk = given !== null && await safeEqual(given.pass, env.SITE_PASS);
  // SITE_USER = comma-separated list of allowed usernames (e.g. an email plus first names); unset = any username
  const names = (env.SITE_USER || '').split(',').map(x => x.trim().toLowerCase()).filter(Boolean);
  const userOk = names.length === 0 || (given !== null && (await Promise.all(names.map(n => safeEqual(given.user.trim().toLowerCase(), n)))).some(Boolean));
  if (!(passOk && userOk) && !(await accessOk(request, env))) {
    return new Response('Private.', {
      status: 401,
      headers: {
        'WWW-Authenticate': 'Basic realm="hybrid builds", charset="UTF-8"',
        'Cache-Control': 'no-store',
        'X-Robots-Tag': 'noindex, nofollow',
      },
    });
  }

  const url = new URL(request.url);
  if (url.pathname.startsWith('/api/')) {
    // No relay on static hosting: answer 404 JSON so the bridge falls back (localStorage / Supabase) instead of parsing an HTML fallback page.
    return new Response('{"err":"no relay on static host"}', {
      status: 404,
      headers: { 'content-type': 'application/json', 'Cache-Control': 'no-store' },
    });
  }

  const res = await next();
  const out = new Response(res.body, res);
  out.headers.set('Cache-Control', 'private, no-store');
  out.headers.set('X-Robots-Tag', 'noindex, nofollow');
  return out;
}
