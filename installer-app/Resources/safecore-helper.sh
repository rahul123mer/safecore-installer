#!/bin/bash
# SafeCore privileged helper. Runs as root (via the macOS administrator prompt)
# and only ever runs the commands the SafeCore developer documented:
#
#   installer -pkg SafeCore-1.0.0.pkg -target /
#   /opt/safecore/WebSocket/safecored/target/release/safecore-setup --non-interactive
#   /opt/safecore/scripts/safecorectl status|start|stop|restart
#
# Usage:
#   safecore-helper.sh install <pkg> <workdir> <fresh|upgrade> [app-to-copy]
#   safecore-helper.sh status|start|stop|restart
#   safecore-helper.sh watchdog-on|watchdog-off   (auto-restart; see safecore-watchdog.sh)
#
# <workdir> is a private (0700) folder created by the app. For a fresh install it
# holds "answers": endpoint, tenant ID, box ID, domain and access key, one per line.
# The file is deleted as soon as it has been read.

set -u
set -o pipefail

SETUP=/opt/safecore/WebSocket/safecored/target/release/safecore-setup
CTL=/opt/safecore/scripts/safecorectl
LOG_DIR=/Library/Logs/SafeCore
LOG="$LOG_DIR/installer.log"

# Match the environment `sudo` gives the developer's commands in Terminal.
CONSOLE_USER=$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || echo root)
export PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/var/root USER=root LOGNAME=root
export SUDO_USER="$CONSOLE_USER"
export SUDO_UID=$(/usr/bin/id -u "$CONSOLE_USER" 2>/dev/null || echo 0)
export SUDO_GID=$(/usr/bin/id -g "$CONSOLE_USER" 2>/dev/null || echo 0)
# The administrator prompt starts us with no locale, unlike Terminal. PostgreSQL on
# macOS refuses to start without one ("postmaster became multithreaded during startup").
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
cd /

mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"

HERE="$(cd "$(dirname "$0")" && pwd)"
SUPPORT="/Library/Application Support/SafeCore"
WD_LABEL=ai.safespaceglobal.safecore-watchdog
WD_PLIST=/Library/LaunchDaemons/$WD_LABEL.plist

# Install (or refresh) the auto-restart watchdog from this app's Resources. $1: 1 = on, 0 = off.
install_watchdog() {
  mkdir -p "$SUPPORT"
  chown root:wheel "$SUPPORT"; chmod 755 "$SUPPORT"
  install -o root -g wheel -m 755 "$HERE/safecore-watchdog.sh" "$SUPPORT/safecore-watchdog.sh" || return 1
  echo "ENABLED=$1" > "$SUPPORT/watchdog.conf"; chmod 644 "$SUPPORT/watchdog.conf"
  install -o root -g wheel -m 644 "$HERE/$WD_LABEL.plist" "$WD_PLIST" || return 1
  launchctl bootout system "$WD_PLIST" 2>/dev/null || true
  launchctl bootstrap system "$WD_PLIST" && launchctl enable "system/$WD_LABEL"
  echo "[$(date '+%F %T')] auto-restart $([ "$1" = 1 ] && echo on || echo off)" >> "$LOG"
  echo "Auto-restart is $([ "$1" = 1 ] && echo on || echo off)."
}

CMD=${1:-}
[ $# -gt 0 ] && shift

case "$CMD" in
  status|start|stop|restart)
    if [ ! -x "$CTL" ]; then
      echo "SafeCore is not installed ($CTL not found)."
      exit 3
    fi
    echo "[$(date '+%F %T')] safecorectl $CMD" >> "$LOG"
    "$CTL" "$CMD" 2>&1 | tee -a "$LOG"
    rc=${PIPESTATUS[0]}
    # After start/stop/restart, report status in the same call so the app asks for the password only once.
    if [ "$CMD" != status ]; then
      echo "@@STATUS@@"
      "$CTL" status 2>&1
    fi
    exit $rc
    ;;
  watchdog-on|watchdog-off)
    install_watchdog "$([ "$CMD" = watchdog-on ] && echo 1 || echo 0)"
    exit $?
    ;;
  install) ;;
  *) echo "usage: $0 install|status|start|stop|restart|watchdog-on|watchdog-off" >&2; exit 64 ;;
