-- Sync, push, groups, blocking, reporting and account deletion.
-- Apply once to a database created from the first schema:
--   wrangler d1 execute typical-talk --remote --file=migrations/0002_sync.sql

ALTER TABLE users ADD COLUMN apple_refresh_token TEXT;   -- to revoke at deletion
ALTER TABLE users ADD COLUMN is_seed INTEGER NOT NULL DEFAULT 0;
ALTER TABLE talks ADD COLUMN created_by TEXT;            -- who made a group
ALTER TABLE takes ADD COLUMN expired_at INTEGER;         -- file deleted at this time

-- Phones that can be pushed to.
CREATE TABLE IF NOT EXISTS devices (
  token       TEXT PRIMARY KEY,                -- APNs device token, hex
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  environment TEXT NOT NULL,                   -- sandbox or production
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS devices_by_user ON devices(user_id);

CREATE TABLE IF NOT EXISTS blocks (
  blocker_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  blocked_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (blocker_id, blocked_id)
);
CREATE INDEX IF NOT EXISTS blocks_by_blocked ON blocks(blocked_id);

-- Deliberately no foreign keys: a report is evidence and has to outlive the
-- take, the person reported, and the person who filed it.
CREATE TABLE IF NOT EXISTS reports (
  id               TEXT PRIMARY KEY,
  reporter_id      TEXT NOT NULL,
  take_id          TEXT,
  reported_user_id TEXT,
  reason           TEXT NOT NULL,
  details          TEXT,
  created_at       INTEGER NOT NULL,
  handled_at       INTEGER
);
CREATE INDEX IF NOT EXISTS reports_by_reporter ON reports(reporter_id, take_id);
CREATE INDEX IF NOT EXISTS reports_open ON reports(handled_at, created_at);

-- Apple accounts that have been removed for abuse and cannot sign up again.
CREATE TABLE IF NOT EXISTS bans (
  apple_user_id TEXT PRIMARY KEY,
  reason        TEXT,
  created_at    INTEGER NOT NULL
);
