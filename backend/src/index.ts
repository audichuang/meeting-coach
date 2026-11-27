import { authenticate, createInvite, isAdmin, type Caller } from "./auth";
import type { Env } from "./env";
import {
  LIVE_TRANSCRIBE_MODEL, RESPONSE_MODELS, TRANSCRIBE_MODEL,
  realtimeSessionEstimateUSD, responseCostUSD, transcribeCostUSD, transcribeSeconds,
} from "./pricing";
import { allowRate, read, record } from "./usage";

const OPENAI = "https://api.openai.com/v1";

// Mirrors the App's `OpenAILiveTranscriber.sessionUpdate`.
const TRANSCRIPTION_SESSION = {
  type: "transcription",
  audio: {
    input: {
      format: { type: "audio/pcm", rate: 24000 },
      transcription: {
        model: LIVE_TRANSCRIBE_MODEL,
        languages: ["zh-tw"],
        prompt: "台灣華語的產品會議，夾雜英文術語。請用繁體中文輸出。",
      },
      turn_detection: null,
    },
  },
};

// Anything else (previous_response_id, conversation, store=true, stream,
// background, service_tier, prompt, include...) is rejected: all users share
// one OpenAI key, so stored responses would be readable across users.
const RESPONSE_KEYS = new Set([
  "model", "instructions", "input", "reasoning", "tools", "tool_choice",
  "max_output_tokens", "text", "temperature", "top_p", "parallel_tool_calls", "truncation", "store",
]);

// The App uploads 300 s chunks of mono AAC at 64 kbps at most (about 2.4 MB);
// the headroom covers AudioChunker's AppleM4A re-encode fallback.
export const MAX_AUDIO_BYTES = 8 * 1024 * 1024;
// `json` only: its body carries the `usage` we bill from.
const TRANSCRIBE_TEXT_FIELDS = new Set(["model", "prompt", "language", "response_format", "temperature"]);

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status });
}

function error(status: number, message: string): Response {
  return json({ error: { message } }, status);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const route = `${request.method} ${url.pathname}`;

    if (url.pathname.startsWith("/admin/")) {
      if (!(await isAdmin(request, env))) return error(401, "unauthorized");
      return admin(request, env, route);
    }
    if (!url.pathname.startsWith("/v1/")) return error(404, "not found");

    const caller = await authenticate(request, env);
    if (!caller) return error(401, "unauthorized");
    if (!(await allowRate(env, caller.id, Number(env.RATE_LIMIT_PER_MINUTE)))) {
      return error(429, "rate limit exceeded");
    }

    switch (route) {
      case "GET /v1/usage":
        return usage(env, caller);
      case "POST /v1/realtime/session":
        return (await overCap(env, caller)) ?? realtimeSession(env, caller);
      case "POST /v1/responses":
        return responses(request, env, caller);
      case "POST /v1/audio/transcriptions":
        return transcriptions(request, env, caller);
      default:
        return error(404, "not found");
    }
  },
} satisfies ExportedHandler<Env>;

async function admin(request: Request, env: Env, route: string): Promise<Response> {
  if (route === "POST /admin/invites") {
    const body = (await request.json().catch(() => ({}))) as { label?: unknown };
    const label = typeof body.label === "string" ? body.label.slice(0, 100) : null;
    return json(await createInvite(env, label), 201);
  }
  if (route === "GET /admin/invites") {
    const { results } = await env.DB.prepare(
      "SELECT id, label, created_at, revoked_at FROM invites ORDER BY created_at",
    ).all();
    return json({ invites: results });
  }
  const revoke = /^DELETE \/admin\/invites\/([\w-]+)$/.exec(route);
  if (revoke) {
    const { meta } = await env.DB.prepare("UPDATE invites SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL")
      .bind(Date.now(), revoke[1]).run();
    return meta.changes ? json({ revoked: revoke[1] }) : error(404, "not found");
  }
  return error(404, "not found");
}

async function usage(env: Env, caller: Caller): Promise<Response> {
  return json({
    ...(await read(env, caller.id)),
    monthly_cap_usd: Number(env.MONTHLY_CAP_USD),
    realtime_usd_is_estimate: true,
    realtime_session_est_minutes: Number(env.REALTIME_SESSION_EST_MINUTES),
  });
}

async function overCap(env: Env, caller: Caller): Promise<Response | null> {
  const { month } = await read(env, caller.id);
  return month.usd >= Number(env.MONTHLY_CAP_USD) ? error(402, "monthly spend cap reached") : null;
}

