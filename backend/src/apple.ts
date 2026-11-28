// Verifies Sign in with Apple identity tokens (RS256 JWTs signed by Apple's published keys).

export const APPLE_ISSUER = "https://appleid.apple.com";
export const APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys";
export const APP_BUNDLE_ID = "com.audichuang.meetingcoach";

export interface AppleIdentity {
  sub: string;
  email: string | null;
}

export class AppleTokenError extends Error {}

const KEYS_TTL_MS = 60 * 60 * 1000;
let keys: { fetchedAt: number; byKid: Map<string, CryptoKey> } | null = null;

async function fetchKeys(): Promise<Map<string, CryptoKey>> {
  const res = await fetch(APPLE_KEYS_URL);
  if (!res.ok) throw new Error(`Apple keys: HTTP ${res.status}`);
  const { keys: jwks } = (await res.json()) as { keys: (JsonWebKey & { kid: string })[] };
  const byKid = new Map<string, CryptoKey>();
  for (const jwk of jwks) {
    byKid.set(jwk.kid, await crypto.subtle.importKey(
      "jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]));
  }
  keys = { fetchedAt: Date.now(), byKid };
  return byKid;
}

async function keyFor(kid: string): Promise<CryptoKey | undefined> {
  const age = keys ? Date.now() - keys.fetchedAt : Infinity;
  // Apple rotates keys: an unseen kid refetches, at most once a minute so junk tokens cannot hammer Apple.
  if (keys && age < KEYS_TTL_MS && (keys.byKid.has(kid) || age < 60_000)) return keys.byKid.get(kid);
  return (await fetchKeys()).get(kid);
}

function b64urlBytes(part: string): Uint8Array {
  const bin = atob(part.replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

function b64urlJSON(part: string): any {
  return JSON.parse(new TextDecoder().decode(b64urlBytes(part)));
}

export async function verifyAppleIdentityToken(token: string, now = Date.now()): Promise<AppleIdentity> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new AppleTokenError("malformed token");
  let header: any, claims: any, signature: Uint8Array;
  try {
    header = b64urlJSON(parts[0]);
    claims = b64urlJSON(parts[1]);
    signature = b64urlBytes(parts[2]);
  } catch {
    throw new AppleTokenError("malformed token");
  }
  if (header?.alg !== "RS256" || typeof header.kid !== "string") throw new AppleTokenError("unsupported key");
  const key = await keyFor(header.kid);
  if (!key) throw new AppleTokenError("unknown key");
  const signed = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  if (!(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, signed))) {
    throw new AppleTokenError("bad signature");
  }
  if (claims?.iss !== APPLE_ISSUER) throw new AppleTokenError("wrong issuer");
  const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!aud.includes(APP_BUNDLE_ID)) throw new AppleTokenError("wrong audience");
  if (typeof claims.exp !== "number" || claims.exp * 1000 <= now) throw new AppleTokenError("expired");
  if (typeof claims.sub !== "string" || !claims.sub) throw new AppleTokenError("missing subject");
  return { sub: claims.sub, email: typeof claims.email === "string" ? claims.email : null };
}