esac

PKG=${1:?pkg}
WORK=${2:?workdir}
MODE=${3:?mode}
APP_SRC=${4:-}
PROGRESS="$WORK/progress.log"
ANSWERS="$WORK/answers"
KEY=""

cleanup() { rm -f "$ANSWERS"; chown "$CONSOLE_USER" "$PROGRESS" 2>/dev/null; }
trap cleanup EXIT

if [ "$MODE" = fresh ]; then
  [ -f "$ANSWERS" ] || { echo "FAIL enrol missing-answers" >> "$PROGRESS"; exit 2; }
  KEY=$(/usr/bin/sed -n 5p "$ANSWERS")
fi

# Print a line to the app and the log file, with the access key hidden.
emit() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line//$'\r'/}
    [ -n "$KEY" ] && line=${line//"$KEY"/[hidden]}
    printf '%s\n' "$line" >> "$PROGRESS"
    printf '[%s] %s\n' "$(date '+%F %T')" "$line" >> "$LOG"
  done
}
step() { echo "STEP $1 $2" >> "$PROGRESS"; echo "[$(date '+%F %T')] STEP $1 $2" >> "$LOG"; }
fail() { step "$1" fail; echo "FAIL $1" >> "$PROGRESS"; exit 1; }

echo "[$(date '+%F %T')] ===== SafeCore install ($MODE) by $CONSOLE_USER =====" >> "$LOG"

# 1. Install (or upgrade) the package. Existing settings and data are kept by the package itself.
step pkg run
/usr/sbin/installer -pkg "$PKG" -target / 2>&1 | emit || fail pkg
step pkg ok

# 2. Enrol: safecore-setup validates the box with the backend, sets up the database and starts all
#    services. It takes the five answers through its own non-interactive mode (SAFECORE_* variables).
#    An already-enrolled box is never re-enrolled: the package's postinstall brings its services back.
step enrol run
if [ -f /opt/safecore/etc/enrolled ]; then
  echo "This box is already enrolled; keeping its enrolment and data." | emit
  rm -f "$ANSWERS"
elif [ "$MODE" = fresh ]; then
  [ -x "$SETUP" ] || { echo "safecore-setup not found at $SETUP" | emit; fail enrol; }
  {
    IFS= read -r SAFECORE_ENDPOINT
    IFS= read -r SAFECORE_TENANT
    IFS= read -r SAFECORE_BOX
    IFS= read -r SAFECORE_DOMAIN
    IFS= read -r SAFECORE_KEY
  } < "$ANSWERS"
  rm -f "$ANSWERS"
  export SAFECORE_ENDPOINT SAFECORE_TENANT SAFECORE_BOX SAFECORE_DOMAIN SAFECORE_KEY
  "$SETUP" --non-interactive --user "$CONSOLE_USER" < /dev/null 2>&1 | emit || fail enrol
  unset SAFECORE_KEY
else
  echo "SafeCore is installed but this box was never enrolled. Open the installer again to enrol it." | emit
  fail enrol
fi
step enrol ok

# 3. Put the SafeCore app in /Applications so it can be used later as the control panel.
if [ -n "$APP_SRC" ] && [ -d "$APP_SRC" ] && [ "$APP_SRC" != /Applications/SafeCore.app ]; then
  rm -rf /Applications/SafeCore.app
  /usr/bin/ditto "$APP_SRC" /Applications/SafeCore.app 2>&1 | emit
fi

# 4. Turn on auto-restart (keeps the box's previous on/off choice on upgrade).
step watchdog run
WD_ON=1
[ -f "$SUPPORT/watchdog.conf" ] && WD_ON=$(sed -n 's/^ENABLED=//p' "$SUPPORT/watchdog.conf")
install_watchdog "${WD_ON:-1}" 2>&1 | emit || fail watchdog
step watchdog ok

# 5. Check that everything is running.
step verify run
"$CTL" status 2>&1 | emit
step verify ok
echo "DONE" >> "$PROGRESS"
exit 0
