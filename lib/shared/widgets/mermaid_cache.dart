class MermaidHeightCache {
  // 带最大容量的简单近似 LRU 缓存；超过上限时淘汰最早插入项。
  static final Map<String, double> _map = <String, double>{};
  static int _maxSize = 200;

  static void configure({int? maxSize}) {
    if (maxSize != null && maxSize > 0) _maxSize = maxSize;
  }

  static double? get(String code) {
    final v = _map[code];
    if (v != null) {
      // 触摸条目以刷新最近使用状态：移除后重新插入
      _map.remove(code);
      _map[code] = v;
    }
    return v;
  }

  static void put(String code, double height) {
    // 基础保护：只存储合理的高度
    final h = height.isFinite ? height.clamp(60, 4000).toDouble() : 160.0;
    if (_map.containsKey(code)) {
      _map.remove(code);
      _map[code] = h;
    } else {
      if (_map.length >= _maxSize) {
        // 淘汰第一个或最早的条目
        final firstKey = _map.keys.isNotEmpty ? _map.keys.first : null;
        if (firstKey != null) _map.remove(firstKey);
      }
      _map[code] = h;
    }
  }
}
