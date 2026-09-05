"""Shared pty harness. Imported by the scenario files, never run.

Starts the app under a real pty, since the chat UI disables wrapping
and scrollback flushing when stty reports no window size.
"""
import fcntl
import json
import os
import pty
import re
import select
import signal
import struct
import tempfile
import termios
import time
from pathlib import Path

ROWS, COLUMNS = 18, 50

ROOT = Path(__file__).resolve().parent.parent.parent
APP = str(ROOT / "bin" / "shellfish")
TEST_BACKEND = str(ROOT / "tests" / "fixtures" / "backend")
CSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")
OSC = re.compile(rb"\x1b\].*?(?:\x07|\x1b\\)", re.S)

# Distinct colours per surface so a probe can tell a styled heading from an
# unstyled one, and from the markdown around it. Without a theme the app leaves
# every style empty and the whole highlighting path goes untested.
THEME = {
    "muted": "#8b949e", "divider": "#8b949e",
    "footer": "#8b949e", "prompt": "#8b949e",
    "system_heading": "#d2a8ff", "context": "#8b949e",
    "user_heading": "#58a6ff", "agent_heading": "#ffb77a",
    "tool": "#8b949e", "reasoning": "#8b949e",
    "error": "#ff7b72",
    "diff_added": "#7ee787", "diff_added_background": "#12261e",
    "diff_removed": "#ffa198", "diff_removed_background": "#2d1519",
    "permission": "#58a6ff",
}


