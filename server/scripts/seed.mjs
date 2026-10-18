#!/usr/bin/env node
/**
 * Fills one account with conversations from people who do not exist, for
 * development. The people are real rows (so everything behaves as it does for
 * real friends) but have no handle, so nobody can find or start a talk with
 * them, and the only talks they are in are ones with the account named here.
 *
 *   export CLOUDFLARE_API_TOKEN=...
 *   node scripts/seed.mjs --to <user id> [--videos ~/Downloads/TypicalTalk]
 *   node scripts/seed.mjs --to <user id> --remove
 *
 * Safe to run twice: ids are derived from names, and existing rows are kept.
 */

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";

const args = process.argv.slice(2);
const flag = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const me = flag("--to");
const remove = args.includes("--remove");
const dry = args.includes("--dry");
const videos = (flag("--videos") ?? "~/Downloads/TypicalTalk").replace(/^~/, homedir());

if (!me || !/^[0-9a-f-]{36}$/.test(me)) {
  console.error("Usage: node scripts/seed.mjs --to <your user id> [--videos <folder>] [--remove]");
  process.exit(1);
}

/** The same name always gives the same id, so a second run finds the first. */
const uuid = (name) => {
  const h = createHash("sha1").update(`typical-talk-seed:${name}`).digest();
  h[6] = (h[6] & 0x0f) | 0x50;
  h[8] = (h[8] & 0x3f) | 0x80;
  const x = h.subarray(0, 16).toString("hex");
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`;
};

const PEOPLE = ["Bob", "Freya", "Lindsey", "Marcus", "Jake", "Priya", "Sofia"];
const GROUP_FILES = "GroupChat/Agent Video - Vertical selfie-style video shot on a phone_s front-facing camera_ held at arm_s lengt";

// file: path under --videos. by: who sent it. ago: minutes before now.
// watched: seen by the other side (the account for theirs, them for yours).
const TALKS = [
  {
    key: "crew", title: "Weekend Crew", members: ["Jake", "Marcus", "Priya"],
    takes: [
      { file: `${GROUP_FILES} (8).mp4`, by: "Priya", ago: 6 },
      { file: `${GROUP_FILES} (7).mp4`, by: "Marcus", ago: 24 },
      { file: `${GROUP_FILES} (6).mp4`, by: "Jake", ago: 51, watched: true },
    ],
  },
  {
    key: "sofia", members: ["Sofia"],
    takes: [
      { file: "ME and Sofia/Sofia2.mp4", by: "Sofia", ago: 14 },
      { file: "ME and Sofia/ME.mp4", by: "me", ago: 40, watched: true },
      { file: "ME and Sofia/Sofia1.mp4", by: "Sofia", ago: 95, watched: true },
    ],
  },
  { key: "bob", members: ["Bob"], takes: [{ file: "Bob2.mp4", by: "Bob", ago: 33 }, { file: "Bob.mp4", by: "Bob", ago: 210 }] },
  { key: "freya", members: ["Freya"], takes: [{ file: "Freya.mp4", by: "Freya", ago: 120 }] },
  { key: "lindsey", members: ["Lindsey"], takes: [{ file: "Lindsey.mp4", by: "Lindsey", ago: 320 }] },
  { key: "marcus", members: ["Marcus"], takes: [{ file: "Marcus.mp4", by: "Marcus", ago: 1500 }] },
];

const wrangler = (...a) => execFileSync("wrangler", a, { stdio: ["ignore", "pipe", "inherit"], encoding: "utf8" });
const q = (s) => `'${String(s).replaceAll("'", "''")}'`;
const sec = (file) => {
  const out = execFileSync("mdls", ["-raw", "-name", "kMDItemDurationSeconds", file], { encoding: "utf8" });
  return Number(out) || 10;
};

const now = Date.now();
const userID = (name) => (name === "me" ? me : uuid(`user:${name}`));
const sql = [];
const uploads = [];
const keys = [];

for (const name of PEOPLE) {
  sql.push(`INSERT OR IGNORE INTO users (id, apple_user_id, name, email, created_at, is_seed) VALUES (${q(userID(name))}, ${q(`seed:${name.toLowerCase()}`)}, ${q(name)}, NULL, ${now}, 1);`);
}

for (const talk of TALKS) {
  const talkID = uuid(`talk:${talk.key}`);
  const isGroup = talk.members.length > 1;
  sql.push(`INSERT OR IGNORE INTO talks (id, title, created_at, created_by) VALUES (${q(talkID)}, ${talk.title ? q(talk.title) : "NULL"}, ${now - 3 * 86_400_000}, ${isGroup ? q(uuid("user:Jake")) : "NULL"});`);
  for (const m of ["me", ...talk.members]) {
    sql.push(`INSERT OR IGNORE INTO members (talk_id, user_id, joined_at) VALUES (${q(talkID)}, ${q(userID(m))}, ${now});`);
  }
  for (const [i, take] of talk.takes.entries()) {
    const path = join(videos, take.file);
    if (!remove && !existsSync(path)) throw new Error(`Missing video: ${path}`);
    const takeID = uuid(`take:${talk.key}:${i}`);
    const key = `takes/${talkID}/${takeID}.mov`;
    keys.push(key);
    if (remove) continue;
    uploads.push({ key, path });
    const sentAt = now - take.ago * 60_000;
    sql.push(`INSERT OR IGNORE INTO takes (id, talk_id, author_id, storage_key, duration, voice_only, sent_at, created_at) VALUES (${q(takeID)}, ${q(talkID)}, ${q(userID(take.by))}, ${q(key)}, ${sec(path)}, 0, ${sentAt}, ${sentAt});`);
    if (take.watched) {
      // Watched by whoever did not send it.
      const watcher = take.by === "me" ? userID(talk.members[0]) : me;
      sql.push(`INSERT OR IGNORE INTO watches (take_id, user_id, watched_at) VALUES (${q(takeID)}, ${q(watcher)}, ${sentAt + 60_000});`);
    }
  }
}

if (dry) {
  console.log(sql.join("\n"));
  console.log(`\n-- ${uploads.length} files would be uploaded:`);
  for (const u of uploads) console.log(`--   ${u.path} -> ${u.key}`);
  process.exit(0);
}

const dir = mkdtempSync(join(tmpdir(), "tt-seed-"));
const file = join(dir, "seed.sql");

if (remove) {
  for (const key of keys) wrangler("r2", "object", "delete", `typical-talk-takes/${key}`, "--remote");
  // Removing the people removes their takes and talks with them (cascade).
  const ids = PEOPLE.map((n) => q(userID(n))).join(", ");
  writeFileSync(file, `DELETE FROM talks WHERE id IN (SELECT talk_id FROM members WHERE user_id IN (${ids}));\nDELETE FROM users WHERE id IN (${ids});\n`);
  wrangler("d1", "execute", "typical-talk", "--remote", `--file=${file}`);
  console.log(`Removed ${PEOPLE.length} seed people and ${keys.length} takes.`);
} else {
  for (const [i, u] of uploads.entries()) {
    console.log(`Uploading ${i + 1}/${uploads.length}: ${u.key.split("/").pop()}`);
    wrangler("r2", "object", "put", `typical-talk-takes/${u.key}`, `--file=${u.path}`, "--content-type=video/quicktime", "--remote");
  }
  writeFileSync(file, sql.join("\n") + "\n");
  wrangler("d1", "execute", "typical-talk", "--remote", `--file=${file}`);
  console.log(`Seeded ${PEOPLE.length} people, ${TALKS.length} talks and ${uploads.length} takes for ${me}.`);
}
