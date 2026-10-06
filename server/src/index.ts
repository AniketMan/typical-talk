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

import { checkHandle, checkName, checkInviteCode, checkID, escapeHTML } from "./validate";

export interface Env {
  DB: D1Database;
  TAKES: R2Bucket;
  SESSION_SECRET: string;
  APPLE_BUNDLE_ID: string;
  INVITE_BASE_URL: string;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

const fail = (status: number, message: string) => json({ error: message }, status);

const now = () => Date.now();
const id = () => crypto.randomUUID();

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;

    try {
      // Invite links are opened in a browser, so this one is public and
      // returns a page rather than JSON.
      if (method === "GET" && path.startsWith("/i/")) {
        return invitePage(path.slice(3), env);
      }

      if (method === "POST" && path === "/v1/session") {
        return startSession(request, env);
      }

      // Everything below needs a session.
      const user = await authenticate(request, env);
      if (!user) return fail(401, "Sign in first.");

      if (method === "GET" && path === "/v1/me") return json({ user });

      if (method === "PUT" && path === "/v1/me") {
        if (!(await withinLimit(env, "rename", user.id, 10, 60_000))) return tooMany();
        const body = (await request.json()) as { name?: string };
        const checked = checkName(body.name);
        if (!checked.value) return fail(400, checked.error!);
        await env.DB.prepare("UPDATE users SET name = ? WHERE id = ?")
          .bind(checked.value, user.id)
          .run();
        return json({ user: { ...user, name: checked.value } });
      }

      if (method === "PUT" && path === "/v1/me/handle") {
        return claimHandle(request, env, user);
      }

      if (method === "GET" && path === "/v1/users") {
        return findByHandle(url, env, user);
      }

      if (method === "POST" && path === "/v1/invites") {
        return createInvite(env, user);
      }

      const redeem = path.match(/^\/v1\/invites\/([A-Za-z0-9]+)\/redeem$/);
      if (method === "POST" && redeem) {
        return redeemInvite(redeem[1], env, user);
      }

      if (method === "POST" && path === "/v1/talks") {
        return startTalk(request, env, user);
      }

      if (method === "GET" && path === "/v1/talks") {
        return listTalks(url, env, user);
      }

      const newTake = path.match(/^\/v1\/talks\/([\w-]+)\/takes$/);
      if (method === "POST" && newTake) {
        return uploadTake(request, newTake[1], env, user);
      }

      const takeBody = path.match(/^\/v1\/takes\/([\w-]+)\/file$/);
      if (method === "GET" && takeBody) {
        return downloadTake(takeBody[1], env, user);
      }

      const watched = path.match(/^\/v1\/takes\/([\w-]+)\/watched$/);
      if (method === "POST" && watched) {
        return markWatched(watched[1], env, user);
      }

      return fail(404, "No such endpoint.");
    } catch (error) {
      // Never hand internals to the caller; log them instead.
      console.error("request failed", path, error);
      return fail(500, "Something went wrong.");
    }
  },
};

/**
 * A fixed window counter in D1. Not exact under concurrency, which is fine:
 * it exists to stop grinding, not to be a precise quota.
 */
async function withinLimit(
  env: Env,
  action: string,
  actor: string,
  limit: number,
  windowMs: number
): Promise<boolean> {
  const window = Math.floor(now() / windowMs);
  const bucket = `${action}:${actor}:${window}`;
  const expires = (window + 1) * windowMs;

  await env.DB.prepare(
    `INSERT INTO rate_limits (bucket, hits, expires_at) VALUES (?, 1, ?)
     ON CONFLICT(bucket) DO UPDATE SET hits = hits + 1`
  )
    .bind(bucket, expires)
    .run();

  const row = await env.DB.prepare("SELECT hits FROM rate_limits WHERE bucket = ?")
    .bind(bucket)
    .first<{ hits: number }>();

  // Opportunistic cleanup so the table does not grow without bound.
  if ((row?.hits ?? 0) % 25 === 0) {
    await env.DB.prepare("DELETE FROM rate_limits WHERE expires_at < ?").bind(now()).run();
  }
  return (row?.hits ?? 0) <= limit;
}

const tooMany = () => fail(429, "Too many attempts. Try again shortly.");

/** Best available caller identity before a session exists. */
const clientIP = (request: Request) => request.headers.get("cf-connecting-ip") ?? "unknown";

// MARK: - Identity

interface User {
  id: string;
  name: string;
  email: string | null;
  handle?: string | null;
}

