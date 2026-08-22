import 'dart:convert';

class AssistantGroup {
  final String id;
  final String name;

  const AssistantGroup({required this.id, required this.name});

  AssistantGroup copyWith({String? id, String? name}) =>
      AssistantGroup(id: id ?? this.id, name: name ?? this.name);

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  static AssistantGroup fromJson(Map<String, dynamic> json) => AssistantGroup(
    id: (json['id'] ?? '').toString(),
    name: (json['name'] ?? '').toString(),
  );

  static String encodeList(List<AssistantGroup> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());
  static List<AssistantGroup> decodeList(String raw) {
    try {
      final arr = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in arr) AssistantGroup.fromJson(e as Map<String, dynamic>),
      ];
    } catch (_) {
      return const <AssistantGroup>[];
    }
  }
}
