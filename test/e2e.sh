#!/usr/bin/env bash
# e2e test, no hardware. this is the phone, device-sim.sh is the esp32
#   BASE=http://127.0.0.1:8787 SECRET=dev-secret-change-me bash test/e2e.sh
# needs curl + node (node is just for reading json)
set -u

BASE="${BASE:-http://127.0.0.1:8787}"
SECRET="${SECRET:?set SECRET}"
PASS=0
FAIL=0
# requestIds stick around in the DO so they have to be unique per run
RUN_ID="e2e-$$-$(date +%s)"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: expected [$3] got [$2]"; fi; }

# jget <json> <path>
jget() {
  printf '%s' "$1" | node -e '
    let s="";
    process.stdin.on("data", d => s += d).on("end", () => {
      try {
        const o = JSON.parse(s);
        const v = process.argv[1].split(".").reduce((a,k) => (a==null ? a : a[k]), o);
        console.log(v === undefined || v === null ? "" : String(v));
      } catch { console.log(""); }
    });
  ' "$2"
}

BODY=""; CODE=""
req() {
  local method="$1" path="$2" data="${3:-}"
  local out
  if [ -n "$data" ]; then
    out=$(curl -sS --max-time 45 -X "$method" \
      -H "X-Lock-Secret: $SECRET" -H 'Content-Type: application/json' \
      -d "$data" -w '\n%{http_code}' "$BASE$path")
  else
    out=$(curl -sS --max-time 45 -X "$method" \
      -H "X-Lock-Secret: $SECRET" -w '\n%{http_code}' "$BASE$path")
  fi
  CODE=$(printf '%s' "$out" | tail -1)
  BODY=$(printf '%s' "$out" | sed '$d')
}

now_ms() { node -e 'console.log(Date.now())'; }

DEVICE_PID=""
start_device() {
  BASE="$BASE" SECRET="$SECRET" SERVO_MS="${1:-300}" bash "$(dirname "$0")/device-sim.sh" >/tmp/dorm-lock-device.log 2>&1 &
  DEVICE_PID=$!
  sleep 2 # let it connect
}
stop_device() {
  [ -n "$DEVICE_PID" ] && kill "$DEVICE_PID" 2>/dev/null
  wait "$DEVICE_PID" 2>/dev/null
  DEVICE_PID=""
  sleep 1
}
trap 'stop_device' EXIT

printf 'Target: %s\n' "$BASE"

say "1. auth"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/health")
check "GET /health needs no secret" "$CODE" "200"

CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/state")
check "GET /state without secret -> 401" "$CODE" "401"

CODE=$(curl -sS -o /dev/null -w '%{http_code}' -H 'X-Lock-Secret: wrong' "$BASE/state")
check "GET /state with wrong secret -> 401" "$CODE" "401"

# secret in the url should NOT work
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/state?secret=$SECRET")
check "secret in the URL is not accepted -> 401" "$CODE" "401"

req GET /state
check "GET /state with secret -> 200" "$CODE" "200"
printf '  state=%s lastConfirmedId=%s\n' "$(jget "$BODY" state)" "$(jget "$BODY" lastConfirmedId)"

say "2. validation"
req POST /command '{"target":"banana"}'
check "bad target -> 400" "$CODE" "400"
req POST /command '{}'
check "missing target -> 400" "$CODE" "400"
req POST /command 'not json'
check "invalid json -> 400" "$CODE" "400"
req POST /confirm '{"ok":true}'
check "confirm without commandId -> 400" "$CODE" "400"

# ---- device online ----
say "3. happy path (device online)"
start_device 300

req POST /command '{"target":"locked","force":true}'
check "force lock -> ok" "$(jget "$BODY" ok)" "true"
check "  status" "$(jget "$BODY" status)" "confirmed"
check "  state" "$(jget "$BODY" state)" "locked"
BASE_ID=$(jget "$BODY" commandId)

req POST /command '{"target":"unlocked"}'
check "unlock -> ok" "$(jget "$BODY" ok)" "true"
check "  status" "$(jget "$BODY" status)" "confirmed"
check "  state" "$(jget "$BODY" state)" "unlocked"
check "  command id incremented" "$(jget "$BODY" commandId)" "$((BASE_ID+1))"
UNLOCK_ID=$(jget "$BODY" commandId)

req GET /state
check "/state agrees" "$(jget "$BODY" state)" "unlocked"
check "/state lastConfirmedId" "$(jget "$BODY" lastConfirmedId)" "$UNLOCK_ID"
check "/state sees the device online" "$(jget "$BODY" device.connected)" "true"

say "4. idempotency"
req POST /command '{"target":"unlocked"}'
check "repeat absolute target -> no new command" "$(jget "$BODY" status)" "already"
check "  command id unchanged" "$(jget "$BODY" commandId)" "$UNLOCK_ID"

req POST /confirm "{\"commandId\":$UNLOCK_ID,\"ok\":true,\"state\":\"unlocked\"}"
check "replayed confirm -> duplicate" "$(jget "$BODY" status)" "duplicate"
check "  state unchanged" "$(jget "$BODY" state)" "unlocked"
check "  lastConfirmedId unchanged" "$(jget "$BODY" lastConfirmedId)" "$UNLOCK_ID"

req POST /confirm "{\"commandId\":$((UNLOCK_ID+99)),\"ok\":true,\"state\":\"locked\"}"
check "confirm for an id never issued -> 409" "$CODE" "409"
check "  error" "$(jget "$BODY" error)" "unknown_command"

req GET /state
check "state survived the bogus confirms" "$(jget "$BODY" state)" "unlocked"