/**
 * Exchanges an Apple identity token for a session token.
 *
 * The identity token is verified against Apple's published keys rather than
 * trusted, so a caller cannot simply claim to be someone.
 */
async function startSession(request: Request, env: Env): Promise<Response> {
  const body = (await request.json()) as {
    identityToken?: string;
    name?: string;
  };
  if (!body.identityToken) return fail(400, "Missing identity token.");
  if (!(await withinLimit(env, "session", clientIP(request), 20, 60_000))) return tooMany();

  const claims = await verifyAppleToken(body.identityToken, env.APPLE_BUNDLE_ID);
  if (!claims) return fail(401, "That sign-in could not be verified with Apple.");

  const appleUserID = claims.sub;
  const email = (claims.email as string) ?? null;

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
    const created = { id: id(), name: checked.value ?? "Someone", email };
    await env.DB.prepare(
      "INSERT INTO users (id, apple_user_id, name, email, created_at) VALUES (?, ?, ?, ?, ?)"
    )
      .bind(created.id, appleUserID, created.name, created.email, now())
      .run();
    user = created;
  }

  const handle = await handleFor(user.id, env);
  return json({ token: await issueSessionToken(user.id, env), user: { ...user, handle } });
}

/** Apple's public keys, fetched per request; Cloudflare caches the response. */
async function verifyAppleToken(token: string, bundleID: string) {
  const [headerPart, payloadPart, signaturePart] = token.split(".");
  if (!headerPart || !payloadPart || !signaturePart) return null;

  const header = JSON.parse(decodeBase64URL(headerPart));
  const payload = JSON.parse(decodeBase64URL(payloadPart)) as Record<string, unknown>;

  const keys = await fetch("https://appleid.apple.com/auth/keys", {
    cf: { cacheTtl: 3600, cacheEverything: true },
  }).then((r) => r.json() as Promise<{ keys: JsonWebKey[] }>);

  const jwk = (keys.keys as (JsonWebKey & { kid: string })[]).find(
    (candidate) => candidate.kid === header.kid
  );
  if (!jwk) return null;

  const key = await crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"]
  );
  const signed = new TextEncoder().encode(`${headerPart}.${payloadPart}`);
  const valid = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    base64URLToBytes(signaturePart),
    signed
  );
  if (!valid) return null;

  if (payload.iss !== "https://appleid.apple.com") return null;
  if (payload.aud !== bundleID) return null;
  if (typeof payload.exp === "number" && payload.exp * 1000 < now()) return null;

  return payload as { sub: string; email?: string };
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

// MARK: - Adding a friend, way one: a handle

async function handleFor(userID: string, env: Env): Promise<string | null> {
  const row = await env.DB.prepare("SELECT handle FROM handles WHERE user_id = ?")
    .bind(userID)
    .first<{ handle: string }>();
  return row?.handle ?? null;
}

