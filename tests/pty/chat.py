#!/usr/bin/env python3
"""Chat UI scenarios in a real pty: startup records, tools, editing, shutdown.

`user_prompt_submit` script scenarios live in hooks.py; the Session harness in _session.py.
"""
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
from _session import APP, COLUMNS, ROWS, Session  # noqa: E402


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


def test_sandbox_auto_runs_once():
    with tempfile.TemporaryDirectory() as detector_dir:
        count = Path(detector_dir) / "git-count"
        git = Path(detector_dir) / "git"
        git.write_text(
            '#!/bin/sh\n'
            '[ "$1 $2" != "var GIT_CONFIG_GLOBAL" ] || '
            'echo x >>"$SF_TEST_GIT_COUNT"\n'
            'exit 1\n'
        )
        git.chmod(0o755)
        env = {
            "PATH": f"{detector_dir}:{os.environ['PATH']}",
            "SF_TEST_GIT_COUNT": str(count),
        }
        session = Session(args=["--sandbox-auto"], env=env)
        try:
            assert count.read_text().splitlines() == ["x"]
        finally:
            session.close()


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
            records = [json.loads(line) for line in path.read_text().splitlines()]
            grant_path = str(Path(grant).resolve())
            assert grant_path in records[0]["harness"]["sandbox_write_paths"]
            assert records[1:] == [{
                "type": "context",
                "hook": "user_prompt_submit",
                "script": "sandbox",
                "content": f"Session sandbox write grant added: {grant_path}\n",
            }]
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
        # A draft typed after the turn proves the editor is still live. This is
        # keystroke echo rather than rendered output, so it needs that view.
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


def test_startup_records_precede_two_turns():
    session = Session(
        explicit_session=True,
        args=["--model", "override-model"],
        session_start=["project_environment"],
        system="startup system prompt",
    )
    try:
        path, records = session.wait_session_records(3, path=session.explicit_session)
        assert records[0]["type"] == "session"
        assert records[1] == {"type": "system", "content": "startup system prompt"}
        assert records[2]["type"] == "context"
        assert records[2]["hook"] == "session_start"
        assert records[2]["script"] == "project_environment"
        banner = (
            "Project:",
            "Tools: read_file, write_file, edit_file, shell",
            "test/override-model",
        )
        for token in banner:
            session.wait_after(0, token)
        transcript = ("startup system prompt", "project_environment · session_start")
        for token in transcript:
            session.wait_after(0, token)
        visible = session.visible()
        assert visible.index(transcript[0]) < visible.index(transcript[1]), visible

        mark = len(session.output)
        session.send(b"one\r")
        _, records = session.wait_session_records(5, path=path)
        end = time.monotonic() + 3
        while (
            not re.search(r" · [\d.]+[km]? ↑", session.visible(mark))
            and time.monotonic() < end
        ):
            session.pump()
        assert re.search(r" · [\d.]+[km]? ↑", session.visible(mark))
        draft_mark = len(session.output)
        session.send(b"two")
        session.wait_after(draft_mark, "two", view=session.typed)
        session.send(b"\r")
        _, records = session.wait_session_records(7, path=path)
        assert [(record.get("role"), record.get("stop")) for record in records[3:]] == [
            ("user", None), ("assistant", "end"),
            ("user", None), ("assistant", "end"),
        ]
        assert "Exec exited unexpectedly" not in session.visible()
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

        # Keep ordinary input adjacent to the interrupt. The heartbeat prefix
        # must forward both rather than consume either sequence.
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
        _, records = session.wait_session_records(3, path=path)
        recovered = records[-1]
        assert recovered["role"] == "assistant" and recovered["stop"] == "length"
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

        _, records = session.wait_session_records(5, path=session.explicit_session)
        session.wait_after(mark, "Tool complete.")
        edit = len(session.output)
        session.send(b"X\x0c")
        session.wait_after(edit, draft + "X", view=session.typed)

        results = [record for record in records if record.get("role") == "tool_result"]
        assert len(results) == 1
        assert results[0]["exit_code"] == 126
        assert results[0]["content"] == "sandbox bypass denied"
        users = [record for record in records if record.get("role") == "user"]
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
            record for record in records if record.get("role") == "tool_result"
        ]
        assert [(record["call_id"], record["exit_code"]) for record in results] == [
            ("call_1", 126),
            ("call_2", 126),
            ("call_3", 126),
        ]
        assert records[-1]["role"] == "assistant" and records[-1]["stop"] == "end"
        session.wait_after(mark, "Cancelled.")
    finally:
        session.close()


