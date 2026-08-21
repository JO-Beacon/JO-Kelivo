import 'dart:convert';

import '../database/business_preferences.dart';

/// 用于将整个列表作为一个 JSON blob 持久化的存储基类。
///
/// 变更操作通过每个实例的串行队列执行，因此并发的读-改-写循环不会相互丢失记录。
/// 解码失败的 blob 会抛出异常，而不是读取为空，因此截断的快照
/// 永远不会覆盖仍存在的行而被持久化。
abstract class JsonBlobStore<T> {
  JsonBlobStore(this._preferences);

  final BusinessPreferences _preferences;
  Future<void> _writeTail = Future<void>.value();

  /// 暴露给除 blob 之外还需管理其他键的子类。
  BusinessPreferences get preferences => _preferences;

  String get storageKey;

  T decodeItem(Map<String, dynamic> json);

  Map<String, dynamic> encodeItem(T item);

  /// 读取整个 blob。解码失败时抛出 [StateError]。
  Future<List<T>> readAll() async {
    await _preferences.load();
    final raw = _preferences.getString(storageKey);
    if (raw == null || raw.isEmpty) return <T>[];
    return decodeAll(raw);
  }

  List<T> decodeAll(String raw) {
    try {
      final values = jsonDecode(raw) as List<dynamic>;
      return <T>[
        for (final value in values)
          decodeItem((value as Map).cast<String, dynamic>()),
      ];
    } catch (_) {
      throw StateError('json_blob_store_corrupt:$storageKey');
    }
  }

  /// 持久化完整列表。调用方必须传入其完整的预期快照；
  /// 部分读取必须先通过 [readAll] 完成。
  Future<void> writeAll(List<T> items) {
    return _preferences.setString(
      storageKey,
      jsonEncode(items.map(encodeItem).toList()),
    );
  }

  /// 在所有先前接受的操作处理完后运行 [operation]。
  Future<R> runExclusive<R>(Future<R> Function() operation) {
    final result = _writeTail.then((_) => operation());
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }
}
