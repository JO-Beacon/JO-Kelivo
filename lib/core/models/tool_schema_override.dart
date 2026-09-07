/// 用户对内置工具 schema 描述文本的覆盖。
///
/// 工具名、参数名、类型、枚举和必填列表始终使用应用内置定义。
/// 空描述表示继续使用内置默认值。
class ToolSchemaOverride {
  const ToolSchemaOverride({
    this.description,
    this.paramDescriptions = const <String, String>{},
  });

  final String? description;
  final Map<String, String> paramDescriptions;

  bool get isEmpty {
    if (description?.trim().isNotEmpty == true) return false;
    return !paramDescriptions.values.any((value) => value.trim().isNotEmpty);
  }

  Map<String, dynamic> toJson() {
    final params = <String, String>{
      for (final entry in paramDescriptions.entries)
        if (entry.value.trim().isNotEmpty) entry.key: entry.value,
    };
    return <String, dynamic>{
      if (description?.trim().isNotEmpty == true) 'description': description,
      if (params.isNotEmpty) 'paramDescriptions': params,
    };
  }

  factory ToolSchemaOverride.fromJson(Map<String, dynamic> json) {
    final rawDescription = json['description'];
    final rawParams = json['paramDescriptions'];
    return ToolSchemaOverride(
      description: rawDescription is String ? rawDescription : null,
      paramDescriptions: <String, String>{
        if (rawParams is Map)
          for (final entry in rawParams.entries)
            if (entry.value is String &&
                (entry.value as String).trim().isNotEmpty)
              entry.key.toString(): entry.value as String,
      },
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ToolSchemaOverride ||
        other.description != description ||
        other.paramDescriptions.length != paramDescriptions.length) {
      return false;
    }
    for (final entry in paramDescriptions.entries) {
      if (other.paramDescriptions[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    description,
    Object.hashAll(
      paramDescriptions.entries.map(
        (entry) => Object.hash(entry.key, entry.value),
      ),
    ),
  );
}
