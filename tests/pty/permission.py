#!/usr/bin/env python3
"""Permission decisions and session grants in a real PTY."""
import json
import os
import tempfile
import time
from pathlib import Path

from _session import Session, run


HOLD_PERMISSION_HOOK = r"""#!/usr/bin/env zsh
(( $# == 0 )) || exit 1
: >"${SHELLFISH_SESSION:h}/permission-ready"
while [[ ! -e ${SHELLFISH_SESSION:h}/permission-release ]]; do sleep 0.02; done
"""


def test_sandbox_updates_without_reload():
    with tempfile.TemporaryDirectory() as grant:
        session = Session(commands=["sandbox"])

        # The header update can land after the rendered result.
        def wait_grant(kind, value):
            end = time.monotonic() + 3
            while time.monotonic() < end:
                records = [json.loads(line) for line in path.read_text().splitlines()]
                grants = records[0]["profile"]["sandbox"]["tools"].get("shell", {})
                section, field = {
                    "read": ("filesystem", "allowRead"),
                    "write": ("filesystem", "allowWrite"),
                    "domains": ("network", "allowedDomains"),
                }[kind]
                if value in grants.get(section, {}).get(field, []):
                    return records, grants
                session.pump()
            raise AssertionError(f"session header did not gain {kind} grant {value}")

        try:
            path, _ = session.wait_session_records(1)
            mark = len(session.output)
            session.send(f"/sandbox shell +write {grant}\r".encode())
            session.wait_after(mark, "Sandbox shell write grant added", timeout=5)
            session.wait_ready(mark, timeout=5)
            assert "Project:" not in session.visible(mark)
            grant_path = str(Path(grant).resolve())
            records, _ = wait_grant("write", grant_path)
            granted = f"The user added a session sandbox write grant for shell: {grant_path}"
            assert len(records) == 2
            result = records[1]
            assert result.pop("id")
            assert result == {
                "type": "hook_result",
                "lifecycle": "user_prompt_submit",
                "user_text": f"**Sandbox** shell write grant added\n{grant_path}",
                "user_preview_lines": "full",
                "model_content": [{"type": "text", "text": f'<context script="sandbox">\n{granted}\n</context>'}],
            }
            mark = len(session.output)
            session.send(b"/sandbox shell +domain github.com\r")
            session.wait_after(mark, "Sandbox shell domain grant added", timeout=5)
            session.wait_ready(mark, timeout=5)
            _, grants = wait_grant("domains", "github.com")
            assert grants["network"]["allowedDomains"] == ["github.com"]
            assert grants["filesystem"]["allowWrite"] == [grant_path]
        finally:
            session.close()


