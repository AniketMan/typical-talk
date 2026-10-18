/**
 * Blocking, reporting, deleting an account, and the small admin surface that
 * lets a report be acted on.
 *
 * App Review expects user generated content to have a way to report it, a way
 * to block its author, and a developer who can remove either quickly.
 */

import { Env, User, fail, json, newID, now, readJSON, tooMany, withinLimit } from "./common";
import { exchangeAuthorizationCode, revokeRefreshToken } from "./apple";
import { deleteFiles, eraseUser, isMember } from "./data";
import { checkDetails, checkID, checkReportReason } from "./validate";

// MARK: - Blocking

export async function listBlocks(env: Env, user: User): Promise<Response> {
  const rows = await env.DB.prepare(
    `SELECT users.id, users.name FROM blocks JOIN users ON users.id = blocks.blocked_id
     WHERE blocks.blocker_id = ? ORDER BY blocks.created_at DESC`
  )
    .bind(user.id)
    .all<{ id: string; name: string }>();
  return json({ blocked: rows.results });
}

export async function blockUser(request: Request, env: Env, user: User): Promise<Response> {
  if (!(await withinLimit(env, "block", user.id, 30, 3_600_000))) return tooMany();
  const body = await readJSON<{ userID?: string }>(request);
  const checked = checkID(body?.userID);
  if (!checked.value) return fail(400, "Say who to block.");
  if (checked.value === user.id) return fail(400, "That is you.");

  // Answer the same whether or not the person exists, so ids cannot be probed.
  const target = await env.DB.prepare("SELECT id FROM users WHERE id = ?").bind(checked.value).first();
  if (target) {
    await env.DB.prepare(
      "INSERT OR IGNORE INTO blocks (blocker_id, blocked_id, created_at) VALUES (?, ?, ?)"
    )
      .bind(user.id, checked.value, now())
      .run();
  }
  return json({ ok: true });
}

export async function unblockUser(rawID: string, env: Env, user: User): Promise<Response> {
  const checked = checkID(rawID);
  if (!checked.value) return fail(404, "No such person.");
  await env.DB.prepare("DELETE FROM blocks WHERE blocker_id = ? AND blocked_id = ?")
    .bind(user.id, checked.value)
    .run();
  return json({ ok: true });
}

// MARK: - Reporting

export async function fileReport(request: Request, env: Env, user: User): Promise<Response> {
  if (!(await withinLimit(env, "report", user.id, 20, 3_600_000))) return tooMany();
  const body = await readJSON<{
    takeID?: string;
    userID?: string;
    reason?: string;
    details?: string;
  }>(request);
  if (!body) return fail(400, "Send the report as JSON.");

  const reason = checkReportReason(body.reason);
  if (!reason.value) return fail(400, reason.error!);

  let takeID: string | null = null;
  let reportedUser: string | null = null;

  if (body.takeID !== undefined) {
    const checked = checkID(body.takeID);
    if (!checked.value) return fail(400, "That take could not be found.");
    const take = await env.DB.prepare("SELECT talk_id, author_id FROM takes WHERE id = ?")
      .bind(checked.value)
      .first<{ talk_id: string; author_id: string }>();
    // Only someone who can see a take can report it.
    if (!take || !(await isMember(take.talk_id, user.id, env))) {
      return fail(404, "That take could not be found.");
    }
    takeID = checked.value;
    reportedUser = take.author_id;
  } else if (body.userID !== undefined) {
    const checked = checkID(body.userID);
    if (!checked.value) return fail(400, "That person could not be found.");
    reportedUser = checked.value;
  } else {
    return fail(400, "Say what you are reporting.");
  }

  await env.DB.prepare(
    `INSERT INTO reports (id, reporter_id, take_id, reported_user_id, reason, details, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`
  )
    .bind(newID(), user.id, takeID, reportedUser, reason.value, checkDetails(body.details), now())
    .run();
  return json({ ok: true });
}