def test_repeated_permission_ctrl_c_exits_after_recovery():
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
        session.send(b"cancel and exit\r")
        session.wait_after(mark, "Allow shell outside of sandbox?")
        session.send(b"\x03")
        session.wait_session_records(7, path=session.explicit_session)
        session.send(b"\x03")
        session.wait_after(mark, "Saved:")
        records = [
            json.loads(line)
            for line in session.explicit_session.read_text().splitlines()
        ]
        results = [
            record for record in records if record.get("role") == "tool_result"
        ]
        assert [record["call_id"] for record in results] == [
            "call_1",
            "call_2",
            "call_3",
        ]
        assert records[-1]["role"] == "assistant" and records[-1]["stop"] == "end"
    finally:
        session.close()


def test_tool_result_preview_reports_total_tokens():
    """Configured previews hide later rows and report whole-node tokens."""
    fixture = Path(__file__).resolve().parents[1] / "fixtures/session/tool-paired.jsonl"
    header = json.loads(fixture.read_text().splitlines()[0])
    rows = [f"preview row {index:02d}" for index in range(1, 7)]
    records = [
        header,
        {"type": "message", "role": "user", "content": [
            {"type": "text", "text": "preview tool result"},
        ]},
        {"type": "message", "role": "assistant", "stop": "tool_calls",
         "content": [{"type": "tool_call", "id": "call_1", "name": "read_file",
                      "input": {"file_path": "README.md"}}],
         "usage": {"input_tokens": 1, "output_tokens": 1}},
        {"type": "message", "role": "tool_result", "call_id": "call_1",
         "name": "read_file", "content": "\n".join(rows), "exit_code": 0},
    ]
    session = Session(explicit_session=True, session_records=records)
    try:
        session.wait_after(0, rows[1])
        visible = session.visible()
        assert rows[0] in visible and rows[1] in visible, visible
        assert not any(row in visible for row in rows[2:]), (
            "lean tool preview rendered beyond its two-row budget\n" + visible
        )
        assert re.search(r"\b\d+ tokens?\b", visible), (
            "lean tool preview did not report whole-node tokens\n" + visible
        )
    finally:
        session.close()


def test_chat_end():
    for submitted, exit_status in ((b"/quit\r", 0), (b"\x03", 130)):
        session = Session()
        try:
            path, _ = session.wait_session_records(1)
            mark = len(session.output)
            session.send(submitted)
            session.wait_after(mark, str(path))
            visible = session.visible(mark)
            assert "Saved:" in visible, visible
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
        # Emacs Ctrl-O accepts the editor buffer without setting a chat action.
        session.send(b"\x0f")
        session.wait_after(mark, "Chat editor exited unexpectedly", timeout=3)
        visible = session.visible(mark)
        assert "state working" in visible, visible
        assert "Saved:" not in visible, visible
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
        {"type": "message", "role": "user", "content": [
            {"type": "text", "text": "seed"},
        ]},
        {"type": "message", "role": "assistant", "stop": "end",
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


def main():
    test_sandbox_auto_runs_once()
    test_sandbox_updates_without_reload()
    test_startup_records_precede_two_turns()
    test_tool_uses_manifest_display()
    test_activity_input_does_not_delay_interrupt()
    test_interrupt_drains_partial_recovery()
    test_permission_decision_restores_draft()
    test_permission_ctrl_c_cancels_pending_tools()
    test_repeated_permission_ctrl_c_exits_after_recovery()
    test_tool_result_preview_reports_total_tokens()
    test_chat_end()
    test_actionless_editor_return_is_not_a_clean_exit()
    test_zle_multiline_editing()
    test_zle_wrapped_line_navigation()
    test_streaming_input_sequences_remain_atomic()
    test_sigterm_leaves_terminal_state()
    print("PASS terminal PTY scenarios")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise
