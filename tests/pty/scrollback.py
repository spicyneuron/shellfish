#!/usr/bin/env python3
"""Chat UI scrollback scenarios in a terminal emulator."""
import json
import os
import re
import sys
import time
from pathlib import Path

try:
    import pyte
except ImportError:
    # pyte is optional outside this suite.
    print("SKIP scrollback: pyte is not installed (pip install pyte)")
    sys.exit(0)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _session import ROWS, COLUMNS, Session, run  # noqa: E402

# Enough words for the agent block to overflow the window.
WORDS = [f"w{index:03d}" for index in range(1, 201)]
SESSION_FIXTURE = Path(__file__).resolve().parents[1] / "fixtures/session/complete.jsonl"
QUEUE_HOOK = r"""#!/usr/bin/env zsh
[[ $1 == user_prompt_submit ]] || exit 1
IFS= read -r prompt
[[ $prompt == alpha ]] || exit 0
: >"${SHELLFISH_SESSION:h}/queue-ready"
IFS= read -r <"${SHELLFISH_SESSION:h}/queue-release"
"""


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

    def turn_finished(self):
        frame = self.frame()
        return (
            re.search(r" · [\d.]+[km]? ↑", frame) is not None
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


def test_tall_turn_loses_neither_text_nor_draft():
    # Stream one word per line across multiple commit epochs.
    session = Session(env={"SF_TEST_BACKEND_LINE_WORDS": "1",
                           "SF_TEST_BACKEND_DELAY": "0.005"})
    terminal = Terminal(session)
    try:
        # Let the draft echo before Enter changes frames.
        session.send(" ".join(WORDS).encode())
        terminal.wait_for("the draft to echo",
                          lambda: WORDS[-1] in terminal.everything())
        session.send(b"\r")
        # Watch overflow only after the unclamped draft commits.
        terminal.wait_for("the prompt to commit",
                          lambda: "─ user" in terminal.scrollback().lower())
        # Waiting for the final record would end the mid-turn observation.
        session_path, _ = session.wait_session_records(1)
        terminal.wait_for(
            "the turn to start",
            lambda: "─ agent" in terminal.everything().lower()
            and not terminal.turn_finished(),
        )
        terminal.watch_overflow = True
        # The agent heading distinguishes its output from the user echo.
        terminal.wait_for("the agent block to commit",
                          lambda: "agent" in terminal.scrollback().lower())
        assert terminal.agent_committed_mid_turn, (
            "agent block reached scrollback only once the turn was over, so "
            "nothing here shows commits landing progressively" + terminal.dump())
        # Require stream progress between keys across commit epochs.
        def echoed_words():
            text = terminal.everything()
            return sum(text.count(word) >= 2 for word in WORDS)

        before = echoed_words()
        assert before < len(WORDS), "turn finished before typing probe" + terminal.dump()
        session.send(b"d")
        terminal.wait_for("the stream to progress after one typed key",
                          lambda: echoed_words() > before)
        for char in b"one":
            before = echoed_words()
            assert before < len(WORDS), (
                "turn finished before typing probe" + terminal.dump()
            )
            session.send(bytes([char]))
            terminal.wait_for(
                "the stream to progress after a typed key",
                lambda: echoed_words() > before,
            )
        terminal.wait_for("the turn to finish", terminal.turn_finished)
        terminal.wait_for("the draft to come back",
                          lambda: "❯ done" in terminal.frame())
        assert not terminal.deleted_during_turn, (
            "active stream deleted terminal rows" + terminal.dump()
        )
        assert "done" not in terminal.scrollback(), (
            "draft reached scrollback" + terminal.dump()
        )
        # Count headings before the second turn changes scrollback.
        for heading in ("user", "agent"):
            count = terminal.scrollback().lower().count(f"─ {heading} ─")
            assert count == 1, f"{heading} committed {count} times" + terminal.dump()
        # Submitting flushes output withheld by the clamp.
        session.send(b"\r")
        session.wait_session_records(5, path=session_path)
        terminal.wait_for(
            "the second turn to finish rendering",
            lambda: terminal.turn_finished()
            and terminal.everything().count("done") >= 2
            and terminal.everything().lower().count("─ user ─") == 2
            and terminal.everything().lower().count("─ agent ─") == 2,
        )

        # Each word appears in both the user block and agent echo.
        text = terminal.everything()
        lost = [word for word in WORDS if text.count(word) < 2]
        assert not lost, (
            f"{len(lost)} of {len(WORDS)} words lost: {lost[:8]}" + terminal.dump()
        )
        print(f"PASS clamp: {len(WORDS)} words survived a turn taller than {ROWS} rows")
    finally:
        session.close()


def test_tall_resume_drains_bounded_backlog():
    header = json.loads(SESSION_FIXTURE.read_text().splitlines()[0])
    lines = [f"resume-{index:03d}" for index in range(1, 201)]
    records = [
        header,
        {"type": "user", "content": [
            {"type": "text", "text": "resume seed"},
        ]},
        {"type": "assistant", "stop": "end",
         "content": [{"type": "text", "text": "\n".join(lines)}],
         "usage": {"input_tokens": 1, "output_tokens": 200}},
    ]
    session = Session(explicit_session=True, session_records=records)
    terminal = Terminal(session)
    try:
        terminal.watch_overflow = True
        terminal.wait_for("the resumed backlog", lambda: lines[-1] in terminal.everything())
        text = terminal.everything()
        missing = [line for line in lines if text.count(line) != 1]
        assert not missing, (
            f"{len(missing)} resumed lines missing or duplicated: {missing[:8]}"
            + terminal.dump()
        )
        assert "resume seed" in text, terminal.dump()
        assert ">...." not in session.visible(), terminal.dump()
        assert len(terminal.screen.scrolled) > ROWS, (
            "resume backlog did not drain through bounded scrollback" + terminal.dump()
        )
        print(f"PASS resume: {len(lines)} lines drained exactly once")
    finally:
        session.close()


def test_queued_submits_keep_committed_history():
    session = Session(hooks={"hold_queue": QUEUE_HOOK})
    terminal = Terminal(session)
    try:
        path, _ = session.wait_session_records(1)
        ready = path.parent / "queue-ready"
        release = path.parent / "queue-release"
        os.mkfifo(release)
        session.send(b"alpha\r")
        terminal.wait_for(
            "the first turn to remain active",
            lambda: "─ user" in terminal.everything().lower()
            and ready.exists()
            and not terminal.turn_finished(),
        )
        session.send(b"two\rthree\rdraft")
        terminal.wait_for(
            "the prompts to queue",
            lambda: "─ queue " in terminal.frame()
            and "two" in terminal.frame()
            and "three" in terminal.frame(),
        )
        release.write_text("\n")
        # The silent prompt hook records nothing, so each turn is two records.
        _, records = session.wait_session_records(7, path=path)
        messages = [
            record["content"][0]["text"]
            for record in records
            if record.get("type") == "user"
        ]
        terminal.wait_for(
            "queued turns to render",
            lambda: all(terminal.everything().count(prompt) >= 2 for prompt in messages)
            and "─ queue " not in terminal.frame()
            and "❯ draft" in terminal.frame(),
        )
        text = terminal.everything()
        assert messages == ["alpha", "two", "three"], messages
        assert text.lower().count("─ user ─") == 3, terminal.dump()
        print("PASS queue: queued turns preserved committed history")
    finally:
        session.close()


if __name__ == "__main__":
    run("scrollback PTY scenarios", [
        test_tall_resume_drains_bounded_backlog,
        test_tall_turn_loses_neither_text_nor_draft,
        test_queued_submits_keep_committed_history,
    ])
