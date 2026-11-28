-- Sign in with Apple users, keyed by the token's `sub`. `id` is what usage and rate rows key on.
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  apple_sub TEXT NOT NULL UNIQUE,
  email TEXT,
  created_at INTEGER NOT NULL,
  blocked_at INTEGER
);

-- One row per signed-in device; only the SHA-256 hex of the token is stored.
CREATE TABLE sessions (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users (id),
  created_at INTEGER NOT NULL
);
