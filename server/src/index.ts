/**
 * Typical Talk API.
 *
 * Small on purpose. It knows who you are, the two ways to add a friend, and
 * the talks and takes that follow. It never sees a transcript: those are made
 * and kept on the phone.
 *
 * Takes are uploaded and served through this Worker rather than with
 * presigned URLs. Clips are about ten seconds, so the simplicity is worth
 * more than shaving a hop, and it keeps bucket credentials off the phone.
 */

import {
  Env,
  User,
  encodeBase64URL,
  decodeBase64URL,
  clientIP,
  fail,
  json,
  newID,
  now,
  readJSON,
  tooMany,
  withinLimit,
} from "./common";
import { exchangeAuthorizationCode, verifyAppleToken } from "./apple";
import { sendPush } from "./apns";
import {
  blockedBetween,
  connected,
  destroyTalk,
  expireOldTakes,
  isMember,
  memberCount,
} from "./data";
import { admin, blockUser, deleteAccount, fileReport, listBlocks, unblockUser } from "./safety";
import {
  checkDeviceToken,
  checkHandle,
  checkID,
  checkInviteCode,
  checkName,
  escapeHTML,
} from "./validate";

type AppEnv = Env & { ADMIN_TOKEN?: string };

export default {
  async fetch(request: Request, env: AppEnv, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;

    try {
      // Invite links are opened in a browser, so this one is public and
      // returns a page rather than JSON.
      if (method === "GET" && path.startsWith("/i/")) {
        return invitePage(path.slice(3), env);
      }

      if (path.startsWith("/admin/")) return admin(request, path, env);

      if (method === "POST" && path === "/v1/session") {
        return startSession(request, env, ctx);
      }

      // Everything below needs a session.
      const user = await authenticate(request, env);
      if (!user) return fail(401, "Sign in first.");

      if (method === "GET" && path === "/v1/me") return json({ user });
      if (method === "DELETE" && path === "/v1/me") return deleteAccount(request, env, user);

      if (method === "PUT" && path === "/v1/me") {
        if (!(await withinLimit(env, "rename", user.id, 10, 60_000))) return tooMany();
        const body = await readJSON<{ name?: string }>(request);
        const checked = checkName(body?.name);
        if (!checked.value) return fail(400, checked.error!);
        await env.DB.prepare("UPDATE users SET name = ? WHERE id = ?")
          .bind(checked.value, user.id)
          .run();
        return json({ user: { ...user, name: checked.value } });
      }

      if (method === "PUT" && path === "/v1/me/handle") return claimHandle(request, env, user);
      if (method === "GET" && path === "/v1/users") return findByHandle(url, env, user);

      if (method === "PUT" && path === "/v1/devices") return registerDevice(request, env, user);
      const device = path.match(/^\/v1\/devices\/([0-9A-Fa-f]+)$/);
      if (method === "DELETE" && device) return unregisterDevice(device[1], env, user);

      if (method === "GET" && path === "/v1/blocks") return listBlocks(env, user);
      if (method === "POST" && path === "/v1/blocks") return blockUser(request, env, user);
      const unblock = path.match(/^\/v1\/blocks\/([\w-]+)$/);
      if (method === "DELETE" && unblock) return unblockUser(unblock[1], env, user);
      if (method === "POST" && path === "/v1/reports") return fileReport(request, env, user);

      if (method === "POST" && path === "/v1/invites") return createInvite(env, user);
      const redeem = path.match(/^\/v1\/invites\/([A-Za-z0-9]+)\/redeem$/);
      if (method === "POST" && redeem) return redeemInvite(redeem[1], env, ctx, user);

      if (method === "POST" && path === "/v1/talks") return startTalk(request, env, ctx, user);
      if (method === "GET" && path === "/v1/talks") return listTalks(url, env, user);

      const upload = path.match(/^\/v1\/talks\/([\w-]+)\/takes\/([\w-]+)$/);
      if (method === "PUT" && upload) return uploadTake(request, upload[1], upload[2], env, ctx, user);

      const addTo = path.match(/^\/v1\/talks\/([\w-]+)\/members$/);
      if (method === "POST" && addTo) return addMember(request, addTo[1], env, ctx, user);

      const leave = path.match(/^\/v1\/talks\/([\w-]+)\/membership$/);
      if (method === "DELETE" && leave) return leaveTalk(leave[1], env, user);

      const takeBody = path.match(/^\/v1\/takes\/([\w-]+)\/file$/);
      if (method === "GET" && takeBody) return downloadTake(request, takeBody[1], env, user);

      const watched = path.match(/^\/v1\/takes\/([\w-]+)\/watched$/);
      if (method === "POST" && watched) return markWatched(watched[1], env, user);

      return fail(404, "No such endpoint.");
    } catch (error) {
      // Never hand internals to the caller; log them instead.
      console.error("request failed", path, error);
      return fail(500, "Something went wrong.");
    }
  },

  /** Runs daily: deletes old files and tidies the small tables. */
  async scheduled(_event: ScheduledController, env: AppEnv, ctx: ExecutionContext) {
    ctx.waitUntil(maintenance(env));
  },
};

async function maintenance(env: AppEnv): Promise<void> {
  try {
    const expired = await expireOldTakes(env, now());
    await env.DB.prepare("DELETE FROM rate_limits WHERE expires_at < ?").bind(now()).run();
    // An invite nobody used in a month is not coming back.
    await env.DB.prepare("DELETE FROM invites WHERE expires_at < ?")
      .bind(now() - 30 * 24 * 60 * 60 * 1000)
      .run();
    console.log("maintenance done, expired takes:", expired);
  } catch (error) {
    console.error("maintenance failed", error);
  }
}

// MARK: - Identity

/**
 * Exchanges an Apple identity token for a session token.
 *
 * The identity token is verified against Apple's published keys rather than
 * trusted, so a caller cannot simply claim to be someone.
 */
async function startSession(request: Request, env: AppEnv, ctx: ExecutionContext): Promise<Response> {
  const body = await readJSON<{
    identityToken?: string;
    authorizationCode?: string;
    name?: string;
  }>(request);
  if (!body?.identityToken) return fail(400, "Missing identity token.");
  if (!(await withinLimit(env, "session", clientIP(request), 20, 60_000))) return tooMany();

  const claims = await verifyAppleToken(body.identityToken, env.APPLE_BUNDLE_ID);
  if (!claims) return fail(401, "That sign-in could not be verified with Apple.");

  const appleUserID = claims.sub;
  const email = (claims.email as string) ?? null;

  const banned = await env.DB.prepare("SELECT 1 AS banned FROM bans WHERE apple_user_id = ?")
    .bind(appleUserID)
    .first();
  if (banned) return fail(403, "This account has been suspended.");

  const existing = await env.DB.prepare(
    "SELECT id, name, email FROM users WHERE apple_user_id = ?"
  )
    .bind(appleUserID)
    .first<{ id: string; name: string; email: string | null }>();

  let user: User;
  if (existing) {
    user = existing;
  } else {
    // Apple sends the name only on the first sign-in, so the client passes it
    // along and it is stored once.
    const checked = checkName(body.name);
    const created = { id: newID(), name: checked.value ?? "Someone", email };
    await env.DB.prepare(
      "INSERT INTO users (id, apple_user_id, name, email, created_at) VALUES (?, ?, ?, ?, ?)"
    )
      .bind(created.id, appleUserID, created.name, created.email, now())
      .run();
    user = created;
  }

  // Keep what Apple needs to revoke the link if this person deletes their
  // account. After the response, so a slow Apple never slows sign in.
  const code = body.authorizationCode;
  if (typeof code === "string" && code) {
    ctx.waitUntil(
      exchangeAuthorizationCode(env, code).then(async (refresh) => {
        if (!refresh) return;
        await env.DB.prepare("UPDATE users SET apple_refresh_token = ? WHERE id = ?")
          .bind(refresh, user.id)
          .run();
      })
    );
  }

  const handle = await handleFor(user.id, env);
  return json({ token: await issueSessionToken(user.id, env), user: { ...user, handle } });
}

const SESSION_LIFETIME = 90 * 24 * 60 * 60 * 1000;

async function issueSessionToken(userID: string, env: Env): Promise<string> {
  const payload = encodeBase64URL(
    JSON.stringify({ sub: userID, iat: now(), exp: now() + SESSION_LIFETIME })
  );
  return `${payload}.${await sign(payload, env.SESSION_SECRET)}`;
}

/** Compares in constant time, so a wrong signature leaks no timing. */
function sameSignature(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let differing = 0;
  for (let i = 0; i < a.length; i++) differing |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return differing === 0;
}

