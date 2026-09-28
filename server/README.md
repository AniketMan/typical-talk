# Typical Talk server

A Cloudflare Worker with D1 and R2. It knows who you are, the two ways to add
a friend, and the talks and takes that follow. Transcripts are made and kept
on the phone and never reach it.

Live at https://typical-talk.anibhatt.workers.dev

## Endpoints

| Method | Path | Does |
|---|---|---|
| POST | `/v1/session` | Verifies an Apple identity token, returns a session token |
| GET | `/v1/me` | The signed-in user |
| PUT | `/v1/me/handle` | Claims or changes a handle |
| GET | `/v1/users?handle=` | Finds someone by handle |
| POST | `/v1/invites` | Creates a single-use invite link |
| POST | `/v1/invites/{code}/redeem` | Accepts an invite, creating the talk |
| POST | `/v1/talks` | Starts a one to one talk |
| GET | `/v1/talks?since=` | Talks, members and takes |
| POST | `/v1/talks/{id}/takes` | Uploads a take (body is the file) |
| GET | `/v1/takes/{id}/file` | Downloads a take |
| POST | `/v1/takes/{id}/watched` | Records a watch receipt |
| GET | `/i/{code}` | The page an invite link opens |

## Deploying

    cd server
    export CLOUDFLARE_API_TOKEN=...            # account: Anibhatt@msn.com
    wrangler d1 execute typical-talk --remote --file=schema.sql
    wrangler secret put SESSION_SECRET         # any random 32+ characters
    wrangler deploy

## Not done yet

- Takes upload and download through the Worker rather than with presigned
  URLs. Fine for ten second clips; revisit if takes get long.
- No push notifications, so a new take is seen on next open.
- Unknown paths answer 401 rather than 404, because the session check runs
  before routing.
