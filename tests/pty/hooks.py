#!/usr/bin/env python3
"""How user_prompt_submit hooks reach the chat UI: display, pacing, and handoff.

Split from chat.py so each file's scenarios fit the runner's per-file timeout
and the two run concurrently.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _session import Session  # noqa: E402

SWITCH_HOOK = r"""#!/usr/bin/env zsh
emulate -R zsh
setopt no_aliases no_multios pipe_fail
typeset submitted=''
integer read_status
[[ $1 == user_prompt_submit ]] || exit 1
IFS= read -r submitted
read_status=$?
[[ "$read_status:$submitted" == '1:/switch' ]] || exit 0
jq -cn --arg path "${SHELLFISH_SESSION:h}/switched.jsonl" \
  --arg executable "$SHELLFISH_EXECUTABLE" \
  '{action:"handoff",argv:[$executable,"--session",$path]}' >&3
exit 11
"""

SLOW_HOOK = r"""#!/usr/bin/env zsh
[[ $1 == user_prompt_submit ]] || exit 1
typeset directory=${SHELLFISH_SESSION:h}
: >"$directory/hook-started"
while [[ ! -e $directory/hook-release ]]; do
  sleep 0.05
done
: >"$directory/hook-completed"
"""

DISPLAY_HOOK = r"""#!/usr/bin/env zsh
[[ $1 == user_prompt_submit ]] || exit 1
integer line
for (( line = 1; line <= 24; line++ )); do
  print -u2 -- "display line $line"
done
exit 10
"""


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
        assert not completed.exists()

        release.touch()
        _, records = session.wait_session_records(3, path=session.explicit_session)
        assert completed.exists()
        assert records[-2]["role"] == "user"
        assert records[-1]["role"] == "assistant"
    finally:
        release.touch()
        session.close()


def test_prompt_hook_display_precedes_agent_section():
    session = Session(hooks={"display": DISPLAY_HOOK})
    try:
        mark = len(session.output)
        session.send(b"display only\r")
        session.wait_after(mark, "display line 24")
        visible = session.visible(mark)
        user = visible.find("─ user ")
        display = visible.find("display line 24")
        assert 0 <= user < display, visible
        assert "─ agent " not in visible, visible
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
        assert len(original) == 1, original
    finally:
        session.close()


def test_prompt_hook_hands_off_to_new_session():
    # /new requests a handoff without --session. This starts from an explicit
    # session outside the session directory, so its new file is unambiguous.
    session = Session(explicit_session=True, hooks={"new": None})
    try:
        mark = len(session.output)
        session.send(b"/new\r")
        session.wait_ready(mark)
        session.send(b"first new turn\r")
        path, records = session.wait_session_records(1)
        assert path != session.explicit_session, (path, session.explicit_session)
        assert len(records) >= 1, records
    finally:
        session.close()


def main():
    test_slow_prompt_hook_keeps_ui_active()
    test_prompt_hook_display_precedes_agent_section()
    test_prompt_hook_hands_off_to_another_session()
    test_prompt_hook_hands_off_to_new_session()
    print("PASS prompt hook PTY scenarios")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise
