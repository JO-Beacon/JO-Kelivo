/// JSON Schema helpers used at the provider tool-schema boundary.
library;

const _refKey = r'$ref';
const _maxRefDepth = 12;
const _maxRefExpansions = 512;
const _definitionKeys = {r'$defs', 'definitions'};
const _schemaMapKeys = {'properties'};
const _schemaListKeys = {
  'anyOf',
  'oneOf',
  'allOf',
  'any_of',
  'one_of',
  'all_of',
  'items',
};
const _subSchemaKeys = {'items', 'additionalProperties'};
const _annotationKeys = {
  'description',
  'title',
  'default',
  'examples',
  'deprecated',
  'readOnly',
  'writeOnly',
  r'$comment',
};

class _RefBudget {
  _RefBudget(this.expandAdditionalProperties);

  final bool expandAdditionalProperties;
  int expansions = 0;
}

/// Inline resolvable local `$ref`s against [schema]'s own document root.
///
/// Only schema-bearing keywords are traversed. This prevents data values that
/// happen to contain `$ref` from being interpreted as schema references.
Map<String, dynamic> resolveJsonSchemaRefs(
  Map<String, dynamic> schema, {
  bool expandAdditionalProperties = true,
}) {
  final result = _resolve(
    schema,
    schema,
    const <String>{},
    0,
    _RefBudget(expandAdditionalProperties),
  );
  return result is Map<String, dynamic> ? result : schema;
}

dynamic _resolve(
  dynamic node,
  Map<String, dynamic> root,
  Set<String> active,
  int depth,
  _RefBudget budget,
) {
  if (node is List) {
    return [
      for (final item in node) _resolve(item, root, active, depth, budget),
    ];
  }
  if (node is! Map) return node;

  final current = Map<String, dynamic>.from(node);
  final rawRef = current[_refKey];
  if (rawRef is String && rawRef.trim().isNotEmpty) {
    final ref = rawRef.trim();
    current.remove(_refKey);
    final target = _lookupRef(ref, root);
    final canExpand =
        target != null &&
        target is! bool &&
        !active.contains(ref) &&
        depth < _maxRefDepth &&
        budget.expansions < _maxRefExpansions;
    if (canExpand) {
      budget.expansions++;
      final resolved = _resolve(
        target,
        root,
        {...active, ref},
        depth + 1,
        budget,
      );
      if (resolved is Map<String, dynamic>) {
        return _overlayAnnotations(resolved, current);
      }
      return resolved;
    }
  }
  return _walk(current, root, active, depth, budget);
}

Map<String, dynamic> _walk(
  Map<String, dynamic> node,
  Map<String, dynamic> root,
  Set<String> active,
  int depth,
  _RefBudget budget,
) {
  final result = <String, dynamic>{};
  node.forEach((key, value) {
    if (_definitionKeys.contains(key)) return;
    if (_schemaMapKeys.contains(key) && value is Map) {
      result[key] = <String, dynamic>{
        for (final entry in value.entries)
          entry.key.toString(): _resolve(
            entry.value,
            root,
            active,
            depth,
            budget,
          ),
      };
      return;
    }
    if (_schemaListKeys.contains(key) && value is List) {
      result[key] = [
        if (value.isNotEmpty)
          _resolve(value.first, root, active, depth, budget),
        if (value.length > 1) ...value.skip(1),
      ];
      return;
    }
    if (key == 'additionalProperties' && !budget.expandAdditionalProperties) {
      result[key] = value;
      return;
    }
    if (_subSchemaKeys.contains(key) && (value is Map || value is List)) {
      result[key] = _resolve(value, root, active, depth, budget);
      return;
    }
    result[key] = value;
  });
  return result;
}

Map<String, dynamic> _overlayAnnotations(
  Map<String, dynamic> target,
  Map<String, dynamic> siblings,
) {
  final result = Map<String, dynamic>.from(target);
  for (final entry in siblings.entries) {
    if (_annotationKeys.contains(entry.key)) result[entry.key] = entry.value;
  }
  return result;
}

dynamic _lookupRef(String ref, Map<String, dynamic> root) {
  if (!ref.startsWith('#')) return null;
  final raw = ref.substring(1);
  if (raw.isEmpty) return root;
  String fragment;
  try {
    fragment = Uri.decodeComponent(raw);
  } catch (_) {
    fragment = raw;
  }
  if (!fragment.startsWith('/')) return null;
  dynamic current = root;
  for (final rawSegment in fragment.substring(1).split('/')) {
    final segment = rawSegment.replaceAll('~1', '/').replaceAll('~0', '~');
    if (current is Map) {
      if (!current.containsKey(segment)) return null;
      current = current[segment];
    } else if (current is List) {
      final index = int.tryParse(segment);
      if (index == null || index < 0 || index >= current.length) return null;
      current = current[index];
    } else {
      return null;
    }
  }
  return current;
}
