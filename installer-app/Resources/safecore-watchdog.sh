#!/bin/bash
# SafeCore watchdog. Runs as root every 30 s (LaunchDaemon ai.safespaceglobal.safecore-watchdog).
#
# Restarts SafeCore when something stops on its own, using the box's existing enrolment
# (.env, Keychain key, URL); nothing is entered again. It never fights a manual stop:
#
#   * `safecorectl stop` (also the app's Stop button) boots the SafeCore daemons out of
#     launchd. While ai.safecore.safecored is not loaded, the watchdog does nothing.
#   * The 9 services are started once by run_all_bins.sh and nothing else restarts them.
#     If one is gone for two checks in a row, the watchdog runs `safecorectl restart`
#     (the developer's script has no single-service restart).
#   * safecored (the WebSocket relay) and PostgreSQL are restarted by launchd if their
#     process dies (KeepAlive). If safecored is alive but stops answering
#     `safecored-cli status` for three checks, the watchdog restarts just safecored.
#
# Limits: at most 3 full restarts and 6 safecored restarts per hour; after that it stops
# trying and the app shows "Auto-restart paused" until SafeCore is started again.

set -u
# SAFECORE_ROOT / WATCHDOG_TEST_DIR / WATCHDOG_TEST_PATH are for tests only.
ROOT=${SAFECORE_ROOT:-/opt/safecore}
CTL=$ROOT/scripts/safecorectl
CLI=$ROOT/WebSocket/safecored/target/release/safecored-cli
SUPPORT=${WATCHDOG_TEST_DIR:-"/Library/Application Support/SafeCore"}
STATE_DIR="$SUPPORT/state"
STATE="$SUPPORT/watchdog-status.json"
CONF="$SUPPORT/watchdog.conf"
LOG_DIR=${WATCHDOG_TEST_DIR:-/Library/Logs/SafeCore}
LOG=$LOG_DIR/watchdog.log
MAX_FULL=3 MAX_WS=6 HOUR=3600

export PATH=${WATCHDOG_TEST_PATH:+$WATCHDOG_TEST_PATH:}/usr/bin:/bin:/usr/sbin:/sbin LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
mkdir -p "$STATE_DIR" "$LOG_DIR"
now=$(date +%s)

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
# keep the log under ~5 MB
[ -f "$LOG" ] && [ "$(stat -f %z "$LOG")" -gt 5000000 ] && mv -f "$LOG" "$LOG.1"

get()  { cat "$STATE_DIR/$1" 2>/dev/null || echo "${2:-0}"; }
put()  { echo "$2" > "$STATE_DIR/$1"; }
# timestamps of recent restarts, one per line; prints how many fall in the last hour
recent() { local f="$STATE_DIR/$1" n=0 t; [ -f "$f" ] || { echo 0; return; }
  : > "$f.tmp"; while read -r t; do [ $((now - t)) -lt $HOUR ] && { echo "$t" >> "$f.tmp"; n=$((n+1)); }; done < "$f"
  mv -f "$f.tmp" "$f"; echo $n; }
clean() { echo "$1" | tr -cd 'A-Za-z0-9 .,:=_/()-' | cut -c1-160; }

MODE="" DETAIL="" SERVICES="" WS_OK=false WS_DETAIL=""
write_state() {
  local tmp="$STATE.tmp"
  {
    printf '{"updated":%s,"enabled":%s,"mode":"%s","detail":"%s",' "$now" "$ENABLED_JSON" "$MODE" "$(clean "$DETAIL")"
    printf '"websocketOK":%s,"websocketDetail":"%s",' "$WS_OK" "$(clean "$WS_DETAIL")"
    printf '"lastRestart":%s,"lastRestartReason":"%s",' "$(get last_restart)" "$(clean "$(get last_reason "")")"
    printf '"restartsLastHour":%s,"services":[%s]}\n' "$(recent full)" "$SERVICES"
  } > "$tmp"
  chmod 644 "$tmp"; mv -f "$tmp" "$STATE"
}

ENABLED=1
[ -f "$CONF" ] && . "$CONF"
ENABLED_JSON=$([ "$ENABLED" = 1 ] && echo true || echo false)

if [ ! -x "$CTL" ]; then MODE=not-installed; write_state; exit 0; fi

loaded()  { launchctl print "system/$1" >/dev/null 2>&1; }
running() { launchctl print "system/$1" 2>/dev/null | grep -q 'state = running'; }

# Stopped on purpose (or never started): leave it alone and forget earlier failures.
if ! loaded ai.safecore.safecored; then
  MODE=stopped; DETAIL="SafeCore was stopped. Auto-restart resumes when it is started again."
  put miss 0; put ws_miss 0; rm -f "$STATE_DIR/paused"
  write_state; exit 0
