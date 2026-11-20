#!/usr/bin/env python3
"""Transcript layout, scrollback, and clipping in a terminal emulator."""
import json
import os
import tempfile
import termios
import time
from collections import Counter
from pathlib import Path

from _session import ROWS, Session, run
from _terminal import Terminal

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
            terminal.wait_for("project notice and idle prompt",
                              lambda: "┆" in terminal.everything()
                              and terminal.turn_finished(r"provider/fake-model"))
            idle = [line.rstrip() for line in
                    terminal.screen.scrolled + terminal.screen.display]
            end = next(i for i, line in enumerate(idle) if "┆" in line)
            divider = next(i for i in range(end + 1, len(idle))
                           if idle[i].startswith("─"))
            assert idle[end + 1:divider] == [""], terminal.dump()

            session.send(b"/help\r")
            session.wait_session_records(3)
            terminal.wait_for("full help notice",
                              lambda: all(alias in terminal.everything()
                                          for alias in ("/quit, /q", "/refresh, /r")))
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
        terminal.wait_for("settled agent reply",
                          lambda: "─ agent " in terminal.everything()
                          and terminal.turn_finished())
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


if __name__ == "__main__":
    run("scrollback PTY scenarios", [
        test_help_notice_keeps_one_separator,
        test_user_and_agent_keep_one_separator,
        test_tall_resume_drains_bounded_backlog,
        test_tall_turn_loses_neither_text_nor_draft,
        test_queued_submits_keep_committed_history,
        test_file_changes_use_full_preview,
    ])
