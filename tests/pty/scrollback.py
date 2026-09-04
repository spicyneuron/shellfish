#!/usr/bin/env python3
"""What the chat UI commits to terminal scrollback, and in what state.

Everything here turns on telling committed scrollback from the live frame, which
is why these render with a real emulator: stripping CSI with a regex cannot make
that distinction, and it is the whole question. Sets the window size too, without
which the shell reads 0x0 from stty and silently disables both wrapping and
flushing, so nothing under test runs.
"""
import json
import os
import re
import sys
import time
from pathlib import Path

try:
    import pyte
except ImportError:
    # The only tests that need a terminal emulator, and the suite otherwise
    # depends on nothing. Skip rather than fail so a bare checkout stays green.
    print("SKIP scrollback: pyte is not installed (pip install pyte)")
    sys.exit(0)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _session import ROWS, COLUMNS, Session  # noqa: E402

# Enough words that the agent block alone overflows the window. That is the last
# overflow site: the user block above it is committed before the turn starts.
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
    """Screen that keeps the lines it scrolls away, which is scrollback."""

    def __init__(self, *args, **kwargs):
        self.scrolled = []
        self.scrolled_cells = []
        super().__init__(*args, **kwargs)

    def index(self):
        top, bottom = self.margins or (0, self.lines - 1)
        if self.cursor.y == bottom:
            self.scrolled.append(self.display[top])
            # Styling is only provable from the cells; display[] is text alone,
            # and a committed row is the only place styling can be lost.
            row = self.buffer[top]
            self.scrolled_cells.append([row[x] for x in range(self.columns)])
        super().index()


class Terminal:
    def __init__(self, session):
        self.session = session
        self.screen = Recorder(COLUMNS, ROWS)
        self.stream = pyte.ByteStream(self.screen)
        self.consumed = 0
        # The clamp governs the output region, not the draft: a typed message
        # taller than the window still overflows, and one test below types one.
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
        # A widget that errors writes straight to the terminal, which both shows
        # in the transcript and desynchronises ZLE's idea of the frame, so it
        # duplicates rows as well. Any such message carries a ":zle:" prefix.
        # Checked against the raw stream, because the frame it corrupts is also
        # what scrolls the evidence away.
        assert b":zle:" not in self.session.output, self.dump()
        # ZLE's marker for a frame taller than the window, whose hidden rows are
        # lost for real. Checked on every pump, since the next frame erases it.
        if self.watch_overflow:
            assert ">...." not in self.frame(), self.dump()
        # Progressive commit is only true while the turn runs, so it is latched
        # on every pump rather than waited for. Waiting cannot express it: the
        # condition stops holding the moment the turn ends, so a poll landing
        # after that would block until the timeout on something already decided.
        if not self.turn_finished() and "agent" in self.scrollback().lower():
            self.agent_committed_mid_turn = True

    def turn_finished(self):
        """True once usage is visible and EOF has cleared activity."""
        frame = self.frame()
        return (
            re.search(r" · \d+ ↑", frame) is not None
            and not any(mark in frame for mark in ("⡀", "⡄", "⠆", "⠃", "⠁"))
        )

    def frame(self):
        """Live frame, with wrapped rows rejoined.

        Rows are padded to the full width, so joining without separators puts
        back anything the terminal split at a wrap without running short lines
        together.
        """
        return "".join(self.screen.display)

    def scrollback(self):
        """Rows that have scrolled off, which is what was committed."""
        return "".join(self.screen.scrolled)

    def committed_style(self, role):
        """First cell of the committed heading row for `role`, or None."""
        for text, cells in zip(self.screen.scrolled, self.screen.scrolled_cells):
            start = text.lower().find(f"─ {role} ─")
            if start >= 0:
                return cells[start + 2]
        return None

    def everything(self):
        return self.scrollback() + self.frame()

    def dump(self):
        return (
            "\n--- scrollback ---\n" + "\n".join(self.screen.scrolled)
            + "\n--- display ---\n" + "\n".join(self.screen.display)
        )

    def wait_for(self, what, predicate, timeout=10):
        """Poll until `predicate` holds, naming `what` if it never does.

        The timeout stays under tests/run's own (30s by default), which would
        otherwise be free to kill the test part-way through writing its dump.
        """
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            self.pump()
            if predicate():
                return
        raise AssertionError(f"timed out waiting for {what}" + self.dump())


