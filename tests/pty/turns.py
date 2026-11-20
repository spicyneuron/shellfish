#!/usr/bin/env python3
"""Turn display, queuing, and cancellation in a real PTY."""

from _session import Session, run


def test_tool_uses_manifest_display():
    session = Session()
    try:
        mark = len(session.output)
        session.send(b"tool\r")
        session.wait_after(mark, "⛭ Shell for")
        visible = session.visible(mark)
        assert 'shell {"command":' not in visible, visible
    finally:
        session.close()


def start_delayed_turn():
    session = Session(
        explicit_session=True,
        env={
            "SF_TEST_PROVIDER_DELAY_MATCH_SECONDS": "30",
            "SF_TEST_PROVIDER_REQUEST": "provider-request.json",
        },
    )
    try:
        session.send(b"delay response\r")
        session.wait_for((session.project_dir / "provider-request.json").exists,
                         "provider receiving the delayed turn")
    except Exception:
        session.close()
        raise
    return session


def test_activity_input_does_not_delay_interrupt():
    session = start_delayed_turn()
    try:
        mark = len(session.output)
        # The heartbeat must forward adjacent input and interrupt bytes.
        session.send(b"draft\x03")
        session.wait_after(mark, "Cancelled.", timeout=1.5)
        edit = len(session.output)
        session.send(b"X\x0c")
        session.wait_after(edit, "draftX", view=session.typed)
    finally:
        session.close()


def test_steer_cancels_and_sends_draft():
    session = start_delayed_turn()
    try:
        mark = len(session.output)
        session.send(b"later\r")
        session.wait_screen(mark, "1. later")
        session.send(b"steer now\x18")
        _, records = session.wait_session_records(7, timeout=5, path=session.explicit_session)
        prompts = [
            record["content"][0]["text"]
            for record in records if record["type"] == "user"
        ]
        assert prompts == ["delay response", "steer now", "later"], prompts
        assert records[-1]["type"] == "assistant", records
        assert records[2] == {
            "type": "error", "section": 2, "user_text": "Cancelled.",
        }, records
    finally:
        session.close()


def test_interrupt_preserves_queue_until_send_now():
    session = start_delayed_turn()
    try:
        path = session.explicit_session
        mark = len(session.output)
        session.send(b"first\rsecond\r\x03")
        session.wait_after(mark, "Cancelled.", timeout=1.5)
        session.wait_screen(mark, "2. second")
        _, records = session.wait_session_records(3, path=path)
        prompts = [
            record["content"][0]["text"]
            for record in records if record["type"] == "user"
        ]
        assert prompts == ["delay response"], prompts
        assert records[-1] == {"type": "error", "section": 2, "user_text": "Cancelled."}, records

        session.send(b"\x1b[13;5u")
        _, records = session.wait_session_records(7, path=path)
        prompts = [
            record["content"][0]["text"]
            for record in records if record["type"] == "user"
        ]
        assert prompts == ["delay response", "first", "second"], prompts
        assert records[-1]["type"] == "assistant", records
    finally:
        session.close()


def test_interrupt_drains_partial_recovery():
    session = Session(
        explicit_session=True,
        env={"SF_TEST_PROVIDER_DELAY": "0.04"},
    )
    try:
        prompt = "think " + " ".join(f"stream{i:02}" for i in range(40))
        mark = len(session.output)
        session.send((prompt + "\r").encode())
        path, _ = session.wait_session_records(2, path=session.explicit_session)
        session.wait_after(mark, "✎ Reasoning")

        mark = len(session.output)
        session.send(b"\x03")
        session.wait_after(mark, "Cancelled.", timeout=2)
        _, records = session.wait_session_records(4, path=path)
        assert records[-1] == {"type": "error", "section": 2, "user_text": "Cancelled."}
        recovered = records[-2]
        assert recovered["type"] == "assistant" and recovered["stop"] == "cancelled"
        assert any(
            item["type"] == "reasoning" and item["text"]
            for item in recovered["content"]
        )
    finally:
        session.close()


if __name__ == "__main__":
    run("turn PTY scenarios", [
        test_tool_uses_manifest_display,
        test_activity_input_does_not_delay_interrupt,
        test_interrupt_drains_partial_recovery,
        test_steer_cancels_and_sends_draft,
        test_interrupt_preserves_queue_until_send_now,
    ])