async function authenticate(request: Request, env: Env): Promise<User | null> {
  const header = request.headers.get("authorization");
  if (!header?.startsWith("Bearer ")) return null;

  const [payload, signature] = header.slice(7).split(".");
  if (!payload || !signature) return null;
  if (!sameSignature(await sign(payload, env.SESSION_SECRET), signature)) return null;

  let sub: string;
  let exp: number | undefined;
  try {
    ({ sub, exp } = JSON.parse(decodeBase64URL(payload)) as { sub: string; exp?: number });
  } catch {
    return null;
  }
  // Tokens issued before expiry existed are treated as expired.
  if (typeof exp !== "number" || exp < now()) return null;
  const user = await env.DB.prepare("SELECT id, name, email FROM users WHERE id = ?")
    .bind(sub)
    .first<User>();
  if (!user) return null;
  return { ...user, handle: await handleFor(user.id, env) };
}

async function sign(value: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value));
  return encodeBase64URL(String.fromCharCode(...new Uint8Array(mac)));
}

// MARK: - Push registration

async function registerDevice(request: Request, env: Env, user: User): Promise<Response> {
  if (!(await withinLimit(env, "device", user.id, 30, 3_600_000))) return tooMany();
  const body = await readJSON<{ token?: string; environment?: string }>(request);
  const token = checkDeviceToken(body?.token);
  if (!token.value) return fail(400, token.error!);
  const environment = body?.environment === "sandbox" ? "sandbox" : "production";

  // A token belongs to one phone, so a new owner takes it over.
  await env.DB.prepare(
    `INSERT INTO devices (token, user_id, environment, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?4)
     ON CONFLICT(token) DO UPDATE SET user_id = ?2, environment = ?3, updated_at = ?4`
  )
    .bind(token.value, user.id, environment, now())
    .run();
  return json({ ok: true });
}

async function unregisterDevice(raw: string, env: Env, user: User): Promise<Response> {
  const token = checkDeviceToken(raw);
  if (!token.value) return fail(404, "No such device.");
  await env.DB.prepare("DELETE FROM devices WHERE token = ? AND user_id = ?")
    .bind(token.value, user.id)
    .run();
  return json({ ok: true });
}

// MARK: - Adding a friend, way one: a handle

async function handleFor(userID: string, env: Env): Promise<string | null> {
  const row = await env.DB.prepare("SELECT handle FROM handles WHERE user_id = ?")
    .bind(userID)
    .first<{ handle: string }>();
  return row?.handle ?? null;
}

async function claimHandle(request: Request, env: Env, user: User): Promise<Response> {
  if (!(await withinLimit(env, "handle", user.id, 10, 60_000))) return tooMany();

  const body = await readJSON<{ handle?: string }>(request);
  const checked = checkHandle(body?.handle);
  if (!checked.value) return fail(400, checked.error!);
  const handle = checked.value;

  const taken = await env.DB.prepare(
    "SELECT user_id FROM handles WHERE handle = ? AND user_id != ?"
  )
    .bind(handle, user.id)
    .first();
  if (taken) return fail(409, "That handle is taken.");

  await env.DB.batch([
    env.DB.prepare("DELETE FROM handles WHERE user_id = ?").bind(user.id),
    env.DB.prepare(
      "INSERT INTO handles (handle, user_id, created_at) VALUES (?, ?, ?)"
    ).bind(handle, user.id, now()),
  ]);
  return json({ handle });
}

async function findByHandle(url: URL, env: Env, user: User): Promise<Response> {
  if (!(await withinLimit(env, "lookup", user.id, 30, 60_000))) return tooMany();

  const checked = checkHandle(url.searchParams.get("handle"));
  // A malformed handle cannot match anyone, and saying so would confirm the
  // rules to someone probing. Answer as though nobody has it.
  if (!checked.value) return json({ user: null });
  const handle = checked.value;

  const row = await env.DB.prepare(
    `SELECT users.id, users.name, handles.handle
     FROM handles JOIN users ON users.id = handles.user_id
     WHERE handles.handle = ?`
  )
    .bind(handle)
    .first<{ id: string; name: string; handle: string }>();

  if (!row || row.id === user.id) return json({ user: null });
  // Someone who blocked you, or whom you blocked, does not turn up.
  if (await blockedBetween(user.id, row.id, env)) return json({ user: null });
  return json({ user: row });
}

// MARK: - Adding a friend, way two: an invite link

