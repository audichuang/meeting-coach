-- Sliding expiry: each authenticated request pushes expires_at out again. Nullable so a
-- Worker still on the previous version (or rolled back) can keep inserting sessions;
-- NULL counts as expired.
ALTER TABLE sessions ADD COLUMN expires_at INTEGER;
UPDATE sessions SET expires_at = created_at + 90 * 86400000;
