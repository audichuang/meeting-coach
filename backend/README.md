# backend

Cloudflare Worker that holds the OpenAI key for the iPad App. The App authenticates with an invite token; the Worker mints Realtime client secrets and proxies Responses calls and post-meeting file transcription (`/v1/audio/transcriptions`, `gpt-transcribe` only).

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

## Cloudflare Access (front door)

The Worker's `workers.dev` URL sits behind a Cloudflare Access self-hosted application whose only policy is Service Auth for one service token (`meeting-coach-ipad-app`). Every request, `/admin/*` included, needs `CF-Access-Client-Id` and `CF-Access-Client-Secret`; without them Access answers 401 before the Worker runs. The Worker does not check these headers itself, so `npx wrangler deploy` is unchanged, but `curl` calls in this README need them too:

```sh
curl -H "CF-Access-Client-Id: $ID" -H "CF-Access-Client-Secret: $SECRET" ...
```

The invite code stays the per-person identity; the token only proves the request comes from the App build. Anyone who unpacks the IPA can extract it, so it filters drive-by traffic and does not replace the invite code or the monthly cap.

Setup (account of the Worker, `cf` CLI, `CLOUDFLARE_ACCOUNT_ID` set):

1. `cf zero-trust access service-tokens create --name meeting-coach-ipad-app --duration 8760h`. The secret is shown once; pipe it straight into the password manager.
2. `cf zero-trust access applications create --body <json>`: `type: self_hosted`, the Worker host in `domain` and `destinations`, `service_auth_401_redirect: true` (401 instead of a login redirect), one policy with `decision: non_identity` and `include: [{service_token: {token_id}}]`.

Build the App with the token and the Worker address: copy `app/Config/Secrets.example.xcconfig` to `app/Config/Secrets.xcconfig` (gitignored) and fill `COACH_WORKER_HOST` (host only; xcconfig reads `//` as a comment) and the two token values. They reach Info.plist; the App talks to that host only (Settings has no server field) and sends the token to it only, never to OpenAI.

Rotate (the token expires after one year, `expires_at` in `cf zero-trust access service-tokens list`): `cf zero-trust access service-tokens rotate <id>` (or refresh in the dashboard) issues a new secret with the same client id and keeps the old one valid for a grace period you choose. Update the password manager and `Secrets.xcconfig`, ship a new App build, and let the old secret lapse. Installed builds stop working when it does, so ship the build first. If the token leaks, rotate with no grace period.

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
- **File transcription is billed from OpenAI's `usage.seconds`** (`gpt-transcribe` has only a per-minute price). If a response ever lacks it, the file size is read at 16 kbps, about half what the App's AAC averages, which overestimates. Uploads over 8 MB are refused: the App's 300 s chunks are about 2.4 MB at its highest bit rate.
- **One OpenAI key is shared by every user**, so `/v1/responses` forces `store: false` and rejects `previous_response_id`, `conversation`, streaming, hosted tools and any other unlisted parameter; otherwise one user could read another's stored responses or run up costs that are never metered.
- **Identity is one function** (`authenticate` in `src/auth.ts`). Replace it with Sign in with Apple or StoreKit later; accounting only needs a stable user id.
- **D1, not KV**, because spend and rate counters need atomic increments.
