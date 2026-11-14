"""Unit tests for the power block and its click handling in i3status-quota-color.

Run: python3 -I -m unittest discover -s test -v
The wrapper path can be overridden with I3STATUS_WRAPPER.
"""
import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
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
                         {"name": "power", "full_text": "⚡ ?", "color": "#888888"})


class ReadPowerModeTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="powermode-test-")
        self.path = os.path.join(self.dir, "powermode")

    def tearDown(self):
        for name in os.listdir(self.dir):
            os.remove(os.path.join(self.dir, name))
        os.rmdir(self.dir)

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
    class FakeProc:
        def __init__(self):
            self.running = True

        def poll(self):
            return None if self.running else 0

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="powermode-test-")
        self.state = os.path.join(self.dir, "powermode")
        self.launched = []
        self.meeting_launched = []
        self.refreshes = 0
        self.procs = []

    def tearDown(self):
        for name in os.listdir(self.dir):
            os.remove(os.path.join(self.dir, name))
        os.rmdir(self.dir)

    def make_handler(self):
        def power_launch(mode):
            self.launched.append(mode)
            proc = self.FakeProc()
            self.procs.append(proc)
            return proc

        def meeting_launch(action):
            self.meeting_launched.append(action)
            return None

        def refresh():
            self.refreshes += 1

        return wrapper.ClickHandler(
            launch=meeting_launch, refresh=refresh, delay=3600,
            power_launch=power_launch, power_state_path=self.state,
        )

    def write_state(self, mode):
        with open(self.state, "w", encoding="utf-8") as fh:
            fh.write(mode + "\n")

    def test_click_launches_next_mode_and_refreshes(self):
        self.write_state("silent")
        handler = self.make_handler()
        self.assertEqual(handler.handle({"name": "power", "button": 1}), "default")
        self.assertEqual(self.launched, ["default"])
        self.assertEqual(self.refreshes, 1)
        self.assertEqual(self.meeting_launched, [])

    def test_right_click_goes_backwards(self):
        self.write_state("silent")
        handler = self.make_handler()
        self.assertEqual(handler.handle({"name": "power", "button": 3}), "turbo")
        self.assertEqual(self.launched, ["turbo"])

    def test_busy_power_change_drops_the_click(self):
        self.write_state("silent")
        handler = self.make_handler()
        handler.handle({"name": "power", "button": 1})
        self.assertIsNone(handler.handle({"name": "power", "button": 1}))
        self.assertEqual(self.launched, ["default"])
        self.procs[0].running = False
        self.assertEqual(handler.handle({"name": "power", "button": 1}), "default")
        self.assertEqual(self.launched, ["default", "default"])

    def test_non_power_click_does_not_launch_power(self):
        self.write_state("silent")
        handler = self.make_handler()
        self.assertIsNone(handler.handle({"name": "zai-quota", "button": 1}))
        self.assertEqual(self.launched, [])
        self.assertEqual(self.refreshes, 0)


class TransformPowerBlockTest(unittest.TestCase):
    def test_power_block_follows_meeting_block(self):
        raw = b'[{"name":"cpu","full_text":"1%"}]\n'
        out = wrapper.transform(
            raw, meeting={"name": "meeting", "full_text": "x"},
            power={"name": "power", "full_text": "y"},
        )
        names = [b["name"] for b in json.loads(out.decode())]
        self.assertEqual(names, ["meeting", "power", "cpu"])

    def test_without_power_the_line_is_as_before(self):
        raw = b'[{"name":"cpu","full_text":"1%"}]\n'
        self.assertEqual(wrapper.transform(raw), raw)


if __name__ == "__main__":
    unittest.main()