async function claimHandle(request: Request, env: Env, user: User): Promise<Response> {
  if (!(await withinLimit(env, "handle", user.id, 10, 60_000))) return tooMany();

  const body = (await request.json()) as { handle?: string };
  const checked = checkHandle(body.handle);
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

async function redeemInvite(raw: string, env: Env, user: User): Promise<Response> {
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

  const talkID = await ensureTalk(invite.inviter_id, user.id, env);
  await env.DB.prepare(
    "UPDATE invites SET redeemed_by = ?, redeemed_at = ? WHERE code = ?"
  )
    .bind(user.id, now(), code)
    .run();

  return json({ talkID });
}

/** One to one talks are reused rather than duplicated. */
async function ensureTalk(a: string, b: string, env: Env): Promise<string> {
  const existing = await env.DB.prepare(
    `SELECT talk_id FROM members WHERE user_id IN (?, ?)
     GROUP BY talk_id HAVING COUNT(DISTINCT user_id) = 2 AND COUNT(*) = 2`
  )
    .bind(a, b)
    .first<{ talk_id: string }>();
  if (existing) return existing.talk_id;

  const talkID = id();
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

// MARK: - Talks and takes

async function startTalk(request: Request, env: Env, user: User): Promise<Response> {
  if (!(await withinLimit(env, "startTalk", user.id, 30, 3_600_000))) return tooMany();

  const body = (await request.json()) as { userID?: string };
  const checked = checkID(body.userID);
  if (!checked.value) return fail(400, "Say who the talk is with.");
  if (checked.value === user.id) return fail(400, "That is you.");

  // Only people who published a handle can be started with by id. Without
  // this, a leaked id is enough to open a talk with anyone.
  const target = await env.DB.prepare(
    "SELECT users.id FROM users JOIN handles ON handles.user_id = users.id WHERE users.id = ?"
  )
    .bind(checked.value)
    .first();
  if (!target) return fail(404, "No such person.");

  const talkID = await ensureTalk(user.id, checked.value, env);
  return json({ talkID });
}

async function listTalks(url: URL, env: Env, user: User): Promise<Response> {
  const since = Number(url.searchParams.get("since") ?? 0);

  const talks = await env.DB.prepare(
    `SELECT talks.id, talks.title FROM talks
     JOIN members ON members.talk_id = talks.id
     WHERE members.user_id = ?`
  )
    .bind(user.id)
    .all<{ id: string; title: string | null }>();

  const result = [];
  for (const talk of talks.results) {
    const members = await env.DB.prepare(
      `SELECT users.id, users.name FROM members
       JOIN users ON users.id = members.user_id WHERE members.talk_id = ?`
    )
      .bind(talk.id)
      .all<{ id: string; name: string }>();

    const takes = await env.DB.prepare(
      `SELECT id, author_id, duration, voice_only, sent_at FROM takes
       WHERE talk_id = ? AND sent_at IS NOT NULL AND sent_at > ?
       ORDER BY sent_at DESC`
    )
      .bind(talk.id, since)
      .all();

    result.push({ ...talk, members: members.results, takes: takes.results });
  }
  return json({ talks: result, serverTime: now() });
}

async function uploadTake(
  request: Request,
  talkID: string,
  env: Env,
  user: User
): Promise<Response> {
  if (!(await isMember(talkID, user.id, env))) return fail(403, "Not your talk.");

  if (!(await withinLimit(env, "upload", user.id, 60, 3_600_000))) return tooMany();

  const duration = Math.min(Math.max(Number(request.headers.get("x-take-duration") ?? 0), 0), 600);
  const voiceOnly = request.headers.get("x-take-voice-only") === "1";
  if (!request.body) return fail(400, "No take in the request.");

  // A two minute square take is about 70 MB at the recorder's bitrate.
  const maxBytes = 120 * 1024 * 1024;
  const declared = Number(request.headers.get("content-length") ?? 0);
  if (declared > maxBytes) return fail(413, "That take is too large.");

  const takeID = id();
  const key = `takes/${talkID}/${takeID}.mov`;
  await env.TAKES.put(key, request.body);

  await env.DB.prepare(
    `INSERT INTO takes (id, talk_id, author_id, storage_key, duration, voice_only, sent_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
  )
    .bind(takeID, talkID, user.id, key, duration, voiceOnly ? 1 : 0, now(), now())
    .run();

  return json({ takeID, sentAt: now() });
}

async function downloadTake(takeID: string, env: Env, user: User): Promise<Response> {
  const take = await env.DB.prepare("SELECT talk_id, storage_key FROM takes WHERE id = ?")
    .bind(takeID)
    .first<{ talk_id: string; storage_key: string }>();
  if (!take) return fail(404, "No such take.");
  if (!(await isMember(take.talk_id, user.id, env))) return fail(403, "Not your talk.");

  const object = await env.TAKES.get(take.storage_key);
  if (!object) return fail(404, "That take is no longer stored.");

  return new Response(object.body, {
    headers: {
      "content-type": "video/quicktime",
      "cache-control": "private, max-age=31536000",
    },
  });
}

async function markWatched(takeID: string, env: Env, user: User): Promise<Response> {
  const take = await env.DB.prepare("SELECT talk_id FROM takes WHERE id = ?")
    .bind(takeID)
    .first<{ talk_id: string }>();
  if (!take) return fail(404, "No such take.");
  if (!(await isMember(take.talk_id, user.id, env))) return fail(403, "Not your talk.");

  await env.DB.prepare(
    "INSERT OR REPLACE INTO watches (take_id, user_id, watched_at) VALUES (?, ?, ?)"
  )
    .bind(takeID, user.id, now())
    .run();
  return json({ ok: true });
}

async function isMember(talkID: string, userID: string, env: Env): Promise<boolean> {
  const row = await env.DB.prepare(
    "SELECT 1 AS present FROM members WHERE talk_id = ? AND user_id = ?"
  )
    .bind(talkID, userID)
    .first();
  return row != null;
}

// MARK: - Base64URL

function decodeBase64URL(value: string): string {
  return atob(value.replace(/-/g, "+").replace(/_/g, "/"));
}

function base64URLToBytes(value: string): Uint8Array {
  const binary = decodeBase64URL(value);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

function encodeBase64URL(value: string): string {
  return btoa(value).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
