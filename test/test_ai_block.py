"""Unit tests for the ai block (desk / away), its busy/failed rendering and its click handling in
i3status-quota-color.

Run: python3 -B -I -m unittest discover -s test -v
The wrapper path can be overridden with I3STATUS_WRAPPER. The wrapper's state, lock and log paths
are pointed at a temp dir before it is loaded, so no test reads or writes the real files.
"""
import atexit
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import stat
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

_SANDBOX = tempfile.mkdtemp(prefix="ai-resources-test-")
atexit.register(shutil.rmtree, _SANDBOX, True)
os.environ["AI_RESOURCES_STATE"] = os.path.join(_SANDBOX, "ai-mode")
os.environ["POWERMODE_STATE"] = os.path.join(_SANDBOX, "run-powermode")
os.environ["POWERMODE_LOCK"] = os.path.join(_SANDBOX, "lock")


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


class AiBlockTest(unittest.TestCase):
    def test_labels_and_colours(self):
        self.assertEqual(wrapper.ai_block("desk"),
                         {"name": "ai", "full_text": "\U0001F9D1‍\U0001F4BB desk", "color": "#5FD75F"})
        self.assertEqual(wrapper.ai_block("away"),
                         {"name": "ai", "full_text": "\U0001F916 away", "color": "#FFD75F"})

    def test_missing_or_invalid_mode_shows_desk(self):
        self.assertEqual(wrapper.ai_block(None), wrapper.ai_block("desk"))
        self.assertEqual(wrapper.ai_block("bogus"), wrapper.ai_block("desk"))

    def test_busy_shows_target_in_grey(self):
        self.assertEqual(wrapper.ai_block("desk", busy="away"),
                         {"name": "ai", "full_text": "⏳ away…", "color": GREY})
        self.assertEqual(wrapper.ai_block("away", busy="desk"),
                         {"name": "ai", "full_text": "⏳ desk…", "color": GREY})

    def test_failed_is_red_and_keeps_the_state_text(self):
        self.assertEqual(wrapper.ai_block("away", failed=True),
                         {"name": "ai", "full_text": "\U0001F916 away", "color": RED})


class ReadAiModeTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="ai-resources-test-")
        self.path = os.path.join(self.dir, "mode")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def write(self, text):
        with open(self.path, "w", encoding="utf-8") as fh:
            fh.write(text)

    def test_missing_file(self):
        self.assertIsNone(wrapper.read_ai_mode(self.path))

    def test_known_modes(self):
        self.write("desk\n")
        self.assertEqual(wrapper.read_ai_mode(self.path), "desk")
        self.write("away")
        self.assertEqual(wrapper.read_ai_mode(self.path), "away")

    def test_unknown_contents(self):
        for text in ("", "AWAY\n", "bogus\n", "away and more\n"):
            self.write(text)
            self.assertIsNone(wrapper.read_ai_mode(self.path), repr(text))


class AiClickActionTest(unittest.TestCase):
    def test_button1_toggles(self):
        self.assertEqual(wrapper.ai_click_action({"name": "ai", "button": 1}), "toggle")

    def test_other_buttons_do_nothing(self):
        for button in (2, 3, 4, 5, None):
            self.assertIsNone(wrapper.ai_click_action({"name": "ai", "button": button}))

    def test_other_blocks_are_ignored(self):
        self.assertIsNone(wrapper.ai_click_action({"name": "power", "button": 1}))
        self.assertIsNone(wrapper.ai_click_action({"name": "meeting", "button": 1}))


class ClickHandlerAiTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="ai-resources-test-")
        self.state = os.path.join(self.dir, "mode")
        self.power_log = os.path.join(self.dir, "power.log")
        self.launched = []
        self.children = []
        self.power_launched = []
        self.meeting_launched = []
        self.refreshes = 0
        self.now = [100.0]

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def write_state(self, text):
        with open(self.state, "w", encoding="utf-8") as fh:
            fh.write(text)

    def make_handler(self, busy_timeout=3600):
        def ai_launch(action):
            self.launched.append(action)
            child = FakeChild()
            self.children.append(child)
            return child

        def power_launch(mode):
            self.power_launched.append(mode)
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
            power_launch=power_launch, power_state_path="/nonexistent/powermode",
            power_lock_path=os.path.join(self.dir, "lock"), power_log_path=self.power_log,
            ai_launch=ai_launch, ai_state_path=self.state,
            busy_timeout=busy_timeout, clock=lambda: self.now[0],
        )

    def test_button1_launches_toggle_and_refreshes(self):
        self.write_state("desk\n")
        handler = self.make_handler()
        self.assertEqual(handler.handle({"name": "ai", "button": 1}), "toggle")
        self.assertEqual(self.launched, ["toggle"])
        self.assertEqual(self.refreshes, 1)
        self.assertEqual(self.meeting_launched, [])
        self.assertEqual(self.power_launched, [])

    def test_other_buttons_launch_nothing(self):
        handler = self.make_handler()
        for button in (2, 3):
            self.assertIsNone(handler.handle({"name": "ai", "button": button}))
        self.assertEqual(self.launched, [])
        self.assertEqual(self.refreshes, 0)

    def test_busy_block_shows_the_target_and_ignores_every_click(self):
        self.write_state("desk\n")
        handler = self.make_handler()
        handler.handle({"name": "ai", "button": 1})
        self.assertEqual(handler.ai.snapshot(), ("away", False))
        for button in (1, 2, 3):
            self.assertIsNone(handler.handle({"name": "ai", "button": button}))
        self.assertEqual(self.launched, ["toggle"])
        self.assertEqual(self.refreshes, 1)

    def test_target_is_desk_when_away(self):
        self.write_state("away\n")
        handler = self.make_handler()
        handler.handle({"name": "ai", "button": 1})
        self.assertEqual(handler.ai.snapshot(), ("desk", False))

    def test_busy_cleared_when_child_exits(self):
        self.write_state("desk\n")
        handler = self.make_handler()
        handler.handle({"name": "ai", "button": 1})
        self.children[0].finish(0)
        handler.join_waiters(5)
        self.assertEqual(handler.ai.snapshot(), (None, False))
        self.assertEqual(self.refreshes, 2)
        self.assertEqual(handler.handle({"name": "ai", "button": 1}), "toggle")
        self.assertEqual(self.launched, ["toggle", "toggle"])

    def test_nonzero_exit_marks_failed_until_next_success(self):
        self.write_state("desk\n")
        handler = self.make_handler()
        handler.handle({"name": "ai", "button": 1})
        self.children[0].finish(1)
        handler.join_waiters(5)
        self.assertEqual(handler.ai.snapshot(), (None, True))
        handler.handle({"name": "ai", "button": 1})
        self.children[1].finish(0)
        handler.join_waiters(5)
        self.assertEqual(handler.ai.snapshot(), (None, False))

    def test_failed_flag_expires_after_thirty_seconds(self):
        self.write_state("desk\n")
        handler = self.make_handler()
        handler.handle({"name": "ai", "button": 1})
        self.children[0].finish(1)
        handler.join_waiters(5)
        self.now[0] = 100.0 + wrapper.FAILED_SECONDS + 1
        self.assertEqual(handler.ai.snapshot(), (None, False))

    def test_safety_timeout_clears_busy(self):
        self.write_state("desk\n")
        handler = self.make_handler(busy_timeout=0.05)
        handler.handle({"name": "ai", "button": 1})
        handler.join_waiters(5)
        self.assertEqual(handler.ai.snapshot(), (None, False))
        self.assertEqual(handler.handle({"name": "ai", "button": 1}), "toggle")

    def test_launch_that_cannot_start_is_a_failure_at_once(self):
        self.write_state("desk\n")
        handler = self.make_handler()
        handler._ai_launch = lambda action: None
        self.assertEqual(handler.handle({"name": "ai", "button": 1}), "toggle")
        self.assertEqual(handler.ai.snapshot(), (None, True))

    def test_busy_ai_block_does_not_block_the_power_block(self):
        self.write_state("desk\n")
        handler = self.make_handler()
        handler.handle({"name": "ai", "button": 1})
        self.assertEqual(handler.handle({"name": "power", "button": 1}), "silent")
        self.assertEqual(self.power_launched, ["silent"])

    def test_power_clicks_still_work_with_no_state(self):
        handler = self.make_handler()
        handler.handle({"name": "power", "button": 1})  # power state unknown: first click gives silent
        self.assertEqual(self.power_launched, ["silent"])
        self.assertEqual(self.launched, [])