class Session:
    def __init__(self, explicit_session=False, hooks=None, env=None, args=None,
                 session_start=None, system=None, session_records=None,
                 sandbox=True):
        env_overrides = env or {}
        self.state_home = tempfile.TemporaryDirectory()
        self.project_home = tempfile.TemporaryDirectory(prefix="shellfish-pty.")
        self.project_dir = Path(self.project_home.name)
        self.config_home = Path(self.state_home.name) / "config"
        config_dir = self.config_home / "shellfish"
        config_dir.mkdir(parents=True)
        self.config_file = config_dir / "shellfish.jsonc"
        config = {
            "default_profile": "development",
            # Pinned rather than "auto", which probes the terminal for its
            # background in raw mode and has nothing here to answer it.
            "theme_mode": "dark",
            "theme_light": "theme",
            "theme_dark": "theme",
            "backends": {"test": {"adapter": TEST_BACKEND}},
            "harnesses": {
                "test": {
                    "tools": ["read_file", "write_file", "edit_file", "shell"],
                    "sandbox": sandbox,
                }
            },
            "profiles": {
                "development": {
                    "backend": "test",
                    "harness": "test",
                    "request": {"model": "fake-model"},
                }
            },
            "themes": {"theme": THEME},
        }
        if hooks:
            config["harnesses"]["test"]["user_prompt_submit"] = list(hooks)
            hook_dir = config_dir / "hooks" / "user_prompt_submit"
            hook_dir.mkdir(parents=True)
            for name, body in hooks.items():
                # A bodyless entry names a bundled script: with nothing written
                # here the reference falls through to share/default/hooks, so the
                # shipped script runs rather than a copy that could drift from it.
                if body is None:
                    continue
                script = hook_dir / name
                script.write_text(body)
                script.chmod(0o755)
        if session_start:
            config["harnesses"]["test"]["session_start"] = session_start
        if system is not None:
            system_dir = config_dir / "system"
            system_dir.mkdir(parents=True, exist_ok=True)
            (system_dir / "startup.md").write_text(system)
            config["profiles"]["development"]["system"] = ["startup.md"]
        self.config_file.write_text(json.dumps(config))
        self.explicit_session = (
            Path(self.state_home.name) / "explicit.jsonl"
            if explicit_session
            else None
        )
        if session_records is not None:
            if self.explicit_session is None:
                raise ValueError("session_records requires explicit_session")
            self.explicit_session.write_text(
                "".join(json.dumps(record) + "\n" for record in session_records)
            )
        # `pty.fork()` raises `OSError: out of pty devices` under a sandboxed
        # shell that withholds ptys; run the pty suite outside such a sandbox.
        # Not a regression in the code under test.
        pid, fd = pty.fork()
        if pid == 0:
            env = os.environ.copy()
            env.pop("NO_COLOR", None)
            env.update(
                TERM="xterm-256color",
                COLUMNS=str(COLUMNS),
                LINES=str(ROWS),
                SF_TEST_BACKEND_DELAY="0.02",
                XDG_STATE_HOME=self.state_home.name,
                XDG_CONFIG_HOME=str(self.config_home),
            )
            env.update(env_overrides)
            os.chdir(self.project_dir)
            argv = [APP, "--config", str(self.config_file)]
            if self.explicit_session:
                argv.extend(["--session", str(self.explicit_session)])
            argv.extend(args or [])
            os.execve(APP, argv, env)
        self.pid = pid
        self.fd = fd
        # Without a window size the shell reads 0x0 from stty and silently
        # disables wrapping and scrollback flushing.
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLUMNS, 0, 0))
        attrs = termios.tcgetattr(fd)
        attrs[3] |= termios.TOSTOP
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
        self.output = bytearray()
        try:
            self.wait_ready()
        except Exception:
            self.close()
            raise

    def pump(self, timeout=0.05):
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready:
            return
        try:
            self.output.extend(os.read(self.fd, 65536))
        except OSError:
            pass

    def wait(self, token, timeout=3):
        encoded = token.encode() if isinstance(token, str) else token
        end = time.monotonic() + timeout
        while encoded not in self.output and time.monotonic() < end:
            self.pump()
        if encoded not in self.output:
            raise AssertionError(f"did not render {token!r}\n{self.visible()[-1500:]}")

    def wait_after(self, start, token, timeout=3, view=None):
        view = view or self.visible
        token = token.decode() if isinstance(token, bytes) else token
        end = time.monotonic() + timeout
        while token not in view(start) and time.monotonic() < end:
            self.pump()
        if token not in view(start):
            raise AssertionError(f"did not render new {token!r}\n{view(start)[-1500:]}")

    def wait_ready(self, start=0, timeout=3):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            visible = self.visible(start)
            if re.search(r"❯\s+─+\s+\S+/\S+\s*$", visible):
                return
            banner = visible.rfind("Project:")
            if banner >= 0 and "❯" in visible[banner:]:
                return
            self.pump()
        raise AssertionError(f"did not render a ready prompt\n{self.visible(start)[-1500:]}")

    def send(self, value):
        os.write(self.fd, value)

    def _stripped(self, start, line_break):
        output = bytes(self.output[start:])
        return OSC.sub(b"", CSI.sub(b"", output)).replace(b"\r", line_break).decode("utf-8", "replace")

    def visible(self, start=0):
        """Rendered output, with a repainted line reading as a new one."""
        return self._stripped(start, b"\n")

    def typed(self, start=0):
        """Keystroke echo. ZLE repaints a character at a time, returning to the
        column with a carriage return between each, so visible() would break a
        single typed word across as many lines as it has characters."""
        return self._stripped(start, b"")

    def wait_session_records(self, count, timeout=3, path=None):
        # No path globs the session directory, where a session the app chose for
        # itself lands. Falling back to explicit_session would defeat the /new
        # test, which asks precisely whether a different file appeared there.
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            paths = (
                [path]
                if path
                else list(Path(self.state_home.name).glob("shellfish/sessions/**/*.jsonl"))
            )
            if len(paths) == 1 and paths[0].exists():
                records = [json.loads(line) for line in paths[0].read_text().splitlines()]
                if len(records) >= count:
                    return paths[0], records
            self.pump(0.02)
        raise AssertionError(f"session did not reach {count} records")

    def close(self):
        try:
            os.kill(self.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        end = time.monotonic() + 1
        while time.monotonic() < end:
            done, _ = os.waitpid(self.pid, os.WNOHANG)
            if done:
                break
            self.pump(0.02)
        else:
            try:
                os.kill(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(self.pid, 0)
            except ChildProcessError:
                pass
        os.close(self.fd)
        self.project_home.cleanup()
        self.state_home.cleanup()