async function createInvite(env: Env, user: User): Promise<Response> {
  if (!(await withinLimit(env, "invite", user.id, 20, 3_600_000))) return tooMany();
  // Short enough to read aloud, long enough not to be guessed.
  // Eight characters from an unambiguous alphabet: about 40 bits, which with
  // the rate limit on redeeming is far out of reach of guessing.
  const alphabet = "abcdefghjkmnpqrstuvwxyz23456789";
  const code = [...crypto.getRandomValues(new Uint8Array(8))]
    .map((byte) => alphabet[byte % alphabet.length])
    .join("");
  const week = 7 * 24 * 60 * 60 * 1000;

  await env.DB.prepare(
    "INSERT INTO invites (code, inviter_id, created_at, expires_at) VALUES (?, ?, ?, ?)"
  )
    .bind(code, user.id, now(), now() + week)
    .run();

  return json({ code, url: `${env.INVITE_BASE_URL}/i/${code}` });
}

async function redeemInvite(
  raw: string,
  env: Env,
  ctx: ExecutionContext,
  user: User
): Promise<Response> {
  if (!(await withinLimit(env, "redeem", user.id, 10, 3_600_000))) return tooMany();

  const checked = checkInviteCode(raw);
  if (!checked.value) return fail(404, "That invite does not exist.");
  const code = checked.value;

  const invite = await env.DB.prepare(
    "SELECT code, inviter_id, expires_at, redeemed_by FROM invites WHERE code = ?"
  )
    .bind(code)
    .first<{ code: string; inviter_id: string; expires_at: number; redeemed_by: string | null }>();

  if (!invite) return fail(404, "That invite does not exist.");
  if (invite.redeemed_by) return fail(409, "That invite has already been used.");
  if (invite.expires_at < now()) return fail(410, "That invite has expired.");
  if (invite.inviter_id === user.id) return fail(400, "That is your own invite.");
  if (await blockedBetween(user.id, invite.inviter_id, env)) {
    return fail(404, "That invite does not exist.");
  }

  const talkID = await ensureTalk(invite.inviter_id, user.id, env);
  await env.DB.prepare(
    "UPDATE invites SET redeemed_by = ?, redeemed_at = ? WHERE code = ?"
  )
    .bind(user.id, now(), code)
    .run();

  ctx.waitUntil(
    sendPush(env, [invite.inviter_id], {
      title: user.name,
      body: "accepted your invite",
      talkID,
    })
  );
  return json({ talkID });
}

/** One to one talks are reused rather than duplicated. */
async function ensureTalk(a: string, b: string, env: Env): Promise<string> {
  // A one to one talk has no creator recorded; groups always do.
  const existing = await env.DB.prepare(
    `SELECT members.talk_id FROM members
     JOIN talks ON talks.id = members.talk_id AND talks.created_by IS NULL
     WHERE members.user_id IN (?, ?)
     GROUP BY members.talk_id
     HAVING COUNT(DISTINCT members.user_id) = 2
       AND (SELECT COUNT(*) FROM members m2 WHERE m2.talk_id = members.talk_id) = 2`
  )
    .bind(a, b)
    .first<{ talk_id: string }>();
  if (existing) return existing.talk_id;

  const talkID = newID();
  await env.DB.batch([
    env.DB.prepare("INSERT INTO talks (id, title, created_at) VALUES (?, NULL, ?)").bind(
      talkID,
      now()
    ),
    env.DB.prepare("INSERT INTO members (talk_id, user_id, joined_at) VALUES (?, ?, ?)").bind(
      talkID,
      a,
      now()
    ),
    env.DB.prepare("INSERT INTO members (talk_id, user_id, joined_at) VALUES (?, ?, ?)").bind(
      talkID,
      b,
      now()
    ),
  ]);
  return talkID;
}

// MARK: - Talks

const MAX_GROUP_MEMBERS = 10;

/**
 * Starts a talk. With `userID` it is one to one; with `userIDs` (two or more)
 * it is a group, which can only be made with people you already talk to.
 */
