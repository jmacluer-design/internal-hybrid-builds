# Second login door: Cloudflare Access (email one-time PIN)

Two ways in, same site:

| Door | Host | Who | How |
|---|---|---|---|
| Password | `game.cluerholdings.com` (and `internal-hybrid-builds.pages.dev`) | you | username = your email, password = Pages secret `SITE_PASS` |
| Access email login | `internal-hybrid-builds.pages.dev` | you, Braden, Darren | type your email, Cloudflare mails a 6-digit PIN, paste it, done. No password to share or rotate |

Access is enforced by Cloudflare before a request reaches the site. `functions/_middleware.js` then verifies the Access JWT
(signature, audience, issuer, expiry) and lets the request through. Every other request still needs the password.
Until `ACCESS_TEAM` and `ACCESS_AUD` are set the code ignores Access entirely (unit-tested, 16 cases).

Why the `.pages.dev` host and not `game.cluerholdings.com`: Access sits in front of the whole hostname, so on the custom
domain it would block password users before they could type the password. To put Access on a custom domain as well, add a
second hostname for it (e.g. `play.cluerholdings.com`: one more CNAME, then attach it to the Pages project).

## One-time setup (about 5 minutes, dashboard)
> Written from memory of the Cloudflare dashboard; menu names move. Zero Trust is `one.dash.cloudflare.com`.

1. **Enable Zero Trust** on the account (dash.cloudflare.com -> Zero Trust). Pick a team name (becomes
   `<team>.cloudflareaccess.com`) and the Free plan (up to 50 users; may ask for a payment method, $0).
   The API cannot do this step: `GET /accounts/<id>/access/apps` currently answers "Access is not enabled".
2. **Add the app:** Access -> Applications -> Add -> Self-hosted. Application domain `internal-hybrid-builds.pages.dev`.
   Login method: One-time PIN (default).
3. **Add the policy:** Action = Allow, Include -> Emails -> yours, Braden's, Darren's. Save.
4. **Copy the Audience tag** from the application's overview page.
5. **Set two Pages secrets, then redeploy** (secrets only bind on the next deploy):

       PATCH /accounts/<id>/pages/projects/internal-hybrid-builds
       {"deployment_configs":{"production":{"env_vars":{
         "ACCESS_TEAM":{"type":"secret_text","value":"<team>"},
         "ACCESS_AUD":{"type":"secret_text","value":"<audience tag>"}}}}}

   Then `REF=HEAD ./deploy.sh`. The PATCH merges by key (checked), so `SITE_PASS` and `SITE_USER` are left alone.

Faster: finish step 1, then give the API token the permissions "Access: Apps and Policies: Edit" and "Access:
Organizations, Identity Providers, and Groups: Read" (dashboard -> My Profile -> API Tokens -> edit). Then steps 2 to 5
are one command and need only the three email addresses.

## Adding or removing a person later
Access -> Applications -> the app -> Policies -> edit the Allow policy's email list. Takes effect immediately; no redeploy.

## What stays gated either way
Preview URLs like `<hash>.internal-hybrid-builds.pages.dev` are not covered by the Access app, but they still hit the
password gate, so they are not open.
