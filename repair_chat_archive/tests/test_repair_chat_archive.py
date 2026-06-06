import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "repair_chat_archive.py"
MODULE_SPEC = importlib.util.spec_from_file_location("repair_chat_archive", MODULE_PATH)
assert MODULE_SPEC is not None
repair_chat_archive = importlib.util.module_from_spec(MODULE_SPEC)
sys.modules[MODULE_SPEC.name] = repair_chat_archive
assert MODULE_SPEC.loader is not None
MODULE_SPEC.loader.exec_module(repair_chat_archive)

default_backup_path = repair_chat_archive.default_backup_path
default_output_path = repair_chat_archive.default_output_path
repair_archive_data = repair_chat_archive.repair_archive_data


def message(message_id, group_id=None, version=0):
    data = {
        "id": message_id,
        "role": "user",
        "content": message_id,
        "version": version,
    }
    if group_id is not None:
        data["groupId"] = group_id
    return data


def archive(message_ids, messages):
    return {
        "version": 1,
        "conversations": [
            {
                "id": "conversation-1",
                "title": "Chat",
                "messageIds": message_ids,
                "versionSelections": {},
            }
        ],
        "messages": messages,
        "toolEvents": {},
        "geminiThoughtSigs": {},
    }


def test_repairs_tail_version_message_near_original_group():
    data = archive(
        ["a", "b", "c", "a-v1"],
        [
            message("a"),
            message("b"),
            message("c"),
            message("a-v1", group_id="a", version=1),
        ],
    )

    repaired, report = repair_archive_data(data)

    assert repaired["conversations"][0]["messageIds"] == ["a", "a-v1", "b", "c"]
    assert repaired["messages"] == data["messages"]
    assert report.conversations_seen == 1
    assert report.conversations_changed == 1
    assert report.messages_moved == 1


def test_keeps_multiple_versions_stable_after_anchor():
    data = archive(
        ["a", "b", "a-v1", "c", "a-v2"],
        [
            message("a"),
            message("b"),
            message("a-v1", group_id="a", version=1),
            message("c"),
            message("a-v2", group_id="a", version=2),
        ],
    )

    repaired, report = repair_archive_data(data)

    assert repaired["conversations"][0]["messageIds"] == [
        "a",
        "a-v1",
        "a-v2",
        "b",
        "c",
    ]
    assert report.messages_moved == 2


def test_normal_messages_without_version_are_not_moved():
    data = archive(
        ["a", "b", "c"],
        [message("a"), message("b", group_id="a", version=0), message("c")],
    )

    repaired, report = repair_archive_data(data)

    assert repaired["conversations"][0]["messageIds"] == ["a", "b", "c"]
    assert report.conversations_changed == 0
    assert report.messages_moved == 0


def test_skips_conversation_with_duplicate_message_ids():
    data = archive(
        ["a", "a", "a-v1"],
        [message("a"), message("a-v1", group_id="a", version=1)],
    )

    repaired, report = repair_archive_data(data)

    assert repaired["conversations"][0]["messageIds"] == ["a", "a", "a-v1"]
    assert report.conversations_skipped == 1
    assert "duplicate messageIds" in report.conversation_reports[0].skipped_reasons[0]


def test_skips_conversation_with_missing_message():
    data = archive(
        ["a", "missing", "a-v1"],
        [message("a"), message("a-v1", group_id="a", version=1)],
    )

    repaired, report = repair_archive_data(data)

    assert repaired["conversations"][0]["messageIds"] == ["a", "missing", "a-v1"]
    assert report.conversations_skipped == 1
    assert "messageIds not found" in report.conversation_reports[0].skipped_reasons[0]


def test_rejects_invalid_backup_shape():
    with pytest.raises(ValueError, match="conversations"):
        repair_archive_data({"messages": []})

    with pytest.raises(ValueError, match="messages"):
        repair_archive_data({"conversations": []})


def test_default_paths():
    path = Path("C:/tmp/chats.json")

    assert default_output_path(path) == Path("C:/tmp/chats.fixed.json")
    assert default_backup_path(path) == Path("C:/tmp/chats.backup.json")


def test_cli_writes_output_and_backup(tmp_path):
    input_path = tmp_path / "chats.json"
    data = archive(
        ["a", "b", "a-v1"],
        [message("a"), message("b"), message("a-v1", group_id="a", version=1)],
    )
    input_path.write_text(json.dumps(data), encoding="utf-8")

    result = subprocess.run(
        [sys.executable, str(ROOT / "repair_chat_archive.py"), str(input_path)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    output_path = tmp_path / "chats.fixed.json"
    backup_path = tmp_path / "chats.backup.json"
    assert output_path.exists()
    assert backup_path.exists()
    assert json.loads(output_path.read_text(encoding="utf-8"))["conversations"][0][
        "messageIds"
    ] == ["a", "a-v1", "b"]
    assert json.loads(backup_path.read_text(encoding="utf-8")) == data
    assert "messages moved: 1" in result.stdout