class StreamAiStatusTest(unittest.TestCase):
    def test_busy_ai_block_renders_in_the_stream(self):
        self_dir = tempfile.mkdtemp(prefix="ai-resources-test-")
        try:
            state = os.path.join(self_dir, "mode")
            with open(state, "w", encoding="utf-8") as fh:
                fh.write("desk\n")
            children = []

            def ai_launch(action):
                child = FakeChild()
                children.append(child)
                return child

            handler = wrapper.ClickHandler(
                launch=lambda action: None, refresh=lambda: None, delay=3600,
                power_launch=lambda mode: None, power_state_path="/nonexistent/powermode",
                power_lock_path=os.path.join(self_dir, "lock"),
                power_log_path=os.path.join(self_dir, "power.log"),
                ai_launch=ai_launch, ai_state_path=state,
            )
            handler.handle({"name": "ai", "button": 1})
            sink = io.BytesIO()
            wrapper.filter_stream(io.BytesIO(b'{"version":1}\n[\n[{"name":"cpu","full_text":"1%"}]\n'),
                                  sink, handler)
            blocks = json.loads(sink.getvalue().splitlines()[2].decode("utf-8").lstrip(","))
            ai = next(b for b in blocks if b["name"] == "ai")
            self.assertEqual(ai, {"name": "ai", "full_text": "⏳ away…", "color": GREY})
            children[0].finish(0)
            handler.join_waiters(5)
        finally:
            shutil.rmtree(self_dir, ignore_errors=True)


class LaunchAiTest(unittest.TestCase):
    """launch_ai runs the real launcher path; a fake ai-resources records its argv."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="ai-resources-test-")
        self.bin = os.path.join(self.dir, "ai-resources")
        self.argv_log = os.path.join(self.dir, "argv.txt")
        with open(self.bin, "w", encoding="utf-8") as fh:
            fh.write('#!/bin/sh\necho "$*" > "%s"\n' % self.argv_log)
        os.chmod(self.bin, os.stat(self.bin).st_mode | stat.S_IXUSR)
        self.saved_bin = wrapper.AI_BIN
        wrapper.AI_BIN = self.bin

    def tearDown(self):
        wrapper.AI_BIN = self.saved_bin
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_toggle_is_launched_detached_with_output_logged(self):
        log = os.path.join(self.dir, "logs", "ai.log")
        proc = wrapper.launch_ai("toggle", log_path=log)
        self.assertIsNotNone(proc)
        self.assertEqual(proc.wait(timeout=10), 0)
        with open(self.argv_log, encoding="utf-8") as fh:
            self.assertEqual(fh.read().strip(), "toggle")
        with open(log, encoding="utf-8") as fh:
            self.assertIn("bar: ai-resources toggle", fh.read())


class TransformAiBlockTest(unittest.TestCase):
    def test_order_is_meeting_power_ai_then_the_rest(self):
        raw = b'[{"name":"cpu","full_text":"1%"}]\n'
        out = wrapper.transform(
            raw,
            meeting={"name": "meeting", "full_text": "m"},
            power={"name": "power", "full_text": "p"},
            ai={"name": "ai", "full_text": "a"},
        )
        names = [b["name"] for b in json.loads(out.decode())]
        self.assertEqual(names, ["meeting", "power", "ai", "cpu"])

    def test_ai_without_power_follows_meeting(self):
        raw = b'[{"name":"cpu","full_text":"1%"}]\n'
        out = wrapper.transform(raw, meeting={"name": "meeting", "full_text": "m"},
                                ai={"name": "ai", "full_text": "a"})
        names = [b["name"] for b in json.loads(out.decode())]
        self.assertEqual(names, ["meeting", "ai", "cpu"])

    def test_no_extra_blocks_leaves_the_line_as_before(self):
        raw = b'[{"name":"cpu","full_text":"1%"}]\n'
        self.assertEqual(wrapper.transform(raw), raw)


if __name__ == "__main__":
    unittest.main()
