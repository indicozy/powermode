"""Unit tests for the power block, its busy/failed/lock rendering and its click handling in
i3status-quota-color.

Run: python3 -B -I -m unittest discover -s test -v
The wrapper path can be overridden with I3STATUS_WRAPPER. The wrapper's state, lock and log paths
are pointed at a temp dir before it is loaded, so no test reads or writes the real powermode files.
"""
import atexit
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

sys.dont_write_bytecode = True

WRAPPER = os.environ.get(
    "I3STATUS_WRAPPER",
    os.path.expanduser("~/.local/bin/i3status-quota-color"),
)

_SANDBOX = tempfile.mkdtemp(prefix="powermode-test-")
atexit.register(shutil.rmtree, _SANDBOX, True)
os.environ["POWERMODE_STATE"] = os.path.join(_SANDBOX, "run-powermode")
os.environ["POWERMODE_LOCK"] = os.path.join(_SANDBOX, "lock")
os.environ["AI_RESOURCES_STATE"] = os.path.join(_SANDBOX, "ai-mode")


def load_wrapper(path):
    loader = importlib.machinery.SourceFileLoader("i3status_quota_color", path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


wrapper = load_wrapper(WRAPPER)
GREY = "#888888"
RED = "#FF5F5F"


class FakeChild:
    """Stands in for subprocess.Popen: wait() returns the exit code once finish() is called."""

    def __init__(self):
        self._done = threading.Event()
        self.returncode = None

    def finish(self, returncode=0):
        self.returncode = returncode
        self._done.set()

    def wait(self, timeout=None):
        if not self._done.wait(timeout):
            raise subprocess.TimeoutExpired(cmd="fake", timeout=timeout)
        return self.returncode


class NextPowerModeTest(unittest.TestCase):
    def test_button1_cycles_forward(self):
        self.assertEqual(wrapper.next_power_mode("silent", 1), "default")
        self.assertEqual(wrapper.next_power_mode("default", 1), "turbo")
        self.assertEqual(wrapper.next_power_mode("turbo", 1), "silent")

    def test_button3_cycles_backward(self):
        self.assertEqual(wrapper.next_power_mode("silent", 3), "turbo")
        self.assertEqual(wrapper.next_power_mode("turbo", 3), "default")
        self.assertEqual(wrapper.next_power_mode("default", 3), "silent")

    def test_other_buttons_do_nothing(self):
        for button in (0, 2, 4, 5, None):
            self.assertIsNone(wrapper.next_power_mode("silent", button))

    def test_unknown_current_mode_starts_at_the_ends(self):
        self.assertEqual(wrapper.next_power_mode(None, 1), "silent")
        self.assertEqual(wrapper.next_power_mode("bogus", 3), "turbo")


class PowerClickActionTest(unittest.TestCase):
    def test_button1_on_power_block(self):
        event = {"name": "power", "button": 1}
        self.assertEqual(wrapper.power_click_action(event, "silent"), "default")

    def test_button3_on_power_block(self):
        event = {"name": "power", "button": 3}
        self.assertEqual(wrapper.power_click_action(event, "silent"), "turbo")

    def test_non_power_click_is_ignored(self):
        self.assertIsNone(wrapper.power_click_action({"name": "meeting", "button": 1}, "silent"))
        self.assertIsNone(wrapper.power_click_action({"name": "zai-quota", "button": 1}, "turbo"))

    def test_meeting_click_never_triggers_power(self):
        self.assertIsNone(wrapper.power_click_action({"name": "meeting", "button": 3}, "default"))


class PowerBlockTest(unittest.TestCase):
    def test_labels_and_colours(self):
        self.assertEqual(wrapper.power_block("silent"),
                         {"name": "power", "full_text": "🔇 silent", "color": "#5FAFFF"})
        self.assertEqual(wrapper.power_block("default"),
                         {"name": "power", "full_text": "⚖ default"})
        self.assertEqual(wrapper.power_block("turbo"),
                         {"name": "power", "full_text": "🚀 turbo", "color": "#FF5F5F"})

    def test_missing_mode_shows_grey_placeholder(self):
        self.assertEqual(wrapper.power_block(None),
                         {"name": "power", "full_text": "⚡ ?", "color": GREY})

    def test_busy_shows_target_in_grey(self):
        self.assertEqual(wrapper.power_block("silent", busy="turbo"),
                         {"name": "power", "full_text": "⏳ turbo…", "color": GREY})

    def test_failed_is_red_and_keeps_the_mode_text(self):
        self.assertEqual(wrapper.power_block("silent", failed=True),
                         {"name": "power", "full_text": "🔇 silent", "color": RED})

    def test_busy_wins_over_failed(self):
        self.assertEqual(wrapper.power_block("silent", busy="default", failed=True),
                         {"name": "power", "full_text": "⏳ default…", "color": GREY})

    def test_lock_icon_is_appended(self):
        self.assertEqual(wrapper.power_block("default", locked=True),
                         {"name": "power", "full_text": "⚖ default 🔒"})
        self.assertEqual(wrapper.power_block("turbo", locked=True)["full_text"], "🚀 turbo 🔒")

    def test_no_lock_no_icon(self):
        self.assertEqual(wrapper.power_block("default", locked=False)["full_text"], "⚖ default")


class ReadPowerModeTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="powermode-test-")
        self.path = os.path.join(self.dir, "powermode")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def write(self, text):
        with open(self.path, "w", encoding="utf-8") as fh:
            fh.write(text)

    def test_missing_file(self):
        self.assertIsNone(wrapper.read_power_mode(self.path))

    def test_known_modes(self):
        for mode in ("silent", "default", "turbo"):
            self.write(mode + "\n")
            self.assertEqual(wrapper.read_power_mode(self.path), mode)

    def test_unknown_contents(self):
        self.write("boot\n")
        self.assertIsNone(wrapper.read_power_mode(self.path))


class ClickHandlerPowerTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="powermode-test-")
        self.state = os.path.join(self.dir, "powermode")
        self.lock = os.path.join(self.dir, "lock")
        self.log = os.path.join(self.dir, "logs", "powermode-bar.log")
        with open(self.state, "w", encoding="utf-8") as fh:
            fh.write("silent\n")
        self.launched = []
        self.children = []
        self.lock_seen_at_launch = []
        self.meeting_launched = []
        self.refreshes = 0
        self.now = [100.0]

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def make_handler(self, busy_timeout=3600, clock=None, launch_returns_none=False):
        def power_launch(mode):
            self.launched.append(mode)
            self.lock_seen_at_launch.append(os.path.exists(self.lock))
            if launch_returns_none:
                return None
            child = FakeChild()
            self.children.append(child)
            return child

        def meeting_launch(action):
            self.meeting_launched.append(action)
            return None

        def refresh():
            self.refreshes += 1

        return wrapper.ClickHandler(
            launch=meeting_launch, refresh=refresh, delay=3600,
            power_launch=power_launch, power_state_path=self.state,
            power_lock_path=self.lock, power_log_path=self.log,
            busy_timeout=busy_timeout, clock=clock or (lambda: self.now[0]),
        )

    def write_state(self, mode):
        with open(self.state, "w", encoding="utf-8") as fh:
            fh.write(mode + "\n")

    def write_lock(self):
        with open(self.lock, "w", encoding="utf-8") as fh:
            fh.write("silent\n")

    def log_text(self):
        try:
            with open(self.log, encoding="utf-8") as fh:
                return fh.read()
        except OSError:
            return ""

    def test_click_launches_next_mode_and_refreshes(self):
        handler = self.make_handler()
        self.assertEqual(handler.handle({"name": "power", "button": 1}), "default")
        self.assertEqual(self.launched, ["default"])
        self.assertEqual(self.refreshes, 1)
        self.assertEqual(self.meeting_launched, [])

    def test_right_click_goes_backwards(self):
        handler = self.make_handler()
        self.assertEqual(handler.handle({"name": "power", "button": 3}), "turbo")
        self.assertEqual(self.launched, ["turbo"])

    def test_busy_block_renders_target_and_ignores_every_click(self):
        handler = self.make_handler()
        handler.handle({"name": "power", "button": 1})
        self.assertTrue(handler.power.is_busy())
        self.assertEqual(handler.power.snapshot(), ("default", False))
        self.assertIsNone(handler.handle({"name": "power", "button": 1}))
        self.assertIsNone(handler.handle({"name": "power", "button": 3}))
        self.assertEqual(self.launched, ["default"])
        self.assertEqual(self.refreshes, 1)  # the ignored clicks do not refresh

    def test_busy_cleared_when_child_exits_and_bar_refreshed_again(self):
        handler = self.make_handler()
        handler.handle({"name": "power", "button": 1})
        self.children[0].finish(0)
        handler.join_waiters(5)
        self.assertEqual(handler.power.snapshot(), (None, False))
        self.assertEqual(self.refreshes, 2)  # once when the change started, once when it ended
        self.assertEqual(handler.handle({"name": "power", "button": 1}), "default")
        self.assertEqual(self.launched, ["default", "default"])

    def test_nonzero_exit_marks_block_failed_until_next_success(self):
        handler = self.make_handler()
        handler.handle({"name": "power", "button": 1})
        self.children[0].finish(1)
        handler.join_waiters(5)
        self.assertEqual(handler.power.snapshot(), (None, True))
        handler.handle({"name": "power", "button": 1})
        # The earlier failure stays recorded while the retry runs; busy is what the block shows.
        self.assertEqual(handler.power.snapshot(), ("default", True))
        busy, failed = handler.power.snapshot()
        self.assertEqual(wrapper.power_block("silent", busy=busy, failed=failed)["color"], GREY)
        self.children[1].finish(0)
        handler.join_waiters(5)
        self.assertEqual(handler.power.snapshot(), (None, False))

    def test_failed_flag_expires_after_thirty_seconds(self):
        handler = self.make_handler()
        handler.handle({"name": "power", "button": 1})
        self.children[0].finish(2)
        handler.join_waiters(5)
        self.now[0] = 100.0 + wrapper.FAILED_SECONDS - 1
        self.assertEqual(handler.power.snapshot(), (None, True))
        self.now[0] = 100.0 + wrapper.FAILED_SECONDS + 1
        self.assertEqual(handler.power.snapshot(), (None, False))

    def test_safety_timeout_clears_busy_without_marking_failed(self):
        handler = self.make_handler(busy_timeout=0.05)
        handler.handle({"name": "power", "button": 1})
        handler.join_waiters(5)  # the child never exits; the waiter gives up after 0.05 s
        self.assertEqual(handler.power.snapshot(), (None, False))
        self.assertEqual(self.refreshes, 2)
        self.assertEqual(handler.handle({"name": "power", "button": 1}), "default")
        self.assertEqual(len(self.launched), 2)

    def test_launch_that_cannot_start_is_a_failure_at_once(self):
        handler = self.make_handler(launch_returns_none=True)
        self.assertEqual(handler.handle({"name": "power", "button": 1}), "default")
        self.assertEqual(handler.power.snapshot(), (None, True))
        self.assertFalse(handler.power.is_busy())
        self.assertEqual(self.refreshes, 1)

    def test_click_releases_the_lock_before_launching(self):
        self.write_lock()
        handler = self.make_handler()
        self.assertEqual(handler.handle({"name": "power", "button": 1}), "default")
        self.assertFalse(os.path.exists(self.lock))
        self.assertEqual(self.lock_seen_at_launch, [False])
        self.assertIn("bar: lock released", self.log_text())

    def test_ignored_click_does_not_release_the_lock(self):
        handler = self.make_handler()
        handler.handle({"name": "power", "button": 1})
        self.write_lock()
        self.assertIsNone(handler.handle({"name": "power", "button": 1}))
        self.assertTrue(os.path.exists(self.lock))
        self.assertNotIn("lock released", self.log_text())

    def test_click_without_a_lock_logs_nothing_and_still_launches(self):
        handler = self.make_handler()
        self.assertEqual(handler.handle({"name": "power", "button": 1}), "default")
        self.assertEqual(self.launched, ["default"])
        self.assertEqual(self.log_text(), "")

    def test_non_power_click_does_not_launch_power(self):
        handler = self.make_handler()
        self.assertIsNone(handler.handle({"name": "zai-quota", "button": 1}))
        self.assertEqual(self.launched, [])
        self.assertEqual(self.refreshes, 0)


class PowerStreamTest(unittest.TestCase):
    """The filtered i3bar stream shows the busy, failed and lock states of the power block."""

    def stream_power_block(self, handler=None):
        sink = io.BytesIO()
        source = io.BytesIO(b'{"version":1}\n[\n[{"name":"cpu","full_text":"1%"}]\n')
        wrapper.filter_stream(source, sink, handler)
        line = sink.getvalue().splitlines()[2]
        blocks = json.loads(line.decode("utf-8").lstrip(","))
        return next(b for b in blocks if b["name"] == "power")

    def setUp(self):
        with open(wrapper.POWER_STATE, "w", encoding="utf-8") as fh:
            fh.write("silent\n")
        self.children = []
        self.dir = tempfile.mkdtemp(prefix="powermode-test-")

    def tearDown(self):
        for path in (wrapper.POWER_STATE, wrapper.POWER_LOCK):
            try:
                os.remove(path)
            except FileNotFoundError:
                pass
        shutil.rmtree(self.dir, ignore_errors=True)

    def make_handler(self):
        def power_launch(mode):
            child = FakeChild()
            self.children.append(child)
            return child

        return wrapper.ClickHandler(
            launch=lambda action: None, refresh=lambda: None, delay=3600,
            power_launch=power_launch, power_lock_path=wrapper.POWER_LOCK,
            power_log_path=os.path.join(self.dir, "power.log"),
        )

    def test_plain_stream_shows_the_recorded_mode(self):
        block = self.stream_power_block()
        self.assertEqual(block["full_text"], "🔇 silent")

    def test_locked_power_block_shows_the_lock_icon(self):
        with open(wrapper.POWER_LOCK, "w", encoding="utf-8") as fh:
            fh.write("silent\n")
        self.assertEqual(self.stream_power_block()["full_text"], "🔇 silent 🔒")

    def test_busy_block_shows_target_in_grey_in_the_stream(self):
        handler = self.make_handler()
        handler.handle({"name": "power", "button": 1})
        block = self.stream_power_block(handler)
        self.assertEqual(block["full_text"], "⏳ default…")
        self.assertEqual(block["color"], GREY)
        self.children[0].finish(0)
        handler.join_waiters(5)
        self.assertEqual(self.stream_power_block(handler)["full_text"], "🔇 silent")

    def test_failed_block_is_red_in_the_stream(self):
        handler = self.make_handler()
        handler.handle({"name": "power", "button": 1})
        self.children[0].finish(1)
        handler.join_waiters(5)
        block = self.stream_power_block(handler)
        self.assertEqual(block["color"], RED)
        self.assertEqual(block["full_text"], "🔇 silent")


if __name__ == "__main__":
    unittest.main()
