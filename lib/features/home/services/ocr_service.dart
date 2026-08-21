import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';

/// OCR 缓存条目
class OcrCacheEntry {
  OcrCacheEntry({required this.text});
  final String text;
}

/// 不受进程 LRU 约束的单次 prepare OCR 状态。
///
/// 每个并发会话 prepare 拥有自己的 session，使快照不会
/// 互相覆盖。
class OcrPrepareSession {
  final Map<String, String> hashesByPath = <String, String>{};
  final Map<String, String> artifactTextsByHash = <String, String>{};
  final Map<String, Map<String, String>> artifactsByRevision =
      <String, Map<String, String>>{};
  final Set<String> loadedRevisionIds = <String>{};

  int get artifactSize => artifactTextsByHash.length;
}

/// OCR 图片处理服务
///
/// 功能：
/// - 运行 OCR 识别图片内容
/// - 管理 OCR 缓存（内存 LRU → 请求级 artifact 快照 → SQLite → OCR 模型）
/// - 包装 OCR 结果为 XML 格式
class OcrService {
  OcrService({
    this.maxCacheEntries = 48,
    this.resolveContentHashes,
    this.loadArtifacts,
    this.persistArtifact,
    this.ocrExecutor,
    this.onError,
  });

  static const String artifactKind = 'image_ocr_v1';
  static const String memoryKeyPrefix = 'image_ocr_v1:';

  /// LRU 缓存最大条目数
  final int maxCacheEntries;

  /// 解析图片路径/data-URL → 内容 SHA-256。
  final Future<Map<String, String>> Function(List<String> imagePaths)?
  resolveContentHashes;

  /// 按 revision ID 批量加载已持久化的 OCR 条目。
  final Future<Map<String, Map<String, String>>> Function(
    List<String> revisionIds,
  )?
  loadArtifacts;

  /// 为某 revision 持久化 OCR 条目（合并 upsert）。失败不得向
  /// 已持有当前请求 OCR 文本的调用方抛出。
  final Future<void> Function(String revisionId, Map<String, String> items)?
  persistArtifact;

  /// 可选的 OCR 后端覆盖（测试用）。为 null 时使用 ChatApiService。
  final Future<String?> Function(List<String> imagePaths)? ocrExecutor;

  /// 上报 OCR 模型请求失败，但不中断聊天请求。
  void Function(Object error)? onError;

  /// OCR 缓存 (memoryKey -> cached OCR text)
  final Map<String, OcrCacheEntry> _cache = <String, OcrCacheEntry>{};

  /// LRU 顺序列表 (最旧的在前)
  final List<String> _cacheOrder = <String>[];

  /// 获取缓存条目数量（用于测试/调试）
  int get cacheSize => _cache.length;

  /// 清除缓存
  void clearCache() {
    _cache.clear();
    _cacheOrder.clear();
  }

  static String memoryKeyForContentHash(String contentHash) {
    return '$memoryKeyPrefix$contentHash';
  }

  /// 运行 OCR 识别图片内容
  ///
  /// [imagePaths] 图片路径列表
  /// [context] BuildContext 用于获取 SettingsProvider
  ///
  /// 返回识别的文本内容，失败时返回 null
  Future<String?> runOcrForImages(
    List<String> imagePaths,
    BuildContext context,
  ) async {
    if (imagePaths.isEmpty) return null;
    if (ocrExecutor != null) {
      final out = (await ocrExecutor!(imagePaths))?.trim();
      return (out == null || out.isEmpty) ? null : out;
    }

    final settings = context.read<SettingsProvider>();
    final prov = settings.ocrModelProvider;
    final model = settings.ocrModelId;
    if (prov == null || model == null) return null;

    final cfg = settings.getProviderConfig(prov);

    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': settings.ocrPrompt},
      {
        'role': 'user',
        'content':
            'Please perform OCR on the attached image(s) and return only the extracted text and visual descriptions.',
      },
    ];

    final stream = ChatApiService.sendMessageStream(
      config: cfg,
      modelId: model,
      messages: messages,
      userImagePaths: imagePaths,
      thinkingBudget: settings.ocrGenerationThinkingBudgetFor(null),
      topP: null,
      maxTokens: null,
      tools: null,
      onToolCall: null,
      extraHeaders: null,
      extraBody: null,
      stream: false,
      ocrActive: true,
    );

