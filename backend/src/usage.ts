import type { Env } from "./env";

export interface PeriodUsage {
  usd: number;
  requests: number;
  realtime_sessions: number;
}

export function periods(now = new Date()): { day: string; month: string } {
  const day = now.toISOString().slice(0, 10);
  return { day, month: day.slice(0, 7) };
}

export async function record(env: Env, userId: string, usd: number, realtimeSessions = 0): Promise<void> {
  const { day, month } = periods();
  const stmt = env.DB.prepare(
    `INSERT INTO usage (user_id, period, usd, requests, realtime_sessions) VALUES (?, ?, ?, 1, ?)
     ON CONFLICT (user_id, period) DO UPDATE SET usd = usd + excluded.usd,
       requests = requests + 1, realtime_sessions = realtime_sessions + excluded.realtime_sessions`,
  );
  await env.DB.batch([day, month].map((p) => stmt.bind(userId, p, usd, realtimeSessions)));
}

export async function read(env: Env, userId: string): Promise<{ day: PeriodUsage; month: PeriodUsage }> {
  const { day, month } = periods();
  const { results } = await env.DB.prepare(
    "SELECT period, usd, requests, realtime_sessions FROM usage WHERE user_id = ? AND period IN (?, ?)",
  ).bind(userId, day, month).all<PeriodUsage & { period: string }>();
  const pick = (p: string): PeriodUsage => {
    const r = results.find((x) => x.period === p);
    return { usd: r?.usd ?? 0, requests: r?.requests ?? 0, realtime_sessions: r?.realtime_sessions ?? 0 };
  };
  return { day: pick(day), month: pick(month) };
}

/** Counts this request and returns false once the per-minute limit is exceeded. */
export async function allowRate(env: Env, userId: string, limit: number): Promise<boolean> {
  const minute = Math.floor(Date.now() / 60_000);
  const [, upsert] = await env.DB.batch<{ count: number }>([
    env.DB.prepare("DELETE FROM rate WHERE user_id = ? AND minute < ?").bind(userId, minute),
    env.DB.prepare(
      `INSERT INTO rate (user_id, minute, count) VALUES (?, ?, 1)
       ON CONFLICT (user_id, minute) DO UPDATE SET count = count + 1 RETURNING count`,
    ).bind(userId, minute),
  ]);
  return (upsert.results[0]?.count ?? 0) <= limit;
}