async function startTalk(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  user: User
): Promise<Response> {
  if (!(await withinLimit(env, "startTalk", user.id, 30, 3_600_000))) return tooMany();

  const body = await readJSON<{ userID?: string; userIDs?: unknown; title?: unknown }>(request);
  if (!body) return fail(400, "Say who the talk is with.");

  if (Array.isArray(body.userIDs)) return startGroup(body.userIDs, body.title, env, ctx, user);

  const checked = checkID(body.userID);
  if (!checked.value) return fail(400, "Say who the talk is with.");
  if (checked.value === user.id) return fail(400, "That is you.");

  // Only people who published a handle can be started with by id, or people
  // you already share a talk with. Without this, a leaked id is enough to open
  // a talk with anyone.
  const target = await env.DB.prepare(
    "SELECT users.id FROM users JOIN handles ON handles.user_id = users.id WHERE users.id = ?"
  )
    .bind(checked.value)
    .first();
  if (!target && !(await connected(user.id, checked.value, env))) {
    return fail(404, "No such person.");
  }
  if (await blockedBetween(user.id, checked.value, env)) return fail(404, "No such person.");

  const talkID = await ensureTalk(user.id, checked.value, env);
  return json({ talkID });
}

async function startGroup(
  rawIDs: unknown[],
  rawTitle: unknown,
  env: Env,
  ctx: ExecutionContext,
  user: User
): Promise<Response> {
  const others = new Set<string>();
  for (const raw of rawIDs) {
    const checked = checkID(raw);
    if (!checked.value) return fail(400, "One of those people could not be found.");
    if (checked.value !== user.id) others.add(checked.value);
  }
  if (others.size < 2) return fail(400, "A group needs at least three people.");
  if (others.size + 1 > MAX_GROUP_MEMBERS) {
    return fail(400, `Groups hold at most ${MAX_GROUP_MEMBERS} people.`);
  }

  let title: string | null = null;
  if (rawTitle !== undefined && rawTitle !== null && rawTitle !== "") {
    const checked = checkName(rawTitle);
    if (!checked.value) return fail(400, checked.error!);
    title = checked.value;
  }

  for (const other of others) {
    if (!(await connected(user.id, other, env)) || (await blockedBetween(user.id, other, env))) {
      return fail(404, "One of those people could not be found.");
    }
  }

  const talkID = newID();
  const members = [user.id, ...others];
  await env.DB.batch([
    env.DB.prepare("INSERT INTO talks (id, title, created_at, created_by) VALUES (?, ?, ?, ?)").bind(
      talkID,
      title,
      now(),
      user.id
    ),
    ...members.map((member) =>
      env.DB.prepare("INSERT INTO members (talk_id, user_id, joined_at) VALUES (?, ?, ?)").bind(
        talkID,
        member,
        now()
      )
    ),
  ]);

  ctx.waitUntil(
    sendPush(env, [...others], {
      title: title ?? user.name,
      body: `${user.name} added you to a group`,
      talkID,
    })
  );
  return json({ talkID });
}

async function addMember(
  request: Request,
  rawTalk: string,
  env: Env,
  ctx: ExecutionContext,
  user: User
): Promise<Response> {
  if (!(await withinLimit(env, "addMember", user.id, 30, 3_600_000))) return tooMany();
  const talk = checkID(rawTalk);
  if (!talk.value || !(await isMember(talk.value, user.id, env))) return fail(403, "Not your talk.");

  const row = await env.DB.prepare("SELECT title, created_by FROM talks WHERE id = ?")
    .bind(talk.value)
    .first<{ title: string | null; created_by: string | null }>();
  if (!row?.created_by) return fail(400, "Start a group to talk with more than one person.");

  const body = await readJSON<{ userID?: string }>(request);
  const target = checkID(body?.userID);
  if (!target.value) return fail(400, "Say who to add.");
  if (await isMember(talk.value, target.value, env)) return json({ ok: true });

  if ((await memberCount(talk.value, env)) >= MAX_GROUP_MEMBERS) {
    return fail(400, `Groups hold at most ${MAX_GROUP_MEMBERS} people.`);
  }
  if (
    !(await connected(user.id, target.value, env)) ||
    (await blockedBetween(user.id, target.value, env))
  ) {
    return fail(404, "That person could not be found.");
  }

  await env.DB.prepare("INSERT INTO members (talk_id, user_id, joined_at) VALUES (?, ?, ?)")
    .bind(talk.value, target.value, now())
    .run();
  ctx.waitUntil(
    sendPush(env, [target.value], {
      title: row.title ?? user.name,
      body: `${user.name} added you to a group`,
      talkID: talk.value,
    })
  );
  return json({ ok: true });
}