fi

# A start/stop/restart is in progress, or the launcher is still bringing services up.
if pgrep -f "$ROOT/scripts/safecorectl" >/dev/null || running ai.safecore.aibox; then
  MODE=starting; DETAIL="SafeCore is starting."; write_state; exit 0
fi

# Which services did the launcher start, and are they still alive?
SJ="$ROOT/status.json"
names_pids=$(tr -d ' \n\t' < "$SJ" 2>/dev/null | grep -oE '"[A-Za-z0-9_]+":\{"pid":[0-9]+' | sed -E 's/"([^"]+)":\{"pid":([0-9]+)/\1 \2/')
dead=""
while read -r name pid; do
  [ -n "$name" ] || continue
  cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
  if [ -n "$cmd" ] && { echo "$cmd" | grep -q '\.bin' || echo "$cmd" | grep -qF "$ROOT"; }; then alive=true; else alive=false; dead="$dead $name"; fi
  SERVICES="$SERVICES${SERVICES:+,}{\"name\":\"$name\",\"pid\":$pid,\"alive\":$alive}"
done <<< "$names_pids"

# Recently (re)started: give weapon_pipeline etc. time to come up before judging.
sj_age=$(( now - $(stat -f %m "$SJ" 2>/dev/null || echo 0) ))

# WebSocket relay health
ws_out=$(perl -e 'alarm 15; exec @ARGV' "$CLI" status 2>&1); ws_rc=$?
WS_DETAIL=$(echo "$ws_out" | head -3 | tr '\n' ' ')
if [ $ws_rc -eq 0 ]; then WS_OK=true; put ws_miss 0; else put ws_miss $(( $(get ws_miss) + 1 )); fi

if [ "$ENABLED" != 1 ]; then
  MODE=disabled; DETAIL="Auto-restart is off."; write_state; exit 0
fi
# a manual start rewrites status.json; that resumes auto-restart
if [ -f "$STATE_DIR/paused" ] && [ "$(stat -f %m "$SJ" 2>/dev/null || echo 0)" -gt "$(get paused_at)" ]; then
  rm -f "$STATE_DIR/paused" "$STATE_DIR/full"; log "SafeCore was started again; auto-restart resumed"
fi
if [ -f "$STATE_DIR/paused" ]; then
  MODE=paused; DETAIL="Auto-restart paused after $MAX_FULL restarts in an hour. Start or restart SafeCore to resume."
  write_state; exit 0
fi

# 1. safecored alive but not answering -> restart only safecored
if [ "$(get ws_miss)" -ge 3 ] && running ai.safecore.safecored; then
  if [ "$(recent ws)" -lt $MAX_WS ]; then
    log "WebSocket relay (safecored) not answering for 3 checks: $WS_DETAIL -> restarting safecored"
    launchctl kickstart -k system/ai.safecore.safecored >> "$LOG" 2>&1
    echo "$now" >> "$STATE_DIR/ws"; put ws_miss 0
    put last_restart "$now"; put last_reason "WebSocket relay was not answering"
  fi
fi

# 2. one or more services gone -> full restart through the developer's script
if [ -n "$dead" ] && [ "$sj_age" -gt 240 ]; then
  miss=$(( $(get miss) + 1 )); put miss $miss
  if [ $miss -ge 2 ]; then
    if [ "$(recent full)" -ge $MAX_FULL ]; then
      log "services stopped again:$dead. $MAX_FULL restarts in the last hour; pausing auto-restart"
      touch "$STATE_DIR/paused"; put paused_at "$now"
      MODE=paused; DETAIL="Services keep stopping:$dead. Auto-restart paused. Check the service logs, then press Start."
      write_state; exit 0
    fi
    log "services stopped on their own:$dead -> safecorectl restart"
    MODE=restarting; DETAIL="Restarting: stopped on their own:$dead"; write_state
    echo "$now" >> "$STATE_DIR/full"; put miss 0
    put last_restart "$now"; put last_reason "Stopped on their own:$dead"
    "$CTL" restart >> "$LOG" 2>&1
    log "restart finished (exit $?)"
    now=$(date +%s); MODE=running; DETAIL="Restarted automatically."; SERVICES=""; write_state
    exit 0
  fi
  MODE=degraded; DETAIL="Stopped:$dead. Restarting in 30 s if they do not come back."
else
  put miss 0
  MODE=running; DETAIL=""
  [ -n "$dead" ] && { MODE=starting; DETAIL="Waiting for services to finish starting."; }
fi
write_state
exit 0