say "5. long poll wakes immediately on a new command"
stop_device
req GET /state
AFTER=$(jget "$BODY" lastCommandId)

T0=$(now_ms)
curl -sS --max-time 30 -H "X-Lock-Secret: $SECRET" \
  -w '\n%{http_code}' "$BASE/poll?after=$AFTER&wait=20000" >/tmp/dorm-lock-poll.out &
POLL_PID=$!
sleep 1

curl -sS -X POST -H "X-Lock-Secret: $SECRET" -H 'Content-Type: application/json' \
  -d '{"target":"locked","waitMs":0}' "$BASE/command" >/dev/null
wait "$POLL_PID"
T1=$(now_ms)
ELAPSED=$((T1-T0))

POLL_BODY=$(sed '$d' /tmp/dorm-lock-poll.out)
POLL_CODE=$(tail -1 /tmp/dorm-lock-poll.out)
check "parked poll returned 200" "$POLL_CODE" "200"
check "  it got the new command" "$(jget "$POLL_BODY" target)" "locked"
PENDING_ID=$(jget "$POLL_BODY" commandId)
if [ "$ELAPSED" -lt 5000 ]; then
  ok "poll woke in ${ELAPSED}ms (not after the 20s timeout)"
else
  bad "poll took ${ELAPSED}ms — it timed out instead of being woken"
fi

say "6. long poll returns 204 when nothing happens"
T0=$(now_ms)
CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
  -H "X-Lock-Secret: $SECRET" "$BASE/poll?after=$PENDING_ID&wait=3000")
T1=$(now_ms)
check "no new command -> 204" "$CODE" "204"
ELAPSED=$((T1-T0))
if [ "$ELAPSED" -ge 2500 ]; then
  ok "held the connection open for ${ELAPSED}ms"
else
  bad "returned after only ${ELAPSED}ms — it is not holding the request"
fi

#### offline
say "7. device offline"
req POST /confirm "{\"commandId\":$PENDING_ID,\"ok\":true,\"state\":\"locked\"}"
check "manual confirm of the queued command" "$(jget "$BODY" status)" "confirmed"
check "  state" "$(jget "$BODY" state)" "locked"

T0=$(now_ms)
req POST /command '{"target":"unlocked","waitMs":3000,"requestId":"'"$RUN_ID"'-retry"}'
T1=$(now_ms)
check "command with no device -> ok:false" "$(jget "$BODY" ok)" "false"
check "  status" "$(jget "$BODY" status)" "timeout"
check "  state is still the last confirmed one" "$(jget "$BODY" state)" "locked"
STUCK_ID=$(jget "$BODY" commandId)
ELAPSED=$((T1-T0))
if [ "$ELAPSED" -ge 2500 ] && [ "$ELAPSED" -lt 8000 ]; then
  ok "waited ~${ELAPSED}ms then gave up"
else
  bad "waited ${ELAPSED}ms, expected ~3000ms"
fi

req POST /command '{"target":"unlocked","waitMs":1000,"requestId":"'"$RUN_ID"'-retry"}'
check "same requestId -> no second command issued" "$(jget "$BODY" commandId)" "$STUCK_ID"
check "  marked as a replay" "$(jget "$BODY" replay)" "true"

req GET /state
check "  still exactly one command outstanding" "$(jget "$BODY" pending.commandId)" "$STUCK_ID"

say "8. the device comes back and picks up the queued command"
start_device 300
sleep 3
req GET /state
check "queued unlock executed on reconnect" "$(jget "$BODY" state)" "unlocked"
check "  nothing left pending" "$(jget "$BODY" pending)" ""

say "9. device reports a failure"
stop_device
curl -sS -X POST -H "X-Lock-Secret: $SECRET" -H 'Content-Type: application/json' \
  -d '{"target":"locked","waitMs":0}' "$BASE/command" >/tmp/dorm-lock-cmd.out
FAIL_ID=$(jget "$(cat /tmp/dorm-lock-cmd.out)" commandId)
req POST /confirm "{\"commandId\":$FAIL_ID,\"ok\":false,\"detail\":\"servo stalled\"}"
check "failed confirm -> ok:false" "$(jget "$BODY" ok)" "false"
check "  status" "$(jget "$BODY" status)" "device_error"
check "  state NOT advanced to the target" "$(jget "$BODY" state)" "unlocked"

req GET /state
check "  /state still unlocked" "$(jget "$BODY" state)" "unlocked"

say "10. a newer command supersedes an older one"
start_device 2500
curl -sS -X POST -H "X-Lock-Secret: $SECRET" -H 'Content-Type: application/json' \
  -d '{"target":"locked","waitMs":8000}' "$BASE/command" >/tmp/dorm-lock-first.out 2>&1 &
FIRST_PID=$!
sleep 4 # device is mid servo move on cmd A here
req POST /command '{"target":"unlocked","waitMs":6000,"force":true}'
wait "$FIRST_PID"
FIRST=$(cat /tmp/dorm-lock-first.out)
printf '  first command finished as: %s\n' "$(jget "$FIRST" status)"
printf '  second command finished as: %s\n' "$(jget "$BODY" status)"
req GET /state
printf '  final state: %s (lastConfirmedId=%s)\n' "$(jget "$BODY" state)" "$(jget "$BODY" lastConfirmedId)"
if [ -z "$(jget "$BODY" pending.commandId)" ]; then
  ok "no command left stuck pending after the race"
else
  bad "command $(jget "$BODY" pending.commandId) left pending after the race"
fi

stop_device

say "result"
printf '  %s passed, %s failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