/** Leaving removes you; the last person out takes the talk and its files with them. */
async function leaveTalk(rawTalk: string, env: Env, user: User): Promise<Response> {
  const talk = checkID(rawTalk);
  if (!talk.value || !(await isMember(talk.value, user.id, env))) return fail(403, "Not your talk.");

  await env.DB.prepare("DELETE FROM members WHERE talk_id = ? AND user_id = ?")
    .bind(talk.value, user.id)
    .run();
  if ((await memberCount(talk.value, env)) === 0) await destroyTalk(env, talk.value);
  return json({ ok: true });
}

interface MemberRow {
  talk_id: string;
  id: string;
  name: string;
  handle: string | null;
}

interface TakeRow {
  id: string;
  author_id: string;
  duration: number;
  voice_only: number;
  sent_at: number;
  expired_at: number | null;
}

/**
 * Everything the phone needs to match the server, in one call.
 *
 * `since` is the `serverTime` of the last call. A take is sent again if it is
 * new, if someone has watched it since, or if its file has since expired, so
 * receipts reach the sender without a separate endpoint.
 */
async function listTalks(url: URL, env: Env, user: User): Promise<Response> {
  if (!(await withinLimit(env, "listTalks", user.id, 120, 60_000))) return tooMany();

  const serverTime = now();
  const since = Math.max(Number(url.searchParams.get("since") ?? 0) || 0, 0);

  const talks = await env.DB.prepare(
    `SELECT talks.id, talks.title, talks.created_at, talks.created_by FROM talks
     JOIN members ON members.talk_id = talks.id
     WHERE members.user_id = ?`
  )
    .bind(user.id)
    .all<{ id: string; title: string | null; created_at: number; created_by: string | null }>();
  if (talks.results.length === 0) return json({ talks: [], serverTime });

  const blocked = new Set(
    (
      await env.DB.prepare("SELECT blocked_id FROM blocks WHERE blocker_id = ?")
        .bind(user.id)
        .all<{ blocked_id: string }>()
    ).results.map((row) => row.blocked_id)
  );

  // A take the reader has reported disappears for them straight away.
  const takeFilter = `
    t.talk_id = ?1 AND t.sent_at IS NOT NULL
    AND (t.sent_at > ?2 OR t.expired_at > ?2
         OR EXISTS (SELECT 1 FROM watches w WHERE w.take_id = t.id AND w.watched_at > ?2))
    AND t.id NOT IN (SELECT take_id FROM reports WHERE reporter_id = ?3 AND take_id IS NOT NULL)`;

  const statements = talks.results.flatMap((talk) => [
    env.DB.prepare(
      `SELECT members.talk_id, users.id, users.name, handles.handle FROM members
       JOIN users ON users.id = members.user_id
       LEFT JOIN handles ON handles.user_id = users.id
       WHERE members.talk_id = ?`
    ).bind(talk.id),
    env.DB.prepare(
      `SELECT t.id, t.author_id, t.duration, t.voice_only, t.sent_at, t.expired_at
       FROM takes t WHERE ${takeFilter} ORDER BY t.sent_at DESC`
    ).bind(talk.id, since, user.id),
    env.DB.prepare(
      `SELECT w.take_id, w.user_id FROM watches w JOIN takes t ON t.id = w.take_id
       WHERE ${takeFilter}`
    ).bind(talk.id, since, user.id),
  ]);
  const answers = await env.DB.batch(statements);

  const result = [];
  for (const [index, talk] of talks.results.entries()) {
    const members = answers[index * 3].results as unknown as MemberRow[];
    const takes = answers[index * 3 + 1].results as unknown as TakeRow[];
    const watches = answers[index * 3 + 2].results as unknown as { take_id: string; user_id: string }[];

    // A one to one talk with someone you blocked is gone from your list.
    const isGroup = talk.created_by !== null;
    if (!isGroup && members.some((member) => blocked.has(member.id))) continue;

    const watchedBy = new Map<string, string[]>();
    for (const watch of watches) {
      watchedBy.set(watch.take_id, [...(watchedBy.get(watch.take_id) ?? []), watch.user_id]);
    }

    result.push({
      id: talk.id,
      title: talk.title,
      isGroup,
      createdAt: talk.created_at,
      members: members.map(({ id, name, handle }) => ({ id, name, handle })),
      takes: takes
        .filter((take) => !blocked.has(take.author_id))
        .map((take) => ({
          id: take.id,
          authorID: take.author_id,
          duration: take.duration,
          voiceOnly: take.voice_only === 1,
          sentAt: take.sent_at,
          expired: take.expired_at !== null,
          watchedBy: watchedBy.get(take.id) ?? [],
        })),
    });
  }
  return json({ talks: result, serverTime });
}

