"""Terminal emulator with retained scrollback for PTY scenarios."""
import re
import sys
import time

try:
    import pyte
except ImportError:
    # tests/run reports status 77 as a skip.
    print("pyte is not installed")
    sys.exit(77)

from _session import COLUMNS, ROWS


class Recorder(pyte.Screen):
    """Screen that retains scrolled rows."""

    def __init__(self, *args, **kwargs):
        self.scrolled = []
        super().__init__(*args, **kwargs)

    def index(self):
        top, bottom = self.margins or (0, self.lines - 1)
        if self.cursor.y == bottom:
            self.scrolled.append(self.display[top])
        super().index()


class Terminal:
    def __init__(self, session):
        self.session = session
        self.screen = Recorder(COLUMNS, ROWS)
        self.stream = pyte.ByteStream(self.screen)
        self.consumed = 0
        self.watch_overflow = False
        self.agent_committed_mid_turn = False
        self.deleted_during_turn = False

    def pump(self, timeout=0.05):
        self.session.pump(timeout)
        pending = bytes(self.session.output[self.consumed:])
        if pending:
            self.stream.feed(pending)
            self.consumed = len(self.session.output)
            if (
                self.watch_overflow
                and b"\x1b[M" in pending
                and not self.turn_finished()
            ):
                self.deleted_during_turn = True
        # Widget errors can corrupt the frame before it scrolls away.
        assert b":zle:" not in self.session.output, self.dump()
        # Catch ZLE's transient marker for lost hidden rows.
        if self.watch_overflow:
            assert ">...." not in self.frame(), self.dump()
        # Latch the transient mid-turn commit state.
        if not self.turn_finished() and "agent" in self.scrollback().lower():
            self.agent_committed_mid_turn = True

    def turn_finished(self, footer=r" · [\d.]+[km]? ↑"):
        frame = self.frame()
        return (
            re.search(footer, frame) is not None
            and not any(mark in frame for mark in ("⡀", "⡄", "⠆", "⠃", "⠁"))
        )

    def frame(self):
        """Return the live frame with padded wrapped rows rejoined."""
        return "".join(self.screen.display)

    def scrollback(self):
        return "".join(self.screen.scrolled)

    def everything(self):
        return self.scrollback() + self.frame()

    def dump(self):
        return (
            "\n--- scrollback ---\n" + "\n".join(self.screen.scrolled)
            + "\n--- display ---\n" + "\n".join(self.screen.display)
        )

    def wait_for(self, what, predicate, timeout=10):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            self.pump()
            if predicate():
                return
        raise AssertionError(f"timed out waiting for {what}" + self.dump())
