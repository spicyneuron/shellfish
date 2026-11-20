#!/usr/bin/env python3
"""Terminal setup, resume, and teardown in a real PTY."""
import fcntl
import json
import os
import pty
import re
import select
import shlex
import shutil
import signal
import subprocess
import struct
import tempfile
import termios
import time
from pathlib import Path

from _session import APP, COLUMNS, ROWS, THEME, Session, assert_terminal_restored, run


def test_piped_prompt_is_submitted():
    session = Session(stdin="piped prompt\n")
    try:
        _, records = session.wait_session_records(3)
        users = [record for record in records if record["type"] == "user"]
        assert users and users[0]["content"][0]["text"] == "piped prompt", records
    finally:
        session.close()


def test_chat_end():
    for submitted, exit_status in ((b"/quit\r", 0), (b"\x03", 130)):
        session = Session()
        try:
            path, _ = session.wait_session_records(1)
            session.wait("provider/fake-model")
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


def hold_projection(directory):
    directory = Path(directory)
    release = directory / "release"
    wrapper = directory / "jq"
    wrapper.write_text(
        '#!/bin/sh\n'
        'case "$*" in *libexec/tui/project.jq*)\n'
        f'  while [ ! -e {shlex.quote(str(release))} ]; do sleep 0.02; done;;\n'
        'esac\n'
        f'exec {shlex.quote(shutil.which("jq"))} "$@"\n'
    )
    wrapper.chmod(0o755)
    return release, str(directory) + ":" + os.environ["PATH"]


def test_resume_loading():
    fixture = Path(__file__).resolve().parents[1] / "fixtures/session/complete.jsonl"
    records = [json.loads(line) for line in fixture.read_text().splitlines()]
    with tempfile.TemporaryDirectory() as directory:
        release, path = hold_projection(directory)
        session = None
        try:
            session = Session(explicit_session=True, session_records=records,
                              env={"PATH": path}, startup_token="Loading session…")
            session.wait("⠃ Loading session…")
            session.wait("⠆ Loading session…")
            session.wait_for(lambda: session.output.count("Loading session…".encode()) >= 3,
                             "a third loading frame")
            mark = len(session.output)
            release.touch()
            session.wait_after(mark, "test/fake-model")
            output = bytes(session.output).decode("utf-8", "replace")
            assert output.index("Session:") < output.index("Loading session…")
            assert "\r\x1b[2K" in output[output.rfind("Loading session…"):]
            assert "Loading session…" not in (session.screen() or "")
            assert [json.loads(line) for line in session.explicit_session.read_text().splitlines()] == records
        finally:
            release.touch()
            if session is not None:
                session.close()


def test_sigterm_leaves_terminal_state(loading=False):
    master, slave = pty.openpty()
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLUMNS, 0, 0))
    before = termios.tcgetattr(slave)
    config_dir = tempfile.TemporaryDirectory()
    # Resuming reads the profile from the session header, so only rendering
    # needs a fixture; a stable theme avoids a terminal background probe.
    shellfish_dir = Path(config_dir.name) / "shellfish"
    shellfish_dir.mkdir(parents=True)
    (shellfish_dir / "tui.jsonc").write_text(
        json.dumps({
            "theme_mode": "dark",
            "theme_light": "theme",
            "theme_dark": "theme",
            "themes": {"theme": THEME},
        })
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
    env["SHELLFISH_DIR"] = str(shellfish_dir)
    env["HOME"] = config_dir.name
    if loading:
        release, env["PATH"] = hold_projection(config_dir.name)
    process = subprocess.Popen(
        [APP, "--session", str(session_file)],
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
            if loading and output.count(b"Loading session") >= 2:
                break
            if not loading and output.count(b"\x1b[?2026h") > output.count(b"\x1b[?2026l"):
                break
        if loading:
            assert output.count(b"Loading session") >= 2
        else:
            assert output.count(b"\x1b[?2026h") > output.count(b"\x1b[?2026l"), (
                "chat never entered synchronized output"
            )
        all_output = output

        process.send_signal(signal.SIGTERM)
        if loading:
            release.touch()
        end = time.monotonic() + 1
        while process.poll() is None and time.monotonic() < end:
            if select.select([master], [], [], 0.02)[0]:
                try:
                    all_output += os.read(master, 65536)
                except OSError:
                    pass
        assert process.poll() == 143, (process.poll(), all_output[-1500:])
        # Process exit can be observed before its final terminal bytes are read.
        while select.select([master], [], [], 0)[0]:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            all_output += chunk
        assert_terminal_restored(slave, before)
        sync = re.findall(rb"\x1b\[\?2026([hl])", all_output)
        assert (loading or b"h" in sync) and sync[-1:] != [b"h"], (
            f"synchronized output still enabled at exit: {sync}"
        )
        if loading:
            assert all_output.endswith(b"\r\x1b[2K"), all_output
    finally:
        if loading:
            release.touch()
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)
        config_dir.cleanup()


def test_sigterm_during_resume():
    test_sigterm_leaves_terminal_state(loading=True)


if __name__ == "__main__":
    run("terminal PTY scenarios", [
        test_resume_loading,
        test_sigterm_during_resume,
        test_piped_prompt_is_submitted,
        test_chat_end,
        test_sigterm_leaves_terminal_state,
    ])
