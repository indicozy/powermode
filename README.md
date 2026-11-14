# powermode

Switches CPU, RAPL and GPU power caps between three modes. The i3bar shows the current mode;
a click cycles it (left click forward, right click backward).

| mode | GPUs (5060 Ti / 4060) | CPU (RAPL PL1 / PL2) | CPU behaviour |
|---|---|---|---|
| silent | min power limit (150 / 90 W), clocks capped at 1800 / 1600 MHz | 65 / 90 W | turbo off, max 60 %, powersave governor, power EPP |
| default | default power limit (180 / 115 W), clocks unlocked | 125 / 190 W | turbo on, max 100 %, powersave governor, balance_performance EPP |
| turbo | max power limit (190 / 138 W), clocks unlocked | 190 / 190 W | turbo on, max 100 %, performance governor, performance EPP |

The GPU limits are read from nvidia-smi at run time, not hardcoded.

There is no motherboard fan control. Fans follow the BIOS curve. Silent works by cutting heat,
not by changing fan speed.

## Install

    sudo ./install.sh

This installs `/usr/local/bin/powermode`, a sudoers rule that lets your user run only that path
without a password, and `powermode.service`, which re-applies the recorded mode at boot. It disables
`thermal-caps.service` (its unit file is kept). The mode is seeded as `silent`.

It also adds `/etc/systemd/system/user@.service.d/delegate-cpuset.conf`, which delegates the cpuset
controller to your user manager so `ai.slice` can limit CPUs itself. That takes effect after a
logout/login or a reboot (until then the slice falls back to taskset pins).

Remove with `sudo ./uninstall.sh`, which re-enables `thermal-caps.service` and removes the cpuset
delegation drop-in.

## Usage

    powermode silent|default|turbo    apply a mode and record it
    powermode status                 show the recorded mode and the live readout (no root needed)
    powermode boot                   re-apply the recorded mode (used by the service)

## Tests

    test/run.sh                                      fake sysfs tree and fake nvidia-smi
    python3 -I test/test_power_block.py              i3bar block and click handling

## ai-resources

A desk/away switch for AI and agent work, shown as the `ai` block in the i3bar (left click toggles it).

| state | meaning | cpus | GPUs (CUDA_VISIBLE_DEVICES) |
|---|---|---|---|
| desk (default) | the owner is at the PC | 8-19 | 1 (RTX 4060) |
| away | nobody at the PC | 0-19 | 0,1 |

The state lives in `~/.config/ai-resources/mode` (`AI_RESOURCES_STATE` overrides it). A missing or
invalid file means desk.

    ai-resources [status]          print e.g. "desk cpus=8-19 gpus=1"
    ai-resources mode|cpus|gpus    print one value
    ai-resources prefix            print the prefix for heavy work (use: $(ai-resources prefix) cmd)
    ai-resources desk|away|toggle  switch the state (applies it, then refreshes i3status)
    ai-resources apply             push the current state onto running AI work
    ai-resources setup             install systemd/ai.slice, daemon-reload, start it, apply

The prefix is `ai-run nice -n 19` when ai.slice has the cpuset controller (the slice limits the CPUs
itself, so jobs can widen when going away). Without cpuset it is `ai-run nice -n 19 taskset -c 8-19`
(or 0-19 when away).

`ai-run CMD...` runs CMD in the systemd user slice `ai.slice` (`~/.local/bin/ai-run` is a symlink to
this script). If no scope can be started (no user bus), it runs CMD without the slice and prints a
warning. Claude itself runs as `alias claude='ai-run tg-claude'` in `~/.zshrc`.

On every switch (and on `apply`) the state is applied to running work:
- with cpuset on ai.slice, `systemctl --user set-property ai.slice AllowedCPUs=` is set to the state's CPUs;
- every process in the ai.slice subtree and every nice-19 process of the user is re-pinned with
  `taskset -a -cp` to the state's CPUs, in both directions (away widens jobs back to 0-19);
- desk warns about processes still on GPU 0 (it does not stop them).

Switching to away changes nothing else. The script needs no sudo. Its `~/.local/bin/ai-resources` is
a symlink to this script. `ai-resources setup` links the unit into `~/.config/systemd/user/`; the
slice's properties are set persistently with `set-property`, so they survive a restart of the session.

Claude Code hook: `claude-hook` (symlinked as `~/.local/bin/ai-resources-hook`) is registered for
`UserPromptSubmit` and `PostToolUse` in `~/.claude/settings.json`. It tells each Claude session the
live state, power mode and lock on first sight, and again only when they change ("Resources CHANGED by
the owner: ..."). Its per-session memory is `~/.cache/ai-resources/seen/<session_id>`. It always exits 0.
A running session learns of a switch on its next prompt or tool use.

Tests (fake state dir, nvidia-smi, /proc, taskset, pkill, systemctl, cgroup tree and systemd-run;
never the real state, the real user manager or real affinities):

    test/ai_resources_run.sh                         ai-resources and ai-run shell checks
    test/claude_hook_run.sh                          Claude hook: first sight, change, garbage, session ids
    python3 -B -I -m unittest discover -s test       i3bar power and ai blocks and click handling

