export interface Env {
  DB: D1Database;
  OPENAI_API_KEY: string;
  ADMIN_SECRET: string;
  MONTHLY_CAP_USD: string;
  RATE_LIMIT_PER_MINUTE: string;
  MAX_OUTPUT_TOKENS: string;
  REALTIME_SESSION_EST_MINUTES: string;
}
