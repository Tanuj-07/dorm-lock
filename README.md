# dorm-lock

This is a work in progress.. esp32 + servo to turn the thumb-turn on my dorm door, controlled from my phone. the mechanics are done, tapping my phone on the nfc tag spins the servo in under a second. the only thing left is mounting it on the door (3d printed parts).

TLDR:
Basically the ESP32 is a little chip that can do wifi and bluetooth and control arduino servos. Originally the ESP32 connected to the dorm wifi directly, but where the door is the signal is around -85 dBm and the connection kept hanging. So now my Mac (which is always on anyway) does the internet part: it talks to the Cloudflare worker and sends the commands to the ESP32 over bluetooth. The ESP32 doesn't touch wifi at all anymore. The ESP32 connects to the servo with dupont wires, nothing super complex. the servo I have is 20 kg·cm of torque, which is more than enough for the thumb turn lock.

So the mechanism is:
- Tap phone on NFC tag (placed somewhere on the door)
- Shortcut sends command to Cloudflare worker
- Mac picks up the command and sends it to the ESP32 over bluetooth
- ESP32 moves the servo, unlocks (or locks) the door. The shortcut just says toggle, and the worker turns that into an absolute locked/unlocked before it gets sent on, so a double tap can't flip it back.

Note: the servo locks movement when connected, so the 3D printed part that will be used for the servo to turn the lock will rest in a position that does not impede regular key usage. This avoids almost all failure modes, though there are things that could still break it, like power loss while the servo is in the middle of movement.

## status

- [x] worker deployed, tests pass against it
- [x] ios shortcut + nfc tag ([SHORTCUTS.md](SHORTCUTS.md))
- [x] esp32 firmware (bluetooth version)
- [x] mac bridge, runs on its own at login
- [x] end to end works: tap the tag -> servo moves
- [ ] mount it on the door: 3d printed parts + calibrate the servo angles once its on the lock
- [ ] rate limiting, DEVICE_SECRET

## how it works

```
phone --POST /toggle--> worker (DO) <--GET /poll-- mac (bridge.py) --bluetooth--> esp32 --> servo
                                    <--POST /confirm--
      <-- {"ok":true,"state":"unlocked"}
```

the phone POSTs `/toggle` (or `/command`) and that request waits. the mac is always long polling `/poll`, so it gets the command right away, sends it to the esp32 over bluetooth, waits for the esp32 to say it moved, then POSTs `/confirm`, which lets the phone's request return with the real result. the phone request and the mac's poll meet in the same durable object so its all in memory, no polling loop.

commands are absolute (`locked`/`unlocked`), not "flip it", so running something twice cant leave the door wrong. they also expire after 60s so an old unlock cant go off when the mac reconnects later.

the bluetooth cmds are signed (hmac with a shared key + a random nonce the esp32 changes after every cmd), otherwise anyone in bluetooth range could unlock the door with a phone app.

## endpoints

everything except /health needs `X-Lock-Secret: <secret>` as a header (putting it in the url doesnt work). https only.

- `POST /command` - `{"target":"locked"}` or `"unlocked"`. waits ~10s for the device. optional: `force`, `requestId` (safe to retry), `waitMs` (0 = dont wait)
- `POST /toggle` - flips from the last confirmed state. 1 request instead of /state + /command, and a double tap joins the first one instead of flipping back
- `GET /poll?after=<id>&wait=<ms>` - for the mac bridge. held open up to 25s, 204 if nothing
- `POST /confirm` - `{"commandId":N,"ok":true,"state":"locked"}`, also the bridge. sending it twice is fine
- `GET /state` - current state + if the bridge is connected
- `GET /health`

replies have `ok` + `status` (`confirmed` `already` `timeout` `device_error` `superseded` `expired` `unknown` `queued`). failures are still http 200 on purpose bc ios shortcuts gives up on anything non-2xx. set `STRICT_STATUS = "1"` for real 504/409s.

## setup

### worker

```bash
npm install
npx wrangler login
npx wrangler deploy
npx wrangler secret put SHARED_SECRET
```

generate a secret with `node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"`. secret put works right away, no redeploy.

local dev: `cp .dev.vars.example .dev.vars`, then `npx wrangler dev`. .dev.vars doesnt override whats already in `[vars]` so change those in wrangler.toml

### esp32

`firmware/dorm_lock_ble/`. arduino ide, board "ESP32 Dev Module", no extra libraries.

1. copy `secrets.example.h` to `secrets.h` and put in a key: `python3 -c "import secrets; print(secrets.token_hex(32))"`. same key goes in the mac's config.json
2. set `CALIBRATE_MODE 1`, upload, open serial at 9600 and type angles to find locked/unlocked. do this before attaching the servo to the lock
3. put the angles in, set `CALIBRATE_MODE 0`, upload again. serial should say `advertising as dorm-lock`

wiring: servo signal on gpio 13, powered from its own 5v supply (not the esp32, it pulls way too much current), with the supply's - tied to the esp32 GND.

`firmware/dorm_lock/` is the old wifi version, not used anymore.

### mac bridge

copy `bridge/` to the mac (i keep it in `~/dorm-lock`), then:

```bash
python3 -m venv ~/dorm-lock-venv
~/dorm-lock-venv/bin/pip install -r requirements.txt
cp config.example.json config.json   # fill in the worker url, secret, ble key
~/dorm-lock-venv/bin/python3 bridge.py
```

macos asks for bluetooth permission the first time. dont use python 3.9.0, it has a typing bug that breaks bleak (3.9.6 from xcode works, so does anything newer).

to run it on its own at login theres a tiny launcher app (`launcher/launcher.c`, built into `DormLockBridge.app`) so the bridge gets its own bluetooth permission, plus a launchd plist. the paths in the plist and launcher are for my mac, change them. build it with:

```bash
clang -O2 -o DormLockBridge.app/Contents/MacOS/DormLockBridge launcher/launcher.c
codesign --force --sign - --identifier com.tanuj.dormlockbridge DormLockBridge.app
cp com.tanuj.dorm-lock-bridge.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tanuj.dorm-lock-bridge.plist
```

to run it by hand for debugging, stop the service first so two bridges dont fight: `launchctl bootout gui/$(id -u)/com.tanuj.dorm-lock-bridge`

`python3 bridge.py --fake-ble` skips bluetooth and just pretends, for testing the worker side.

## testing

no hardware needed. `device-sim` pretends to be the bridge/esp32, `e2e` pretends to be the phone. theres a bash and a powershell version of each

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

- free tier is 100k req/day. the mac's polling is basically all of it, 25s polls = ~3.5k/day. durable object duration is the tighter one, the poll keeps the DO busy all day so its ~11k of the 13k GB-s/day free. fine as long as nothing else on the account uses durable objects
- the worker secret is basically the key to the door. its in the shortcut and the mac's config.json. the ble key is in config.json and the esp32's secrets.h. all gitignored
- keep a real key on you. wifi / power / cloudflare / the mac can all go down
