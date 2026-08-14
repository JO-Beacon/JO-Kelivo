#!/usr/bin/env python3
"""Standalone JO-Kelivo legacy chats.json version-order optimization tool.

Only JO-Kelivo 0.1.5 and earlier legacy chats.json exports are accepted. The
tool does not import app code, touch Hive/SQLite databases, or change messages.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

JsonObject = dict[str, Any]

_LEGACY_ROOT_FIELDS = {
    "version",
    "conversations",
    "messages",
    "toolEvents",
    "geminiThoughtSigs",
}
_LEGACY_CONVERSATION_FIELDS = {"id", "messageIds", "versionSelections"}
_LEGACY_MESSAGE_FIELDS = {
    "id",
    "role",
    "content",
    "timestamp",
    "conversationId",
    "groupId",
    "version",
}


@dataclass
class ConversationReport:
    conversation_id: str
    moved_message_ids: list[str] = field(default_factory=list)
    skipped_reasons: list[str] = field(default_factory=list)

    @property
    def changed(self) -> bool:
        return bool(self.moved_message_ids)


@dataclass
class OptimizationReport:
    conversations_seen: int = 0
    conversations_changed: int = 0
    messages_seen: int = 0
    messages_moved: int = 0
    conversations_skipped: int = 0
    conversation_reports: list[ConversationReport] = field(default_factory=list)

    def to_lines(self) -> list[str]:
        lines = [
            "Optimization report",
            f"- conversations seen: {self.conversations_seen}",
            f"- conversations changed: {self.conversations_changed}",
            f"- conversations skipped: {self.conversations_skipped}",
            f"- messages seen: {self.messages_seen}",
            f"- messages moved: {self.messages_moved}",
        ]
        for item in self.conversation_reports:
            if item.moved_message_ids:
                lines.append(
                    f"- conversation {item.conversation_id}: moved "
                    f"{len(item.moved_message_ids)} message(s): "
                    f"{', '.join(item.moved_message_ids)}"
                )
            for reason in item.skipped_reasons:
                lines.append(f"- conversation {item.conversation_id}: skipped: {reason}")
        return lines


def _message_id(message: JsonObject) -> str | None:
    value = message.get("id")
    return value if isinstance(value, str) and value else None


def _conversation_id(conversation: JsonObject, fallback_index: int) -> str:
    value = conversation.get("id")
    if isinstance(value, str) and value:
        return value
    return f"<conversation #{fallback_index}>"


def _message_version(message: JsonObject) -> int:
    value = message.get("version", 0)
    if isinstance(value, int):
        return value
    return 0


def _message_group_id(message: JsonObject) -> str | None:
    value = message.get("groupId")
    return value if isinstance(value, str) and value else None


def _effective_group_id(message: JsonObject) -> str | None:
    return _message_group_id(message) or _message_id(message)


def _is_version_message(message: JsonObject) -> bool:
    return _message_version(message) > 0 and _message_group_id(message) is not None


def _duplicates(values: list[str]) -> list[str]:
    seen: set[str] = set()
    duplicated: list[str] = []
    duplicated_seen: set[str] = set()
    for value in values:
        if value in seen and value not in duplicated_seen:
            duplicated.append(value)
            duplicated_seen.add(value)
        seen.add(value)
    return duplicated


def _optimize_message_ids(
    message_ids: list[str],
    messages_by_id: dict[str, JsonObject],
    conversation_id: str,
) -> tuple[list[str], ConversationReport]:
    report = ConversationReport(conversation_id=conversation_id)

    duplicated = _duplicates(message_ids)
    if duplicated:
        report.skipped_reasons.append(
            "duplicate messageIds: " + ", ".join(duplicated)
        )
        return message_ids, report

    missing = [message_id for message_id in message_ids if message_id not in messages_by_id]
    if missing:
        report.skipped_reasons.append(
            "messageIds not found in messages: " + ", ".join(missing)
        )
        return message_ids, report

    ids_by_group: dict[str, list[str]] = {}
    movable_by_group: dict[str, list[str]] = {}
    movable_ids: set[str] = set()

    for message_id in message_ids:
        message = messages_by_id[message_id]
        group_id = _effective_group_id(message)
        if not group_id:
            continue
        ids_by_group.setdefault(group_id, []).append(message_id)
        if _is_version_message(message):
            movable_by_group.setdefault(group_id, []).append(message_id)

    for group_id, version_ids in movable_by_group.items():
        group_ids = ids_by_group.get(group_id, [])
        anchors = [message_id for message_id in group_ids if message_id not in version_ids]
        if not anchors:
            report.skipped_reasons.append(
                f"group {group_id} has version messages but no non-version anchor"
            )
            continue
        movable_ids.update(version_ids)

    if not movable_ids:
        return message_ids, report

    base_ids = [message_id for message_id in message_ids if message_id not in movable_ids]
    optimized_ids = list(base_ids)

    for group_id, version_ids in movable_by_group.items():
        version_ids = [message_id for message_id in version_ids if message_id in movable_ids]
        if not version_ids:
            continue

        insert_after = -1
        for index, message_id in enumerate(optimized_ids):
            message = messages_by_id[message_id]
            if _effective_group_id(message) == group_id:
                insert_after = index

        if insert_after < 0:
            report.skipped_reasons.append(
                f"group {group_id} anchor disappeared during Optimization"
            )
            continue

        insert_at = insert_after + 1
        for message_id in version_ids:
            optimized_ids.insert(insert_at, message_id)
            insert_at += 1

    if sorted(optimized_ids) != sorted(message_ids):
        report.skipped_reasons.append(
            "internal invariant failed: optimized messageIds differ from original set"
        )
        return message_ids, report

    if optimized_ids != message_ids:
        report.moved_message_ids = [
            message_id
            for message_id in message_ids
            if message_id in movable_ids and optimized_ids.index(message_id) != message_ids.index(message_id)
        ]

    return optimized_ids, report


def validate_legacy_archive_data(data: JsonObject) -> None:
    """Reject anything other than the legacy JO chats.json export shape."""
    missing_root = _LEGACY_ROOT_FIELDS.difference(data)
    if missing_root:
        raise ValueError(
            "not a JO 0.1.5-or-earlier chats.json: missing root field(s): "
            + ", ".join(sorted(missing_root))
        )
    if data.get("version") != 1:
        raise ValueError(
            "not a JO 0.1.5-or-earlier chats.json: version must be 1"
        )

    conversations = data.get("conversations")
    messages = data.get("messages")
    if not isinstance(conversations, list):
        raise ValueError("backup JSON field 'conversations' must be a list")
    if not isinstance(messages, list):
        raise ValueError("backup JSON field 'messages' must be a list")
    if not isinstance(data.get("toolEvents"), dict):
        raise ValueError("backup JSON field 'toolEvents' must be an object")
    if not isinstance(data.get("geminiThoughtSigs"), dict):
        raise ValueError("backup JSON field 'geminiThoughtSigs' must be an object")

    for index, conversation in enumerate(conversations):
        if not isinstance(conversation, dict):
            raise ValueError(f"conversation #{index} must be an object")
        missing = _LEGACY_CONVERSATION_FIELDS.difference(conversation)
        if missing:
            raise ValueError(
                f"conversation #{index} is not a legacy conversation: missing "
                + ", ".join(sorted(missing))
            )
        if not isinstance(conversation.get("id"), str) or not conversation["id"]:
            raise ValueError(f"conversation #{index} field 'id' must be a string")
        message_ids = conversation.get("messageIds")
        if not isinstance(message_ids, list) or not all(
            isinstance(item, str) for item in message_ids
        ):
            raise ValueError(
                f"conversation {conversation['id']} field 'messageIds' "
                "must be a list of strings"
            )
        if not isinstance(conversation.get("versionSelections"), dict):
            raise ValueError(
                f"conversation {conversation['id']} field 'versionSelections' "
                "must be an object"
            )

    for index, message in enumerate(messages):
        if not isinstance(message, dict):
            raise ValueError(f"message #{index} must be an object")
        if "parts" in message:
            raise ValueError(
                "structured message parts belong to JO 0.1.6/Kelivo 1.2.x; "
                "this tool only accepts JO 0.1.5-or-earlier chats.json"
            )
        missing = _LEGACY_MESSAGE_FIELDS.difference(message)
        if missing:
            raise ValueError(
                f"message #{index} is not a legacy message: missing "
                + ", ".join(sorted(missing))
            )
        for field_name in ("id", "role", "content", "timestamp", "conversationId"):
            if not isinstance(message.get(field_name), str):
                raise ValueError(
                    f"message #{index} field '{field_name}' must be a string"
                )
        if message.get("groupId") is not None and not isinstance(
            message.get("groupId"), str
        ):
            raise ValueError(f"message #{index} field 'groupId' must be a string or null")
        if not isinstance(message.get("version"), int):
            raise ValueError(f"message #{index} field 'version' must be an integer")


def optimize_archive_data(data: JsonObject) -> tuple[JsonObject, OptimizationReport]:
    validate_legacy_archive_data(data)
    conversations = data.get("conversations")
    messages = data.get("messages")
    assert isinstance(conversations, list)
    assert isinstance(messages, list)

    messages_by_id: dict[str, JsonObject] = {}
    duplicate_message_ids: list[str] = []
    for raw_message in messages:
        if not isinstance(raw_message, dict):
            continue
        message_id = _message_id(raw_message)
        if message_id is None:
            continue
        if message_id in messages_by_id:
            duplicate_message_ids.append(message_id)
        messages_by_id[message_id] = raw_message

    if duplicate_message_ids:
        raise ValueError(
            "backup JSON field 'messages' contains duplicate id(s): "
            + ", ".join(sorted(set(duplicate_message_ids)))
        )

    optimized = dict(data)
    optimized_conversations: list[Any] = []
    report = OptimizationReport(
        conversations_seen=len(conversations),
        messages_seen=len(messages_by_id),
    )

    for index, raw_conversation in enumerate(conversations):
        if not isinstance(raw_conversation, dict):
            optimized_conversations.append(raw_conversation)
            report.conversations_skipped += 1
            report.conversation_reports.append(
                ConversationReport(
                    conversation_id=f"<conversation #{index}>",
                    skipped_reasons=["conversation is not a JSON object"],
                )
            )
            continue

        conversation = dict(raw_conversation)
        conversation_id = _conversation_id(conversation, index)
        message_ids = conversation.get("messageIds")
        if not isinstance(message_ids, list) or not all(
            isinstance(item, str) for item in message_ids
        ):
            optimized_conversations.append(conversation)
            report.conversations_skipped += 1
            report.conversation_reports.append(
                ConversationReport(
                    conversation_id=conversation_id,
                    skipped_reasons=["messageIds is not a list of strings"],
                )
            )
            continue

        optimized_ids, conversation_report = _optimize_message_ids(
            list(message_ids),
            messages_by_id,
            conversation_id,
        )
        if conversation_report.changed:
            conversation["messageIds"] = optimized_ids
            report.conversations_changed += 1
            report.messages_moved += len(conversation_report.moved_message_ids)
        if conversation_report.skipped_reasons:
            report.conversations_skipped += 1
        optimized_conversations.append(conversation)
        if conversation_report.changed or conversation_report.skipped_reasons:
            report.conversation_reports.append(conversation_report)

    optimized["conversations"] = optimized_conversations
    return optimized, report


def read_json(path: Path) -> JsonObject:
    with path.open("r", encoding="utf-8") as file:
        data = json.load(file)
    if not isinstance(data, dict):
        raise ValueError("backup JSON root must be an object")
    return data


def write_json(path: Path, data: JsonObject) -> None:
    with path.open("w", encoding="utf-8") as file:
        json.dump(data, file, ensure_ascii=False, indent=2)
        file.write("\n")


def default_output_path(input_path: Path) -> Path:
    if input_path.suffix:
        return input_path.with_name(f"{input_path.stem}.optimized{input_path.suffix}")
    return input_path.with_name(f"{input_path.name}.optimized.json")


def default_backup_path(input_path: Path) -> Path:
    if input_path.suffix:
        return input_path.with_name(f"{input_path.stem}.backup{input_path.suffix}")
    return input_path.with_name(f"{input_path.name}.backup.json")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Optimize Kelivo chats.json version message order without importing Kelivo code."
    )
    parser.add_argument("input", type=Path, help="Path to the source chats.json file.")
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output path. Defaults to chats.optimized.json next to the input file.",
    )
    parser.add_argument(
        "--backup",
        type=Path,
        default=None,
        help="Backup path. Defaults to chats.backup.json next to the input file.",
    )
    parser.add_argument(
        "--no-backup",
        action="store_true",
        help="Do not create a backup copy of the input file.",
    )
    parser.add_argument(
        "--overwrite-output",
        action="store_true",
        help="Allow overwriting an existing output file.",
    )
    parser.add_argument(
        "--overwrite-backup",
        action="store_true",
        help="Allow overwriting an existing backup file after input validation.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    input_path = args.input
    output_path = args.output or default_output_path(input_path)
    backup_path = args.backup or default_backup_path(input_path)

    resolved_input = input_path.resolve()
    resolved_output = output_path.resolve()
    resolved_backup = backup_path.resolve()
    if resolved_input == resolved_output:
        print("Output path must differ from the input path.", file=sys.stderr)
        return 2
    if not args.no_backup and resolved_input == resolved_backup:
        print("Backup path must differ from the input path.", file=sys.stderr)
        return 2
    if not args.no_backup and resolved_output == resolved_backup:
        print("Output path must differ from the backup path.", file=sys.stderr)
        return 2

    if not input_path.is_file():
        print(f"Input file does not exist: {input_path}", file=sys.stderr)
        return 2
    if output_path.exists() and not args.overwrite_output:
        print(
            f"Output file already exists: {output_path}. "
            "Use --overwrite-output to replace it.",
            file=sys.stderr,
        )
        return 2
    if not args.no_backup and backup_path.exists() and not args.overwrite_backup:
        print(f"Backup file already exists: {backup_path}", file=sys.stderr)
        return 2

    try:
        data = read_json(input_path)
        optimized, report = optimize_archive_data(data)
        if not args.no_backup:
            shutil.copy2(input_path, backup_path)
        write_json(output_path, optimized)
    except Exception as error:  # noqa: BLE001 - CLI must report exact failure.
        print(f"Optimization failed: {error}", file=sys.stderr)
        return 1

    for line in report.to_lines():
        print(line)
    print(f"Output: {output_path}")
    if not args.no_backup:
        print(f"Backup: {backup_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())



