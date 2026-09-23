#!/usr/bin/env python3
"""Hook display, startup pacing, and handoff in the chat UI."""
import json
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _session import Session, run  # noqa: E402

SWITCH_HOOK = r"""#!/usr/bin/env zsh
emulate -R zsh
setopt no_aliases no_multios pipe_fail
typeset submitted=''
integer read_status
(( $# == 0 )) || exit 1
IFS= read -r submitted
read_status=$?
[[ "$read_status:$submitted" == '1:/switch' ]] || exit 0
jq -cn --arg path "${SHELLFISH_SESSION:h}/switched.jsonl" \
  --arg executable "$SHELLFISH_EXECUTABLE" \
  '{action:"handoff",argv:[$executable,"--session-out",$path]}' >&3
"""

SLOW_HOOK = r"""#!/usr/bin/env zsh
(( $# == 0 )) || exit 1
typeset directory=${SHELLFISH_SESSION:h}
: >"$directory/hook-started"
while [[ ! -e $directory/hook-release ]]; do
  sleep 0.05
done
: >"$directory/hook-completed"
"""

DISPLAY_HOOK = r"""#!/usr/bin/env zsh
(( $# == 0 )) || exit 1
integer line
for (( line = 1; line <= 24; line++ )); do
  print -u2 -- "display line $line"
done
print -r -u3 -- '{"action":"block"}'
"""

START_HOOK = r"""#!/usr/bin/env zsh
typeset directory=${SHELLFISH_SESSION:h} name=${0:t}
print -r -u3 -- "{\"user_draft\":\"Inspecting $name\"}"
: >"$directory/$name-started"
while [[ ! -e $directory/$name-release ]]; do
  sleep 0.05
done
print -r -u3 -- "{\"user_final\":\"$name context\",\"model_final\":\"$name context\"}"
[[ -z ${SHELLFISH_PARENT_HOOK-} ]] || exec "$SHELLFISH_PARENT_HOOK"
"""


def start_hook(directory, name):
    script = Path(directory) / name
    script.write_text(START_HOOK)
    script.chmod(0o755)
    return str(script)


def test_startup_streams_hooks_and_runs_the_queued_prompt():
    with tempfile.TemporaryDirectory() as directory:
        session = Session(
            explicit_session=True,
            session_start=[start_hook(directory, "first_start"),
                           start_hook(directory, "second_start")],
            args=["initial prompt"],
        )
        state = session.explicit_session.parent
        try:
            session.wait_after(0, "Inspecting first_start")
            assert "1. initial prompt" in session.visible(), session.visible()
            activity = ("⡀", "⡄", "⠆", "⠃", "⠁")
            mark = len(session.output)
            end = time.monotonic() + 2
            while len({frame for frame in activity if frame in session.visible(mark)}) < 2:
                assert time.monotonic() < end, session.visible(mark)
                session.pump()

            # Each startup hook settles its own block before the next drafts.
            mark = len(session.output)
            (state / "first_start-release").touch()
            session.wait_after(mark, "Inspecting second_start")
            (state / "second_start-release").touch()
            _, records = session.wait_session_records(5, path=session.explicit_session)
            assert [record["type"] for record in records[:3]] == [
                "session", "hook_result", "hook_result"
            ]
            assert records[3]["type"] == "user"
            assert records[3]["content"][0]["text"] == "initial prompt"
        finally:
            (state / "first_start-release").touch()
            (state / "second_start-release").touch()
            session.close()


def test_startup_cancellation_retains_the_transcript():
    with tempfile.TemporaryDirectory() as directory:
        session = Session(explicit_session=True,
                          session_start=[start_hook(directory, "slow_start")])
        try:
            session.wait_after(0, "Inspecting slow_start")
            session.send(b"\x03")
            session.wait_after(0, "Cancelled.")
            # The creation path remains provisional, so cancellation stops the
            # client without offering it while the written prefix stays on disk.
            assert "Submit /quit to leave." in session.visible(), session.visible()
            assert session.explicit_session.exists()
            _, records = session.wait_session_records(
                1, path=session.explicit_session
            )
            assert [record["type"] for record in records] == ["session"]
            mark = len(session.output)
            session.send(b"\x03")
            end = time.monotonic() + 0.2
            while time.monotonic() < end:
                session.pump()
            assert "Resume with:" not in session.visible(mark), session.visible(mark)
        finally:
            (session.explicit_session.parent / "slow_start-release").touch()
            session.close()