// MARK: - Deleting your account

export async function deleteAccount(
  request: Request,
  env: Env,
  user: User
): Promise<Response> {
  if (!(await withinLimit(env, "delete", user.id, 5, 3_600_000))) return tooMany();
  const body = await readJSON<{ authorizationCode?: string }>(request);

  // Apple asks that deleting an account also revokes the Sign in with Apple
  // link. A fresh code from the person confirming works for everyone; the
  // stored refresh token covers accounts that have signed in since.
  const row = await env.DB.prepare("SELECT apple_refresh_token FROM users WHERE id = ?")
    .bind(user.id)
    .first<{ apple_refresh_token: string | null }>();
  let refreshToken = row?.apple_refresh_token ?? null;
  if (typeof body?.authorizationCode === "string" && body.authorizationCode) {
    refreshToken = (await exchangeAuthorizationCode(env, body.authorizationCode)) ?? refreshToken;
  }
  if (refreshToken) await revokeRefreshToken(env, refreshToken);

  await eraseUser(env, user.id);
  return json({ ok: true });
}

// MARK: - Admin

/** Constant time, so the token cannot be recovered by timing. */
function sameToken(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let differing = 0;
  for (let i = 0; i < a.length; i++) differing |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return differing === 0;
}

/**
 * Handles /admin/*. Answers 404 when no admin token is configured, so the
 * surface does not exist until it is switched on.
 */
export async function admin(
  request: Request,
  path: string,
  env: Env & { ADMIN_TOKEN?: string }
): Promise<Response> {
  const header = request.headers.get("authorization") ?? "";
  if (!env.ADMIN_TOKEN || !header.startsWith("Bearer ") || !sameToken(header.slice(7), env.ADMIN_TOKEN)) {
    return fail(404, "No such endpoint.");
  }

  if (request.method === "GET" && path === "/admin/reports") {
    const rows = await env.DB.prepare(
      `SELECT id, reporter_id, take_id, reported_user_id, reason, details, created_at
       FROM reports WHERE handled_at IS NULL ORDER BY created_at ASC LIMIT 100`
    ).all();
    return json({ reports: rows.results });
  }

  const handled = path.match(/^\/admin\/reports\/([0-9a-f-]{36})\/handled$/);
  if (request.method === "POST" && handled) {
    await env.DB.prepare("UPDATE reports SET handled_at = ? WHERE id = ?").bind(now(), handled[1]).run();
    return json({ ok: true });
  }

  // Removes one take and its file, leaving the person and the talk alone.
  const takedown = path.match(/^\/admin\/takes\/([0-9a-f-]{36})\/remove$/);
  if (request.method === "POST" && takedown) {
    const take = await env.DB.prepare("SELECT storage_key FROM takes WHERE id = ?")
      .bind(takedown[1])
      .first<{ storage_key: string }>();
    if (!take) return fail(404, "No such take.");
    await deleteFiles(env, [take.storage_key]);
    await env.DB.prepare("DELETE FROM takes WHERE id = ?").bind(takedown[1]).run();
    return json({ ok: true });
  }

  // Erases the person and stops the same Apple ID from signing up again.
  const ban = path.match(/^\/admin\/users\/([0-9a-f-]{36})\/ban$/);
  if (request.method === "POST" && ban) {
    const target = await env.DB.prepare("SELECT apple_user_id FROM users WHERE id = ?")
      .bind(ban[1])
      .first<{ apple_user_id: string }>();
    if (!target) return fail(404, "No such person.");
    await env.DB.prepare(
      "INSERT OR IGNORE INTO bans (apple_user_id, reason, created_at) VALUES (?, 'removed', ?)"
    )
      .bind(target.apple_user_id, now())
      .run();
    await eraseUser(env, ban[1]);
    return json({ ok: true });
  }

  return fail(404, "No such endpoint.");
}