// MARK: - Takes

const MAX_TAKE_BYTES = 120 * 1024 * 1024;

/**
 * Stores a take under an id the phone chose, so sending the same take twice
 * (after a dropped connection, say) cannot make two of it.
 */
async function uploadTake(
  request: Request,
  rawTalk: string,
  rawTake: string,
  env: Env,
  ctx: ExecutionContext,
  user: User
): Promise<Response> {
  const talk = checkID(rawTalk);
  const take = checkID(rawTake);
  if (!talk.value || !take.value) return fail(400, "Not a valid id.");
  const talkID = talk.value;
  const takeID = take.value;

  if (!(await isMember(talkID, user.id, env))) return fail(403, "Not your talk.");

  const prior = await env.DB.prepare("SELECT author_id, sent_at FROM takes WHERE id = ?")
    .bind(takeID)
    .first<{ author_id: string; sent_at: number | null }>();
  if (prior) {
    if (prior.author_id !== user.id) return fail(409, "That take id is taken.");
    if (prior.sent_at) return json({ takeID, sentAt: prior.sent_at, alreadySent: true });
  }

  if (!(await withinLimit(env, "upload", user.id, 120, 3_600_000))) return tooMany();

  // In a one to one talk a block closes it to the blocked person. The answer
  // is the same as any other refusal so it does not announce itself.
  const members = await env.DB.prepare("SELECT user_id FROM members WHERE talk_id = ?")
    .bind(talkID)
    .all<{ user_id: string }>();
  const group = await env.DB.prepare("SELECT created_by FROM talks WHERE id = ?")
    .bind(talkID)
    .first<{ created_by: string | null }>();
  if (!group?.created_by) {
    for (const member of members.results) {
      if (member.user_id !== user.id && (await blockedBetween(user.id, member.user_id, env))) {
        return fail(403, "You can't send takes in this talk.");
      }
    }
  }

  const duration = Math.min(Math.max(Number(request.headers.get("x-take-duration") ?? 0) || 0, 0), 600);
  const voiceOnly = request.headers.get("x-take-voice-only") === "1";
  if (!request.body) return fail(400, "No take in the request.");

  const declared = Number(request.headers.get("content-length") ?? 0);
  if (!declared) return fail(411, "Send the take with a length.");
  if (declared > MAX_TAKE_BYTES) return fail(413, "That take is too large.");

  const key = `takes/${talkID}/${takeID}.mov`;
  const stored = await env.TAKES.put(key, request.body);
  if (!stored) return fail(500, "The take could not be stored.");

  // Only video containers are kept. The first bytes of a QuickTime or MP4
  // file name its first box, so anything else is something else.
  const head = await env.TAKES.get(key, { range: { offset: 4, length: 4 } });
  const box = head ? new TextDecoder("latin1").decode(await head.arrayBuffer()) : "";
  if (stored.size > MAX_TAKE_BYTES || !["ftyp", "moov", "mdat", "wide", "free", "skip"].includes(box)) {
    await env.TAKES.delete(key);
    return fail(stored.size > MAX_TAKE_BYTES ? 413 : 415, "That is not a video this app can use.");
  }

  const sentAt = now();
  await env.DB.prepare(
    `INSERT INTO takes (id, talk_id, author_id, storage_key, duration, voice_only, sent_at, created_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)
     ON CONFLICT(id) DO UPDATE SET sent_at = ?7, storage_key = ?4, duration = ?5, voice_only = ?6
     WHERE takes.author_id = ?3`
  )
    .bind(takeID, talkID, user.id, key, duration, voiceOnly ? 1 : 0, sentAt)
    .run();

  // Tell everyone else, except people who blocked the sender.
  const blockers = await env.DB.prepare("SELECT blocker_id FROM blocks WHERE blocked_id = ?")
    .bind(user.id)
    .all<{ blocker_id: string }>();
  const silenced = new Set(blockers.results.map((row) => row.blocker_id));
  const recipients = members.results
    .map((member) => member.user_id)
    .filter((member) => member !== user.id && !silenced.has(member));

  const talkTitle = await env.DB.prepare("SELECT title FROM talks WHERE id = ?")
    .bind(talkID)
    .first<{ title: string | null }>();
  ctx.waitUntil(
    sendPush(env, recipients, {
      title: group?.created_by ? (talkTitle?.title ?? "Group talk") : user.name,
      body: group?.created_by
        ? `${user.name} sent a ${voiceOnly ? "voice take" : "take"}`
        : voiceOnly
          ? "sent you a voice take"
          : "sent you a take",
      talkID,
      takeID,
    })
  );

  return json({ takeID, sentAt });
}

