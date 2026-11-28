import { env, exports } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { APPLE_ISSUER, APPLE_KEYS_URL, APP_BUNDLE_ID, verifyAppleIdentityToken } from "../src/apple";
import { createInvite, sha256Hex } from "../src/auth";

const BASE = "https://worker.test";
const KID = "test-kid";
const ALG = { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" };

// One key pair for the file: the Worker caches Apple's keys per isolate.
const apple = (await crypto.subtle.generateKey(ALG, true, ["sign", "verify"])) as CryptoKeyPair;
const other = (await crypto.subtle.generateKey(ALG, true, ["sign", "verify"])) as CryptoKeyPair;
const jwks = { keys: [{ ...(await crypto.subtle.exportKey("jwk", apple.publicKey)), kid: KID, alg: "RS256", use: "sig" }] };

const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const part = (obj: unknown) => b64url(new TextEncoder().encode(JSON.stringify(obj)));

async function sign(claims: Record<string, unknown> = {}, { key = apple.privateKey, kid = KID } = {}) {
  const body = {
    iss: APPLE_ISSUER, aud: APP_BUNDLE_ID, exp: Math.floor(Date.now() / 1000) + 600,
    sub: "001234.synthetic.0001", email: "user@example.test", ...claims,
  };
  const signingInput = `${part({ alg: "RS256", kid })}.${part(body)}`;
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(signingInput));
  return `${signingInput}.${b64url(new Uint8Array(sig))}`;
}

function mockAppleKeys() {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
    if (String(input) === APPLE_KEYS_URL) return Response.json(jwks);
    throw new Error(`unexpected fetch ${String(input)}`);
  });
}

async function exchange(identityToken: unknown) {
  return exports.default.fetch(`${BASE}/v1/auth/apple`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ identity_token: identityToken }),
  });
}

const usage = (token: string) =>
  exports.default.fetch(`${BASE}/v1/usage`, { headers: { Authorization: `Bearer ${token}` } });

const admin = (path: string, method = "GET") =>
  exports.default.fetch(`${BASE}${path}`, { method, headers: { Authorization: `Bearer ${env.ADMIN_SECRET}` } });

afterEach(() => vi.restoreAllMocks());

describe("verifyAppleIdentityToken", () => {
  it("accepts a token signed by Apple's key and returns sub and email", async () => {
    mockAppleKeys();
    expect(await verifyAppleIdentityToken(await sign())).toEqual({ sub: "001234.synthetic.0001", email: "user@example.test" });
    expect((await verifyAppleIdentityToken(await sign({ email: undefined }))).email).toBeNull();
  });

  it("rejects bad signatures, wrong aud or iss, expiry, unknown keys and junk", async () => {
    mockAppleKeys();
    const reject = (t: string, message: string) => expect(verifyAppleIdentityToken(t)).rejects.toThrow(message);
    await reject(await sign({}, { key: other.privateKey }), "bad signature");
    await reject(await sign({ aud: "com.example.other" }), "wrong audience");
    await reject(await sign({ iss: "https://evil.example.test" }), "wrong issuer");
    await reject(await sign({ exp: Math.floor(Date.now() / 1000) - 1 }), "expired");
    await reject(await sign({}, { kid: "nope" }), "unknown key");
    await reject("not-a-jwt", "malformed token");
    await reject("a.b.c", "malformed token");
    // A tampered payload under a valid signature.
    const [h, , s] = (await sign()).split(".");
    await reject(`${h}.${part({ iss: APPLE_ISSUER, aud: APP_BUNDLE_ID, exp: 9e9, sub: "x" })}.${s}`, "bad signature");
  });
});

describe("POST /v1/auth/apple", () => {
  it("mints a session token that works as a bearer and keys usage per Apple user", async () => {
    mockAppleKeys();
    const res = await exchange(await sign({ sub: "001234.synthetic.0002" }));
    expect(res.status).toBe(201);
    const first = (await res.json()) as { token: string; user_id: string; email: string };
    expect(first.token).toMatch(/^mcs_/);
    expect(first.email).toBe("user@example.test");

    // Second device, later sign-in without the email claim: same user, email kept, separate session.
    const again = (await (await exchange(await sign({ sub: "001234.synthetic.0002", email: undefined }))).json()) as typeof first;
    expect(again.user_id).toBe(first.user_id);
    expect(again.email).toBe("user@example.test");
    expect(again.token).not.toBe(first.token);
    vi.restoreAllMocks();

    expect((await usage(first.token)).status).toBe(200);
    expect((await usage(again.token)).status).toBe(200);
    const stored = await env.DB.prepare("SELECT token_hash FROM sessions WHERE user_id = ?").bind(first.user_id).all();
    // Only the hash is stored.
    expect(stored.results.map((r) => r.token_hash)).toContain(await sha256Hex(first.token));
  });

  it("rejects missing and invalid identity tokens without creating users", async () => {
    mockAppleKeys();
    expect((await exchange(undefined)).status).toBe(400);
    expect((await exchange("bogus")).status).toBe(401);
    expect((await exchange(await sign({ aud: "com.example.other", sub: "001234.synthetic.0003" }))).status).toBe(401);
    const row = await env.DB.prepare("SELECT 1 FROM users WHERE apple_sub = ?").bind("001234.synthetic.0003").first();
    expect(row).toBeNull();
  });

  it("invite tokens keep working next to session tokens", async () => {
    const { token } = await createInvite(env, "legacy");
    expect((await usage(token)).status).toBe(200);
    expect((await usage("mcs_unknown")).status).toBe(401);
  });

  it("admin lists users with usage and blocking ends existing sessions and sign-in", async () => {
    mockAppleKeys();
    const sub = "001234.synthetic.0004";
    const { token, user_id } = (await (await exchange(await sign({ sub }))).json()) as { token: string; user_id: string };
    vi.restoreAllMocks();

    expect((await exports.default.fetch(`${BASE}/admin/users`)).status).toBe(401);
    const list = (await (await admin("/admin/users")).json()) as { users: { id: string; email: string; month_usd: number }[] };
    expect(list.users.find((u) => u.id === user_id)).toMatchObject({ email: "user@example.test", month_usd: 0 });

    expect((await admin(`/admin/users/${user_id}/block`, "POST")).status).toBe(200);
    expect((await usage(token)).status).toBe(401);
    mockAppleKeys();
    expect((await exchange(await sign({ sub }))).status).toBe(403);
    vi.restoreAllMocks();

    expect((await admin(`/admin/users/${user_id}/unblock`, "POST")).status).toBe(200);
    expect((await usage(token)).status).toBe(200);
    expect((await admin("/admin/users/missing/block", "POST")).status).toBe(404);
  });
});
