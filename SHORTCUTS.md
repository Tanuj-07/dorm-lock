# ios shortcuts

one "Toggle Door" shortcut + an nfc tag by the door.

you need the worker url (`https://dorm-lock.your-subdomain.workers.dev`) and the secret you gave `wrangler secret put SHARED_SECRET`.

## toggle door

uses `/toggle` so its one request, the worker picks locked/unlocked itself.

1. **Text** - the worker url, no slash at the end
2. **Set Variable** `Base` = that text
3. **Text** - the secret
4. **Set Variable** `Secret` = that text
5. **Get Contents of URL**
   - url: the `Base` variable, then type `/toggle` after it
   - method POST
   - header `X-Lock-Secret` = the `Secret` variable
   - body: JSON with no fields (empty is right)
6. **Get Dictionary Value** key `state` -> **Set Variable** `Result`
7. **Get Dictionary Value** key `status` -> **Set Variable** `Status`
8. **Show Notification**: `Status` + ` - door reads ` + `Result`

gotchas:
- 2 Text actions in a row and Set Variable likes to grab the wrong one. check both
- `state`/`status` are json keys so you type them. `Result`/`Status` are your own variables
- step 5 hangs up to ~10s while the esp32 does its thing. dont add a Wait
- notif says "door reads" not "door is now" bc on a timeout nothing actually moved

normally you get `confirmed`. `timeout` = esp32 offline, `device_error` = servo reported a failure.

double taps are fine, the 2nd one joins the first instead of flipping it back.

## separate lock / unlock

if you want absolute buttons instead (better for siri or someone else using it): same thing but POST `/command` with a JSON field `target` = `locked` or `unlocked`. can GET `/state` first and bail with a notification if its already there.

## nfc

1. Shortcuts > Automation > + > NFC
2. Scan, hold the TOP of the phone to the tag
3. pick Toggle Door
4. Run Immediately on, Notify When Run off

- phone has to be unlocked for it to run. ios thing, no way around it (it sees the tag on the lock screen but wont run until face id)
- slow to read? tag on metal is bad (get on-metal tags) and aim the top edge of the phone not the middle
- apple watch, or hey siri with Allow Siri When Locked on, are the only ways that skip unlocking

## testing without the esp32

run the fake esp32 on a laptop, then tap the shortcut:

```powershell
.\test\device-sim.ps1 -Base https://dorm-lock.your-subdomain.workers.dev -Secret ...
```

with nothing running you get `timeout` after ~10s, which is correct
