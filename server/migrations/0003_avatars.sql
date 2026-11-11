-- Profile photos. The image lives in R2 at avatars/<user id>.jpg; this is the
-- version other phones compare to know when to fetch a new one.
ALTER TABLE users ADD COLUMN avatar_version INTEGER;
