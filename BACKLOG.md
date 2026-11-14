# Backlog

## RAM cap for AI work (parked 2026-11-14)

Goal: keep RAM free for the owner; AI/agent work must not eat it.

- Put AI work in a systemd user slice `ai.slice` (memory controller is delegated to user@1000, no root
  needed). `ai-resources prefix` becomes `systemd-run --user --scope --slice=ai.slice nice -n 19 taskset -c …`.
- desk: `MemoryHigh`/`MemoryMax` on ai.slice (amount TBD, e.g. 16 GB of 31 GB); away: limit lifted.
  `ai-resources desk|away` applies it live with `systemctl --user set-property ai.slice …`.
- Protect the desktop session with `MemoryLow` (e.g. 12 GB) so the kernel reclaims from others first.
- Open: start Claude itself inside ai.slice (change the `claude` alias)? Today it runs in the desktop
  session scope, so the cap would only cover prefixed jobs. Decide the desk-mode cap.
