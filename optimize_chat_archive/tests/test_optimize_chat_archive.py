import importlib.util
import json
import sqlite3
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "optimize_chat_archive.py"
MODULE_SPEC = importlib.util.spec_from_file_location("optimize_chat_archive", MODULE_PATH)
assert MODULE_SPEC is not None
optimize_chat_archive = importlib.util.module_from_spec(MODULE_SPEC)
sys.modules[MODULE_SPEC.name] = optimize_chat_archive
assert MODULE_SPEC.loader is not None
MODULE_SPEC.loader.exec_module(optimize_chat_archive)

default_backup_path = optimize_chat_archive.default_backup_path
default_output_path = optimize_chat_archive.default_output_path
optimize_archive_data = optimize_chat_archive.optimize_archive_data


def message(message_id, group_id=None, version=0):
    data = {
        "id": message_id,
        "role": "user",
        "content": message_id,
        "timestamp": "2026-01-01T00:00:00.000Z",
        "conversationId": "conversation-1",
        "groupId": group_id or message_id,
        "version": version,
    }
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


def test_optimizes_tail_version_message_near_original_group():
    data = archive(
        ["a", "b", "c", "a-v1"],
        [
            message("a"),
            message("b"),
            message("c"),
            message("a-v1", group_id="a", version=1),
        ],
    )

    optimized, report = optimize_archive_data(data)

    assert optimized["conversations"][0]["messageIds"] == ["a", "a-v1", "b", "c"]
    assert optimized["messages"] == data["messages"]
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

    optimized, report = optimize_archive_data(data)

    assert optimized["conversations"][0]["messageIds"] == [
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

    optimized, report = optimize_archive_data(data)

    assert optimized["conversations"][0]["messageIds"] == ["a", "b", "c"]
    assert report.conversations_changed == 0
    assert report.messages_moved == 0


def test_skips_conversation_with_duplicate_message_ids():
    data = archive(
        ["a", "a", "a-v1"],
        [message("a"), message("a-v1", group_id="a", version=1)],
    )

    optimized, report = optimize_archive_data(data)

    assert optimized["conversations"][0]["messageIds"] == ["a", "a", "a-v1"]
    assert report.conversations_skipped == 1
    assert "duplicate messageIds" in report.conversation_reports[0].skipped_reasons[0]


def test_skips_conversation_with_missing_message():
    data = archive(
        ["a", "missing", "a-v1"],
        [message("a"), message("a-v1", group_id="a", version=1)],
    )

    optimized, report = optimize_archive_data(data)

    assert optimized["conversations"][0]["messageIds"] == ["a", "missing", "a-v1"]
    assert report.conversations_skipped == 1
    assert "messageIds not found" in report.conversation_reports[0].skipped_reasons[0]


def test_skips_version_group_without_non_version_anchor():
    data = archive(
        ["b", "a-v1"],
        [message("b"), message("a-v1", group_id="a", version=1)],
    )

    optimized, report = optimize_archive_data(data)

    assert optimized["conversations"][0]["messageIds"] == ["b", "a-v1"]
    assert report.conversations_skipped == 1
    assert report.conversations_changed == 0
    assert report.messages_moved == 0
    assert "no non-version anchor" in report.conversation_reports[0].skipped_reasons[0]


def test_rejects_invalid_backup_shape():
    with pytest.raises(ValueError, match="conversations"):
        optimize_archive_data({"messages": []})

    with pytest.raises(ValueError, match="messages"):
        optimize_archive_data({"conversations": []})


def test_accepts_empty_legacy_archive_as_no_op():
    optimized, report = optimize_archive_data(
        {
            "version": 1,
            "conversations": [],
            "messages": [],
            "toolEvents": {},
            "geminiThoughtSigs": {},
        }
    )

    assert optimized["conversations"] == []
    assert report.conversations_seen == 0


def test_rejects_structured_parts_archive():
    data = archive(["a"], [message("a")])
    data["messages"][0]["parts"] = [{"kind": "text", "payload": "a"}]

    with pytest.raises(ValueError, match="structured message parts"):
        optimize_archive_data(data)


def test_default_paths():
    path = Path("C:/tmp/chats.json")

    assert default_output_path(path) == Path("C:/tmp/chats.optimized.json")
    assert default_backup_path(path) == Path("C:/tmp/chats.backup.json")


def test_cli_writes_output_and_backup(tmp_path):
    input_path = tmp_path / "chats.json"
    data = archive(
        ["a", "b", "a-v1"],
        [message("a"), message("b"), message("a-v1", group_id="a", version=1)],
    )
    input_path.write_text(json.dumps(data), encoding="utf-8")

    result = subprocess.run(
        [sys.executable, str(ROOT / "optimize_chat_archive.py"), str(input_path)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    output_path = tmp_path / "chats.optimized.json"
    backup_path = tmp_path / "chats.backup.json"
    assert output_path.exists()
    assert backup_path.exists()
    assert json.loads(output_path.read_text(encoding="utf-8"))["conversations"][0][
        "messageIds"
    ] == ["a", "a-v1", "b"]
    assert json.loads(backup_path.read_text(encoding="utf-8")) == data
    assert "messages moved: 1" in result.stdout


@pytest.mark.parametrize("kind", ["hive", "sqlite", "zip", "other_json", "modern_json"])
def test_cli_rejects_non_target_input_without_modifying_any_file(tmp_path, kind):
    input_path = tmp_path / "chats.json"
    if kind == "hive":
        input_path.write_bytes(b"HIVE\x00\x01not-json")
    elif kind == "sqlite":
        connection = sqlite3.connect(input_path)
        connection.execute("CREATE TABLE messages (id TEXT PRIMARY KEY)")
        connection.commit()
        connection.close()
    elif kind == "zip":
        with zipfile.ZipFile(input_path, "w") as archive_file:
            archive_file.writestr("chats.json", "{}")
    elif kind == "other_json":
        input_path.write_text(
            json.dumps({"version": 1, "conversations": [], "messages": []}),
            encoding="utf-8",
        )
    else:
        data = archive(["a"], [message("a")])
        data["messages"][0]["parts"] = [{"kind": "text", "payload": "a"}]
        input_path.write_text(json.dumps(data), encoding="utf-8")

    output_path = tmp_path / "chats.optimized.json"
    backup_path = tmp_path / "chats.backup.json"
    output_path.write_bytes(b"existing-output")
    backup_path.write_bytes(b"existing-backup")
    before = input_path.read_bytes()

    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / "optimize_chat_archive.py"),
            str(input_path),
            "--overwrite-output",
            "--overwrite-backup",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 1
    assert "Optimization failed" in result.stderr
    assert input_path.read_bytes() == before
    assert output_path.read_bytes() == b"existing-output"
    assert backup_path.read_bytes() == b"existing-backup"


@pytest.mark.parametrize("collision", ["output_input", "backup_input", "output_backup"])
def test_cli_rejects_overlapping_paths_without_modifying_input(tmp_path, collision):
    input_path = tmp_path / "chats.json"
    input_path.write_text(
        json.dumps(archive(["a"], [message("a")])),
        encoding="utf-8",
    )
    shared_path = tmp_path / "shared.json"
    before = input_path.read_bytes()

    args = [
        sys.executable,
        str(ROOT / "optimize_chat_archive.py"),
        str(input_path),
        "--overwrite-output",
        "--overwrite-backup",
    ]
    if collision == "output_input":
        args.extend(["--output", str(input_path)])
    elif collision == "backup_input":
        args.extend(["--backup", str(input_path)])
    else:
        args.extend(["--output", str(shared_path), "--backup", str(shared_path)])

    result = subprocess.run(
        args,
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 2
    assert input_path.read_bytes() == before
    assert not shared_path.exists()


