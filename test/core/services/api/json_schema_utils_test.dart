import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/api/json_schema_utils.dart';

void main() {
  test('inlines nested local definitions and removes definition blocks', () {
    final resolved = resolveJsonSchemaRefs({
      r'$defs': {
        'Payload': {
          'type': 'object',
          'properties': {
            'value': {'type': 'string'},
          },
        },
      },
      'type': 'object',
      'properties': {
        'payload': {r'$ref': r'#/$defs/Payload'},
      },
    });

    expect(resolved, isNot(contains(r'$defs')));
    expect((resolved['properties'] as Map)['payload'], {
      'type': 'object',
      'properties': {
        'value': {'type': 'string'},
      },
    });
  });

  test('resolves nested refs and overlays annotation siblings', () {
    final resolved = resolveJsonSchemaRefs({
      r'$defs': {
        'Base': {
          'type': 'object',
          'properties': {
            'tag': {r'$ref': r'#/$defs/Tag'},
          },
        },
        'Tag': {'type': 'string'},
      },
      'properties': {
        'item': {
          r'$ref': r'#/$defs/Base',
          'description': 'Item',
          'minLength': 3,
        },
      },
    });

    final item = (resolved['properties'] as Map)['item'] as Map;
    expect(item['description'], 'Item');
    expect(item, isNot(contains('minLength')));
    expect((item['properties'] as Map)['tag'], {'type': 'string'});
  });

  test('leaves data refs, remote refs, and cycles unresolved', () {
    final resolved = resolveJsonSchemaRefs({
      r'$defs': {
        'Loop': {
          'type': 'object',
          'properties': {
            'next': {r'$ref': r'#/$defs/Loop'},
          },
        },
      },
      'properties': {
        'loop': {r'$ref': r'#/$defs/Loop'},
        'remote': {r'$ref': 'https://example.test/schema.json'},
        'data': {
          'default': {r'$ref': r'#/$defs/Loop'},
        },
      },
    });

    final props = resolved['properties'] as Map;
    expect((props['loop'] as Map)['properties']['next'], isA<Map>());
    expect(props['remote'], isA<Map>());
    expect((props['data'] as Map)['default'], {r'$ref': r'#/$defs/Loop'});
  });

  test('supports percent-encoded JSON pointer segments', () {
    final resolved = resolveJsonSchemaRefs({
      r'$defs': {
        'Payload': {'type': 'integer'},
      },
      'properties': {
        'value': {r'$ref': r'#%2F%24defs%2FPayload'},
      },
    });
    expect((resolved['properties'] as Map)['value'], {'type': 'integer'});
  });
}
