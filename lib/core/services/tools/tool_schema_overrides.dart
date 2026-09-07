import 'dart:convert';

import '../../../features/home/services/built_in_tool_names.dart';
import '../../models/tool_schema_override.dart';

class ToolParamDescriptor {
  const ToolParamDescriptor({
    required this.path,
    this.type,
    this.enumValues,
    this.defaultDescription,
  });

  final String path;
  final String? type;
  final List<String>? enumValues;
  final String? defaultDescription;
}

/// 只把用户覆盖写入内置工具已有的描述位置，不改变 schema 结构。
abstract final class ToolSchemaOverrides {
  ToolSchemaOverrides._();

  static List<Map<String, dynamic>> apply(
    List<Map<String, dynamic>> definitions,
    Map<String, ToolSchemaOverride> overrides,
  ) {
    if (overrides.isEmpty) return definitions;
    List<Map<String, dynamic>>? result;
    for (var index = 0; index < definitions.length; index++) {
      final applied = _applyOne(definitions[index], overrides);
      if (applied == null) continue;
      result ??= List<Map<String, dynamic>>.from(definitions);
      result[index] = applied;
    }
    return result ?? definitions;
  }

  static List<ToolParamDescriptor> describeParams(
    Map<String, dynamic> definition,
  ) {
    final function = _asMap(definition['function']);
    final parameters = _asMap(function?['parameters']);
    final properties = _asMap(parameters?['properties']);
    if (properties == null) return const <ToolParamDescriptor>[];
    final result = <ToolParamDescriptor>[];
    _walkProperties(properties, '', result);
    return result;
  }

  static Map<String, dynamic>? _applyOne(
    Map<String, dynamic> definition,
    Map<String, ToolSchemaOverride> overrides,
  ) {
    final function = _asMap(definition['function']);
    final name = function?['name'];
    if (name is! String || !BuiltInToolNames.all.contains(name)) return null;
    final override = overrides[name];
    if (override == null || override.isEmpty) return null;

    final copy = jsonDecode(jsonEncode(definition)) as Map<String, dynamic>;
    final copiedFunction = _asMap(copy['function'])!;
    var changed = false;
    if (override.description?.trim().isNotEmpty == true) {
      copiedFunction['description'] = override.description;
      changed = true;
    }
    final parameters = _asMap(copiedFunction['parameters']);
    if (parameters != null) {
      for (final entry in override.paramDescriptions.entries) {
        if (entry.value.trim().isEmpty) continue;
        changed =
            _setParamDescription(parameters, entry.key, entry.value) || changed;
      }
    }
    return changed ? copy : null;
  }

  static void _walkProperties(
    Map<String, dynamic> properties,
    String prefix,
    List<ToolParamDescriptor> result,
  ) {
    for (final entry in properties.entries) {
      final schema = _asMap(entry.value);
      if (schema == null) continue;
      final path = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
      final rawEnum = schema['enum'];
      result.add(
        ToolParamDescriptor(
          path: path,
          type: schema['type'] is String ? schema['type'] as String : null,
          enumValues: rawEnum is List
              ? rawEnum
                    .where((value) => value != null)
                    .map((value) => '$value')
                    .toList()
              : null,
          defaultDescription: schema['description'] is String
              ? schema['description'] as String
              : null,
        ),
      );
      final nested = _asMap(schema['properties']);
      if (nested != null) _walkProperties(nested, path, result);
      final items = _asMap(schema['items']);
      if (items == null) continue;
      final itemProperties = _asMap(items['properties']);
      if (itemProperties != null) {
        _walkProperties(itemProperties, '$path.items', result);
      } else if (items['description'] is String) {
        final itemEnum = items['enum'];
        result.add(
          ToolParamDescriptor(
            path: '$path.items',
            type: items['type'] is String ? items['type'] as String : null,
            enumValues: itemEnum is List
                ? itemEnum
                      .where((value) => value != null)
                      .map((value) => '$value')
                      .toList()
                : null,
            defaultDescription: items['description'] as String,
          ),
        );
      }
    }
  }

  static bool _setParamDescription(
    Map<String, dynamic> parameters,
    String path,
    String description,
  ) {
    final segments = path.split('.');
    if (segments.isEmpty || segments.any((segment) => segment.isEmpty)) {
      return false;
    }
    var node = parameters;
    for (final segment in segments) {
      if (segment == 'items') {
        final items = _asMap(node['items']);
        if (items == null) return false;
        node['items'] = items;
        node = items;
        continue;
      }
      final properties = _asMap(node['properties']);
      if (properties == null) return false;
      node['properties'] = properties;
      final next = _asMap(properties[segment]);
      if (next == null) return false;
      properties[segment] = next;
      node = next;
    }
    node['description'] = description;
    return true;
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }
}
