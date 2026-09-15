#!/usr/bin/env python3
"""Chat UI scenarios in a real pty."""
import fcntl
import json
import os
import pty
import re
import select
import signal
import subprocess
import struct
import sys
import tempfile
import termios
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _session import APP, COLUMNS, ROWS, Session, run  # noqa: E402


ECHO_HOOK = r"""#!/usr/bin/env zsh
[[ $1 == user_prompt_submit ]] || exit 1
cat >"${SHELLFISH_SESSION:h}/submitted"
print -u2 accepted
exit 10
"""

HOLD_PERMISSION_HOOK = r"""#!/usr/bin/env zsh
[[ $1 == user_prompt_submit ]] || exit 1
: >"${SHELLFISH_SESSION:h}/permission-ready"
while [[ ! -e ${SHELLFISH_SESSION:h}/permission-release ]]; do sleep 0.02; done
"""


def test_sandbox_updates_without_reload():
    with tempfile.TemporaryDirectory() as grant:
        session = Session(hooks={"sandbox": None})
        try:
            path, _ = session.wait_session_records(1)
            mark = len(session.output)
            session.send(f"/sandbox +w {grant}\r".encode())
            session.wait_after(mark, "Session sandbox write grant added", timeout=5)
            session.wait_ready(mark, timeout=5)
            assert "Project:" not in session.visible(mark)
            grant_path = str(Path(grant).resolve())
            end = time.monotonic() + 3
            while time.monotonic() < end:
                records = [json.loads(line) for line in path.read_text().splitlines()]
                if grant_path in records[0]["harness"]["sandbox_write_paths"]:
                    break
                session.pump()
            assert grant_path in records[0]["harness"]["sandbox_write_paths"]
            granted = f"Session sandbox write grant added: {grant_path}\n"
            assert len(records) == 2
            result = records[1]
            assert result.pop("id")
            assert result == {
                "type": "hook_result",
                "lifecycle": "user_prompt_submit",
                "name": "sandbox",
                "executable": records[0]["harness"]["user_prompt_submit"][0]["command"],
                "input": f"/sandbox +w {grant}",
                "user_text": granted,
                "model_text": granted,
                "exit_code": 11,
            }
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
        end = time.monotonic() + 3
        while (
            (not submitted.exists() or submitted.read_text() != expected)
            and time.monotonic() < end
        ):
            session.pump()
        assert submitted.read_text() == expected
        end = time.monotonic() + 3
        while "accepted" not in session.visible(mark) and time.monotonic() < end:
            session.pump()
        assert "accepted" in session.visible(mark)
        session.send(b"draftX")
        session.wait_after(mark, "draftX", view=session.typed)
    finally:
        session.close()


def test_zle_wrapped_line_navigation():
    session = Session(hooks={"echo": ECHO_HOOK})
    try:
        draft = "0123456789" * 7
        session.send(draft.encode() + b"\x1b[AX\r")
        path, _ = session.wait_session_records(1)
        submitted = path.parent / "submitted"
        expected = draft[:20] + "X" + draft[20:]
        end = time.monotonic() + 3
        while (
            (not submitted.exists() or submitted.read_text() != expected)
            and time.monotonic() < end
        ):
            session.pump()
        assert submitted.read_text() == expected
    finally:
        session.close()


