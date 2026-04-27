#!/usr/bin/env bash
#
# Example installer for the daemon-mode Telegram plugin patch.
#
# This script rehydrates Claude Code's plugin cache + marketplace copies of
# server.ts from a local snapshot, installs a launchd plist, and bootstraps
# the daemon. Idempotent — run after every Claude Code update that touches
# the telegram plugin.
#
# Usage:
#   ./install.sh             # rehydrate + bootstrap daemon
#   ./install.sh --check     # report drift, do not modify (exit 2 on drift)
#   ./install.sh --no-start  # rehydrate but do not bootstrap
#
# Adapt to your own paths. This is an example, not a turnkey installer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The patched server.ts and example plist live alongside this script.
VENDORED_SERVER="$SCRIPT_DIR/../server.ts"
VENDORED_PLIST="$SCRIPT_DIR/com.example.tg-bridge-daemon.plist"

CACHE_SERVER="$HOME/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6/server.ts"
MARKETPLACE_SERVER="$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts"
INSTALLED_PLIST="$HOME/Library/LaunchAgents/com.example.tg-bridge-daemon.plist"
LOG_DIR="$HOME/Library/Logs"
STATE_DIR="$HOME/.claude/channels/telegram"
LAUNCHD_LABEL="com.example.tg-bridge-daemon"

MODE="install"
for arg in "$@"; do
  case "$arg" in
    --check)    MODE="check" ;;
    --no-start) MODE="install-no-start" ;;
    -h|--help)  sed -n '3,16p' "$0"; exit 0 ;;
    *)          echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

err() { echo "[tg-bridge] $*" >&2; }
log() { echo "[tg-bridge] $*"; }

require_file() {
  [ -f "$1" ] || { err "missing: $1"; exit 1; }
}

require_file "$VENDORED_SERVER"
require_file "$VENDORED_PLIST"

# Drift check ────────────────────────────────────────────────────────────────
drift_count=0
for target in "$CACHE_SERVER" "$MARKETPLACE_SERVER"; do
  if [ ! -f "$target" ]; then
    log "drift: missing $target"
    drift_count=$((drift_count + 1))
  elif ! cmp -s "$VENDORED_SERVER" "$target"; then
    log "drift: $target differs from vendored server.ts"
    drift_count=$((drift_count + 1))
  else
    log "ok: $target matches vendored"
  fi
done

if [ ! -f "$INSTALLED_PLIST" ]; then
  log "drift: plist not installed at $INSTALLED_PLIST"
  drift_count=$((drift_count + 1))
elif ! cmp -s "$VENDORED_PLIST" "$INSTALLED_PLIST"; then
  log "drift: installed plist differs from vendored"
  drift_count=$((drift_count + 1))
else
  log "ok: plist matches"
fi

if [ "$MODE" = "check" ]; then
  if [ "$drift_count" -gt 0 ]; then
    log "check: $drift_count drift(s) found. Re-run without --check to fix."
    exit 2
  fi
  log "check: no drift."
  exit 0
fi

# Install / rehydrate ────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR" "$STATE_DIR"

if [ -d "$(dirname "$CACHE_SERVER")" ]; then
  cp "$VENDORED_SERVER" "$CACHE_SERVER"
  log "wrote: $CACHE_SERVER"
else
  err "cache dir missing — install the telegram plugin via Claude Code first"
  exit 1
fi

if [ -d "$(dirname "$MARKETPLACE_SERVER")" ]; then
  cp "$VENDORED_SERVER" "$MARKETPLACE_SERVER"
  log "wrote: $MARKETPLACE_SERVER"
else
  err "marketplace dir missing — skipping"
fi

cp "$VENDORED_PLIST" "$INSTALLED_PLIST"
log "wrote: $INSTALLED_PLIST"

# launchd bootstrap with retry. After `bootout`, launchd may take a moment to
# release the service name. Immediate bootstrap can fail with IO error (5).
SERVICE_TARGET="gui/$(id -u)/$LAUNCHD_LABEL"
DOMAIN_TARGET="gui/$(id -u)"

bootstrap_with_retry() {
  local attempts=5 i=1
  while [ "$i" -le "$attempts" ]; do
    if launchctl bootstrap "$DOMAIN_TARGET" "$INSTALLED_PLIST" 2>/dev/null; then
      log "loaded: $LAUNCHD_LABEL (bootstrap, attempt $i)"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  err "bootstrap failed after $attempts attempts"
  return 1
}

if [ "$MODE" = "install" ]; then
  launchctl bootout "$SERVICE_TARGET" 2>/dev/null || true
  sleep 1
  bootstrap_with_retry || exit 1

  sleep 2
  if [ -f "$STATE_DIR/bot.pid" ]; then
    log "daemon state: bot.pid=$(cat "$STATE_DIR/bot.pid")"
  else
    err "daemon did not write bot.pid — check $LOG_DIR/tg-bridge-daemon.err.log"
    exit 1
  fi
else
  if ! launchctl print "$SERVICE_TARGET" &>/dev/null; then
    bootstrap_with_retry || exit 1
  else
    log "already loaded: $LAUNCHD_LABEL (--no-start, not restarting)"
  fi
fi

log "done."
