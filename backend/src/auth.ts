// Identity layer. Today: invite tokens. Swap `authenticate` for Sign in with
// Apple / StoreKit later; the rest of the Worker only needs a stable user id.
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

export async function authenticate(request: Request, env: Env): Promise<Caller | null> {
  const token = bearer(request);
  if (!token) return null;
  const row = await env.DB.prepare("SELECT id FROM invites WHERE token_hash = ? AND revoked_at IS NULL")
    .bind(await sha256Hex(token))
    .first<{ id: string }>();
  return row ? { id: row.id } : null;
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
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const token = "mc_" + btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const id = crypto.randomUUID();
  await env.DB.prepare("INSERT INTO invites (id, token_hash, label, created_at) VALUES (?, ?, ?, ?)")
    .bind(id, await sha256Hex(token), label, Date.now())
    .run();
  return { id, token };
}
