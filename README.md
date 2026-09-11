# dorm-lock

This is a work in progress.. esp32 + servo to turn the thumb-turn on my dorm door, controlled from my phone. backend, phone side and a first pass at the firmware are here. the hardware is on my desk, not on the door yet.

TLDR:
Basically the ESP32 is a little chip that can both connect to wifi and control arduino servos. The ESP32 connects to wifi (in my case dorm wifi, which makes things considerably harder than a personal wifi connection). Then, the ESP32 also connects to the servo (dupont wires, nothing super complex). the servo I have is 20 kg·cm of torque, which is more than enough for the thumb turn lock. the ESP32 connection is already done, the connection to the servo is already done, and the actual wireless trigger mechanism with the shortcut/NFC tag is done too.

The way it works, in essence, is that the shortcut on the phone connects to the cloudflare worker, sends a toggle command, and the ESP32 gets that command, which triggers the servo movement that locks/unlocks the door. That's all.

So the final mechanism would be: 
- Tap phone on NFC tag (placed somewhere on the door)
- Shortcut sends command to Cloudflare worker
- ESP32 gets the command, sends movement command to servo
- servo moves, unlocks (or locks) the door. The shortcut just says toggle, and the worker turns that into an absolute locked/unlocked before the ESP32 sees it, so a double tap can't flip it back.

Note: the servo locks movement when connected, so the 3D printed part that will be used for the servo to turn the lock will rest in a position that does not impede regular key usage. This avoids almost all failure modes, though there are things that could still break it, like power loss while the servo is in the middle of movement.

## status

- [x] worker deployed, tests pass against it
- [x] fake esp32 script so i can test without the board
- [x] ios shortcut + nfc tag ([SHORTCUTS.md](SHORTCUTS.md))
- [ ] esp32 firmware - wip. connects to wifi and reaches the worker, but the wifi where the board is sits around -85 dBm and long polls were hanging. current version has a watchdog + 8s polls, havent confirmed it on the board yet
- [ ] calibrate the servo angles
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

## firmware

`firmware/dorm_lock/`. arduino ide, board "ESP32 Dev Module", no extra libraries.

1. copy `secrets.example.h` to `secrets.h` and fill it in (its gitignored)
2. set `CALIBRATE_MODE 1`, upload, open serial at 9600 and type angles to find locked/unlocked. do this before attaching the servo to the lock
3. put the angles in, set `CALIBRATE_MODE 0`, upload again

wiring: servo signal on gpio 13, powered from its own 5v supply (not the esp32, it pulls way too much current), with the supply's - tied to the esp32 GND.

tls is pinned to GTS Root R4 (what workers.dev uses) instead of setInsecure(), so nobody on the dorm wifi can grab the secret.

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

- free tier is 100k req/day. the esp32 polling is basically all of it - 25s polls = ~3.5k/day, the 8s polls the firmware uses right now = ~11k/day, both fine. durable object duration (GB-s) is the thing to actually keep an eye on since the poll keeps it busy all day
- the secret is basically the key to the door. its in the shortcut and in secrets.h
- keep a real key on you. wifi / power / cloudflare can all go down
