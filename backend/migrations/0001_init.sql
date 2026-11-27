-- Invite tokens are stored only as SHA-256 hex; the plaintext is shown once at creation.
CREATE TABLE invites (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  label TEXT,
  created_at INTEGER NOT NULL,
  revoked_at INTEGER
);

-- period is 'YYYY-MM' (month) or 'YYYY-MM-DD' (day), UTC.
CREATE TABLE usage (
  user_id TEXT NOT NULL,
  period TEXT NOT NULL,
  usd REAL NOT NULL DEFAULT 0,
  requests INTEGER NOT NULL DEFAULT 0,
  realtime_sessions INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, period)
);

-- minute is unix time / 60.
CREATE TABLE rate (
  user_id TEXT NOT NULL,
  minute INTEGER NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (user_id, minute)
);
