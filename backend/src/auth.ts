// Identity layer: Worker session tokens minted after Sign in with Apple, plus the
// older invite tokens build 1 still sends. The rest of the Worker only needs a stable user id.
import type { AppleIdentity } from "./apple";
import type { Env } from "./env";

export interface Caller {
  id: string;
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function bearer(request: Request): string | null {
  const match = /^Bearer (.+)$/.exec(request.headers.get("Authorization") ?? "");
  return match ? match[1] : null;
}

/** A session left unused this long stops working; every authenticated request extends it. */
export const SESSION_TTL_MS = 90 * 86_400_000;

export async function authenticate(request: Request, env: Env): Promise<Caller | null> {
  const token = bearer(request);
  if (!token) return null;
  const hash = await sha256Hex(token);
  const now = Date.now();
  const session = await env.DB.prepare(
    `UPDATE sessions SET expires_at = ?2 WHERE token_hash = ?1 AND expires_at > ?3
       AND user_id IN (SELECT id FROM users WHERE blocked_at IS NULL) RETURNING user_id`,
  ).bind(hash, now + SESSION_TTL_MS, now).first<{ user_id: string }>();
  if (session) return { id: session.user_id };
  const invite = await env.DB.prepare("SELECT id FROM invites WHERE token_hash = ? AND revoked_at IS NULL")
    .bind(hash).first<{ id: string }>();
  return invite ? { id: invite.id } : null;
}

/** Ends the bearer's session. An invite token has no session, so this leaves it working. */
export async function signOut(request: Request, env: Env): Promise<void> {
  const token = bearer(request);
  if (!token) return;
  await env.DB.prepare("DELETE FROM sessions WHERE token_hash = ?").bind(await sha256Hex(token)).run();
}

export type SignInResult = { token: string; user_id: string; email: string | null } | "blocked";

/** Upserts the Apple user and mints a new session token for this device. */
export async function signInWithApple(env: Env, identity: AppleIdentity): Promise<SignInResult> {
  const user = await env.DB.prepare(
    `INSERT INTO users (id, apple_sub, email, created_at) VALUES (?, ?, ?, ?)
     ON CONFLICT (apple_sub) DO UPDATE SET email = COALESCE(excluded.email, users.email)
     RETURNING id, email, blocked_at`,
  ).bind(crypto.randomUUID(), identity.sub, identity.email, Date.now())
    .first<{ id: string; email: string | null; blocked_at: number | null }>();
  if (!user || user.blocked_at !== null) return "blocked";
  const token = newToken("mcs_");
  const now = Date.now();
  await env.DB.prepare("INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)")
    .bind(await sha256Hex(token), user.id, now, now + SESSION_TTL_MS).run();
  return { token, user_id: user.id, email: user.email };
}

function newToken(prefix: string): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return prefix + btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function isAdmin(request: Request, env: Env): Promise<boolean> {
  const token = bearer(request);
  if (!token || !env.ADMIN_SECRET) return false;
  // Compare digests so lengths always match for timingSafeEqual.
  const [a, b] = await Promise.all([token, env.ADMIN_SECRET].map(async (s) =>
    crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))));
  return crypto.subtle.timingSafeEqual(a, b);
}

export async function createInvite(env: Env, label: string | null): Promise<{ id: string; token: string }> {
  const token = newToken("mc_");
  const id = crypto.randomUUID();
  await env.DB.prepare("INSERT INTO invites (id, token_hash, label, created_at) VALUES (?, ?, ?, ?)")
    .bind(id, await sha256Hex(token), label, Date.now())
    .run();
  return { id, token };
}
