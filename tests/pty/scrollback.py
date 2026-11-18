#!/usr/bin/env python3
"""Chat UI scrollback scenarios in a terminal emulator."""
import json
import os
import re
import sys
import tempfile
import termios
import time
from collections import Counter
from pathlib import Path

try:
    import pyte
except ImportError:
    # pyte is optional; tests/run reports status 77 as a skip.
    print("pyte is not installed")
    sys.exit(77)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _session import ROWS, COLUMNS, Session, run  # noqa: E402

# Enough words for the agent block to overflow the window.
WORDS = [f"w{index:03d}" for index in range(1, 201)]
SESSION_FIXTURE = Path(__file__).resolve().parents[1] / "fixtures/session/complete.jsonl"
QUEUE_HOOK = r"""#!/usr/bin/env zsh
(( $# == 0 )) || exit 1
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


def test_help_notice_keeps_one_separator():
    with tempfile.TemporaryDirectory() as directory:
        hook = Path(directory) / "instructions"
        hook.mkdir()
        (hook / "manifest.json").write_text('{"on":"session_start","user_text":"${output.stdout}"}')
        script = hook / "run"
        script.write_text(
            '#!/usr/bin/env zsh\n'
            'print -r -- "Project instructions (AGENTS.md):"\n'
            'print -r -- "# Shellfish"\n'
            'repeat 100 print -r -- "some instructions"\n'
        )
        script.chmod(0o755)
        session = Session(commands=["help"], session_start=[str(hook)])
        terminal = Terminal(session)
        try:
            session.wait_session_records(2)
            session.wait_ready()
            terminal.wait_for("project notice", lambda: "┆" in terminal.everything())
            for _ in range(5):
                terminal.pump()
            idle = [line.rstrip() for line in
                    terminal.screen.scrolled + terminal.screen.display]
            end = next(i for i, line in enumerate(idle) if "┆" in line)
            divider = next(i for i in range(end + 1, len(idle))
                           if idle[i].startswith("─"))
            assert idle[end + 1:divider] == [""], terminal.dump()

            session.send(b"/help\r")
            session.wait_session_records(3)
            session.wait_ready()
            terminal.wait_for("help notice", lambda: "/quit, /q" in terminal.everything())
            for _ in range(5):
                terminal.pump()
            lines = [line.rstrip() for line in
                     terminal.screen.scrolled + terminal.screen.display]
            end = next(i for i, line in enumerate(lines) if "┆" in line)
            help_row = lines.index("ℹ Help:")
            assert lines[end + 1:help_row] == [""], terminal.dump()
            assert not any(line.startswith("─ user ") for line in lines), terminal.dump()
            session.send(b"numbered prompt\r")
            _, records = session.wait_session_records(5)
            assert [r["section"] for r in records if r["type"] in ("user", "assistant")] == [1, 2]
        finally:
            session.close()


def test_user_and_agent_keep_one_separator():
    session = Session()
    terminal = Terminal(session)
    try:
        session.send(b"wqr\r")
        session.wait_session_records(3)
        session.wait_ready()
        terminal.wait_for("agent reply", lambda: "─ agent " in terminal.everything())
        for _ in range(5):
            terminal.pump()
        lines = [line.rstrip() for line in
                 terminal.screen.scrolled + terminal.screen.display]
        user_row = lines.index("wqr")
        agent_row = next(i for i in range(user_row + 1, len(lines))
                         if lines[i].startswith("─ agent "))
        assert lines[user_row + 1:agent_row] == [""], terminal.dump()
    finally:
        session.close()


def test_tall_turn_loses_neither_text_nor_draft():
    # Stream one word per line across multiple commit epochs.
    session = Session(env={"SF_TEST_PROVIDER_LINE_WORDS": "1",
                           "SF_TEST_PROVIDER_DELAY": "0.005"})
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
            counts = Counter(terminal.everything().split())
            return sum(counts[word] >= 2 for word in WORDS)

        before = echoed_words()
        assert before < len(WORDS), "turn finished before typing probe" + terminal.dump()
        # ZLE briefly allows kernel echo while handing rows to scrollback.
        # Sample the tty directly, not the timing of any escape sequence.
        deadline = time.monotonic() + 2
        while not termios.tcgetattr(session.fd)[3] & termios.ECHO:
            assert time.monotonic() < deadline, "tty never enabled echo during a commit"
            session.pump(0)
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
        _, records = session.wait_session_records(3, path=session_path)
        reply = next(record for record in records if record["type"] == "assistant")
        assert reply["content"][0]["text"].split() == WORDS, reply
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
        _, records = session.wait_session_records(5, path=session_path)
        assert records[3]["type"] == "user", records[3]
        assert records[3]["content"] == [{"type": "text", "text": "done"}], records[3]
        terminal.wait_for(
            "the second turn to finish rendering",
            lambda: terminal.turn_finished()
            and terminal.everything().count("done") >= 2
            and terminal.everything().lower().count("─ user ─") == 2
            and terminal.everything().lower().count("─ agent ─") == 2,
        )

        # The second turn can render before the previous reply finishes draining.
        def reply_rows():
            rows = terminal.screen.scrolled + terminal.screen.display
            start = next(i for i, row in enumerate(rows) if row.startswith("─ agent ─"))
            end = next((i for i, row in enumerate(rows) if i > start
                        and row.startswith("─ user ─")), len(rows))
            return [row.strip() for row in rows[start + 1:end] if row.strip()]

        terminal.wait_for("all reply rows intact and in order", lambda: reply_rows() == WORDS)
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
            lambda: ready.exists() and not terminal.turn_finished(),
        )
        assert "─ user" not in terminal.everything().lower(), terminal.dump()
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


def test_file_changes_use_full_preview():
    session = Session(explicit_session=True)
    terminal = Terminal(session)
    try:
        session.send(b"write\r")
        terminal.wait_for("permission prompt",
                          lambda: "[s]top and discuss" in terminal.frame())
        session.send(b"a")
        _, records = session.wait_session_records(4, path=session.explicit_session)
        result = next(record for record in records if record.get("type") == "tool_result")
        assert result["user_preview_lines"] == "full", result
        assert result["user_text"].startswith("**Write** "), result
        terminal.wait_for("the full file preview",
                          lambda: "+   1. Definitions." in terminal.everything())
    finally:
        session.close()


def test_permission_countdown():
    session = Session(env={
        "SF_TEST_PROVIDER_TOOL_CALL": "1",
        "SF_TEST_PROVIDER_TOOL_BYPASS": "true",
    })
    terminal = Terminal(session)
    try:
        session.send(b"request permission\r")
        for seconds in (120, 119, 118):
            terminal.wait_for(
                f"permission countdown at {seconds}s",
                lambda: f"2. [d]eny and continue ({seconds}s)" in terminal.frame(),
                timeout=3,
            )
        session.send(b"d")
        terminal.wait_for(
            "permission prompt to close",
            lambda: "Allow shell outside of sandbox?" not in terminal.frame(),
        )
    finally:
        session.close()


def test_permission_keys_do_not_edit():
    session = Session(env={
        "SF_TEST_PROVIDER_TOOL_CALL": "1",
        "SF_TEST_PROVIDER_TOOL_BYPASS": "true",
    })
    terminal = Terminal(session)
    try:
        session.send(b"permission history probe\r")
        terminal.wait_for(
            "permission prompt",
            lambda: "2. [d]eny and continue (119s)" in terminal.frame(),
        )
        session.send(
            b"xyz\x1b[A\x1bOA\x10\x0e\x1b[1;1A\x1b[1;1B\x1b[13;2u"
            b"\x1b[3;5~\x12\x19\x04\x1bx\x1b[200~a1s3\x1b[201~\r"
        )
        for seconds in (120, 119):
            terminal.wait_for(
                f"permission countdown after taking control ({seconds}s)",
                lambda: f"2. [d]eny and continue ({seconds}s)" in terminal.frame(),
            )
        frame = terminal.frame()
        assert "3. [s]top and discuss" in frame, terminal.dump()
        tail = frame.split("3. [s]top and discuss", 1)[1]
        assert not tail.split("─", 1)[0].strip(), terminal.dump()
        session.send(b"d")
        terminal.wait_for(
            "tool completion",
            lambda: "Tool complete." in terminal.everything(),
        )
        session.send(b"xyz")
        terminal.wait_for("editing restored", lambda: "❯ xyz" in terminal.frame())
        session.send(b"\x1b[A")
        terminal.wait_for(
            "history restored",
            lambda: "❯ permission history probe" in terminal.frame(),
        )
    finally:
        session.close()


def test_external_draft_and_pager():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        editor = root / "editor"
        editor.write_text(
            '#!/bin/sh\n'
            'cat "$1" >"$PROBE/original"\n'
            'touch "$PROBE/open"\n'
            'while [ ! -f "$PROBE/close" ]; do sleep 0.05; done\n'
            'cat "$PROBE/replacement" >"$1"\n'
            'exit "$(cat "$PROBE/result")"\n'
        )
        editor.chmod(0o755)
        pager = root / "pager"
        pager.write_text('#!/bin/sh\ncp "$1" "$PROBE/paged"\n')
        pager.chmod(0o755)
        (root / "result").write_text("0")
        (root / "replacement").write_text("edited\nmultiline\n")
        session = Session(env={"VISUAL": str(editor), "PAGER": str(pager),
                               "EDITOR": "/bin/false",
                               "PROBE": directory, "SF_TEST_PROVIDER_DELAY": "0.03"})
        terminal = Terminal(session)
        try:
            session.send((" ".join(WORDS) + "\r").encode())
            terminal.wait_for("streamed scrollback",
                              lambda: "w020" in terminal.scrollback())
            session.send(b"draft\x07")
            terminal.wait_for("editor", lambda: (root / "open").exists())
            before = terminal.everything()
            assert (root / "original").read_text() == "draft"
            # Nothing may draw while the editor owns the tty, so watch a fixed window.
            end = time.monotonic() + 0.5
            while time.monotonic() < end:
                terminal.pump()
            assert terminal.everything() == before, terminal.dump()
            (root / "close").touch()
            terminal.wait_for("edited draft", lambda: "❯ edited" in terminal.frame()
                              and "multiline" in terminal.frame())
            terminal.wait_for("turn finished", terminal.turn_finished)
            terminal.wait_for("queued rows", lambda: terminal.everything().count("w200") == 2)
            _, records = session.wait_session_records(3)
            assert len([r for r in records if r["type"] == "user"]) == 1
            for word in WORDS:
                assert terminal.everything().count(word) == 2, (word, terminal.dump())
            (root / "result").write_text("1")
            (root / "replacement").write_text("must not replace the draft")
            (root / "open").unlink()
            session.send(b"\x07")
            terminal.wait_for("failed editor opened", lambda: (root / "open").exists())
            terminal.wait_for("failed editor preserves draft",
                              lambda: "❯ edited" in terminal.frame()
                              and "must not replace" not in terminal.frame())
            assert (root / "original").read_text() == "edited\nmultiline\n"
            (root / "result").write_text("0")
            (root / "replacement").write_text("")
            (root / "open").unlink()
            session.send(b"\x07")
            terminal.wait_for("empty editor opened", lambda: (root / "open").exists())
            terminal.wait_for("empty draft", lambda: "❯ edited" not in terminal.frame())
            session.send(b"/verbose\r")
            terminal.wait_for("pager", lambda: (root / "paged").exists())
            assert all(word in (root / "paged").read_text() for word in WORDS)
            session.send(b"still here")
            terminal.wait_for("same chat", lambda: "❯ still here" in terminal.frame())
            for word in WORDS:
                assert terminal.everything().count(word) == 2, (word, terminal.dump())
        finally:
            session.close()


def test_idle_editor_fallback():
    with tempfile.TemporaryDirectory() as directory:
        editor = Path(directory) / "draft editor"
        editor.write_text('#!/bin/sh\n[ "$1" = --draft ] || exit 1\n'
                          'printf "idle replacement" >"$2"\n')
        editor.chmod(0o755)
        session = Session(env={"VISUAL": "", "EDITOR": f'"{editor}" --draft'})
        terminal = Terminal(session)
        try:
            session.wait_session_records(1)
            session.send(b"unsent\x07")
            terminal.wait_for("idle edited draft",
                              lambda: "❯ idle replacement" in terminal.frame())
            _, records = session.wait_session_records(1)
            assert not any(r["type"] == "user" for r in records)
            session.send(b"\x18")
            _, records = session.wait_session_records(3)
            user = next(r for r in records if r["type"] == "user")
            assert user["content"][0]["text"] == "idle replacement"
        finally:
            session.close()


if __name__ == "__main__":
    run("scrollback PTY scenarios", [
        test_help_notice_keeps_one_separator,
        test_user_and_agent_keep_one_separator,
        test_tall_resume_drains_bounded_backlog,
        test_tall_turn_loses_neither_text_nor_draft,
        test_queued_submits_keep_committed_history,
        test_file_changes_use_full_preview,
        test_permission_countdown,
        test_permission_keys_do_not_edit,
        test_external_draft_and_pager,
        test_idle_editor_fallback,
    ])
