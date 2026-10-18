-- Typical Talk, D1 schema.
--
-- Deliberately small: identity, the two ways to add a friend, and the talks
-- and takes that follow. Transcripts are absent on purpose, because they are
-- produced and kept on the phone.

CREATE TABLE IF NOT EXISTS users (
  id            TEXT PRIMARY KEY,           -- our id, not Apple's
  apple_user_id TEXT NOT NULL UNIQUE,       -- stable identifier from Apple
  name          TEXT NOT NULL,
  email         TEXT,
  created_at    INTEGER NOT NULL,
  apple_refresh_token TEXT,                 -- to revoke at deletion
  is_seed       INTEGER NOT NULL DEFAULT 0
);

-- Handles are how someone finds you on purpose: unique, lower case, and
-- changeable. Stored separately from users so the uniqueness constraint is
-- about the handle rather than the person.
CREATE TABLE IF NOT EXISTS handles (
  handle     TEXT PRIMARY KEY,              -- lower case, no @
  user_id    TEXT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL
);

-- An invite link. Single use by default, so a forwarded link cannot keep
-- adding strangers.
CREATE TABLE IF NOT EXISTS invites (
  code        TEXT PRIMARY KEY,
  inviter_id  TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  INTEGER NOT NULL,
  expires_at  INTEGER NOT NULL,
  redeemed_by TEXT REFERENCES users(id),
  redeemed_at INTEGER
);

CREATE TABLE IF NOT EXISTS talks (
  id         TEXT PRIMARY KEY,
  title      TEXT,                          -- null for one to one: name comes from the other member
  created_at INTEGER NOT NULL,
  created_by TEXT                           -- who made a group
);

CREATE TABLE IF NOT EXISTS members (
  talk_id   TEXT NOT NULL REFERENCES talks(id) ON DELETE CASCADE,
  user_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  joined_at INTEGER NOT NULL,
  PRIMARY KEY (talk_id, user_id)
);
CREATE INDEX IF NOT EXISTS members_by_user ON members(user_id);

CREATE TABLE IF NOT EXISTS takes (
  id          TEXT PRIMARY KEY,
  talk_id     TEXT NOT NULL REFERENCES talks(id) ON DELETE CASCADE,
  author_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  storage_key TEXT NOT NULL,                -- object key in R2
  duration    REAL NOT NULL DEFAULT 0,
  voice_only  INTEGER NOT NULL DEFAULT 0,
  sent_at     INTEGER,                      -- null until the upload completes
  created_at  INTEGER NOT NULL,
  expired_at  INTEGER                       -- file deleted at this time
);
CREATE INDEX IF NOT EXISTS takes_by_talk ON takes(talk_id, sent_at);

-- Who has watched what, so a receipt survives reinstalling the app.
CREATE TABLE IF NOT EXISTS watches (
  take_id    TEXT NOT NULL REFERENCES takes(id) ON DELETE CASCADE,
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  watched_at INTEGER NOT NULL,
  PRIMARY KEY (take_id, user_id)
);

-- Counters for rate limiting, one row per actor per window. Cheap to write,
-- and old rows are deleted as they are read.
CREATE TABLE IF NOT EXISTS rate_limits (
  bucket     TEXT PRIMARY KEY,   -- action + actor + window
  hits       INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

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
