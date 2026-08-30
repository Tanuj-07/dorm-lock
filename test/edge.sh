#!/usr/bin/env bash
# edge cases e2e.sh cant really hit: supersede + expiry
# expiry part needs a short ttl -> set COMMAND_TTL_MS = "3000" in wrangler.toml
# (.dev.vars doesnt override it), let wrangler reload, run this, then put it back
#
#   BASE=http://127.0.0.1:8787 SECRET=dev-secret-change-me bash test/edge.sh
set -u

BASE="${BASE:-http://127.0.0.1:8787}"
SECRET="${SECRET:?set SECRET}"
PASS=0
FAIL=0

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: expected [$3] got [$2]"; fi; }

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

printf 'Target: %s\n' "$BASE"

# starting point. no device running for any of this
req GET /state
START=$(jget "$BODY" state)
TTL=$(jget "$BODY" config.commandTtlMs)
printf 'state=%s commandTtlMs=%s\n' "$START" "$TTL"

OTHER=locked
[ "$START" = "locked" ] && OTHER=unlocked

say "1. a newer command supersedes the one still in flight"

# A wants the other state and just sits there, nothing confirms it
curl -sS -X POST -H "X-Lock-Secret: $SECRET" -H 'Content-Type: application/json' \
  -d "{\"target\":\"$OTHER\",\"waitMs\":15000}" "$BASE/command" >/tmp/dorm-lock-A.out &
A_PID=$!
sleep 1

req GET /state
A_ID=$(jget "$BODY" pending.commandId)
check "command A is pending" "$(jget "$BODY" pending.target)" "$OTHER"

# B wants the original state. different target so it should replace A not join it
req POST /command "{\"target\":\"$START\",\"waitMs\":1500}"
B_ID=$(jget "$BODY" commandId)
check "command B got a new id" "$B_ID" "$((A_ID+1))"

wait "$A_PID"
A_BODY=$(cat /tmp/dorm-lock-A.out)
check "command A was released early, not left hanging" "$(jget "$A_BODY" status)" "superseded"
check "  A reports failure" "$(jget "$A_BODY" ok)" "false"

req GET /state
check "only B is left pending" "$(jget "$BODY" pending.commandId)" "$B_ID"
check "  state did not move on its own" "$(jget "$BODY" state)" "$START"

# device should only ever see B
req GET "/poll?after=0&wait=0"
check "the device is handed B, never A" "$(jget "$BODY" commandId)" "$B_ID"
check "  with B's target" "$(jget "$BODY" target)" "$START"

req POST /confirm "{\"commandId\":$B_ID,\"ok\":true,\"state\":\"$START\"}"
check "confirm B" "$(jget "$BODY" status)" "confirmed"

if [ -z "$TTL" ] || [ "$TTL" -gt 10000 ]; then
  say "2. expiry — SKIPPED"
  printf '  commandTtlMs=%s is too long to test in reasonable time.\n' "$TTL"
  printf '  Set COMMAND_TTL_MS = "3000" in wrangler.toml and re-run.\n'
else
  say "2. an unexecuted command dies at the TTL instead of firing late"

  req POST /command "{\"target\":\"$OTHER\",\"waitMs\":0}"
  STALE_ID=$(jget "$BODY" commandId)
  check "queued command $STALE_ID" "$(jget "$BODY" status)" "queued"

  req GET "/poll?after=0&wait=0"
  check "device would get it right now" "$(jget "$BODY" commandId)" "$STALE_ID"

  sleep "$(awk "BEGIN{print ($TTL/1000)+1.5}")"

  # the important one. expired cmd should never get handed out
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' -H "X-Lock-Secret: $SECRET" "$BASE/poll?after=0&wait=0")
  check "after the TTL the device is handed nothing -> 204" "$CODE" "204"

  req GET /state
  check "  nothing pending" "$(jget "$BODY" pending)" ""
  check "  state never moved to the abandoned target" "$(jget "$BODY" state)" "$START"

  say "3. a device that executed it anyway can still correct the record"
  req POST /confirm "{\"commandId\":$STALE_ID,\"ok\":true,\"state\":\"$OTHER\"}"
  check "late confirm is accepted" "$(jget "$BODY" status)" "late"
  check "  state corrected to what the door actually did" "$(jget "$BODY" state)" "$OTHER"

  req GET /state
  check "  /state agrees" "$(jget "$BODY" state)" "$OTHER"

  # same late confirm again = no-op
  req POST /confirm "{\"commandId\":$STALE_ID,\"ok\":true,\"state\":\"$OTHER\"}"
  check "repeating the late confirm -> duplicate" "$(jget "$BODY" status)" "duplicate"
  check "  state unchanged" "$(jget "$BODY" state)" "$OTHER"
fi

say "result"
printf '  %s passed, %s failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
