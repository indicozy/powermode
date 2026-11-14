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

Remove with `sudo ./uninstall.sh`, which re-enables `thermal-caps.service`.

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
    ai-resources prefix            print "nice -n 19 taskset -c 8-19" (use: $(ai-resources prefix) cmd)
    ai-resources desk|away|toggle  switch the state

Switching to desk re-pins the user's nice-19 processes onto CPUs 8-19 and warns about processes still
on GPU 0 (it does not stop them). Switching to away changes nothing else. Both refresh i3status.
The script needs no sudo. Its `~/.local/bin/ai-resources` is a symlink to this script.

Tests (fake state dir, nvidia-smi, /proc, taskset and pkill; never the real state):

    test/ai_resources_run.sh                         shell checks
    python3 -B -I -m unittest discover -s test       i3bar power and ai blocks and click handling
