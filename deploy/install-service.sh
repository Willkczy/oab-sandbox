#!/bin/sh
# Make this machine run the sandbox by itself: at login, and again after a crash.
#
# Two agents, because they fail differently. The VM is started once and stays up;
# the sandbox is a foreground `docker run` that launchd restarts when it exits.
# Keeping them apart means a restarting agent never restarts the VM under it.
#
#   dev.oab.colima    starts the container VM, once, at login
#   dev.oab.sandbox   runs deploy/start-sandbox.sh, and again whenever it exits
#
# Nothing here holds a secret: the token stays in the environment file that
# start-sandbox.sh reads, because a LaunchAgent plist is world-readable.
#
# Usage:
#   ./deploy/install-service.sh            install and start
#   ./deploy/install-service.sh --remove   stop and remove both agents
#
# The sandbox is not a long-running service on a laptop you use. This is for the
# machine that only does this.

set -eu

SANDBOX="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"
COLIMA_LABEL=dev.oab.colima
SANDBOX_LABEL=dev.oab.sandbox
WATCHDOG_LABEL=dev.oab.watchdog
LOGS="$HOME/Library/Logs"
WATCHDOG_INTERVAL="${OAB_WATCHDOG_INTERVAL:-300}"

COLIMA_CPU="${OAB_COLIMA_CPU:-2}"
COLIMA_MEMORY="${OAB_COLIMA_MEMORY:-4}"
COLIMA_DISK="${OAB_COLIMA_DISK:-20}"

boot_out() {   # a label that is not loaded is not an error here
    launchctl bootout "$DOMAIN/$1" 2>/dev/null || true
}

if [ "${1:-}" = "--remove" ]; then
    boot_out "$WATCHDOG_LABEL"
    boot_out "$SANDBOX_LABEL"
    boot_out "$COLIMA_LABEL"
    rm -f "$AGENTS/$WATCHDOG_LABEL.plist" "$AGENTS/$SANDBOX_LABEL.plist" "$AGENTS/$COLIMA_LABEL.plist"
    echo "removed all three agents; containers already running are left alone"
    exit 0
fi

COLIMA=$(command -v colima || echo "$HOME/.local/bin/colima")
[ -x "$COLIMA" ] || { echo "colima not found; install a container runtime first" >&2; exit 1; }
[ -f "$SANDBOX/config/config.toml" ] || { echo "config/config.toml is missing -- copy it from config.toml.example and fill it in" >&2; exit 1; }
[ -d "$SANDBOX/vault/.git" ] || { echo "vault/ is not a clone -- see the README on keeping it in step" >&2; exit 1; }

mkdir -p "$AGENTS" "$LOGS"

cat > "$AGENTS/$COLIMA_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$COLIMA_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$COLIMA</string>
    <string>start</string>
    <string>--vm-type</string><string>vz</string>
    <string>--cpu</string><string>$COLIMA_CPU</string>
    <string>--memory</string><string>$COLIMA_MEMORY</string>
    <string>--disk</string><string>$COLIMA_DISK</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOGS/$COLIMA_LABEL.log</string>
  <key>StandardErrorPath</key><string>$LOGS/$COLIMA_LABEL.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <!-- launchd starts a job with PATH=/usr/bin:/bin:/usr/sbin:/sbin, and colima
         runs limactl by name. Without this the agent exits 1 at login and the VM
         never starts. Same list as deploy/start-sandbox.sh. -->
    <key>PATH</key><string>$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
PLIST

cat > "$AGENTS/$SANDBOX_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$SANDBOX_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>$SANDBOX/deploy/start-sandbox.sh</string>
  </array>
  <key>WorkingDirectory</key><string>$SANDBOX</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <!-- A crash loop should be visible in the log, not a busy machine. -->
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$LOGS/$SANDBOX_LABEL.log</string>
  <key>StandardErrorPath</key><string>$LOGS/$SANDBOX_LABEL.log</string>
  <key>EnvironmentVariables</key>
  <dict><key>HOME</key><string>$HOME</string></dict>
</dict>
</plist>
PLIST

cat > "$AGENTS/$WATCHDOG_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$WATCHDOG_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>$SANDBOX/deploy/watchdog.sh</string>
  </array>
  <key>WorkingDirectory</key><string>$SANDBOX</string>
  <key>RunAtLoad</key><true/>
  <!-- Not KeepAlive: this is one check, on a timer, not a process to keep up. -->
  <key>StartInterval</key><integer>$WATCHDOG_INTERVAL</integer>
  <key>StandardOutPath</key><string>$LOGS/$WATCHDOG_LABEL.log</string>
  <key>StandardErrorPath</key><string>$LOGS/$WATCHDOG_LABEL.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
PLIST

boot_out "$WATCHDOG_LABEL"
boot_out "$SANDBOX_LABEL"
boot_out "$COLIMA_LABEL"
launchctl bootstrap "$DOMAIN" "$AGENTS/$COLIMA_LABEL.plist"
launchctl bootstrap "$DOMAIN" "$AGENTS/$SANDBOX_LABEL.plist"
launchctl bootstrap "$DOMAIN" "$AGENTS/$WATCHDOG_LABEL.plist"

echo "installed:"
echo "  $AGENTS/$COLIMA_LABEL.plist"
echo "  $AGENTS/$SANDBOX_LABEL.plist"
echo "  $AGENTS/$WATCHDOG_LABEL.plist  (every ${WATCHDOG_INTERVAL}s)"
echo "logs:"
echo "  $LOGS/$COLIMA_LABEL.log"
echo "  $LOGS/$SANDBOX_LABEL.log"
echo "  $LOGS/$WATCHDOG_LABEL.log"
echo
echo "state:"
launchctl print "$DOMAIN/$SANDBOX_LABEL" 2>/dev/null | grep -E "state|pid|last exit" | head -3 || true
