/**
 * Sign in with Apple: verifying the identity token, and exchanging and
 * revoking tokens so that deleting an account also tells Apple.
 */

import {
  Env,
  base64URLToBytes,
  decodeBase64URL,
  now,
  signES256,
} from "./common";

/** Apple's public keys, fetched per request; Cloudflare caches the response. */
export async function verifyAppleToken(token: string, bundleID: string) {
  const [headerPart, payloadPart, signaturePart] = token.split(".");
  if (!headerPart || !payloadPart || !signaturePart) return null;

  let header: { kid?: string };
  let payload: Record<string, unknown>;
  try {
    header = JSON.parse(decodeBase64URL(headerPart));
    payload = JSON.parse(decodeBase64URL(payloadPart)) as Record<string, unknown>;
  } catch {
    return null;
  }

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

const configured = (env: Env) =>
  Boolean(env.APPLE_SIWA_KEY_ID && env.APPLE_SIWA_PRIVATE_KEY && env.APPLE_TEAM_ID);

/** The client secret Apple's token endpoints ask for: a short lived JWT. */
async function clientSecret(env: Env): Promise<string> {
  const issued = Math.floor(now() / 1000);
  return signES256(
    { alg: "ES256", kid: env.APPLE_SIWA_KEY_ID },
    {
      iss: env.APPLE_TEAM_ID,
      iat: issued,
      exp: issued + 300,
      aud: "https://appleid.apple.com",
      sub: env.APPLE_BUNDLE_ID,
    },
    env.APPLE_SIWA_PRIVATE_KEY!
  );
}

/**
 * Trades the one use authorization code from sign in for a refresh token,
 * which is what Apple needs later to revoke the link. Returns null when the
 * key is not set up or Apple refuses; sign in must never depend on this.
 */
export async function exchangeAuthorizationCode(env: Env, code: string): Promise<string | null> {
  if (!configured(env)) return null;
  try {
    const response = await fetch("https://appleid.apple.com/auth/token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: env.APPLE_BUNDLE_ID,
        client_secret: await clientSecret(env),
        grant_type: "authorization_code",
        code,
      }),
    });
    const body = (await response.json()) as { refresh_token?: string; error?: string };
    if (!response.ok || !body.refresh_token) {
      console.error("apple token exchange refused", response.status, body.error);
      return null;
    }
    return body.refresh_token;
  } catch (error) {
    console.error("apple token exchange failed", error);
    return null;
  }
}

/** Tells Apple the app no longer has access to this person's Apple ID. */
export async function revokeRefreshToken(env: Env, refreshToken: string): Promise<boolean> {
  if (!configured(env)) return false;
  try {
    const response = await fetch("https://appleid.apple.com/auth/revoke", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: env.APPLE_BUNDLE_ID,
        client_secret: await clientSecret(env),
        token: refreshToken,
        token_type_hint: "refresh_token",
      }),
    });
    if (!response.ok) console.error("apple revoke refused", response.status);
    return response.ok;
  } catch (error) {
    console.error("apple revoke failed", error);
    return false;
  }
}
