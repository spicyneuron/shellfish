#!/usr/bin/env python3
"""Draft editing and command completion in a real PTY."""
import re

from _session import COLUMNS, ROWS, Session, run


ECHO_HOOK = r"""#!/usr/bin/env zsh
(( $# == 0 )) || exit 1
cat >"${SHELLFISH_SESSION:h}/submitted"
print -u2 accepted
print -r -u3 -- '{"action":"deny"}'
"""


def test_slash_command_completion():
    session = Session(commands=["help", "fork", "rewind"], hooks={"echo": ECHO_HOOK})
    try:
        path, _ = session.wait_session_records(1)
        submitted = path.parent / "submitted"
        session.wait("provider/fake-model")
        mark = len(session.output)
        session.send(b"/qu\t")
        session.wait_screen(mark, "─ completions ")
        if session.screen() is not None:
            session.wait_screen(mark, "  /queue", "  /quit", "provider/fake-model")
            lines = [line.strip() for line in session.screen().splitlines()]
            assert lines.index("/queue") < lines.index("/quit")
        for key in (b"\x1b", b"\x02", b"X"):
            mark = len(session.output)
            session.send(key)
            if session.screen() is not None:
                session.wait_for(lambda: "─ completions " not in session.screen(),
                                 "completion drawer closing")
            session.send(b"\x15/qu\t")
            session.wait_screen(mark, "─ completions ")
        session.send(b"\x15")
        mark = len(session.output)
        session.send(b"/\t")
        session.wait_screen(mark, "─ completions (")
        if session.screen() is not None:
            session.wait_screen(mark, "/fork", "/help", "provider/fake-model")
        for rows in (ROWS + 4, ROWS):
            mark = len(session.output)
            session.resize(rows, COLUMNS)
            session.wait_after(mark, "─ completions (")
        mark = len(session.output)
        session.send(b"\t")
        if session.screen() is not None:
            session.wait_screen(mark, "─ completions (1/", "▸ /fork", "❯ /fork")
        else:
            session.wait_after(mark, "▸ /fork")
        mark = len(session.output)
        session.send(b"\x1b[Z\x1b[Z")
        if session.screen() is not None:
            session.wait_screen(mark, "▸ /rewind", "❯ /rewind")
        else:
            session.wait_after(mark, "rewind")
        session.send(b"\x15")
        (session.project_dir / "notes.md").write_text("")
        mark = len(session.output)
        session.send(b"Read @no\tX\r")
        session.wait_after(mark, "accepted")
        assert submitted.read_text() == "Read @notes.mdX"
        session.wait_ready(mark)
        session.send(b"/hel\t\r")
        session.wait("Help:")
        _, records = session.wait_session_records(2)
        assert not any(record["type"] == "user" for record in records), records
    finally:
        session.close()


def test_completion_drawer_during_streaming():
    session = Session(explicit_session=True,
                      env={"SF_TEST_PROVIDER_RELEASE": "release-provider"})
    try:
        prompt = "stream0 stream1 stream2"
        mark = len(session.output)
        session.send(prompt.encode() + b"\r")
        session.wait_session_records(2, path=session.explicit_session)
        session.wait_after(mark, "stream0")
        session.send(b"queued\r/qu\t")
        session.wait_screen(mark, "─ queue ", "─ completions ")
        if session.screen() is not None:
            session.wait_screen(mark, "1. queued", "/queue", "/quit", "provider/fake-model")
        (session.project_dir / "release-provider").touch()
        session.wait_session_records(5, timeout=8, path=session.explicit_session)
        if session.screen() is not None:
            def only_completion_drawer():
                screen = session.screen()
                return ("─ queue " not in screen and "─ completions " in screen
                        and "❯ /qu" in screen)

            session.wait_for(only_completion_drawer, "completion drawer after queue drains")
        session.send(b"X\r")
        _, records = session.wait_session_records(6, path=session.explicit_session)
        assert records[5]["content"][0]["text"] == "/quX"
    finally:
        session.close()


def test_zle_multiline_editing():
    session = Session(hooks={"echo": ECHO_HOOK})
    try:
        session.wait("─" * 13)
        mark = len(session.output)
        session.send(
            b"abcdefghij\x1b[13;2uabc\x1b[13;2u0123456789"
            b"\x1b[1;1A\x1b[1;1AX\x1b[1;1B\x1b[1;1BY\r"
        )
        path, _ = session.wait_session_records(1)
        submitted = path.parent / "submitted"
        expected = "abcdefghXij\nabc\n0123456789Y"
        session.wait_after(mark, "accepted")
        assert submitted.read_text() == expected
        session.send(b"draftX")
        session.wait_after(mark, "draftX", view=session.typed)
    finally:
        session.close()


def test_zle_wrapped_line_navigation():
    session = Session(hooks={"echo": ECHO_HOOK})
    try:
        draft = "0123456789" * 7
        mark = len(session.output)
        session.send(draft.encode() + b"\x1b[AX\r")
        path, _ = session.wait_session_records(1)
        submitted = path.parent / "submitted"
        expected = draft[:20] + "X" + draft[20:]
        session.wait_after(mark, "accepted")
        assert submitted.read_text() == expected
    finally:
        session.close()


def test_streaming_input_sequences_remain_atomic():
    prompt = " ".join(f"stream{i}" for i in range(12))
    session = Session(
        explicit_session=True,
        env={"SF_TEST_PROVIDER_DELAY": "0.04"},
    )
    try:
        mark = len(session.output)
        session.send(prompt.encode() + b"\r")
        session.wait_session_records(2, path=session.explicit_session)
        session.wait_after(mark, "stream0")

        sequence = b"\x1b[A\x1b[B\x1b[C\x1b[D\x1b[3;5~"
        for index in range(3):
            session.send(b"draft" + str(index).encode() + sequence)
            session.pump(0.04)

        session.wait_session_records(3, timeout=5, path=session.explicit_session)
        session.send(b"X\r")
        _, records = session.wait_session_records(
            4, timeout=5, path=session.explicit_session
        )
        draft = records[-1]["content"][0]["text"]
        assert draft == "draft" * 3 + "X", draft
        output = session.visible(mark)
        assert "Rendering failed" not in output, output
        assert not re.search(r"\[\d+\].*(?:done|terminated)", output, re.I), output
    finally:
        session.close()


if __name__ == "__main__":
    run("editor PTY scenarios", [
        test_slash_command_completion,
        test_completion_drawer_during_streaming,
        test_zle_multiline_editing,
        test_zle_wrapped_line_navigation,
        test_streaming_input_sequences_remain_atomic,
    ])