async function downloadTake(
  request: Request,
  rawTake: string,
  env: Env,
  user: User
): Promise<Response> {
  const checked = checkID(rawTake);
  if (!checked.value) return fail(404, "No such take.");

  const take = await env.DB.prepare(
    "SELECT talk_id, author_id, storage_key, expired_at FROM takes WHERE id = ?"
  )
    .bind(checked.value)
    .first<{ talk_id: string; author_id: string; storage_key: string; expired_at: number | null }>();
  if (!take) return fail(404, "No such take.");
  if (!(await isMember(take.talk_id, user.id, env))) return fail(403, "Not your talk.");
  if (take.expired_at) return fail(410, "That take is no longer stored.");
  if (take.author_id !== user.id && (await blockedBetween(user.id, take.author_id, env))) {
    return fail(404, "No such take.");
  }

  // Range support lets an interrupted download pick up where it stopped.
  const ranged = request.headers.has("range");
  const object = await env.TAKES.get(take.storage_key, ranged ? { range: request.headers } : undefined);
  if (!object) return fail(404, "That take is no longer stored.");

  const headers: Record<string, string> = {
    "content-type": "video/quicktime",
    "cache-control": "private, max-age=31536000",
    "accept-ranges": "bytes",
    etag: object.httpEtag,
  };
  const range = ranged ? (object.range as { offset?: number; length?: number; suffix?: number } | undefined) : undefined;
  if (range) {
    const start = range.suffix !== undefined ? object.size - range.suffix : (range.offset ?? 0);
    const length = range.suffix !== undefined ? range.suffix : (range.length ?? object.size - start);
    headers["content-range"] = `bytes ${start}-${start + length - 1}/${object.size}`;
    headers["content-length"] = String(length);
    return new Response(object.body, { status: 206, headers });
  }
  headers["content-length"] = String(object.size);
  return new Response(object.body, { headers });
}

async function markWatched(rawTake: string, env: Env, user: User): Promise<Response> {
  const checked = checkID(rawTake);
  if (!checked.value) return fail(404, "No such take.");
  if (!(await withinLimit(env, "watched", user.id, 600, 3_600_000))) return tooMany();

  const take = await env.DB.prepare("SELECT talk_id, author_id FROM takes WHERE id = ?")
    .bind(checked.value)
    .first<{ talk_id: string; author_id: string }>();
  if (!take) return fail(404, "No such take.");
  if (!(await isMember(take.talk_id, user.id, env))) return fail(403, "Not your talk.");
  // Watching your own take is not a receipt.
  if (take.author_id === user.id) return json({ ok: true });

  await env.DB.prepare(
    "INSERT OR REPLACE INTO watches (take_id, user_id, watched_at) VALUES (?, ?, ?)"
  )
    .bind(checked.value, user.id, now())
    .run();
  return json({ ok: true });
}

/** The page an invite link opens in a browser. */
async function invitePage(raw: string, env: Env): Promise<Response> {
  const checked = checkInviteCode(raw);
  const code = checked.value ?? "";

  const invite = await env.DB.prepare(
    `SELECT users.name FROM invites JOIN users ON users.id = invites.inviter_id
     WHERE invites.code = ?`
  )
    .bind(code)
    .first<{ name: string }>();

  // Escaped: a name is attacker controlled, and this page is opened by other
  // people. Unescaped, a name containing markup ran in their browser.
  const who = escapeHTML(invite?.name ?? "Someone");
  const page = `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Join ${who} on Typical Talk</title>
<style>body{background:#08090c;color:#fff;font:17px -apple-system,system-ui;display:grid;
place-items:center;height:100dvh;margin:0;text-align:center;padding:24px}
a{display:inline-block;margin-top:24px;background:#ff536f;color:#fff;text-decoration:none;
padding:14px 28px;border-radius:999px;font-weight:600}</style></head>
<body><div><h1>${who} invited you to Typical Talk</h1>
<p>Async video messages. Record a take, send it, they watch when they can.</p>
<a href="typicaltalk://invite/${encodeURIComponent(code)}">Open in Typical Talk</a></div></body></html>`;

  return new Response(page, { headers: { "content-type": "text/html; charset=utf-8" } });
}