def test_permission_decision_restores_draft():
    session = Session(
        explicit_session=True,
        hooks={"hold_permission": HOLD_PERMISSION_HOOK},
        env={
            "SF_TEST_PROVIDER_TOOL_CALL": "1",
            "SF_TEST_PROVIDER_TOOL_BYPASS": "true",
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
        session.wait_for(ready.exists, "prompt hook holding the turn")
        draft_mark = len(session.output)
        session.send(draft.encode() + b"\x0c")
        session.wait_after(draft_mark, draft, view=session.typed)
        release.touch()
        session.wait_after(mark, "Allow shell outside of sandbox?")
        session.wait_after(mark, "[d]eny and continue (")
        session.send(b"d")

        # The silent prompt hook records nothing before the turn.
        _, records = session.wait_session_records(5, path=session.explicit_session)
        session.wait_screen(mark, "Tool complete.")
        edit = len(session.output)
        session.send(b"X\x0c")
        session.wait_after(edit, draft + "X", view=session.typed)

        results = [record for record in records if record.get("type") == "tool_result"]
        assert len(results) == 1
        assert results[0]["exit_code"] == 126
        assert results[0]["model_content"][0]["text"].endswith("Reason: sandbox access denied by user\n</sandbox_notice>")
        assert results[0]["sandbox_access"] == "denied"
        users = [record for record in records if record.get("type") == "user"]
        assert len(users) == 1
        assert users[0]["content"] == [{"type": "text", "text": prompt}]
        assert draft not in session.explicit_session.read_text()
    finally:
        release.touch()
        session.close()


def test_permission_review_runs_with_prompt():
    for pending in (True, False):
        review = r'''#!/usr/bin/env zsh
cat >/dev/null
sleep "${REVIEW_DELAY:-0}"
print -r -u2 -- reviewed
print -r -u3 -- '{"action":"allow","reason":"ok"}'
'''
        session = Session(
            explicit_session=True,
            hooks={"review": review},
            env={
                "SF_TEST_PROVIDER_TOOL_CALL": "1",
                "SF_TEST_PROVIDER_TOOL_BYPASS": "true",
                "REVIEW_DELAY": "30" if pending else "0",
            },
        )
        try:
            manifest = session.shellfish_dir / "hooks/review/manifest.json"
            manifest.write_text(json.dumps({
                "on": "permission_request", "user_text": "${output.stderr}",
            }))
            mark = len(session.output)
            session.send(b"review access\r")
            session.wait_after(mark, "Allow shell outside of sandbox?")
            if pending:
                session.wait_after(mark, "Reviewer: checking")
                session.send(b"a")
            else:
                has_screen = session.screen() is not None
                if has_screen:
                    session.wait_screen(mark, "Reviewer: approve: ok", "[a]pprove (")
                else:
                    session.wait_after(mark, "approve: ok")
                session.send(b"x")
                if has_screen:
                    session.wait_screen(mark, "[d]eny and continue (")
                session.send(b"d")
            session.wait_screen(mark, "Tool complete.")
            _, records = session.wait_session_records(5, path=session.explicit_session)
            results = [r for r in records if r.get("type") == "tool_result"]
            assert len(results) == 1
            assert results[0]["sandbox_access"] == ("approved" if pending else "denied")
        finally:
            session.close()


def test_permission_grant_for_session():
    granted = tempfile.mkdtemp()
    grant = {"request_sandbox_access": {"read": [granted], "reason": "read the fixture"}}
    session = Session(
        explicit_session=True,
        env={
            "SF_TEST_PROVIDER_TOOL_CALL": "1",
            "SF_TEST_PROVIDER_TOOL_EXTRA": json.dumps(grant),
        },
    )
    try:
        mark = len(session.output)
        session.send(b"grant access\r")
        session.wait_after(mark, "Grant shell this sandbox access?")
        session.wait_after(mark, 'Operation:')
        session.wait_after(mark, '"command":')
        session.wait_after(mark, 'Access:')
        session.wait_after(mark, "read " + granted)
        session.wait_after(mark, "2. approve for [t]his session")
        session.send(b"t")
        _, records = session.wait_session_records(5, path=session.explicit_session)
        session.wait_after(mark, "[sandbox access approved for session]")
        results = [record for record in records if record.get("type") == "tool_result"]
        assert len(results) == 1
        assert results[0]["sandbox_access"] == "session"
        assert records[0]["profile"]["sandbox"]["tools"]["shell"]["filesystem"]["allowRead"] == [
            str(Path(granted).resolve())
        ]
    finally:
        session.close()
        os.rmdir(granted)


def test_permission_stop_cancels_pending_tools():
    for key in (b"\x03", b"s"):
        session = Session(
            explicit_session=True,
            env={
                "SF_TEST_PROVIDER_TOOL_CALL": "1",
                "SF_TEST_PROVIDER_TOOL_BYPASS": "true",
                "SF_TEST_PROVIDER_TOOL_COUNT": "3",
            },
        )
        try:
            mark = len(session.output)
            session.send(b"cancel tools\r")
            session.wait_after(mark, "Allow shell outside of sandbox?")
            session.send(key)
            _, records = session.wait_session_records(
                7, path=session.explicit_session
            )
            results = [
                record for record in records if record.get("type") == "tool_result"
            ]
            assert [(record["id"], record["exit_code"]) for record in results] == [
                ("call_1", 126),
                ("call_2", 126),
                ("call_3", 126),
            ]
            assert [record.get("sandbox_access") for record in results] == [
                "cancelled",
                None,
                None,
            ]
            assert records[-1] == {"type": "error", "section": 2, "user_text": "Cancelled."}
            session.wait_after(mark, "Cancelled.")
        finally:
            session.close()


if __name__ == "__main__":
    run("permission PTY scenarios", [
        test_permission_decision_restores_draft,
        test_permission_review_runs_with_prompt,
        test_permission_grant_for_session,
        test_permission_stop_cancels_pending_tools,
        test_sandbox_updates_without_reload,
    ])
