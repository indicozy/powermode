"""Unit tests for the ai block (desk / away) and its click handling in i3status-quota-color.

Run: python3 -I -m unittest discover -s test -v
The wrapper path can be overridden with I3STATUS_WRAPPER.
"""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import stat
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True

WRAPPER = os.environ.get(
    "I3STATUS_WRAPPER",
    os.path.expanduser("~/.local/bin/i3status-quota-color"),
)


def load_wrapper(path):
    loader = importlib.machinery.SourceFileLoader("i3status_quota_color", path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


wrapper = load_wrapper(WRAPPER)


class AiBlockTest(unittest.TestCase):
    def test_labels_and_colours(self):
        self.assertEqual(wrapper.ai_block("desk"),
                         {"name": "ai", "full_text": "\U0001F9D1‍\U0001F4BB desk", "color": "#5FD75F"})
        self.assertEqual(wrapper.ai_block("away"),
                         {"name": "ai", "full_text": "\U0001F916 away", "color": "#FFD75F"})

    def test_missing_or_invalid_mode_shows_desk(self):
        self.assertEqual(wrapper.ai_block(None), wrapper.ai_block("desk"))
        self.assertEqual(wrapper.ai_block("bogus"), wrapper.ai_block("desk"))


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
    class FakeProc:
        def __init__(self):
            self.running = True

        def poll(self):
            return None if self.running else 0

    def setUp(self):
        self.launched = []
        self.meeting_launched = []
        self.power_launched = []
        self.refreshes = 0
        self.procs = []

    def make_handler(self):
        def ai_launch(action):
            self.launched.append(action)
            proc = self.FakeProc()
            self.procs.append(proc)
            return proc

        def meeting_launch(action):
            self.meeting_launched.append(action)
            return None

        def power_launch(mode):
            self.power_launched.append(mode)
            return None

        def refresh():
            self.refreshes += 1

        return wrapper.ClickHandler(
            launch=meeting_launch, refresh=refresh, delay=3600,
            power_launch=power_launch, power_state_path="/nonexistent/powermode",
            ai_launch=ai_launch,
        )

    def test_button1_launches_toggle_and_refreshes(self):
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

    def test_busy_toggle_drops_the_click(self):
        handler = self.make_handler()
        handler.handle({"name": "ai", "button": 1})
        self.assertIsNone(handler.handle({"name": "ai", "button": 1}))
        self.assertEqual(self.launched, ["toggle"])
        self.procs[0].running = False
        self.assertEqual(handler.handle({"name": "ai", "button": 1}), "toggle")
        self.assertEqual(self.launched, ["toggle", "toggle"])

    def test_power_clicks_still_work(self):
        handler = self.make_handler()
        handler.handle({"name": "power", "button": 1})  # power state unknown: first click gives silent
        self.assertEqual(self.power_launched, ["silent"])
        self.assertEqual(self.launched, [])


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
