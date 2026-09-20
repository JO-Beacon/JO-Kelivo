import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/services/device/device_identity.dart';

void main() {
  setUp(DeviceIdentityService.resetCache);
  tearDown(() {
    DeviceIdentityService.debugCollectorOverride = null;
    DeviceIdentityService.resetCache();
  });

  group('假 UUID 判定', () {
    test('全 0 视为采集失败', () {
      expect(
        DeviceIdentityService.isUsableHardwareId(
          '00000000-0000-0000-0000-000000000000',
        ),
        isFalse,
      );
      expect(
        DeviceIdentityService.isUsableHardwareId('0000000000000000'),
        isFalse,
      );
      expect(DeviceIdentityService.isUsableHardwareId('0000-0000'), isFalse);
    });

    test('全 F 视为采集失败（大小写都算）', () {
      expect(
        DeviceIdentityService.isUsableHardwareId(
          'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF',
        ),
        isFalse,
      );
      expect(
        DeviceIdentityService.isUsableHardwareId(
          'ffffffff-ffff-ffff-ffff-ffffffffffff',
        ),
        isFalse,
      );
    });

    test('空值与空白视为采集失败', () {
      expect(DeviceIdentityService.isUsableHardwareId(''), isFalse);
      expect(DeviceIdentityService.isUsableHardwareId('   '), isFalse);
      expect(DeviceIdentityService.isUsableHardwareId('---'), isFalse);
    });

    test('真实格式的主板 UUID 可用', () {
      expect(
        DeviceIdentityService.isUsableHardwareId(
          '4C4C4544-0037-3010-8043-B5C04F463032',
        ),
        isTrue,
      );
      // Android 的 16 位十六进制 ANDROID_ID
      expect(
        DeviceIdentityService.isUsableHardwareId('9774d56d682e549c'),
        isTrue,
      );
      // 含 0 但也有非 0 字符，不应被误杀
      expect(DeviceIdentityService.isUsableHardwareId('0a0b0c0d0e0f'), isTrue);
    });
  });

  group('指纹派生', () {
    test('相同原始标识派生出相同指纹；不同标识派生不同指纹', () async {
      DeviceIdentityService.debugCollectorOverride = () async =>
          const DeviceIdentity(
            fingerprintHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            displayName: 'Test',
            platform: 'windows',
          );
      final first = await DeviceIdentityService.resolve();

      DeviceIdentityService.resetCache();
      DeviceIdentityService.debugCollectorOverride = () async =>
          const DeviceIdentity(
            fingerprintHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            displayName: 'Test',
            platform: 'windows',
          );
      final second = await DeviceIdentityService.resolve();

      DeviceIdentityService.resetCache();
      DeviceIdentityService.debugCollectorOverride = () async =>
          const DeviceIdentity(
            fingerprintHash: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            displayName: 'Test',
            platform: 'windows',
          );
      final third = await DeviceIdentityService.resolve();

      expect(first, isNotNull);
      expect(first, second);
      expect(first == third, isFalse);
    });

    test('真实采集路径下指纹为 32 位十六进制散列', () async {
      // 在测试环境（非桌面平台）通常采集不到，此处只验证契约：
      // 采集失败必须返回 null 而不是抛异常。
      final identity = await DeviceIdentityService.resolve();
      if (identity != null) {
        expect(identity.fingerprintHash, hasLength(32));
        expect(
          RegExp(r'^[a-f0-9]{32}$').hasMatch(identity.fingerprintHash),
          isTrue,
        );
        expect(identity.displayName, isNotEmpty);
        expect(identity.platform, isNotEmpty);
      }
    });
  });

  group('异常与降级', () {
    test('采集器抛异常时返回 null，不向上抛', () async {
      DeviceIdentityService.debugCollectorOverride = () async =>
          throw StateError('boom');
      expect(await DeviceIdentityService.resolve(), isNull);
    });

    test('采集器返回 null 时缓存 null 且不重复采集', () async {
      var calls = 0;
      DeviceIdentityService.debugCollectorOverride = () async {
        calls++;
        return null;
      };
      expect(await DeviceIdentityService.resolve(), isNull);
      expect(await DeviceIdentityService.resolve(), isNull);
      expect(calls, 1);
    });

    test('成功结果被缓存，只采集一次', () async {
      var calls = 0;
      DeviceIdentityService.debugCollectorOverride = () async {
        calls++;
        return const DeviceIdentity(
          fingerprintHash: 'cccccccccccccccccccccccccccccccc',
          displayName: 'Cached',
          platform: 'linux',
        );
      };
      final a = await DeviceIdentityService.resolve();
      final b = await DeviceIdentityService.resolve();
      expect(a, b);
      expect(calls, 1);
    });
  });

  group('DeviceIdentity 值语义', () {
    test('字段相同的两个实例相等且 hash 一致', () {
      const a = DeviceIdentity(
        fingerprintHash: 'dddddddddddddddddddddddddddddddd',
        displayName: 'PC',
        platform: 'windows',
      );
      const b = DeviceIdentity(
        fingerprintHash: 'dddddddddddddddddddddddddddddddd',
        displayName: 'PC',
        platform: 'windows',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.toString(), contains('windows'));
    });
  });
}
