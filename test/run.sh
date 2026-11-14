#!/usr/bin/env bash
# Tests for powermode against a fake sysfs tree and a fake nvidia-smi. Runs as a normal user.
# Usage: test/run.sh      exits 0 when every check passes.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PM=$HERE/../powermode
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass=0
fail=0
OUT=""
RC=0
SMI_FAIL=""
Q="--query-gpu=index,power.min_limit,power.default_limit,power.max_limit --format=csv,noheader,nounits"
CPU=sys/devices/system/cpu
RAPL=sys/class/powercap/intel-rapl:0

# The fake nvidia-smi logs every call and answers the queries powermode makes. It keeps each GPU's
# last "-i N -pl W" in FAKE_SMI_DIR/plN (0 before any write) and reports it as power.limit.
# FAKE_SMI_SLEEP delays the calls that change clocks or power state (-pm), to test the lock.
mkdir -p "$T/bin"
cat > "$T/bin/nvidia-smi" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_SMI_LOG"
if [ -n "${FAKE_SMI_SLEEP:-}" ]; then
  case "$*" in *-pm*) sleep "$FAKE_SMI_SLEEP" ;; esac
fi
if [ -n "${FAKE_SMI_FAIL:-}" ]; then
  case "$*" in *"$FAKE_SMI_FAIL"*) exit 1 ;; esac
fi
if [ "${1:-}" = -i ] && [ "${3:-}" = -pl ]; then
  printf '%s\n' "$4" > "$FAKE_SMI_DIR/pl$2"
fi
case "$*" in
  *power.min_limit*) printf '0, 150.00, 180.00, 190.00\n1, 90.00, 115.00, 138.00\n' ;;
  *clocks.max.gr*) printf '0, 150.00, 1200, 3180\n1, 90.00, 210, 3105\n' ;;
  *"index,power.limit --"*)
    for i in 0 1; do
      v=$(cat "$FAKE_SMI_DIR/pl$i" 2>/dev/null || echo 0)
      printf '%s, %s.00\n' "$i" "$v"
    done ;;
esac
exit 0
EOF
chmod 0755 "$T/bin/nvidia-smi"

# make_tree DIR: a fresh fake tree in the cold-boot state (no state files, 90 W caps).
make_tree() {
  local d=$1 cpu
  mkdir -p "$d/$CPU/intel_pstate" "$d/$RAPL" "$d/run" "$d/var/lib"
  printf '1\n' > "$d/$CPU/intel_pstate/no_turbo"
  printf '50\n' > "$d/$CPU/intel_pstate/max_perf_pct"
  for cpu in 0 1 2 3; do
    mkdir -p "$d/$CPU/cpu$cpu/cpufreq"
    printf 'powersave\n' > "$d/$CPU/cpu$cpu/cpufreq/scaling_governor"
    printf 'power\n' > "$d/$CPU/cpu$cpu/cpufreq/energy_performance_preference"
  done
  printf '90000000\n' > "$d/$RAPL/constraint_0_power_limit_uw"
  printf '90000000\n' > "$d/$RAPL/constraint_1_power_limit_uw"
}

# run_pm TREE ARGS...: run powermode against TREE; sets OUT (stdout and stderr) and RC.
run_pm() {
  local tree=$1
  shift
  rm -f "$tree/smi.log"
  OUT=$(POWERMODE_SYSFS_ROOT="$tree" POWERMODE_NVIDIA_SMI="$T/bin/nvidia-smi" \
    FAKE_SMI_LOG="$tree/smi.log" FAKE_SMI_DIR="$tree" FAKE_SMI_FAIL="$SMI_FAIL" "$PM" "$@" 2>&1)
  RC=$?
}

smi_log() { cat "$1/smi.log" 2>/dev/null; }

