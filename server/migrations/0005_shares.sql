-- Takes sent through the Messages app. Each is reachable by an unguessable
-- code; opening one in the app files it into a one to one talk between the
-- sender and whoever opened it.
CREATE TABLE IF NOT EXISTS shares (
  id          TEXT PRIMARY KEY,
  code        TEXT NOT NULL UNIQUE,
  author_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  storage_key TEXT NOT NULL,
  duration    REAL NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL,
  expired_at  INTEGER
);

-- Who has opened which share, and the take it became for them, so opening it
-- twice does not file it twice.
CREATE TABLE IF NOT EXISTS share_opens (
  share_id TEXT NOT NULL REFERENCES shares(id) ON DELETE CASCADE,
  user_id  TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  talk_id  TEXT NOT NULL,
  take_id  TEXT NOT NULL,
  PRIMARY KEY (share_id, user_id)
);