function openai(env: Env, path: string, body: unknown): Promise<Response> {
  return fetch(`${OPENAI}${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${env.OPENAI_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function realtimeSession(env: Env, caller: Caller): Promise<Response> {
  // The secret only gates opening sockets, and one secret can open several
  // sessions while valid, so keep it short; the App fetches one per (re)connect.
  const upstream = await openai(env, "/realtime/client_secrets", {
    expires_after: { anchor: "created_at", seconds: 60 },
    session: TRANSCRIPTION_SESSION,
  });
  const text = await upstream.text();
  if (upstream.ok) {
    await record(env, caller.id, realtimeSessionEstimateUSD(Number(env.REALTIME_SESSION_EST_MINUTES)), 1);
  }
  return new Response(text, { status: upstream.status, headers: { "Content-Type": "application/json" } });
}

async function responses(request: Request, env: Env, caller: Caller): Promise<Response> {
  const body = (await request.json().catch(() => null)) as Record<string, any> | null;
  if (!body || typeof body !== "object" || Array.isArray(body)) return error(400, "body must be a JSON object");

  const unknown = Object.keys(body).filter((k) => !RESPONSE_KEYS.has(k));
  if (unknown.length) return error(400, `unsupported parameters: ${unknown.join(", ")}`);
  if (!RESPONSE_MODELS.has(body.model)) return error(400, `model not allowed: ${String(body.model)}`);
  if (body.tools !== undefined &&
      (!Array.isArray(body.tools) || body.tools.some((t: any) => t?.type !== "function"))) {
    return error(400, "only function tools are allowed");
  }
  const cap = Number(env.MAX_OUTPUT_TOKENS);
  if (body.max_output_tokens !== undefined &&
      (!Number.isInteger(body.max_output_tokens) || body.max_output_tokens <= 0)) {
    return error(400, "max_output_tokens must be a positive integer");
  }
  body.max_output_tokens = Math.min(body.max_output_tokens ?? cap, cap);
  body.store = false;

  const capped = await overCap(env, caller);
  if (capped) return capped;

  const upstream = await openai(env, "/responses", body);
  const text = await upstream.text();
  if (upstream.ok) {
    let usage;
    try { usage = JSON.parse(text).usage; } catch { /* billed as zero below */ }
    if (usage) await record(env, caller.id, responseCostUSD(body.model, usage));
  }
  return new Response(text, { status: upstream.status, headers: { "Content-Type": "application/json" } });
}

async function transcriptions(request: Request, env: Env, caller: Caller): Promise<Response> {
  // Reject an oversized upload before buffering it; multipart overhead is small.
  if (Number(request.headers.get("Content-Length") ?? 0) > MAX_AUDIO_BYTES + 64 * 1024) {
    return error(413, "audio file too large");
  }
  const form = await request.formData().catch(() => null);
  if (!form) return error(400, "body must be multipart/form-data");

  const upstreamForm = new FormData();
  for (const [key, value] of form) {
    if (key === "file") continue;
    if (!TRANSCRIBE_TEXT_FIELDS.has(key) || typeof value !== "string") {
      return error(400, `unsupported parameter: ${key}`);
    }
    upstreamForm.append(key, value);
  }
  if (form.get("model") !== TRANSCRIBE_MODEL) return error(400, `model not allowed: ${String(form.get("model"))}`);
  const format = form.get("response_format");
  if (format !== null && format !== "json") return error(400, "response_format must be json");
  const file = form.get("file");
  if (!(file instanceof File) || file.size === 0) return error(400, "file is required");
  if (file.size > MAX_AUDIO_BYTES) return error(413, "audio file too large");
  upstreamForm.set("response_format", "json");
  upstreamForm.append("file", file, file.name);

  const capped = await overCap(env, caller);
  if (capped) return capped;

  const upstream = await fetch(`${OPENAI}/audio/transcriptions`, {
    method: "POST",
    headers: { Authorization: `Bearer ${env.OPENAI_API_KEY}` },
    body: upstreamForm,
  });
  const text = await upstream.text();
  if (upstream.ok) {
    let usage;
    try { usage = JSON.parse(text).usage; } catch { /* billed from the file size below */ }
    await record(env, caller.id, transcribeCostUSD(transcribeSeconds(usage, file.size)));
  }
  return new Response(text, { status: upstream.status, headers: { "Content-Type": "application/json" } });
}
