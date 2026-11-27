// All prices in one place. Source: https://developers.openai.com/api/docs/pricing
// (checked 2026-11-27). USD per 1M tokens; output includes reasoning tokens.
export const TOKEN_RATES: Record<string, { input: number; cached: number; output: number }> = {
  "gpt-6-luna": { input: 0.1, cached: 0.01, output: 0.5 },
  "gpt-6.1-terra": { input: 1, cached: 0.05, output: 5 },
};

/** The only models /v1/responses forwards. */
export const RESPONSE_MODELS = new Set(Object.keys(TOKEN_RATES));

export const LIVE_TRANSCRIBE_MODEL = "gpt-live-transcribe";
/** USD per audio minute. */
export const LIVE_TRANSCRIBE_PER_MINUTE = 0.017;

export interface ResponseUsage {
  input_tokens?: number;
  output_tokens?: number;
  input_tokens_details?: { cached_tokens?: number };
}

export function responseCostUSD(model: string, usage: ResponseUsage): number {
  const rates = TOKEN_RATES[model];
  if (!rates) return 0;
  const input = usage.input_tokens ?? 0;
  const cached = Math.min(usage.input_tokens_details?.cached_tokens ?? 0, input);
  const output = usage.output_tokens ?? 0;
  return ((input - cached) * rates.input + cached * rates.cached + output * rates.output) / 1_000_000;
}

// shortcut: the Worker never sees the audio, so each minted realtime session is
// billed as a flat ESTIMATE of `minutes` audio minutes. Flaky networks
// (many reconnects) overcount; one long session undercounts. Upgrade by having
// the App report OpenAI's billed seconds, or by metering through a relay.
export function realtimeSessionEstimateUSD(minutes: number): number {
  return minutes * LIVE_TRANSCRIBE_PER_MINUTE;
}
