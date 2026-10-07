CREATE TABLE IF NOT EXISTS installations (
  key_id TEXT PRIMARY KEY,
  public_key TEXT NOT NULL,
  receipt TEXT NOT NULL,
  sign_count INTEGER NOT NULL DEFAULT 0,
  revoked INTEGER NOT NULL DEFAULT 0 CHECK(revoked IN (0,1)),
  created_at INTEGER NOT NULL,
  last_seen INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS challenges (
  challenge TEXT PRIMARY KEY,
  key_id TEXT NOT NULL,
  purpose TEXT NOT NULL CHECK(purpose IN ('register','session')),
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS challenges_expiry ON challenges(expires_at);