def test_slow_prompt_hook_keeps_ui_active():
    session = Session(explicit_session=True, hooks={"slow": SLOW_HOOK})
    directory = session.explicit_session.parent
    started = directory / "hook-started"
    release = directory / "hook-release"
    completed = directory / "hook-completed"
    try:
        mark = len(session.output)
        session.send(b"slow hook\r")
        end = time.monotonic() + 3
        while not started.exists() and time.monotonic() < end:
            session.pump()
        assert started.exists(), session.visible(mark)
        assert not completed.exists()

        activity = ("⡀", "⡄", "⠆", "⠃", "⠁")
        end = time.monotonic() + 3
        while (
            len({frame for frame in activity if frame in session.visible(mark)}) < 2
            and time.monotonic() < end
        ):
            session.pump()
        frames = {frame for frame in activity if frame in session.visible(mark)}
        assert len(frames) >= 2, session.visible(mark)
        assert "slow · user_prompt_submit" not in session.visible(mark), session.visible(mark)
        assert not completed.exists()

        release.touch()
        # The silent hook records nothing; only the turn it released persists.
        _, records = session.wait_session_records(3, path=session.explicit_session)
        assert completed.exists()
        assert records[-2]["type"] == "user"
        assert records[-1]["type"] == "assistant"
    finally:
        release.touch()
        session.close()


def test_prompt_hook_display_precedes_agent_section():
    session = Session(hooks={"display": DISPLAY_HOOK})
    try:
        mark = len(session.output)
        session.send(b"display only\r")
        session.wait_after(mark, "display line 3")
        visible = session.visible(mark)
        user = visible.find("─ user ")
        display = visible.find("display line 3")
        assert 0 <= user < display, visible
        assert "─ agent " not in visible, visible
    finally:
        session.close()


def test_help_shows_its_full_listing():
    session = Session(hooks={"help": None})
    try:
        mark = len(session.output)
        session.send(b"/help\r")
        # The listing outlasts the default two-line preview.
        session.wait_after(mark, "/quit, /q")
        assert "/refresh, /r" in session.visible(mark), session.visible(mark)
    finally:
        session.close()


def test_prompt_hook_hands_off_to_another_session():
    session = Session(explicit_session=True, hooks={"switch": SWITCH_HOOK})
    try:
        switched = session.explicit_session.parent / "switched.jsonl"
        mark = len(session.output)
        session.send(b"/switch\r")
        session.wait_ready(mark)
        session.send(b"first switched turn\r")
        _, records = session.wait_session_records(1, path=switched)
        assert len(records) >= 1, records
        original = [
            json.loads(line)
            for line in session.explicit_session.read_text().splitlines()
        ]
        # The silent redirect leaves the original session at its header.
        assert [record["type"] for record in original] == ["session"], original
    finally:
        session.close()


def test_prompt_hook_hands_off_to_new_session():
    # Freeze the source profile before changing ambient config.
    session = Session(explicit_session=True, hooks={"new": None})
    try:
        session.wait_session_records(1, path=session.explicit_session)
        config = json.loads(session.config_file.read_text())
        config["request"]["model"] = "changed-model"
        session.config_file.write_text(json.dumps(config))
        mark = len(session.output)
        session.send(b"/new\r")
        session.wait_ready(mark)
        session.send(b"first new turn\r")
        path, records = session.wait_session_records(1)
        assert path != session.explicit_session, (path, session.explicit_session)
        assert len(records) >= 1, records
        assert records[0]["profile"]["request"]["model"] == "fake-model", records[0]
    finally:
        session.close()


def test_fork_restores_removed_user_prompt_as_draft():
    session = Session(explicit_session=True, hooks={"fork": None})
    fork = session.explicit_session.with_name("explicit_fork_1.jsonl")
    try:
        session.send(b"original prompt\r")
        session.wait_session_records(3, path=session.explicit_session)
        mark = len(session.output)
        session.send(b"/fork 1\r")
        session.wait_after(mark, "❯ original prompt", view=session.typed)
        session.send(b" edited\r")
        _, records = session.wait_session_records(3, path=fork)
        assert fork.stat().st_mode & 0o777 == 0o600
        assert records[-2]["content"][0]["text"] == "original prompt edited", records
    finally:
        session.close()


if __name__ == "__main__":
    run("hook script PTY scenarios", [
        test_startup_streams_hooks_and_runs_the_queued_prompt,
        test_startup_cancellation_retains_the_transcript,
        test_slow_prompt_hook_keeps_ui_active,
        test_prompt_hook_display_precedes_agent_section,
        test_help_shows_its_full_listing,
        test_prompt_hook_hands_off_to_another_session,
        test_prompt_hook_hands_off_to_new_session,
        test_fork_restores_removed_user_prompt_as_draft,
    ])
