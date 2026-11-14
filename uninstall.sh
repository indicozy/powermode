#!/usr/bin/env bash
# Remove powermode and put thermal-caps.service back. Run as: sudo ./uninstall.sh
# The CPU and GPU limits last set by powermode stay until thermal-caps (or a reboot) changes them.
set -euo pipefail

BIN=/usr/local/bin/powermode
SUDOERS=/etc/sudoers.d/powermode
UNIT=/etc/systemd/system/powermode.service
OLD_UNIT=/etc/systemd/system/thermal-caps.service

if (( EUID != 0 )); then
  echo "uninstall.sh: run as root (sudo ./uninstall.sh)" >&2
  exit 1
fi

if systemctl cat powermode.service >/dev/null 2>&1; then
  systemctl disable --now powermode.service
fi
rm -f "$UNIT" "$SUDOERS" "$BIN"
rm -rf /var/lib/powermode /run/powermode
systemctl daemon-reload

if [[ -f $OLD_UNIT ]]; then
  systemctl enable --now thermal-caps.service
  echo "re-enabled thermal-caps.service"
fi
echo "powermode removed"