def test_streaming_input_sequences_remain_atomic():
    prompt = " ".join(f"stream{i}" for i in range(12))
    session = Session(
        explicit_session=True,
        env={"SF_TEST_BACKEND_DELAY": "0.04"},
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


def test_tool_uses_manifest_display():
    session = Session()
    try:
        mark = len(session.output)
        session.send(b"tool\r")
        session.wait_after(mark, "│ for")
        visible = session.visible(mark)
        assert "⛭ shell" in visible and "│ for" in visible, visible
        assert 'shell {"command":' not in visible, visible
    finally:
        session.close()


def test_activity_input_does_not_delay_interrupt():
    session = Session(
        explicit_session=True,
        env={"SF_TEST_BACKEND_DELAY_MATCH_SECONDS": "2"},
    )
    try:
        mark = len(session.output)
        session.send(b"delay response\r")
        session.wait_session_records(2, path=session.explicit_session)

        # The heartbeat must forward adjacent input and interrupt bytes.
        session.send(b"draft\x03")
        session.wait_after(mark, "Cancelled.", timeout=1.5)
        edit = len(session.output)
        session.send(b"X\x0c")
        session.wait_after(edit, "draftX", view=session.typed)
    finally:
        session.close()


def test_interrupt_drains_partial_recovery():
    session = Session(
        explicit_session=True,
        env={"SF_TEST_BACKEND_DELAY": "0.04"},
    )
    try:
        prompt = "think " + " ".join(f"stream{i:02}" for i in range(40))
        mark = len(session.output)
        session.send((prompt + "\r").encode())
        path, _ = session.wait_session_records(2, path=session.explicit_session)
        session.wait_after(mark, "Thinking…")

        mark = len(session.output)
        session.send(b"\x03")
        session.wait_after(mark, "Cancelled.", timeout=2)
        _, records = session.wait_session_records(4, path=path)
        assert records[-1] == {"type": "error", "user_text": "Cancelled."}
        recovered = records[-2]
        assert recovered["type"] == "assistant" and recovered["stop"] == "cancelled"
        assert any(
            item["type"] == "reasoning" and item["text"]
            for item in recovered["content"]
        )
    finally:
        session.close()


def test_permission_decision_restores_draft():
    session = Session(
        explicit_session=True,
        hooks={"hold_permission": HOLD_PERMISSION_HOOK},
        env={
            "SF_TEST_BACKEND_TOOL_CALL": "1",
            "SF_TEST_BACKEND_TOOL_BYPASS": "true",
        },
    )
    directory = session.explicit_session.parent
    ready = directory / "permission-ready"
    release = directory / "permission-release"
    try:
        prompt = "deny permission"
        draft = "draft after denial"
        mark = len(session.output)
        session.send(prompt.encode() + b"\r")
        end = time.monotonic() + 3
        while not ready.exists() and time.monotonic() < end:
            session.pump()
        assert ready.exists(), session.visible(mark)
        draft_mark = len(session.output)
        session.send(draft.encode() + b"\x0c")
        session.wait_after(draft_mark, draft, view=session.typed)
        release.touch()
        session.wait_after(mark, "Allow shell outside of sandbox?")
        session.send(b"d")

        # The silent prompt hook records nothing before the turn.
        _, records = session.wait_session_records(5, path=session.explicit_session)
        session.wait_after(mark, "Tool complete.")
        edit = len(session.output)
        session.send(b"X\x0c")
        session.wait_after(edit, draft + "X", view=session.typed)

        results = [record for record in records if record.get("type") == "tool_result"]
        assert len(results) == 1
        assert results[0]["exit_code"] == 126
        assert results[0]["model_text"] == "sandbox bypass denied\nexit 126"
        users = [record for record in records if record.get("type") == "user"]
        assert len(users) == 1
        assert users[0]["content"] == [{"type": "text", "text": prompt}]
        assert draft not in session.explicit_session.read_text()
    finally:
        release.touch()
        session.close()


def test_permission_ctrl_c_cancels_pending_tools():
    session = Session(
        explicit_session=True,
        env={
            "SF_TEST_BACKEND_TOOL_CALL": "1",
            "SF_TEST_BACKEND_TOOL_BYPASS": "true",
            "SF_TEST_BACKEND_TOOL_COUNT": "3",
        },
    )
    try:
        mark = len(session.output)
        session.send(b"cancel tools\r")
        session.wait_after(mark, "Allow shell outside of sandbox?")
        session.send(b"\x03")
        _, records = session.wait_session_records(7, path=session.explicit_session)
        results = [
            record for record in records if record.get("type") == "tool_result"
        ]
        assert [(record["id"], record["exit_code"]) for record in results] == [
            ("call_1", 126),
            ("call_2", 126),
            ("call_3", 126),
        ]
        assert records[-1] == {"type": "error", "user_text": "Cancelled."}
        session.wait_after(mark, "Cancelled.")
    finally:
        session.close()


def test_chat_end():
    for submitted, exit_status in ((b"/quit\r", 0), (b"\x03", 130)):
        session = Session()
        try:
            path, _ = session.wait_session_records(1)
            session.settle()
            mark = len(session.output)
            session.send(submitted)
            session.wait_after(mark, str(path))
            visible = session.visible(mark)
            assert "Resume with:" in visible, visible
            assert "❯" not in visible
            assert re.search(r"─{13,}", visible), visible
            end = time.monotonic() + 3
            result = None
            while result is None and time.monotonic() < end:
                result = os.waitid(
                    os.P_PID, session.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT
                )
                session.pump()
            assert result is not None and result.si_status == exit_status
        finally:
            session.close()


def test_actionless_editor_return_is_not_a_clean_exit():
    session = Session(env={"SF_TEST_BACKEND_DELAY_MATCH_SECONDS": "2"})
    try:
        session.send(b"delay response\r")
        session.wait_session_records(2)
        mark = len(session.output)
        # Ctrl-O returns without setting a chat action.
        session.send(b"\x0f")
        session.wait_after(mark, "Chat editor exited unexpectedly", timeout=3)
        visible = session.visible(mark)
        assert "state working" in visible, visible
        assert "Resume with:" not in visible, visible
        end = time.monotonic() + 3
        result = None
        while result is None and time.monotonic() < end:
            result = os.waitid(
                os.P_PID, session.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT
            )
            session.pump()
        assert result is not None and result.si_status == 1
    finally:
        session.close()


def test_sigterm_leaves_terminal_state():
    master, slave = pty.openpty()
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLUMNS, 0, 0))
    before = termios.tcgetattr(slave)
    config_dir = tempfile.TemporaryDirectory()
    config = Path(config_dir.name) / "shellfish.jsonc"
    config.write_text(
        json.dumps(
            {
                "default_profile": "development",
                "profiles": {
                    "development": {
                        "backend": "openai",
                        "request": {"model": "fake-model"},
                    }
                },
            }
        )
    )
    fixture = Path(__file__).resolve().parents[1] / "fixtures/session/complete.jsonl"
    header = json.loads(fixture.read_text().splitlines()[0])
    session_file = Path(config_dir.name) / "tall.jsonl"
    records = [
        header,
        {"type": "user", "content": [
            {"type": "text", "text": "seed"},
        ]},
        {"type": "assistant", "stop": "end",
         "content": [{"type": "text", "text": "\n".join(
             f"line-{index:04d}" for index in range(1, 501)
         )}], "usage": {"input_tokens": 1, "output_tokens": 500}},
    ]
    session_file.write_text("".join(json.dumps(record) + "\n" for record in records))
    env = os.environ.copy()
    env.pop("NO_COLOR", None)
    env["TERM"] = "xterm-256color"
    env["XDG_STATE_HOME"] = config_dir.name
    process = subprocess.Popen(
        [APP, "--config", str(config), "--session", str(session_file)],
        stdin=slave, stdout=slave, stderr=slave, env=env,
        close_fds=True, start_new_session=True,
    )
    try:
        output = b""
        end = time.monotonic() + 3
        while time.monotonic() < end:
            ready, _, _ = select.select([master], [], [], 0.05)
            if ready:
                output += os.read(master, 65536)
            if output.count(b"\x1b[?2026h") > output.count(b"\x1b[?2026l"):
                break
        assert output.count(b"\x1b[?2026h") > output.count(b"\x1b[?2026l"), (
            "chat never entered synchronized output"
        )
        all_output = output

        assert not termios.tcgetattr(slave)[3] & termios.ICANON

        process.send_signal(signal.SIGTERM)
        end = time.monotonic() + 1
        while process.poll() is None and time.monotonic() < end:
            if select.select([master], [], [], 0.02)[0]:
                try:
                    all_output += os.read(master, 65536)
                except OSError:
                    pass
        assert process.poll() == 143
        assert before[6][termios.VINTR] == termios.tcgetattr(slave)[6][termios.VINTR]
        sync_starts = all_output.count(b"\x1b[?2026h")
        sync_ends = all_output.count(b"\x1b[?2026l")
        assert sync_starts > 0 and sync_starts == sync_ends, (
            f"unbalanced synchronized output: {sync_starts} starts, {sync_ends} ends"
        )
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)
        config_dir.cleanup()


if __name__ == "__main__":
    run("terminal PTY scenarios", [
        test_sandbox_updates_without_reload,
        test_tool_uses_manifest_display,
        test_activity_input_does_not_delay_interrupt,
        test_interrupt_drains_partial_recovery,
        test_permission_decision_restores_draft,
        test_permission_ctrl_c_cancels_pending_tools,
        test_chat_end,
        test_actionless_editor_return_is_not_a_clean_exit,
        test_zle_multiline_editing,
        test_zle_wrapped_line_navigation,
        test_streaming_input_sequences_remain_atomic,
        test_sigterm_leaves_terminal_state,
    ])
