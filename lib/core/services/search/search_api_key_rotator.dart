/// 为配置了多个 key 的搜索服务轮换 API key。
///
/// 轮换池为 `[primary, ...extras]`（去空白、去重）。
/// 下一次索引游标按 service id 保存在内存中，与模型 provider 的
/// `ApiKeyManager` 瞬时轮询行为一致。
class SearchApiKeyRotator {
  SearchApiKeyRotator._();

  static final SearchApiKeyRotator instance = SearchApiKeyRotator._();

  final Map<String, int> _indices = {}; // serviceId -> 下一个池索引

  /// 选择 [serviceId] 下一次请求使用的 key。
  ///
  /// 当清洗后的池只有一个 key（例如空 [primary] 加一个
  /// extra）时，直接返回该 key 而不推进游标。当
  /// 池为空时，原样返回原始 [primary]。
  String select(String serviceId, String primary, List<String> extras) {
    final pool = _pool(primary, extras);
    if (pool.isEmpty) return primary;
    if (pool.length == 1) return pool.first;
    final current = _indices[serviceId] ?? 0;
    final index = current % pool.length;
    _indices[serviceId] = (index + 1) % pool.length;
    return pool[index];
  }

  /// 参与轮换的所有 key，按轮换顺序。
  static List<String> rotationPool(String primary, List<String> extras) =>
      _pool(primary, extras);

  /// 将批量粘贴拆分为单个 key。接受以换行、逗号、
  /// 分号或空白分隔的 key；去空白、去重并
  /// 保留顺序。
  static List<String> parseBatch(String input) {
    final seen = <String>{};
    final keys = <String>[];
    for (final part in input.split(RegExp(r'[\s,;]+'))) {
      final key = part.trim();
      if (key.isEmpty || !seen.add(key)) continue;
      keys.add(key);
    }
    return keys;
  }

  /// 对 key 做掩码处理用于展示，保留首尾各四位字符。
  static String mask(String key) {
    final trimmed = key.trim();
    if (trimmed.length <= 8) return '••••••••';
    return '${trimmed.substring(0, 4)}••••${trimmed.substring(trimmed.length - 4)}';
  }

  static List<String> _pool(String primary, List<String> extras) {
    final seen = <String>{};
    final pool = <String>[];
    void add(String key) {
      final trimmed = key.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) return;
      pool.add(trimmed);
    }

    add(primary);
    for (final key in extras) {
      add(key);
    }
    return pool;
  }
}
