import { env, exports } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createInvite } from "../src/auth";
import { responseCostUSD } from "../src/pricing";

const E = env;
const BASE = "https://worker.test";

// Same shape the App's CoachResponsesClient sends.
const appBody = (model = "gpt-6-luna") => ({
  model,
  instructions: "judge",
  input: "synthetic transcript",
  reasoning: { effort: "low" },
  tools: [{ type: "function", name: "emit", description: "d", parameters: { type: "object", properties: {} } }],
  tool_choice: { type: "function", name: "emit" },
});

function mockOpenAI(body: unknown, status = 200) {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async () => Response.json(body, { status }));
}

async function call(token: string, path: string, body?: unknown) {
  return exports.default.fetch(`${BASE}${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

afterEach(() => vi.restoreAllMocks());

describe("auth", () => {
  it("rejects missing, unknown and revoked tokens with 401", async () => {
    expect((await exports.default.fetch(`${BASE}/v1/usage`)).status).toBe(401);
    expect((await call("mc_nope", "/v1/usage")).status).toBe(401);

    const { id, token } = await createInvite(E, "t");
    expect((await call(token, "/v1/usage")).status).toBe(200);
    const revoke = await exports.default.fetch(`${BASE}/admin/invites/${id}`, {
      method: "DELETE", headers: { Authorization: `Bearer ${E.ADMIN_SECRET}` },
    });
    expect(revoke.status).toBe(200);
    expect((await call(token, "/v1/usage")).status).toBe(401);
  });

  it("admin endpoints need the admin secret and issue working tokens", async () => {
    expect((await call("wrong", "/admin/invites", {})).status).toBe(401);
    const res = await call(E.ADMIN_SECRET, "/admin/invites", { label: "family" });
    expect(res.status).toBe(201);
    const { token } = (await res.json()) as { token: string };
    expect((await call(token, "/v1/usage")).status).toBe(200);
  });
});

describe("/v1/responses", () => {
  it("forwards whitelisted models with store=false and capped max_output_tokens", async () => {
    const { token } = await createInvite(E, null);
    const fetchSpy = mockOpenAI({ output: [], usage: { input_tokens: 10, output_tokens: 5 } });
    const res = await call(token, "/v1/responses", { ...appBody(), max_output_tokens: 999999 });
    expect(res.status).toBe(200);
    const sent = JSON.parse(fetchSpy.mock.calls[0][1]!.body as string);
    expect(sent.store).toBe(false);
    expect(sent.max_output_tokens).toBe(Number(E.MAX_OUTPUT_TOKENS));
    expect(sent.tool_choice).toEqual({ type: "function", name: "emit" });
    expect((fetchSpy.mock.calls[0][1]!.headers as Record<string, string>).Authorization).toBe("Bearer test-openai-key");
  });

  it("rejects non-whitelisted models, hosted tools and unsafe parameters", async () => {
    const { token } = await createInvite(E, null);
    const fetchSpy = mockOpenAI({});
    expect((await call(token, "/v1/responses", appBody("gpt-5-pro"))).status).toBe(400);
    expect((await call(token, "/v1/responses", { ...appBody(), tools: [{ type: "web_search" }] })).status).toBe(400);
    expect((await call(token, "/v1/responses", { ...appBody(), previous_response_id: "resp_x" })).status).toBe(400);
    expect((await call(token, "/v1/responses", { ...appBody(), stream: true })).status).toBe(400);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("passes upstream errors through without billing", async () => {
    const { token } = await createInvite(E, null);
    mockOpenAI({ error: { message: "bad" } }, 429);
    expect((await call(token, "/v1/responses", appBody())).status).toBe(429);
    vi.restoreAllMocks();
    const usage = (await (await call(token, "/v1/usage")).json()) as any;
    expect(usage.month.usd).toBe(0);
  });
});

describe("usage and caps", () => {
  it("accumulates daily and monthly spend from response usage and realtime estimates", async () => {
    const { token } = await createInvite(E, null);
    const usage = { input_tokens: 1000, input_tokens_details: { cached_tokens: 400 }, output_tokens: 200 };
    mockOpenAI({ output: [], usage });
    await call(token, "/v1/responses", appBody("gpt-6.1-terra"));
    await call(token, "/v1/responses", appBody("gpt-6.1-terra"));
    vi.restoreAllMocks();
    mockOpenAI({ value: "ek_test", expires_at: 1 });
    expect((await call(token, "/v1/realtime/session", {})).status).toBe(200);
    vi.restoreAllMocks();

    // (600*1 + 400*0.05 + 200*5) / 1e6 = 0.00162 per call
    expect(responseCostUSD("gpt-6.1-terra", usage)).toBeCloseTo(0.00162, 8);
    const realtime = Number(E.REALTIME_SESSION_EST_MINUTES) * 0.017;
    const body = (await (await call(token, "/v1/usage")).json()) as any;
    for (const p of [body.day, body.month]) {
      expect(p.usd).toBeCloseTo(2 * 0.00162 + realtime, 8);
      expect(p.requests).toBe(3);
      expect(p.realtime_sessions).toBe(1);
    }
    expect(body.realtime_usd_is_estimate).toBe(true);
  });

  it("returns 402 once the monthly cap is reached", async () => {
    const { id, token } = await createInvite(E, null);
    const month = new Date().toISOString().slice(0, 7);
    await E.DB.prepare("INSERT INTO usage (user_id, period, usd) VALUES (?, ?, ?)")
      .bind(id, month, Number(E.MONTHLY_CAP_USD)).run();
    const fetchSpy = mockOpenAI({});
    expect((await call(token, "/v1/responses", appBody())).status).toBe(402);
    expect((await call(token, "/v1/realtime/session", {})).status).toBe(402);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("returns 429 past the per-minute request limit", async () => {
    const { token } = await createInvite(E, null);
    const limit = Number(E.RATE_LIMIT_PER_MINUTE);
    for (let i = 0; i < limit; i++) expect((await call(token, "/v1/usage")).status).toBe(200);
    expect((await call(token, "/v1/usage")).status).toBe(429);
  });
});
