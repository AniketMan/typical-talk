# Typical Talk server

A Cloudflare Worker with D1 and R2. It knows who you are, how people find each
other, and the talks and takes that follow. Transcripts are made and kept on
the phone and never reach it.

Live at https://typical-talk.anibhatt.workers.dev

## Endpoints

Everything under `/v1` except `/v1/session` needs `Authorization: Bearer <session>`.

| Method | Path | Does |
|---|---|---|
| POST | `/v1/session` | Verifies an Apple identity token, returns a session token |
| GET / PUT / DELETE | `/v1/me` | The signed-in user; rename; delete the account and everything in it |
| PUT | `/v1/me/handle` | Claims or changes a handle |
| GET | `/v1/users?handle=` | Finds someone by handle |
| POST | `/v1/invites` | Creates a single-use invite link |
| POST | `/v1/invites/{code}/redeem` | Accepts an invite, creating the talk |
| POST | `/v1/talks` | `{userID}` starts a one to one talk; `{userIDs, title?}` starts a group |
| GET | `/v1/talks?since=` | Talks, members and takes, incrementally (see below) |
| POST | `/v1/talks/{id}/members` | Adds someone you already talk to into a group |
| DELETE | `/v1/talks/{id}/membership` | Leaves a talk |
| PUT | `/v1/talks/{id}/takes/{takeID}` | Uploads a take (body is the file). The id is the phone's, so a retry cannot duplicate it |
| GET | `/v1/takes/{id}/file` | Downloads a take, with `Range` support |
| POST | `/v1/takes/{id}/watched` | Records a watch receipt |
| PUT / DELETE | `/v1/devices[/{token}]` | Registers or removes a phone for push |
| GET / POST / DELETE | `/v1/blocks[/{userID}]` | Lists, adds and removes blocks |
| POST | `/v1/reports` | Reports a take |
| GET | `/i/{code}` | The page an invite link opens |

`GET /v1/talks?since=T` returns every talk you are in, but only the takes that
are new since `T`, that someone has watched since `T`, or whose file has since
expired. `serverTime` in the answer is the `T` for next time. Start with 0.

## Deploying

    cd server
    source <something that exports CLOUDFLARE_API_TOKEN>     # account: Anibhatt@msn.com
    npm install && npm run check                             # type-check
    wrangler d1 execute typical-talk --remote --file=migrations/0002_sync.sql   # once
    wrangler deploy

`schema.sql` is the full schema for a fresh database. `migrations/` holds the
steps for one that already exists; apply each once, in order.

### Secrets

    wrangler secret put SESSION_SECRET        # signs session tokens (required)
    wrangler secret put ADMIN_TOKEN           # switches on /admin (see below)
    wrangler secret put APNS_KEY_ID           # push: the key's 10 character id
    wrangler secret put APNS_PRIVATE_KEY      # push: contents of the .p8 file
    wrangler secret put APPLE_SIWA_KEY_ID     # revoke Sign in with Apple on deletion
    wrangler secret put APPLE_SIWA_PRIVATE_KEY

Push and Sign in with Apple revocation are optional: without their secrets the
rest works and those two quietly do nothing. The APNs key must be created in
the Apple Developer portal under Keys with "Apple Push Notifications service"
ticked; the Sign in with Apple key under Keys with "Sign in with Apple".

## How long takes are kept

A take's file is deleted 90 days after it was sent (`TAKE_LIFETIME_MS` in
`src/common.ts`). A daily cron does it and marks the take `expired`; phones that
already downloaded it keep their copy, and phones that have not drop it. An R2
lifecycle rule on `takes/` at 100 days is a backstop for files that were
uploaded but never recorded in the database.

## Handling reports

Someone reports a take from the thread's menu. The take vanishes for them at
once and a row lands in `reports`. To act on it, with the token in
`~/.typical-talk-admin-token`:

    TOKEN=$(cat ~/.typical-talk-admin-token); H=https://typical-talk.anibhatt.workers.dev
    curl -H "authorization: Bearer $TOKEN" $H/admin/reports                       # open reports
    curl -X POST -H "authorization: Bearer $TOKEN" $H/admin/takes/<take id>/remove  # delete one take
    curl -X POST -H "authorization: Bearer $TOKEN" $H/admin/users/<user id>/ban     # erase the person, bar the Apple ID
    curl -X POST -H "authorization: Bearer $TOKEN" $H/admin/reports/<id>/handled    # close it

App Review expects reports to be dealt with within a day.

## Development data

`scripts/seed.mjs` fills one account with conversations from people who do not
exist, using videos from a folder on disk. They have no handle, so nobody can
find them or start a talk with them, and they are only in talks with that
account. `--remove` takes them out again.

    node scripts/seed.mjs --to <your user id> --videos ~/Downloads/TypicalTalk

## Notes

- Takes upload and download through the Worker rather than with presigned
  URLs. Fine for ten second clips; revisit if takes get long.
- Unknown paths answer 401 rather than 404, because the session check runs
  before routing.
