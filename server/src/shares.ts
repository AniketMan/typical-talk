/**
 * Takes sent through the Messages app.
 *
 * The phone uploads the take and gets back a link. The link goes in an
 * iMessage. Opening it in the app files the take into a one to one talk with
 * the sender, so from then on it is an ordinary take in an ordinary talk.
 * Without the app, the link opens a page that plays it.
 */

import { Env, User, fail, json, newID, now, tooMany, withinLimit } from "./common";
import { blockedBetween } from "./data";
import { escapeHTML } from "./validate";

const MAX_BYTES = 120 * 1024 * 1024;
const CODE_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";

/** 14 characters from 31: about 69 bits. Not guessable, short enough for a URL. */
function newCode(): string {
  return [...crypto.getRandomValues(new Uint8Array(14))]
    .map((byte) => CODE_ALPHABET[byte % CODE_ALPHABET.length])
    .join("");
}

export const shareCode = (raw: string) => (/^[a-z2-9]{14}$/.test(raw) ? raw : null);

export async function createShare(request: Request, env: Env, user: User): Promise<Response> {
  if (!(await withinLimit(env, "share", user.id, 60, 3_600_000))) return tooMany();
  if (!request.body) return fail(400, "No take in the request.");
  const declared = Number(request.headers.get("content-length") ?? 0);
  if (!declared) return fail(411, "Send the take with a length.");
  if (declared > MAX_BYTES) return fail(413, "That take is too large.");

  const id = newID();
  const code = newCode();
  const key = `shares/${id}.mov`;
  const stored = await env.TAKES.put(key, request.body);
  if (!stored) return fail(500, "The take could not be stored.");

  const head = await env.TAKES.get(key, { range: { offset: 4, length: 4 } });
  const box = head ? new TextDecoder("latin1").decode(await head.arrayBuffer()) : "";
  if (stored.size > MAX_BYTES || !["ftyp", "moov", "mdat", "wide", "free", "skip"].includes(box)) {
    await env.TAKES.delete(key);
    return fail(415, "That is not a video this app can use.");
  }

  const duration = Math.min(Math.max(Number(request.headers.get("x-take-duration") ?? 0) || 0, 0), 600);
  await env.DB.prepare(
    "INSERT INTO shares (id, code, author_id, storage_key, duration, created_at) VALUES (?, ?, ?, ?, ?, ?)"
  )
    .bind(id, code, user.id, key, duration, now())
    .run();

  return json({ code, url: `${env.INVITE_BASE_URL}/s/${code}` });
}

/**
 * Files a shared take into the opener's one to one talk with its sender,
 * once. Returns where it went so the app can open it.
 */
export async function openShare(
  rawCode: string,
  env: Env,
  user: User,
  ensureTalk: (a: string, b: string, env: Env) => Promise<string>
): Promise<Response> {
  if (!(await withinLimit(env, "openShare", user.id, 60, 3_600_000))) return tooMany();
  const code = shareCode(rawCode);
  if (!code) return fail(404, "That take could not be found.");

  const share = await env.DB.prepare(
    "SELECT id, author_id, storage_key, duration, created_at, expired_at FROM shares WHERE code = ?"
  )
    .bind(code)
    .first<{ id: string; author_id: string; storage_key: string; duration: number; created_at: number; expired_at: number | null }>();
  if (!share || share.expired_at) return fail(404, "That take is no longer available.");
  if (await blockedBetween(user.id, share.author_id, env)) return fail(404, "That take could not be found.");

  const opened = await env.DB.prepare("SELECT talk_id, take_id FROM share_opens WHERE share_id = ? AND user_id = ?")
    .bind(share.id, user.id)
    .first<{ talk_id: string; take_id: string }>();
  if (opened) return json({ talkID: opened.talk_id, takeID: opened.take_id });

  // The sender opening their own link just lands back in the app.
  if (share.author_id === user.id) return json({ talkID: null, takeID: null });

  const talkID = await ensureTalk(share.author_id, user.id, env);
  const takeID = newID();
  const key = `takes/${talkID}/${takeID}.mov`;

  // R2 has no server side copy, so the file is streamed across.
  const source = await env.TAKES.get(share.storage_key);
  if (!source) return fail(404, "That take is no longer available.");
  await env.TAKES.put(key, source.body);

  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO takes (id, talk_id, author_id, storage_key, duration, voice_only, sent_at, created_at)
       VALUES (?, ?, ?, ?, ?, 0, ?, ?)`
    ).bind(takeID, talkID, share.author_id, key, share.duration, share.created_at, now()),
    env.DB.prepare("INSERT INTO share_opens (share_id, user_id, talk_id, take_id) VALUES (?, ?, ?, ?)").bind(
      share.id,
      user.id,
      talkID,
      takeID
    ),
  ]);
  return json({ talkID, takeID });
}

/** The page a share link opens in a browser: the take, and a way to get the app. */
export async function sharePage(rawCode: string, env: Env): Promise<Response> {
  const code = shareCode(rawCode);
  const share = code
    ? await env.DB.prepare(
        `SELECT users.name, shares.expired_at FROM shares JOIN users ON users.id = shares.author_id WHERE shares.code = ?`
      )
        .bind(code)
        .first<{ name: string; expired_at: number | null }>()
    : null;

  const who = escapeHTML(share?.name ?? "Someone");
  const available = share && !share.expired_at;
  const video = available
    ? `<video src="/s/${code}/video" controls playsinline autoplay muted></video>`
    : `<p>This take is no longer available.</p>`;
  const page = `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>A take from ${who}</title>
<meta property="og:title" content="A take from ${who}">
<meta property="og:site_name" content="Typical Take">
<style>body{background:#08090c;color:#fff;font:17px -apple-system,system-ui;margin:0;padding:24px;text-align:center}
video{width:100%;max-width:480px;border-radius:24px;background:#000;margin:16px auto;display:block}
a{display:inline-block;margin:8px;background:#ff536f;color:#fff;text-decoration:none;padding:14px 28px;border-radius:999px;font-weight:600}
a.plain{background:#22252d}</style></head>
<body><h1>A take from ${who}</h1>${video}
<a href="typicaltalk://share/${code ?? ""}">Open in Typical Take</a>
<a class="plain" href="https://testflight.apple.com/join/FkE6Q4YN">Get Typical Take</a></body></html>`;
  return new Response(page, { headers: { "content-type": "text/html; charset=utf-8" } });
}

/** The video behind a share link. Public by design: the code is the key. */
export async function shareVideo(request: Request, rawCode: string, env: Env): Promise<Response> {
  const code = shareCode(rawCode);
  if (!code) return fail(404, "Not found.");
  const share = await env.DB.prepare("SELECT storage_key, expired_at FROM shares WHERE code = ?")
    .bind(code)
    .first<{ storage_key: string; expired_at: number | null }>();
  if (!share || share.expired_at) return fail(404, "Not found.");

  const ranged = request.headers.has("range");
  const object = await env.TAKES.get(share.storage_key, ranged ? { range: request.headers } : undefined);
  if (!object) return fail(404, "Not found.");
  const headers: Record<string, string> = {
    "content-type": "video/quicktime",
    "accept-ranges": "bytes",
    "cache-control": "private, max-age=3600",
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
