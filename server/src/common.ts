/** Shared plumbing: environment, responses, ids, rate limiting, encoding. */

export interface Env {
  DB: D1Database;
  TAKES: R2Bucket;
  SESSION_SECRET: string;
  APPLE_BUNDLE_ID: string;
  APPLE_TEAM_ID: string;
  INVITE_BASE_URL: string;
  // Sign in with Apple key, used to exchange and revoke tokens. Optional:
  // without it sign-in and deletion still work, Apple is just not told.
  APPLE_SIWA_KEY_ID?: string;
  APPLE_SIWA_PRIVATE_KEY?: string;
  // APNs key. Optional: without it no push is sent.
  APNS_KEY_ID?: string;
  APNS_PRIVATE_KEY?: string;
}

export interface User {
  id: string;
  name: string;
  email: string | null;
  handle?: string | null;
}

/** How long a take is kept on the server before the file is deleted. */
export const TAKE_LIFETIME_MS = 90 * 24 * 60 * 60 * 1000;

export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

export const fail = (status: number, message: string) => json({ error: message }, status);
export const tooMany = () => fail(429, "Too many attempts. Try again shortly.");

export const now = () => Date.now();
export const newID = () => crypto.randomUUID();

/** Best available caller identity before a session exists. */
export const clientIP = (request: Request) => request.headers.get("cf-connecting-ip") ?? "unknown";

/** A malformed body is the caller's mistake, not a server error. */
export async function readJSON<T extends object>(request: Request): Promise<T | null> {
  try {
    const value = await request.json();
    return value && typeof value === "object" ? (value as T) : null;
  } catch {
    return null;
  }
}

/**
 * A fixed window counter in D1. Not exact under concurrency, which is fine:
 * it exists to stop grinding, not to be a precise quota.
 */
export async function withinLimit(
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

// MARK: - Base64URL

export function decodeBase64URL(value: string): string {
  return atob(value.replace(/-/g, "+").replace(/_/g, "/"));
}

export function base64URLToBytes(value: string): Uint8Array {
  const binary = decodeBase64URL(value);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

export function encodeBase64URL(value: string): string {
  return btoa(value).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function bytesToBase64URL(bytes: Uint8Array): string {
  return encodeBase64URL(String.fromCharCode(...bytes));
}

// MARK: - Signing with an Apple key

/**
 * Signs an ES256 JWT with a .p8 key from Apple. Both APNs and Sign in with
 * Apple authenticate this way, so they share it.
 *
 * WebCrypto returns the signature as raw r||s, which is exactly the form a
 * JWT wants, so no DER conversion is needed.
 */
export async function signES256(
  header: Record<string, unknown>,
  claims: Record<string, unknown>,
  pem: string
): Promise<string> {
  const der = Uint8Array.from(
    atob(pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "")),
    (c) => c.charCodeAt(0)
  );
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
  const input =
    encodeBase64URL(JSON.stringify(header)) + "." + encodeBase64URL(JSON.stringify(claims));
  const signature = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input))
  );
  return `${input}.${bytesToBase64URL(signature)}`;
}