check() { # LABEL EXPECTED ACTUAL
  if [[ $2 == "$3" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1"
    echo "  expected: $2"
    echo "  actual:   $3"
  fi
}

check_file() { # LABEL FILE EXPECTED: first line of FILE
  check "$1" "$3" "$(head -n 1 "$2" 2>/dev/null)"
}

expect_has() { # LABEL NEEDLE TEXT: TEXT contains NEEDLE as a fixed string
  if grep -qF -- "$2" <<< "$3"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1"
    echo "  missing:  $2"
    echo "  in:       $3"
  fi
}

expect_match() { # LABEL REGEX TEXT: some line of TEXT matches the extended regex
  if grep -qE -- "$2" <<< "$3"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1"
    echo "  no line matches: $2"
    echo "  in:              $3"
  fi
}

expect_intel() { # TREE NO_TURBO MAX_PERF
  check_file "no_turbo" "$1/$CPU/intel_pstate/no_turbo" "$2"
  check_file "max_perf_pct" "$1/$CPU/intel_pstate/max_perf_pct" "$3"
}

expect_cpus() { # TREE GOVERNOR EPP: every cpu's governor and energy preference
  local cpu
  for cpu in 0 1 2 3; do
    check_file "cpu$cpu governor" "$1/$CPU/cpu$cpu/cpufreq/scaling_governor" "$2"
    check_file "cpu$cpu epp" "$1/$CPU/cpu$cpu/cpufreq/energy_performance_preference" "$3"
  done
}

expect_rapl() { # TREE PL1_UW PL2_UW
  check_file "rapl PL1" "$1/$RAPL/constraint_0_power_limit_uw" "$2"
  check_file "rapl PL2" "$1/$RAPL/constraint_1_power_limit_uw" "$3"
}

expect_state() { # TREE MODE: the mode recorded for boot and for the bar
  check_file "boot mode file" "$1/var/lib/powermode/mode" "$2"
  check_file "bar state file" "$1/run/powermode" "$2"
}

# Walk one tree through silent, default, turbo, status and the rejected arguments.
A=$T/a
make_tree "$A"

run_pm "$A" silent
check "silent exit" 0 "$RC"
check "silent output" "" "$OUT"
expect_intel "$A" 1 60
expect_cpus "$A" powersave power
expect_rapl "$A" 65000000 90000000
expect_state "$A" silent
check "state file mode" 644 "$(stat -c %a "$A/run/powermode")"
check "silent nvidia-smi calls" \
  "$(printf '%s\n' "-pm 1" "$Q" "-i 0 -pl 150" "-i 0 -lgc 210,1800" "-i 1 -pl 90" "-i 1 -lgc 210,1600")" \
  "$(smi_log "$A")"

run_pm "$A" default
check "default exit" 0 "$RC"
expect_intel "$A" 0 100
expect_cpus "$A" powersave balance_performance
expect_rapl "$A" 125000000 190000000
expect_state "$A" default
check "default nvidia-smi calls" \
  "$(printf '%s\n' "-pm 1" "$Q" "-i 0 -pl 180" "-i 0 -rgc" "-i 1 -pl 115" "-i 1 -rgc")" \
  "$(smi_log "$A")"

run_pm "$A" turbo
check "turbo exit" 0 "$RC"
expect_intel "$A" 0 100
expect_cpus "$A" performance performance
expect_rapl "$A" 190000000 190000000
expect_state "$A" turbo
check "turbo nvidia-smi calls" \
  "$(printf '%s\n' "-pm 1" "$Q" "-i 0 -pl 190" "-i 0 -rgc" "-i 1 -pl 138" "-i 1 -rgc")" \
  "$(smi_log "$A")"

run_pm "$A" status
check "status exit" 0 "$RC"
expect_match "status mode" '^mode: +turbo$' "$OUT"
expect_match "status no_turbo" '^no_turbo: +0$' "$OUT"
expect_match "status max_perf_pct" '^max_perf_pct: +100$' "$OUT"
expect_match "status governor" '^governor: +performance \(cpu0\)$' "$OUT"
expect_match "status epp" '^epp: +performance \(cpu0\)$' "$OUT"
expect_match "status PL1" '^rapl PL1: +190 W$' "$OUT"
expect_match "status PL2" '^rapl PL2: +190 W$' "$OUT"
expect_match "status gpu 0" 'gpu 0: +limit 150 W, clock 1200 MHz \(max 3180\)$' "$OUT"
expect_match "status gpu 1" 'gpu 1: +limit 90 W, clock 210 MHz \(max 3105\)$' "$OUT"
check "status only queries nvidia-smi" "--query-gpu=index,power.limit,clocks.gr,clocks.max.gr --format=csv,noheader,nounits" "$(smi_log "$A")"

# expect_rejected LABEL ARGS...: powermode must refuse these arguments without touching anything.
expect_rejected() {
  local label=$1
  shift
  run_pm "$A" "$@"
  check "$label exit" 2 "$RC"
  expect_has "$label usage" "usage: powermode" "$OUT"
  check "$label nvidia-smi calls" "" "$(smi_log "$A")"
}
expect_rejected "bogus" bogus
expect_rejected "no argument"
expect_rejected "empty argument" ""
expect_rejected "wrong case" Silent
expect_rejected "extra argument" silent extra
expect_rejected "shell metacharacters" "silent;touch x"
expect_rejected "force alone" --force
expect_rejected "force with status" --force status
expect_rejected "force with boot" --force boot
check_file "rejected arguments left no_turbo" "$A/$CPU/intel_pstate/no_turbo" 0
check_file "rejected arguments kept the turbo state" "$A/run/powermode" turbo
expect_rapl "$A" 190000000 190000000

# boot re-applies the mode in /var/lib/powermode/mode.
B=$T/b
make_tree "$B"
mkdir -p "$B/var/lib/powermode"
printf 'default\n' > "$B/var/lib/powermode/mode"
run_pm "$B" boot
check "boot default exit" 0 "$RC"
expect_intel "$B" 0 100
expect_cpus "$B" powersave balance_performance
expect_rapl "$B" 125000000 190000000
expect_state "$B" default

# boot with no mode file falls back to silent and seeds the mode file.
C=$T/c
make_tree "$C"
run_pm "$C" boot
check "boot missing exit" 0 "$RC"
expect_intel "$C" 1 60
expect_rapl "$C" 65000000 90000000
expect_state "$C" silent

# boot with an invalid mode file also falls back to silent.
D=$T/d
make_tree "$D"
mkdir -p "$D/var/lib/powermode"
printf 'boot\n' > "$D/var/lib/powermode/mode"
run_pm "$D" boot
check "boot invalid exit" 0 "$RC"
expect_intel "$D" 1 60
expect_state "$D" silent

# A refused EPP write under the performance governor is tolerated without a warning.
E=$T/e
make_tree "$E"
rm -f "$E/$CPU/cpu3/cpufreq/energy_performance_preference"
mkdir -p "$E/$CPU/cpu3/cpufreq/energy_performance_preference"
run_pm "$E" turbo
check "turbo refused epp exit" 0 "$RC"
check "turbo refused epp output" "" "$OUT"
check_file "turbo refused epp cpu0" "$E/$CPU/cpu0/cpufreq/energy_performance_preference" performance
expect_state "$E" turbo

# Failures are reported, the run goes on, and the recorded mode is left alone.
F=$T/f
make_tree "$F"
rm -f "$F/$RAPL/constraint_1_power_limit_uw"
mkdir -p "$F/$RAPL/constraint_1_power_limit_uw"
SMI_FAIL="-i 1 -rgc"
run_pm "$F" turbo
SMI_FAIL=""
check "failure exit" 1 "$RC"
expect_has "failure rapl warning" "cannot write 190000000 to $F/$RAPL/constraint_1_power_limit_uw" "$OUT"
expect_has "failure nvidia-smi warning" "nvidia-smi -i 1 -rgc failed" "$OUT"
expect_has "failure summary" "turbo applied with errors; recorded mode unchanged" "$OUT"
check_file "failure still wrote PL1" "$F/$RAPL/constraint_0_power_limit_uw" 190000000
check_file "failure still wrote no_turbo" "$F/$CPU/intel_pstate/no_turbo" 0
check "failure records no state" "no" "$([[ -e $F/run/powermode ]] && echo yes || echo no)"

# Status with no state file yet reports an unknown mode.
G=$T/g
make_tree "$G"
run_pm "$G" status
check "status cold exit" 0 "$RC"
expect_match "status cold mode" '^mode: +\?$' "$OUT"

# Idempotency: a repeated mode is "already" and writes nothing; drift, --force and the 1 W
# tolerance behave as documented.
H=$T/h
make_tree "$H"
run_pm "$H" turbo
check "idempotent first turbo exit" 0 "$RC"
check "idempotent first turbo output" "" "$OUT"
sleep 1.1
: > "$H/marker"
sleep 1.1
run_pm "$H" turbo
check "repeat turbo exit" 0 "$RC"
check "repeat turbo says already" "already turbo" "$OUT"
check "repeat turbo nvidia-smi calls are reads only" \
  "$(printf '%s\n' "$Q" "--query-gpu=index,power.limit --format=csv,noheader,nounits")" \
  "$(smi_log "$H")"
check "repeat turbo writes no files" "" \
  "$(find "$H" -newer "$H/marker" -type f ! -name smi.log)"
expect_state "$H" turbo

printf '1\n' > "$H/$CPU/intel_pstate/no_turbo"
run_pm "$H" turbo
check "no_turbo drift exit" 0 "$RC"
check "no_turbo drift output" "" "$OUT"
expect_intel "$H" 0 100
expect_has "no_turbo drift reapplied" "-pm 1" "$(smi_log "$H")"

printf '50\n' > "$H/$CPU/intel_pstate/max_perf_pct"
run_pm "$H" turbo
expect_intel "$H" 0 100
expect_has "max_perf drift reapplied" "-pm 1" "$(smi_log "$H")"

printf '180000000\n' > "$H/$RAPL/constraint_0_power_limit_uw"
run_pm "$H" turbo
expect_rapl "$H" 190000000 190000000
expect_has "RAPL drift reapplied" "-pm 1" "$(smi_log "$H")"

printf '150\n' > "$H/pl0"
run_pm "$H" turbo
check_file "GPU 0 drift reapplied" "$H/pl0" 190
expect_has "GPU drift reapplied" "-i 0 -pl 190" "$(smi_log "$H")"

# Within 1 W counts as a match: 189 W against 190 W is already turbo.
printf '189\n' > "$H/pl0"
printf '137\n' > "$H/pl1"
run_pm "$H" turbo
check "within 1 W exit" 0 "$RC"
check "within 1 W says already" "already turbo" "$OUT"
check_file "within 1 W left GPU 0 alone" "$H/pl0" 189
# 2 W off is a drift.
printf '188\n' > "$H/pl0"
run_pm "$H" turbo
check_file "2 W off reapplied" "$H/pl0" 190

# --force applies even when everything matches.
run_pm "$H" turbo
check "already before force" "already turbo" "$OUT"
run_pm "$H" --force turbo
check "force exit" 0 "$RC"
check "force output" "" "$OUT"
expect_has "force sends the writes" "-rgc" "$(smi_log "$H")"
expect_state "$H" turbo

# A different mode is never "already": default is applied.
run_pm "$H" default
check "mode change exit" 0 "$RC"
check "mode change output" "" "$OUT"
expect_state "$H" default
expect_intel "$H" 0 100
expect_rapl "$H" 125000000 190000000

# Recorded silent but the live caps still at default (an earlier run failed half way): silent is applied.
printf 'silent\n' > "$H/var/lib/powermode/mode"
run_pm "$H" silent
check "recorded silent but live default applies" "" "$OUT"
expect_intel "$H" 1 60
expect_state "$H" silent

# Concurrency: a second run waits on the lock while the first is inside its writes, then finds
# the mode already applied. The first run writes the -pm call only after taking the lock.
J=$T/j
make_tree "$J"
( POWERMODE_SYSFS_ROOT="$J" POWERMODE_NVIDIA_SMI="$T/bin/nvidia-smi" FAKE_SMI_LOG="$J/smi.log" \
  FAKE_SMI_DIR="$J" FAKE_SMI_SLEEP=2 "$PM" turbo > "$J/a.out" 2>&1; echo $? > "$J/a.rc" ) &
for i in $(seq 1 100); do grep -q -- "-pm" "$J/smi.log" 2>/dev/null && break; sleep 0.1; done
( POWERMODE_SYSFS_ROOT="$J" POWERMODE_NVIDIA_SMI="$T/bin/nvidia-smi" FAKE_SMI_LOG="$J/smi.log" \
  FAKE_SMI_DIR="$J" "$PM" turbo > "$J/b.out" 2>&1; echo $? > "$J/b.rc" ) &
wait
check_file "concurrent first exit" "$J/a.rc" 0
check_file "concurrent second exit" "$J/b.rc" 0
check "concurrent first output" "" "$(cat "$J/a.out")"
check "concurrent second waited and found it applied" "already turbo" "$(cat "$J/b.out")"
expect_state "$J" turbo

# A lock held past LOCK_TIMEOUT: the run gives up with a message and touches nothing.
K=$T/k
make_tree "$K"
mkdir -p "$K/run"
flock "$K/run/powermode.lock" -c "touch '$K/held'; sleep 4" &
for i in $(seq 1 100); do [ -e "$K/held" ] && break; sleep 0.1; done
run_pm_timeout() {
  OUT=$(POWERMODE_LOCK_TIMEOUT=1 POWERMODE_SYSFS_ROOT="$K" POWERMODE_NVIDIA_SMI="$T/bin/nvidia-smi" \
    FAKE_SMI_LOG="$K/smi.log" FAKE_SMI_DIR="$K" "$PM" "$@" 2>&1)
  RC=$?
}
run_pm_timeout turbo
check "held lock exit" 1 "$RC"
expect_has "held lock message" "another run still holds $K/run/powermode.lock after 1s; giving up" "$OUT"
check "held lock wrote nothing" "" "$(smi_log "$K")"
[ ! -e "$K/var/lib/powermode/mode" ] && [ ! -e "$K/run/powermode" ] \
  && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: held lock recorded a mode"; }
wait

echo "powermode tests: $pass passed, $fail failed"
if (( fail > 0 )); then
  exit 1
fi
