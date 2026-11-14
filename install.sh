#!/usr/bin/env bash
# Install powermode: the script, a NOPASSWD sudoers rule for the invoking user, and the boot service.
# Run as: sudo ./install.sh     Safe to run again.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN=/usr/local/bin/powermode
SUDOERS=/etc/sudoers.d/powermode
UNIT=/etc/systemd/system/powermode.service
OLD_UNIT=/etc/systemd/system/thermal-caps.service
STATE_DIR=/var/lib/powermode
TARGET_USER=${SUDO_USER:-}

if (( EUID != 0 )); then
  echo "install.sh: run as root (sudo ./install.sh)" >&2
  exit 1
fi
if [[ -z $TARGET_USER || $TARGET_USER == root ]]; then
  echo "install.sh: run it with sudo from your user account so the sudoers rule names that user" >&2
  exit 1
fi
if [[ ! $TARGET_USER =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "install.sh: unusable user name: $TARGET_USER" >&2
  exit 1
fi

install -m 0755 -o root -g root "$HERE/powermode" "$BIN"

# Build the sudoers rule in a scratch file, check it, and only then move it into place.
scratch=$(mktemp)
trap 'rm -f "$scratch"' EXIT
printf '%s ALL=(root) NOPASSWD: %s\n' "$TARGET_USER" "$BIN" > "$scratch"
if visudo -cf "$scratch" >/dev/null; then
  install -m 0440 -o root -g root "$scratch" "$SUDOERS"
  echo "installed $SUDOERS"
else
  rm -f "$SUDOERS"
  echo "install.sh: sudoers rule did not validate; $SUDOERS removed" >&2
  exit 1
fi

install -m 0644 -o root -g root "$HERE/powermode.service" "$UNIT"

# The old cap service is replaced by powermode.service; its unit file is left in place.
if [[ -f $OLD_UNIT ]] && systemctl cat thermal-caps.service >/dev/null 2>&1; then
  systemctl disable --now thermal-caps.service
  echo "disabled thermal-caps.service"
fi

systemctl daemon-reload
systemctl enable powermode.service

install -d -m 0755 "$STATE_DIR"
if [[ ! -f $STATE_DIR/mode ]]; then
  printf 'silent\n' > "$STATE_DIR/mode"
  chmod 0644 "$STATE_DIR/mode"
fi

if "$BIN" boot; then
  echo "powermode installed; mode: $(cat "$STATE_DIR/mode")"
else
  echo "install.sh: installed, but applying the mode failed (see the messages above)" >&2
  exit 1
fi
