#!/usr/bin/env bash
# fake esp32 - polls, "moves the servo" (just a sleep), confirms. same loop as the real firmware
#
#   BASE=https://dorm-lock.you.workers.dev SECRET=... bash test/device-sim.sh
#
# env: BASE, SECRET, SERVO_MS (400), FAIL_EVERY (0 = never fail), MAX_LOOPS (0 = forever)
set -u

BASE="${BASE:-http://127.0.0.1:8787}"
SECRET="${SECRET:?set SECRET}"
SERVO_MS="${SERVO_MS:-400}"
FAIL_EVERY="${FAIL_EVERY:-0}"
MAX_LOOPS="${MAX_LOOPS:-0}"

last_id="${START_AFTER:-0}"
loops=0
executed=0

# grab lastConfirmedId first so we dont replay old commands
boot=$(curl -sS -H "X-Lock-Secret: $SECRET" "$BASE/state")
if [ -n "$boot" ]; then
  boot_id=$(printf '%s' "$boot" | sed -n 's/.*"lastConfirmedId": *\([0-9]*\).*/\1/p' | head -1)
  [ -n "${boot_id:-}" ] && last_id="$boot_id"
  echo "[device] boot: resuming after command id $last_id"
fi

echo "[device] polling $BASE/poll (25s holds)"
while :; do
  loops=$((loops + 1))
  [ "$MAX_LOOPS" -gt 0 ] && [ "$loops" -gt "$MAX_LOOPS" ] && { echo "[device] max loops reached"; exit 0; }

  body=$(curl -sS --max-time 40 \
    -H "X-Lock-Secret: $SECRET" \
    -w '\n%{http_code}' \
    "$BASE/poll?after=$last_id")
  code=$(printf '%s' "$body" | tail -1)
  json=$(printf '%s' "$body" | sed '$d')

  case "$code" in
    204)
      echo "[device] 204 no command, re-polling"
      continue
      ;;
    200) : ;;
    *)
      echo "[device] poll failed http=$code $json"
      sleep 2
      continue
      ;;
  esac

  # janky json parsing but it works for this
  cmd_id=$(printf '%s' "$json" | sed -n 's/.*"commandId": *\([0-9]*\).*/\1/p' | head -1)
  target=$(printf '%s' "$json" | sed -n 's/.*"target": *"\([a-z]*\)".*/\1/p' | head -1)
  [ -z "$cmd_id" ] && { echo "[device] unparseable: $json"; sleep 1; continue; }

  echo "[device] command #$cmd_id -> $target (moving servo ${SERVO_MS}ms)"
  sleep "$(awk "BEGIN{print $SERVO_MS/1000}")"

  executed=$((executed + 1))
  ok=true
  if [ "$FAIL_EVERY" -gt 0 ] && [ $((executed % FAIL_EVERY)) -eq 0 ]; then
    ok=false
    echo "[device] simulating a servo failure on #$cmd_id"
  fi

  if [ "$ok" = true ]; then
    payload="{\"commandId\":$cmd_id,\"ok\":true,\"state\":\"$target\"}"
  else
    payload="{\"commandId\":$cmd_id,\"ok\":false,\"detail\":\"servo stalled\"}"
  fi

  curl -sS -X POST \
    -H "X-Lock-Secret: $SECRET" \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    "$BASE/confirm" >/dev/null

  echo "[device] confirmed #$cmd_id"
  last_id="$cmd_id"
done
