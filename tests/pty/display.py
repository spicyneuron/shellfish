#!/usr/bin/env python3
"""Input routing and external editors in a terminal emulator."""
import re
import tempfile
from pathlib import Path

from _session import Session, run
from _terminal import Terminal


def test_permission_keys_do_not_edit():
    session = Session(env={
        "SF_TEST_PROVIDER_TOOL_CALL": "1",
        "SF_TEST_PROVIDER_TOOL_BYPASS": "true",
    })
    terminal = Terminal(session)
    try:
        def countdown():
            found = re.search(r"\[d\]eny and continue \((\d+)s\)", terminal.frame())
            return int(found[1]) if found else None

        session.send(b"permission history probe\r")
        terminal.wait_for("permission countdown", lambda: countdown() is not None)
        initial = countdown()
        terminal.wait_for("countdown advancing",
                          lambda: countdown() is not None and countdown() < initial)
        remaining = countdown()
        session.send(
            b"xyz\x1b[A\x1bOA\x10\x0e\x1b[1;1A\x1b[1;1B\x1b[13;2u"
            b"\x1b[3;5~\x12\x19\x04\x1bx\x1b[200~a1s3\x1b[201~\r"
        )
        terminal.wait_for("countdown reset after taking control",
                          lambda: countdown() is not None and countdown() > remaining)
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
                               "PROBE": directory, "SF_TEST_PROVIDER_DELAY": "0",
                               "SF_TEST_PROVIDER_RELEASE": "release-provider"})
        terminal = Terminal(session)
        words = [f"w{index:03d}" for index in range(1, 49)]
        try:
            session.send((" ".join(words) + "\r").encode())
            terminal.wait_for("streaming turn",
                              lambda: "─ agent ─" in terminal.everything())
            session.send(b"draft\x07")
            terminal.wait_for("editor", lambda: (root / "open").exists())
            before = terminal.everything()
            assert (root / "original").read_text() == "draft"
            # Finish the turn while the editor owns the tty.
            (session.project_dir / "release-provider").touch()
            _, records = session.wait_session_records(3)
            assert [r["type"] for r in records] == ["session", "user", "assistant"]
            terminal.pump(0)
            assert terminal.everything() == before, terminal.dump()
            (root / "close").touch()
            terminal.wait_for("edited draft", lambda: "❯ edited" in terminal.frame()
                              and "multiline" in terminal.frame())
            terminal.wait_for("turn finished", terminal.turn_finished)
            terminal.wait_for("queued rows", lambda: terminal.everything().count(words[-1]) == 2)
            for word in words:
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
            terminal.wait_for("empty draft",
                              lambda: "❯ " in terminal.frame() and "edited" not in terminal.frame())
            session.send(b"/verbose\r")
            paged = root / "paged"
            terminal.wait_for("complete pager output",
                              lambda: paged.exists() and words[-1] in paged.read_text())
            assert all(word in paged.read_text() for word in words)
            session.send(b"still here")
            terminal.wait_for("same chat", lambda: "❯ still here" in terminal.frame())
            for word in words:
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
            # The header can reach disk before chat stops its startup activity.
            terminal.wait_for("idle startup prompt",
                              lambda: terminal.turn_finished(r"provider/fake-model"))
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
    run("interactive display PTY scenarios", [
        test_permission_keys_do_not_edit,
        test_external_draft_and_pager,
        test_idle_editor_fallback,
    ])
