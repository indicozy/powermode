# Backlog

## RAM cap for AI work (parked 2026-11-14)

Goal: keep RAM free for the owner; AI/agent work must not eat it.

- Done: AI work runs in the systemd user slice `ai.slice` (`ai-run`, `ai-resources setup`). The prefix
  is `ai-run nice -n 19` (plus taskset when cpuset is not delegated). Claude runs as `ai-run tg-claude`.
- Done: the slice limits CPUs live (`AllowedCPUs` with cpuset delegated by install.sh, re-pin otherwise).
- Open, owner's decision: the RAM cap amount. The mechanism is not built yet (no MemoryHigh/MemoryMax
  yet). When chosen: desk → `MemoryHigh`/`MemoryMax` on ai.slice, away → limit lifted, applied by
  `ai-resources apply`. Also open: `MemoryLow` on the desktop session so the kernel reclaims from others first.
