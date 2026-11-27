#!/usr/bin/env bash
# Installs RetinaLink Receiver.app on the receiver Mac and keeps it running with a LaunchAgent.
#
# Usage: scripts/install-receiver.sh [--local | <ssh-target>]
#   --local       install on this Mac (run it on the receiver Mac itself)
#   <ssh-target>  install on another Mac over SSH, e.g. me@studio.local
#   Installs dist/RetinaLink Receiver.app from scripts/build-and-sign.sh, building it first if missing
#   (as a universal binary for SSH targets, so the receiver's architecture does not matter).
# Environment:
#   BUNDLE_ID_PREFIX  must match the build; the LaunchAgent label is $BUNDLE_ID_PREFIX.receiver
#                     (default: dev.retinalink)
#   SSH_OPTS          extra ssh options, e.g. "-p 2222 -i ~/.ssh/receiver"
#   SIGN_IDENTITY     passed through to scripts/build-and-sign.sh when it builds
set -euo pipefail

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

TARGET=""
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --local) TARGET="" ;;
  "") echo "Choose --local or an SSH target." >&2; usage >&2; exit 64 ;;
  -*) echo "Unknown option: $1" >&2; usage >&2; exit 64 ;;
  *) TARGET="$1" ;;
esac
(( $# <= 1 )) || { echo "Too many arguments." >&2; usage >&2; exit 64; }

if [[ "$(uname -s)" != Darwin ]]; then
  echo "install-receiver.sh must run on macOS." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID_PREFIX="${BUNDLE_ID_PREFIX:-dev.retinalink}"
LABEL="$BUNDLE_ID_PREFIX.receiver"
APP_NAME="RetinaLink Receiver.app"
LOCAL_APP="$ROOT/dist/$APP_NAME"

if [[ ! -d "$LOCAL_APP" ]]; then
  echo "==> No $APP_NAME in dist/; building it"
  if [[ -n "$TARGET" ]]; then
    "$ROOT/scripts/build-and-sign.sh" --arch universal
  else
    "$ROOT/scripts/build-and-sign.sh"
  fi
fi
echo "==> Checking the bundle's signature"
codesign --verify --deep --strict --verbose=2 "$LOCAL_APP"

# Runs on the receiver Mac: install <bundle .app or .zip> <launchd label>
read -r -d '' INSTALLER <<'REMOTE' || true
set -euo pipefail
source="$1"
label="$2"
app="/Applications/RetinaLink Receiver.app"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"

if [[ "$source" == *.zip ]]; then
  staging="$(dirname "$source")"
  trap 'rm -rf "$staging"' EXIT
  ditto -x -k "$source" "$staging"
  bundle="$staging/RetinaLink Receiver.app"
else
  bundle="$source"
fi
codesign --verify --deep --strict --verbose=2 "$bundle"

# Boot out by service label only: a plist path here would boot out the whole login session.
launchctl bootout "$domain/$label" 2>/dev/null || true

if [[ "$bundle" != "$app" ]]; then
  rm -rf "$app"
  ditto "$bundle" "$app"
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$app/Contents/MacOS/RetinaLinkReceiverApp</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>/tmp/retinalink-receiver.log</string>
  <key>StandardErrorPath</key><string>/tmp/retinalink-receiver.log</string>
</dict>
</plist>
PLIST
plutil -lint "$plist" >/dev/null

# A just-booted-out service can take a moment to leave the domain.
bootstrapped=0
for _ in 1 2 3 4 5; do
  if launchctl bootstrap "$domain" "$plist" 2>/dev/null; then bootstrapped=1; break; fi
  sleep 1
done
if (( ! bootstrapped )); then
  launchctl bootstrap "$domain" "$plist"
fi
launchctl kickstart -k "$domain/$label"

sleep 2
if launchctl print "$domain/$label" | grep -q 'state = running'; then
  echo "RetinaLink Receiver is running ($domain/$label)."
else
  echo "RetinaLink Receiver did not start; see /tmp/retinalink-receiver.log" >&2
  launchctl print "$domain/$label" | grep -E 'state =|last exit' >&2 || true
  exit 1
fi
REMOTE

if [[ -z "$TARGET" ]]; then
  echo "==> Installing the app and LaunchAgent on this Mac"
  bash -s -- "$LOCAL_APP" "$LABEL" <<<"$INSTALLER"
  exit 0
fi

ssh_opts=(-o BatchMode=yes)
if [[ -n "${SSH_OPTS:-}" ]]; then
  read -r -a extra <<<"$SSH_OPTS"
  ssh_opts+=("${extra[@]}")
fi
SSH=(ssh "${ssh_opts[@]}" "$TARGET")

echo "==> Copying $APP_NAME to $TARGET"
STAGING="$("${SSH[@]}" 'mktemp -d -t retinalink-receiver')"
ditto -c -k --sequesterRsrc --keepParent "$LOCAL_APP" - | "${SSH[@]}" "cat > '$STAGING/receiver.zip'"

echo "==> Installing the app and LaunchAgent on $TARGET"
"${SSH[@]}" bash -s -- "'$STAGING/receiver.zip'" "'$LABEL'" <<<"$INSTALLER"
