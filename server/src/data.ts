/** Small queries that several handlers share. */

import { Env, TAKE_LIFETIME_MS } from "./common";

export async function isMember(talkID: string, userID: string, env: Env): Promise<boolean> {
  const row = await env.DB.prepare("SELECT 1 AS present FROM members WHERE talk_id = ? AND user_id = ?")
    .bind(talkID, userID)
    .first();
  return row != null;
}

/** True when either person has blocked the other. */
export async function blockedBetween(a: string, b: string, env: Env): Promise<boolean> {
  const row = await env.DB.prepare(
    `SELECT 1 AS blocked FROM blocks
     WHERE (blocker_id = ?1 AND blocked_id = ?2) OR (blocker_id = ?2 AND blocked_id = ?1)`
  )
    .bind(a, b)
    .first();
  return row != null;
}

/** True when the two share at least one talk, which is what "friends" means here. */
export async function connected(a: string, b: string, env: Env): Promise<boolean> {
  const row = await env.DB.prepare(
    `SELECT 1 AS shared FROM members x JOIN members y ON x.talk_id = y.talk_id
     WHERE x.user_id = ?1 AND y.user_id = ?2 LIMIT 1`
  )
    .bind(a, b)
    .first();
  return row != null;
}

export async function memberCount(talkID: string, env: Env): Promise<number> {
  const row = await env.DB.prepare("SELECT COUNT(*) AS n FROM members WHERE talk_id = ?")
    .bind(talkID)
    .first<{ n: number }>();
  return row?.n ?? 0;
}

/** R2 deletes at most 1000 keys per call. */
export async function deleteFiles(env: Env, keys: string[]): Promise<void> {
  for (let i = 0; i < keys.length; i += 1000) {
    await env.TAKES.delete(keys.slice(i, i + 1000));
  }
}

/** Removes a talk, its takes and their files. Used once nobody is left in it. */
export async function destroyTalk(env: Env, talkID: string): Promise<void> {
  const files = await env.DB.prepare("SELECT storage_key FROM takes WHERE talk_id = ?")
    .bind(talkID)
    .all<{ storage_key: string }>();
  await deleteFiles(env, files.results.map((row) => row.storage_key));
  await env.DB.prepare("DELETE FROM talks WHERE id = ?").bind(talkID).run();
}

/**
 * Deletes a person and everything of theirs: the files they recorded, their
 * place in every talk, and any talk that nobody else is in.
 */
export async function eraseUser(env: Env, userID: string): Promise<void> {
  const mine = await env.DB.prepare("SELECT storage_key FROM takes WHERE author_id = ?")
    .bind(userID)
    .all<{ storage_key: string }>();
  await deleteFiles(env, mine.results.map((row) => row.storage_key));

  const talks = await env.DB.prepare("SELECT talk_id FROM members WHERE user_id = ?")
    .bind(userID)
    .all<{ talk_id: string }>();
  for (const { talk_id } of talks.results) {
    const others = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM members WHERE talk_id = ? AND user_id != ?"
    )
      .bind(talk_id, userID)
      .first<{ n: number }>();
    if ((others?.n ?? 0) === 0) await destroyTalk(env, talk_id);
  }

  await env.DB.batch([
    // The only reference to a user that does not cascade.
    env.DB.prepare("DELETE FROM invites WHERE redeemed_by = ?").bind(userID),
    env.DB.prepare("DELETE FROM users WHERE id = ?").bind(userID),
  ]);
}

/** Deletes files past their lifetime and marks the takes as expired. */
export async function expireOldTakes(env: Env, nowMs: number): Promise<number> {
  const cutoff = nowMs - TAKE_LIFETIME_MS;
  let expired = 0;
  for (let round = 0; round < 10; round++) {
    const batch = await env.DB.prepare(
      "SELECT id, storage_key FROM takes WHERE sent_at < ? AND expired_at IS NULL LIMIT 200"
    )
      .bind(cutoff)
      .all<{ id: string; storage_key: string }>();
    if (batch.results.length === 0) break;

    await deleteFiles(env, batch.results.map((row) => row.storage_key));
    await env.DB.batch(
      batch.results.map((row) =>
        env.DB.prepare("UPDATE takes SET expired_at = ? WHERE id = ?").bind(nowMs, row.id)
      )
    );
    expired += batch.results.length;
  }
  return expired;
}
