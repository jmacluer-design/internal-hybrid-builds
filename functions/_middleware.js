// Private gate for the whole site (Cloudflare Pages Function, runs before every static asset).
// HTTP Basic Auth: password = Pages secret SITE_PASS; username must equal Pages secret SITE_USER when that is set
// (case-insensitive; if SITE_USER is unset any username works). Fails CLOSED if SITE_PASS is missing.
// Same-origin fetches (pad -> /api/input, games -> /api/save) reuse the browser's cached credentials automatically.
//
// Rotate:  PATCH /accounts/<id>/pages/projects/internal-hybrid-builds  {"deployment_configs":{"production":{"env_vars":{"SITE_PASS":{"type":"secret_text","value":"<new>"},"SITE_USER":{"type":"secret_text","value":"<login email>"}}}}}
//          (or dashboard: Workers & Pages -> internal-hybrid-builds -> Settings -> Variables and Secrets), then redeploy.
// Swap for Cloudflare Access (email login) later by deleting this file.

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

export async function onRequest({ request, env, next }) {
  if (!env.SITE_PASS) {
    return new Response('gate not configured', { status: 503, headers: { 'Cache-Control': 'no-store' } });
  }
  const given = credsFrom(request.headers.get('Authorization') || '');
  // evaluate both compares unconditionally so a wrong username and a wrong password take the same path
  const passOk = given !== null && await safeEqual(given.pass, env.SITE_PASS);
  const userOk = !env.SITE_USER || (given !== null && await safeEqual(given.user.trim().toLowerCase(), env.SITE_USER.trim().toLowerCase()));
  if (!passOk || !userOk) {
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