def test_tall_turn_loses_neither_text_nor_draft():
    # Settling is line-granular, so a one-word-per-line echo is what lets the
    # turn commit while it streams; a single-line echo settles nothing until the
    # turn ends and never exercises the heartbeat at all. The delay is equally
    # load-bearing: lines have to arrive faster than an epoch commits them, or
    # each commit fits in one chunk and never chains across editor entries.
    # Measured against a deliberately broken watcher teardown, 5 ms faults on
    # every run and 10 ms on none.
    session = Session(env={"SF_TEST_BACKEND_LINE_WORDS": "1",
                           "SF_TEST_BACKEND_DELAY": "0.005"})
    terminal = Terminal(session)
    try:
        # Synchronise on content, and never bundle Enter with the text: the draft
        # has to echo first, or the key lands in whatever frame is being flushed.
        session.send(" ".join(WORDS).encode())
        terminal.wait_for("the draft to echo",
                          lambda: WORDS[-1] in terminal.everything())
        session.send(b"\r")
        # Writing Enter is not ZLE reading it: until it does, the frame is still
        # the unclamped draft and legitimately overflows. Start watching at the
        # first frame that cannot be the draft any more, which is the one where
        # the prompt has become committed transcript.
        terminal.wait_for("the prompt to commit",
                          lambda: "─ user" in terminal.scrollback().lower())
        # Only the path is wanted, so wait for the file rather than a record
        # count. The third record is the final assistant message, so waiting for
        # it would mean waiting for the turn to end, which the next wait and this
        # whole test require not to have happened.
        session_path, _ = session.wait_session_records(1)
        terminal.wait_for(
            "the turn to start",
            lambda: "─ agent" in terminal.everything().lower()
            and not terminal.turn_finished(),
        )
        terminal.watch_overflow = True
        # Progressive commit: the agent's own early words reach scrollback while
        # the turn is still working. Waiting for the agent heading to scroll off
        # is what distinguishes them from the echo of the user block above.
        terminal.wait_for("the agent block to commit",
                          lambda: "agent" in terminal.scrollback().lower())
        # The wait above is also satisfied by the flush ending the turn, so the
        # latch is what carries the real claim: the heading reached scrollback
        # while the turn still had work left. This test's premise is a stream
        # slower than the epochs committing it, so a starved machine fails here.
        assert terminal.agent_committed_mid_turn, (
            "agent block reached scrollback only once the turn was over, so "
            "nothing here shows commits landing progressively" + terminal.dump())
        # One character must not strand the heartbeat it interrupted. Require
        # visible stream progress before sending another key, then keep typing
        # through the remaining epochs so the draft spans their commits.
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
        # One turn has committed and the next has not started, so each heading
        # stands in scrollback exactly once. A second copy would mean an epoch
        # recommitted what an earlier one had already flushed. Checked here
        # rather than at the end, where the count depends on how much of the
        # second turn happens to have scrolled off.
        for heading in ("user", "agent"):
            count = terminal.scrollback().lower().count(f"─ {heading} ─")
            assert count == 1, f"{heading} committed {count} times" + terminal.dump()
        # Text the clamp held back is not lost, only undisplayed: submitting
        # flushes what is left into scrollback a screen at a time.
        session.send(b"\r")
        session.wait_session_records(5, path=session_path)
        terminal.wait_for(
            "the second turn to finish rendering",
            lambda: terminal.turn_finished()
            and terminal.everything().count("done") >= 2
            and terminal.everything().lower().count("─ user ─") == 2
            and terminal.everything().lower().count("─ agent ─") == 2,
        )

        # Every word was committed twice, once in the user block and once in the
        # agent's echo of it, so a word seen only once means one of the two was
        # lost. Repaint duplication can only add copies, so undercounting is the
        # only direction that proves anything.
        text = terminal.everything()
        lost = [word for word in WORDS if text.count(word) < 2]
        assert not lost, (
            f"{len(lost)} of {len(WORDS)} words lost: {lost[:8]}" + terminal.dump()
        )
        print(f"PASS clamp: {len(WORDS)} words survived a turn taller than {ROWS} rows")
    finally:
        session.close()


def test_committed_headings_keep_style():
    """A committed heading retains the semantic style painted by ZLE."""
    session = Session(env={"SF_TEST_BACKEND_LINE_WORDS": "1",
                           "SF_TEST_BACKEND_DELAY": "0.001"})
    terminal = Terminal(session)
    try:
        session.send(" ".join(WORDS[:50]).encode() + b"\r")
        terminal.wait_for(
            "styled headings to commit",
            lambda: all(
                terminal.committed_style(role) is not None
                for role in ("user", "agent")
            ),
        )
        for role in ("user", "agent"):
            cell = terminal.committed_style(role)
            assert cell.fg != "default" and cell.bold, (
                f"{role} committed unstyled: fg={cell.fg} bg={cell.bg} "
                f"bold={cell.bold}" + terminal.dump()
            )
        print("PASS style: committed headings retained semantic styling")
    finally:
        session.close()


def test_tall_resume_drains_bounded_backlog():
    """A resumed closed node drains completely without duplication."""
    header = json.loads(SESSION_FIXTURE.read_text().splitlines()[0])
    lines = [f"resume-{index:03d}" for index in range(1, 201)]
    records = [
        header,
        {"type": "message", "role": "user", "content": [
            {"type": "text", "text": "resume seed"},
        ]},
        {"type": "message", "role": "assistant", "stop": "end",
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
    """Queued submits execute in order without disturbing committed output."""
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
        _, records = session.wait_session_records(7, path=path)
        messages = [
            record["content"][0]["text"]
            for record in records
            if record.get("role") == "user"
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


def main():
    test_tall_resume_drains_bounded_backlog()
    test_tall_turn_loses_neither_text_nor_draft()
    test_committed_headings_keep_style()
    test_queued_submits_keep_committed_history()


if __name__ == "__main__":
    main()
