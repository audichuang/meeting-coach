# backend

Cloudflare Worker that holds the OpenAI key for the iPad App. The App authenticates with an invite token; the Worker mints Realtime client secrets and proxies Responses calls.

## Deploy

```sh
npm install
npm test
npx wrangler d1 migrations apply meeting-coach --remote
npx wrangler deploy
```

`wrangler.jsonc` points at an existing D1 database; for a fresh account create one (`npx wrangler d1 create meeting-coach`) and replace `database_id`.

Limits live in `vars` in `wrangler.jsonc`: `MONTHLY_CAP_USD` (per user, default 30), `RATE_LIMIT_PER_MINUTE`, `MAX_OUTPUT_TOKENS`, `REALTIME_SESSION_EST_MINUTES`. Prices are in `src/pricing.ts`.

## Secrets

Pipe values in so they never reach argv or disk:

```sh
op read "op://<vault>/<item>/credential" | tr -d '\n' | npx wrangler secret put OPENAI_API_KEY
op read "op://<vault>/<admin-item>/credential" | tr -d '\n' | npx wrangler secret put ADMIN_SECRET
```

Generate `ADMIN_SECRET` (for example `openssl rand -base64 36`) straight into the password manager first; it is the only way to issue invites.

## Invites

```sh
# issue: the token is shown once, only its SHA-256 is stored
curl -X POST "$WORKER/admin/invites" -H "Authorization: Bearer $ADMIN_SECRET" -d '{"label":"name"}'
# list
curl "$WORKER/admin/invites" -H "Authorization: Bearer $ADMIN_SECRET"
# revoke
curl -X DELETE "$WORKER/admin/invites/<id>" -H "Authorization: Bearer $ADMIN_SECRET"
```

## Why it is built this way

- **Audio never passes through the Worker.** `/v1/realtime/session` returns a short-lived OpenAI client secret and the App connects to OpenAI directly. The secret only gates opening the socket; an open session keeps running after it expires, so the App asks for a new one on every (re)connect.
- **Realtime spend is an estimate.** The Worker never sees audio duration, so each minted session is billed as `REALTIME_SESSION_EST_MINUTES` minutes. Responses spend is exact, from OpenAI's `usage`.
- **One OpenAI key is shared by every user**, so `/v1/responses` forces `store: false` and rejects `previous_response_id`, `conversation`, streaming, hosted tools and any other unlisted parameter; otherwise one user could read another's stored responses or run up costs that are never metered.
- **Identity is one function** (`authenticate` in `src/auth.ts`). Replace it with Sign in with Apple or StoreKit later; accounting only needs a stable user id.
- **D1, not KV**, because spend and rate counters need atomic increments.
