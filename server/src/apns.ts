/**
 * Push notifications through APNs, authenticated with a .p8 key.
 *
 * Nothing here is allowed to fail a request: a take that was uploaded is
 * uploaded whether or not anyone could be told about it.
 */

import { Env, now, signES256 } from "./common";

interface Device {
  token: string;
  environment: string;
}

export interface Push {
  title: string;
  body: string;
  talkID: string;
  takeID?: string;
}

// APNs rejects a provider token that is refreshed too often, so reuse one for
// most of its hour. Module scope lives as long as the isolate does.
let cached: { jwt: string; issuedAt: number } | null = null;

async function providerToken(env: Env): Promise<string> {
  if (cached && now() - cached.issuedAt < 40 * 60 * 1000) return cached.jwt;
  const jwt = await signES256(
    { alg: "ES256", kid: env.APNS_KEY_ID },
    { iss: env.APPLE_TEAM_ID, iat: Math.floor(now() / 1000) },
    env.APNS_PRIVATE_KEY!
  );
  cached = { jwt, issuedAt: now() };
  return jwt;
}

/** Unwatched takes by other people: the number on the app icon. */
async function badgeFor(env: Env, userID: string): Promise<number> {
  const row = await env.DB.prepare(
    `SELECT COUNT(*) AS unread FROM takes t
     JOIN members m ON m.talk_id = t.talk_id AND m.user_id = ?1
     WHERE t.author_id != ?1 AND t.sent_at IS NOT NULL AND t.expired_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM watches w WHERE w.take_id = t.id AND w.user_id = ?1)
       AND t.author_id NOT IN (SELECT blocked_id FROM blocks WHERE blocker_id = ?1)`
  )
    .bind(userID)
    .first<{ unread: number }>();
  return row?.unread ?? 0;
}

export async function sendPush(env: Env, userIDs: string[], push: Push): Promise<void> {
  if (!env.APNS_KEY_ID || !env.APNS_PRIVATE_KEY || userIDs.length === 0) return;

  try {
    const jwt = await providerToken(env);

    for (const userID of userIDs) {
      const devices = await env.DB.prepare(
        "SELECT token, environment FROM devices WHERE user_id = ?"
      )
        .bind(userID)
        .all<Device>();
      if (devices.results.length === 0) continue;

      const badge = await badgeFor(env, userID);
      const body = JSON.stringify({
        aps: {
          alert: { title: push.title, body: push.body },
          sound: "default",
          badge,
          "thread-id": push.talkID,
          // Wakes the app briefly so the take is already downloaded when the
          // notification is opened.
          "content-available": 1,
        },
        talkID: push.talkID,
        takeID: push.takeID,
      });

      await Promise.all(
        devices.results.map(async (device) => {
          const host =
            device.environment === "sandbox"
              ? "api.sandbox.push.apple.com"
              : "api.push.apple.com";
          const response = await fetch(`https://${host}/3/device/${device.token}`, {
            method: "POST",
            headers: {
              authorization: `bearer ${jwt}`,
              "apns-topic": env.APPLE_BUNDLE_ID,
              "apns-push-type": "alert",
              "apns-priority": "10",
            },
            body,
          });
          if (response.ok) return;

          const reason = ((await response.json().catch(() => ({}))) as { reason?: string }).reason;
          console.error("apns refused", response.status, reason);
          // A token Apple no longer recognises will never work again.
          if (
            response.status === 410 ||
            reason === "BadDeviceToken" ||
            reason === "Unregistered" ||
            reason === "DeviceTokenNotForTopic"
          ) {
            await env.DB.prepare("DELETE FROM devices WHERE token = ?").bind(device.token).run();
          }
          // An expired provider token: drop the cache so the next call mints one.
          if (reason === "ExpiredProviderToken") cached = null;
        })
      );
    }
  } catch (error) {
    console.error("push failed", error);
  }
}