    String out = '';
    try {
      await for (final chunk in stream) {
        if (chunk.content.isNotEmpty) {
          out += chunk.content;
        }
      }
    } catch (e) {
      onError?.call(e);
      return null;
    }
    out = out.trim();
    if (out.isEmpty) {
      onError?.call('empty_response');
      return null;
    }
    return out;
  }

  /// 缓存 OCR 文本结果（按内容哈希）
  void cacheOcrText(String contentHash, String text) {
    final hash = contentHash.trim();
    if (hash.isEmpty) return;
    final key = memoryKeyForContentHash(hash);

    _cache[key] = OcrCacheEntry(text: text);
    _cacheOrder.remove(key);
    _cacheOrder.add(key);

    // LRU 淘汰：移除最旧的条目
    while (_cacheOrder.length > maxCacheEntries) {
      final oldest = _cacheOrder.removeAt(0);
      _cache.remove(oldest);
    }
  }

  /// 获取缓存的 OCR 文本
  ///
  /// 返回缓存的文本，不存在时返回 null
  /// 访问时会更新 LRU 顺序
  String? getCachedOcrText(String contentHash) {
    final hash = contentHash.trim();
    if (hash.isEmpty) return null;
    final key = memoryKeyForContentHash(hash);

    final entry = _cache[key];
    if (entry != null) {
      // 提升为最近使用
      _cacheOrder.remove(key);
      _cacheOrder.add(key);
      return entry.text;
    }
    return null;
  }

  String? _lookupCachedText(String contentHash, OcrPrepareSession? session) {
    final sessionText = session?.artifactTextsByHash[contentHash]?.trim();
    if (sessionText != null && sessionText.isNotEmpty) return sessionText;
    final memoryText = getCachedOcrText(contentHash)?.trim();
    if (memoryText != null && memoryText.isNotEmpty) return memoryText;
    return null;
  }

  void _rememberRequestText(
    String contentHash,
    String text,
    OcrPrepareSession? session,
  ) {
    final hash = contentHash.trim();
    final trimmed = text.trim();
    if (hash.isEmpty || trimmed.isEmpty) return;
    if (session != null) {
      session.artifactTextsByHash[hash] = trimmed;
    }
    cacheOcrText(hash, trimmed);
  }

  /// 为单次 prepare/send 预取哈希与 SQLite OCR。
  ///
  /// 返回由调用方拥有的隔离 session。并发 prepare 不得
  /// 共享此对象。
  Future<OcrPrepareSession> prefetchPersistedOcr({
    required List<String> revisionIds,
    required List<String> imagePaths,
  }) async {
    final session = OcrPrepareSession();

    final paths = <String>[
      ...{
        for (final path in imagePaths)
          if (path.trim().isNotEmpty) path.trim(),
      },
    ];
    if (paths.isNotEmpty && resolveContentHashes != null) {
      try {
        session.hashesByPath.addAll(await resolveContentHashes!(paths));
      } catch (_) {}
    }

    final ids = revisionIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    session.loadedRevisionIds.addAll(ids);

    if (ids.isEmpty || loadArtifacts == null) return session;

    Map<String, Map<String, String>> artifacts;
    try {
      artifacts = await loadArtifacts!(ids);
    } catch (_) {
      return session;
    }

    for (final entry in artifacts.entries) {
      final revisionItems = <String, String>{};
      for (final item in entry.value.entries) {
        final hash = item.key.trim();
        final text = item.value.trim();
        if (hash.isEmpty || text.isEmpty) continue;
        revisionItems[hash] = text;
        session.artifactTextsByHash[hash] = text;
        cacheOcrText(hash, text);
      }
      if (revisionItems.isNotEmpty) {
        session.artifactsByRevision[entry.key] = revisionItems;
      }
    }
    return session;
  }

  /// 获取图片的 OCR 文本（优先使用缓存）
  ///
  /// [imagePaths] 图片路径列表
  /// [context] BuildContext 用于获取 SettingsProvider
  /// [revisionId] 带图 user 消息 revision，用于 SQLite 持久化
  /// [session] 是每次 prepare 的、来自 [prefetchPersistedOcr] 的可选快照
  ///
  /// 返回合并后的 OCR 文本，失败时返回 null
  Future<String?> getOcrTextForImages(
    List<String> imagePaths,
    BuildContext context, {
    String? revisionId,
    OcrPrepareSession? session,
  }) async {
    if (imagePaths.isEmpty) return null;

    // 测试替身注入 ocrExecutor 并跳过 SettingsProvider 装配。
    if (ocrExecutor == null) {
      final settings = context.read<SettingsProvider>();
      if (!(settings.ocrEnabled &&
          settings.ocrModelProvider != null &&
          settings.ocrModelId != null)) {
        return null;
      }
    }

    final paths = imagePaths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    if (paths.isEmpty) return null;

    final hashesByPath = <String, String>{};
    final unresolved = <String>[];
    for (final path in paths) {
      final cachedHash = session?.hashesByPath[path]?.trim();
      if (cachedHash != null && cachedHash.isNotEmpty) {
        hashesByPath[path] = cachedHash;
      } else if (!unresolved.contains(path)) {
        unresolved.add(path);
      }
    }
    if (unresolved.isNotEmpty && resolveContentHashes != null) {
      try {
        final resolved = await resolveContentHashes!(unresolved);
        for (final entry in resolved.entries) {
          final hash = entry.value.trim();
          if (hash.isEmpty) continue;
          hashesByPath[entry.key] = hash;
          session?.hashesByPath[entry.key] = hash;
        }
      } catch (_) {}
    }

    final normalizedRevisionId = revisionId?.trim();
    final hasRevision =
        normalizedRevisionId != null && normalizedRevisionId.isNotEmpty;

    // 仅当该 revision 不在批量预取范围内时才在此访问 SQLite。
    if (hasRevision &&
        loadArtifacts != null &&
        (session == null ||
            !session.loadedRevisionIds.contains(normalizedRevisionId))) {
      try {
        final artifacts = await loadArtifacts!([normalizedRevisionId]);
        final items = artifacts[normalizedRevisionId] ?? const {};
        session?.loadedRevisionIds.add(normalizedRevisionId);
        if (items.isNotEmpty) {
          final revisionItems = <String, String>{
            for (final entry in items.entries)
              if (entry.key.trim().isNotEmpty && entry.value.trim().isNotEmpty)
                entry.key.trim(): entry.value.trim(),
          };
          if (revisionItems.isNotEmpty) {
            session?.artifactsByRevision[normalizedRevisionId] = {
              ...session.artifactsByRevision[normalizedRevisionId] ?? const {},
              ...revisionItems,
            };
            for (final entry in revisionItems.entries) {
              _rememberRequestText(entry.key, entry.value, session);
            }
          }
        }
      } catch (_) {}
    }

    final existingForRevision = hasRevision
        ? <String, String>{
            ...session?.artifactsByRevision[normalizedRevisionId] ?? const {},
          }
        : const <String, String>{};

    final combined = StringBuffer();
    final toPersist = <String, String>{};

    for (final path in paths) {
      final hash = hashesByPath[path]?.trim();
      if (hash != null && hash.isNotEmpty) {
        final cached = _lookupCachedText(hash, session);
        if (cached != null) {
          combined.writeln(cached);
          _rememberRequestText(hash, cached, session);
          if (hasRevision && !existingForRevision.containsKey(hash)) {
            toPersist[hash] = cached;
          }
          continue;
        }
      }

      if (!context.mounted) break;
      final text = await runOcrForImages([path], context);
      if (text != null && text.trim().isNotEmpty) {
        final t = text.trim();
        if (hash != null && hash.isNotEmpty) {
          _rememberRequestText(hash, t, session);
          if (hasRevision) {
            toPersist[hash] = t;
          }
        }
        combined.writeln(t);
      }
    }

    if (toPersist.isNotEmpty && hasRevision && persistArtifact != null) {
      try {
        await persistArtifact!(normalizedRevisionId, toPersist);
        if (session != null) {
          session.artifactsByRevision[normalizedRevisionId] = {
            ...session.artifactsByRevision[normalizedRevisionId] ?? const {},
            ...toPersist,
          };
        }
      } catch (_) {
        // 持久化失败不得阻塞当前聊天轮次。
      }
    }

    final out = combined.toString().trim();
    return out.isEmpty ? null : out;
  }

  /// 包装 OCR 文本为 XML 格式
  ///
  /// [ocrText] OCR 识别的原始文本
  ///
  /// 返回包装后的 XML 格式文本
  String wrapOcrBlock(String ocrText) {
    final buf = StringBuffer();
    buf.writeln(
      "The image_file_ocr tag contains a description of an image that the user uploaded to you, not the user's prompt.",
    );
    buf.writeln('<image_file_ocr>');
    buf.writeln(ocrText.trim());
    buf.writeln('</image_file_ocr>');
    buf.writeln();
    return buf.toString();
  }
}
