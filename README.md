# dorm-lock

wip. esp32 + servo to turn the thumb-turn on my dorm door, controlled from my phone. this is the backend part so far - a cloudflare worker + durable object. no hardware yet.

## status

- [x] worker deployed, tests pass against it
- [x] fake esp32 script so i can test without the board
- [ ] ios shortcut
- [ ] esp32 firmware
- [ ] servo mount / 3d printed parts
- [ ] rate limiting, DEVICE_SECRET

## how it works

phone POSTs `/command` (or `/toggle`) and that request waits. the esp32 long polls `/poll`, gets the command right away, turns the servo, then POSTs `/confirm` which lets the phone's request return. both requests meet in the same durable object so its all in memory, no polling loop.

commands are absolute (`locked`/`unlocked`), not "flip it", so running something twice cant leave the door wrong. they also expire after 60s so an old unlock cant go off when the esp32 reconnects later.

```
phone --POST /command--> worker (DO) --wakes--> esp32 (waiting on GET /poll)
                                     <--POST /confirm--
      <-- {"ok":true,"state":"unlocked"}
```

## endpoints

everything except /health needs `X-Lock-Secret: <secret>` as a header (putting it in the url doesnt work). https only.

- `POST /command` - `{"target":"locked"}` or `"unlocked"`. waits ~10s for the esp32. optional: `force`, `requestId` (safe to retry), `waitMs` (0 = dont wait)
- `POST /toggle` - flips from the last confirmed state. 1 request instead of /state + /command, and a double tap joins the first one instead of flipping back
- `GET /poll?after=<id>&wait=<ms>` - for the esp32. held open up to 25s, 204 if nothing
- `POST /confirm` - `{"commandId":N,"ok":true,"state":"locked"}`, also esp32. sending it twice is fine
- `GET /state` - current state + if the esp32 is connected
- `GET /health`

replies have `ok` + `status` (`confirmed` `already` `timeout` `device_error` `superseded` `expired` `unknown` `queued`). failures are still http 200 on purpose bc ios shortcuts gives up on anything non-2xx. set `STRICT_STATUS = "1"` for real 504/409s.

## setup

```bash
npm install
npx wrangler login
npx wrangler deploy
npx wrangler secret put SHARED_SECRET
```

generate a secret with `node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"`. secret put works right away, no redeploy.

local dev: `cp .dev.vars.example .dev.vars`, then `npx wrangler dev`. .dev.vars doesnt override whats already in `[vars]` so change those in wrangler.toml

## testing

no hardware needed. `device-sim` pretends to be the esp32, `e2e` pretends to be the phone. theres a bash and a powershell version of each

```bash
BASE=https://dorm-lock.your-subdomain.workers.dev SECRET=... bash test/e2e.sh
```

```powershell
.\test\e2e.ps1 -Base https://dorm-lock.your-subdomain.workers.dev -Secret ...
```

- `test/edge.sh` - supersede + expiry. needs `COMMAND_TTL_MS = "3000"` in wrangler.toml for a sec
- `test/toggle.ps1` - /toggle stuff

on windows use `curl.exe` not `curl`, and if powershell blocks the scripts run them with `powershell -ExecutionPolicy Bypass -File ...`

## notes

- free tier is 100k req/day. the esp32 polling is basically all of it, 25s polls = ~3.5k/day. durable object duration (GB-s) is the thing to actually keep an eye on since the poll keeps it busy all day
- the secret is basically the key to the door
- keep a real key on you. wifi / power / cloudflare can all go down
