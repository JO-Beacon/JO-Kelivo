import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import '../../database/business_repository.dart';
import '../../database/business_settings_router.dart';
import '../../models/api_keys.dart';
import '../../models/backup.dart';
import '../../models/chat_message.dart';
import '../../models/conversation.dart';
import '../../models/message_part.dart';
import '../chat/chat_service.dart';
import '../../../utils/app_directories.dart';
import '../../../utils/sandbox_path_resolver.dart';
import 'cherry_direct_backup_reader.dart';

export 'cherry_direct_backup_reader.dart'
    show CherryUnsupportedBackupVersionException;

class CherryImportResult {
  final int providers;
  final int assistants;
  final int conversations;
  final int messages;
  final int files;
  const CherryImportResult({
    required this.providers,
    required this.assistants,
    required this.conversations,
    required this.messages,
    required this.files,
  });
}

class CherryImporter {
  CherryImporter._();

  // 业务设置路由器使用的已发布备份键。
  static const String _providersKey = 'provider_configs_v1';
  static const String _providersOrderKey = 'providers_order_v1';
  static const String _assistantsKey = 'assistants_v1';

  static Future<CherryImportResult> importFromCherryStudio({
    required File file,
    required RestoreMode mode,
    required BusinessRepository businessRepository,
    required ChatService chatService,
  }) async {
    // 1) 从 ZIP/BAK 加载 JSON（尽力而为）
    final Map<String, dynamic> root = await _readCherryBackupFile(file);

    // 2) 基本校验
    final version = (root['version'] as num?)?.toInt() ?? 0;
    if (version < 2) {
      throw Exception('Unsupported Cherry backup version: $version');
    }

    // 3) 解析 localStorage persist:cherry-studio（Redux persist）
    final localStorage =
        (root['localStorage'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v),
        ) ??
        const <String, dynamic>{};
    final persistStr = (localStorage['persist:cherry-studio'] ?? '') as String;
    if (persistStr.isEmpty) {
      throw Exception('Missing localStorage["persist:cherry-studio"]');
    }
    late Map<String, dynamic> persistObj;
    try {
      persistObj = jsonDecode(persistStr) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('Invalid persist:cherry-studio JSON');
    }

    // persist 中的 slices 也是 JSON 编码的字符串
    Map<String, dynamic> assistantsSlice = const {};
    Map<String, dynamic> llmSlice = const {};
    try {
      final aStr = (persistObj['assistants'] ?? '') as String;
      if (aStr.isNotEmpty) {
        assistantsSlice = jsonDecode(aStr) as Map<String, dynamic>;
      }
    } catch (_) {}
    try {
      final lStr = (persistObj['llm'] ?? '') as String;
      if (lStr.isNotEmpty) {
        llmSlice = jsonDecode(lStr) as Map<String, dynamic>;
      }
    } catch (_) {}

    final List<dynamic> cherryProviders =
        (llmSlice['providers'] as List?) ?? const <dynamic>[];
    final Map<String, dynamic> assistantsRoot = assistantsSlice;
    final List<dynamic> cherryAssistants =
        (assistantsRoot['assistants'] as List?) ?? const <dynamic>[];

    // 4) IndexedDB
    final indexedDB =
        (root['indexedDB'] as Map?)?.map((k, v) => MapEntry(k.toString(), v)) ??
        const <String, dynamic>{};
    final List<dynamic> cherryFiles =
        (indexedDB['files'] as List?) ?? const <dynamic>[];
    final List<dynamic> cherryTopicsWithMessages =
        (indexedDB['topics'] as List?) ?? const <dynamic>[];
    final List<dynamic> cherryMessageBlocks =
        (indexedDB['message_blocks'] as List?) ?? const <dynamic>[];

    // 从 assistants[].topics[] 构建主题元数据映射
    final Map<String, Map<String, dynamic>> topicMeta =
        <String, Map<String, dynamic>>{};
    for (final a in cherryAssistants) {
      if (a is! Map) continue;
      final topics = (a['topics'] as List?) ?? const <dynamic>[];
      for (final t in topics) {
        if (t is Map && t['id'] != null) {
          final id = t['id'].toString();
          topicMeta[id] = t.map((k, v) => MapEntry(k.toString(), v));
          final tm = topicMeta[id]!;
          final parentAssistantId = (a['id'] ?? '').toString();
          final topicAssistantId = (t['assistantId'] ?? '').toString();
          // Cherry 可能保留过期的 topic.assistantId；父级 assistant 的
          // topic 列表才是可靠的所有权来源。
          final ownerAssistantId = parentAssistantId.isNotEmpty
              ? parentAssistantId
              : topicAssistantId;
          if (ownerAssistantId.isNotEmpty) {
            tm['assistantId'] = ownerAssistantId;
          }
        }
      }
    }

    // 构建 topicId -> messages 映射
    final Map<String, List<Map<String, dynamic>>> topicMessages =
        <String, List<Map<String, dynamic>>>{};
    for (final e in cherryTopicsWithMessages) {
      if (e is! Map) continue;
      final id = (e['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final msgs = (e['messages'] as List?) ?? const <dynamic>[];
      topicMessages[id] = [
        for (final m in msgs)
          if (m is Map) m.map((k, v) => MapEntry(k.toString(), v)),
      ];
    }

    // 构建 messageId -> 从 message_blocks 重建的文本映射（用于 message.content 为空的情况）
    final Map<String, String> blockTextByMessageId = <String, String>{};
    for (final b in cherryMessageBlocks) {
      if (b is! Map) continue;
      final type = (b['type'] ?? '').toString();
      final messageId = (b['messageId'] ?? '').toString();
      if (messageId.isEmpty) continue;
      // 只包含可读的 blocks
      if (type == 'main_text') {
        final content = (b['content'] ?? '').toString();
        if (content.isNotEmpty) {
          final prev = blockTextByMessageId[messageId];
          blockTextByMessageId[messageId] = prev == null || prev.isEmpty
              ? content
              : '$prev\n$content';
        }
      } else if (type == 'code') {
        final code = (b['content'] ?? '').toString();
        final lang = (b['language'] ?? '').toString();
        if (code.isNotEmpty) {
          final fenced = '```$lang\n$code\n```';
          final prev = blockTextByMessageId[messageId];
          blockTextByMessageId[messageId] = prev == null || prev.isEmpty
              ? fenced
              : '$prev\n$fenced';
        }
      } else if (type == 'error') {
        final err = (b['content'] ?? '').toString();
        if (err.isNotEmpty) {
          final tagged = '> Error\n> ${err.replaceAll('\n', '\n> ')}';
          final prev = blockTextByMessageId[messageId];
          blockTextByMessageId[messageId] = prev == null || prev.isEmpty
              ? tagged
              : '$prev\n$tagged';
        }
      } else if (type == 'thinking') {
        // 可选：在纯文本中作为类似可折叠的部分包含
        final think = (b['content'] ?? '').toString();
        if (think.isNotEmpty) {
          final wrapped = '<think>\n$think\n</think>';
          final prev = blockTextByMessageId[messageId];
          blockTextByMessageId[messageId] = prev == null || prev.isEmpty
              ? wrapped
              : '$prev\n$wrapped';
        }
      }
    }

    // 5) 在打开单一写事务之前解析业务数据。
    final importedProviders = _parseProviders(cherryProviders);
    final importedAssistants = _parseAssistants(cherryAssistants);
    await _importBusinessData(
      businessRepository: businessRepository,
      mode: mode,
      providers: importedProviders,
      assistants: importedAssistants,
    );

    // 如果覆盖，则在写入任何上传内容之前先清除 chats/files，以免稍后被删除
    if (!chatService.initialized) {
      await chatService.init();
    }
    if (mode == RestoreMode.overwrite) {
      await chatService.clearAllData();
    }

    // 7) 准备文件（仅当消息引用了这些文件时）
    final filesById = <String, Map<String, dynamic>>{
      for (final f in cherryFiles)
        if (f is Map && f['id'] != null)
          f['id'].toString(): f.map((k, v) => MapEntry(k.toString(), v)),
    };

    // 预计算已使用的文件 ID
    final usedFileIds = <String>{};
    for (final entry in topicMessages.entries) {
      for (final m in entry.value) {
        final files = (m['files'] as List?) ?? const <dynamic>[];
        for (final rf in files) {
          if (rf is Map && rf['id'] != null) {
            usedFileIds.add(rf['id'].toString());
          }
        }
      }
    }

    // 当存在 'file' 对象时，也纳入 message_blocks 引用的文件
    for (final b in cherryMessageBlocks) {
      if (b is! Map) continue;
      final fileObj = (b['file'] as Map?)?.map(
        (k, v) => MapEntry(k.toString(), v),
      );
      final fid = (fileObj?['id'] ?? '').toString();
      if (fid.isNotEmpty) usedFileIds.add(fid);
    }

    // 将引用的文件写入 Documents/upload 并构建路径映射
    final pathsByFileId = await _materializeFiles(
      filesById,
      usedFileIds,
      backupArchive: file,
    );

    // 构建 message_blocks 中额外附件（images/files）的映射（这些附件未出现在 message.files 中）
    final Map<String, List<_PendingAttachmentRef>> pendingAttachmentsByMessage =
        <String, List<_PendingAttachmentRef>>{};
    for (final b in cherryMessageBlocks) {
      if (b is! Map) continue;
      final type = (b['type'] ?? '').toString();
      final messageId = (b['messageId'] ?? '').toString();
      if (messageId.isEmpty) continue;
      final fileObj = (b['file'] as Map?)?.map(
        (k, v) => MapEntry(k.toString(), v),
      );
      final url = (b['url'] ?? '').toString();
      final isImageType =
          type.toLowerCase().contains('image') ||
          (fileObj?['type']?.toString().toLowerCase().startsWith('image') ??
              false);
      if (fileObj != null && (fileObj['id'] ?? '').toString().isNotEmpty) {
        final originPath = (fileObj['path'] ?? '').toString().trim();
        (pendingAttachmentsByMessage[messageId] ??= <_PendingAttachmentRef>[])
            .add(
              _PendingAttachmentRef(
                fileId: (fileObj['id'] ?? '').toString(),
                name: (fileObj['origin_name'] ?? fileObj['name'] ?? '')
                    .toString(),
                mime: (fileObj['type'] ?? '').toString(),
                originPath: originPath.isNotEmpty ? originPath : null,
                isImage: isImageType,
              ),
            );
      } else if (url.isNotEmpty) {
        if (url.startsWith('data:image')) {
          (pendingAttachmentsByMessage[messageId] ??= <_PendingAttachmentRef>[])
              .add(_PendingAttachmentRef(dataUrl: url, isImage: true));
        } else {
          (pendingAttachmentsByMessage[messageId] ??= <_PendingAttachmentRef>[])
              .add(_PendingAttachmentRef(url: url, isImage: isImageType));
        }
      }
    }

    // 8) 将 topics 与 messages 导入 ChatService
    final convCountAndMsgCount = await _importConversations(
      topicMeta: topicMeta,
      topicMessages: topicMessages,
      filePaths: pathsByFileId,
      chatService: chatService,
      mode: mode,
      blockTexts: blockTextByMessageId,
      pendingAttachmentsByMessage: pendingAttachmentsByMessage,
    );

    return CherryImportResult(
      providers: importedProviders.length,
      assistants: importedAssistants.length,
      conversations: convCountAndMsgCount.$1,
      messages: convCountAndMsgCount.$2,
      files: pathsByFileId.length + convCountAndMsgCount.$3,
    );
  }

  // ---------- 辅助函数 ----------

  /// 仅用于*推测性* ZIP 条目探测的上限（未知 / 非 `.json` 名称）。
  static const int defaultSpeculativeJsonProbeBytes = 32 * 1024 * 1024;

  /// 仅针对归档内已识别的 `.json` 条目的绝对上限。
  /// 整个文件 JSON 和 gunzipped JSON 仍不受上限限制。
  static const int defaultIdentifiedArchiveJsonBytes = 256 * 1024 * 1024;

  /// 测试接缝，用于在无需大型 fixture 的情况下缩小推测性探测预算。
  @visibleForTesting
  static int? debugSpeculativeJsonProbeBytes;

  /// 测试接缝，用于归档内已识别的 `.json` 上限。
  @visibleForTesting
  static int? debugIdentifiedArchiveJsonBytes;

  @visibleForTesting
  static int get speculativeJsonProbeBytes =>
      debugSpeculativeJsonProbeBytes ?? defaultSpeculativeJsonProbeBytes;

  @visibleForTesting
  static int get identifiedArchiveJsonBytes =>
      debugIdentifiedArchiveJsonBytes ?? defaultIdentifiedArchiveJsonBytes;

  /// 统计 JSON 探测过程中对 ZIP 条目内容的访问次数（不含元数据）。
  @visibleForTesting
  static int debugZipJsonProbeDecodeCount = 0;

  @visibleForTesting
  static void debugResetJsonProbeBudgets() {
    debugSpeculativeJsonProbeBytes = null;
    debugIdentifiedArchiveJsonBytes = null;
    debugZipJsonProbeDecodeCount = 0;
  }

  static const Set<String> _blockedSpeculativeProbeExtensions = <String>{
    '.sqlite',
    '.db',
    '.ldb',
    '.log',
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.pdf',
    '.bin',
    '.exe',
    '.dll',
    '.so',
    '.dylib',
    '.wasm',
    '.mp3',
    '.mp4',
    '.wav',
    '.zip',
    '.gz',
  };

  static String _entryBaseName(String name) {
    final normalized = name.replaceAll('\\', '/').toLowerCase();
    return normalized.split('/').last;
  }

  /// 以 `.json` 结尾的归档条目会被视为已识别的 JSON 目标。
  @visibleForTesting
  static bool isIdentifiedJsonEntryName(String name) {
    return _entryBaseName(name).endsWith('.json');
  }

  /// 当 [name] 没有目录组成部分（归档根条目）时返回 true。
  @visibleForTesting
  static bool isArchiveRootEntryName(String name) {
    var normalized = name.replaceAll('\\', '/');
    while (normalized.startsWith('./')) {
      normalized = normalized.substring(2);
    }
    while (normalized.startsWith('/')) {
      normalized = normalized.substring(1);
    }
    return normalized.isNotEmpty && !normalized.contains('/');
  }

  /// 判断非 `.json` ZIP 条目是否可以作为推测性 JSON 探测进行解压。
  /// 在访问 [ArchiveFile.content]（该操作会解压并缓存）之前，
  /// 会先依据 [speculativeJsonProbeBytes] 检查大小。
  @visibleForTesting
  static bool isSpeculativeJsonEntryCandidate(String name, int size) {
    if (size <= 0 || size > speculativeJsonProbeBytes) return false;
    if (isIdentifiedJsonEntryName(name)) return false;
    final base = _entryBaseName(name);
    for (final ext in _blockedSpeculativeProbeExtensions) {
      if (base.endsWith(ext)) return false;
    }
    return true;
  }

  /// 判断归档内 `.json` 条目是否可以解压。该操作受
  /// [identifiedArchiveJsonBytes] 限制，以免嵌套附件转储导致 OOM。
  @visibleForTesting
  static bool isIdentifiedArchiveJsonEntryCandidate(String name, int size) {
    if (size <= 0 || size > identifiedArchiveJsonBytes) return false;
    return isIdentifiedJsonEntryName(name);
  }

  static bool _looksLikeZip(List<int> bytes) {
    return bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4b &&
        (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07) &&
        (bytes[3] == 0x04 || bytes[3] == 0x06 || bytes[3] == 0x08);
  }

  static bool _looksLikeGzip(List<int> bytes) {
    return bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
  }

  static Map<String, dynamic>? _tryParseBackupJson(String text) {
    try {
      final obj = jsonDecode(text) as Map<String, dynamic>;
      if (obj.containsKey('localStorage') && obj.containsKey('indexedDB')) {
        return obj;
      }
    } catch (_) {}
    return null;
  }

  static Map<String, dynamic>? _tryDecodeBackupJsonBytes(
    List<int> raw, {
    required bool allowMalformed,
  }) {
    try {
      return _tryParseBackupJson(
        utf8.decode(raw, allowMalformed: allowMalformed),
      );
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _tryParseZipJsonEntry(
    ArchiveFile entry, {
    required bool identified,
  }) {
    if (!entry.isFile || entry.size <= 0) return null;
    if (identified) {
      if (!isIdentifiedArchiveJsonEntryCandidate(entry.name, entry.size)) {
        return null;
      }
    } else if (!isSpeculativeJsonEntryCandidate(entry.name, entry.size)) {
      return null;
    }
    try {
      debugZipJsonProbeDecodeCount++;
      final raw = entry.content;
      if (identified) {
        if (raw.length > identifiedArchiveJsonBytes) return null;
      } else if (raw.length > speculativeJsonProbeBytes) {
        return null;
      }
      return _tryDecodeBackupJsonBytes(raw, allowMalformed: identified);
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> _readCherryBackupFile(File file) async {
    final bytes = await file.readAsBytes();

    // 整个文件 JSON（非 ZIP/GZIP）：不受上限限制，allowMalformed。
    if (!_looksLikeZip(bytes) && !_looksLikeGzip(bytes)) {
      final obj = _tryDecodeBackupJsonBytes(bytes, allowMalformed: true);
      if (obj != null) return obj;
    }

    // ZIP：在任何条目探测之前，先通过 metadata.json 进行版本门控。
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      CherryDirectBackupReader.readMetadataOrThrowIfUnsupported(archive);
      for (final entry in archive) {
        if (!isArchiveRootEntryName(entry.name)) continue;
        final obj = _tryParseZipJsonEntry(entry, identified: true);
        if (obj != null) return obj;
      }
      for (final entry in archive) {
        if (isArchiveRootEntryName(entry.name)) continue;
        final obj = _tryParseZipJsonEntry(entry, identified: true);
        if (obj != null) return obj;
      }
      for (final entry in archive) {
        final obj = _tryParseZipJsonEntry(entry, identified: false);
        if (obj != null) return obj;
      }
      final directBackup = CherryDirectBackupReader.readArchive(archive);
      if (directBackup != null) return directBackup;
    } on CherryUnsupportedBackupVersionException {
      rethrow;
    } catch (_) {}

    // GZIP JSON 载荷：不受上限限制，allowMalformed。
    if (_looksLikeGzip(bytes)) {
      try {
        final gunzipped = GZipDecoder().decodeBytes(bytes, verify: false);
        final obj = _tryDecodeBackupJsonBytes(gunzipped, allowMalformed: true);
        if (obj != null) return obj;
      } catch (_) {}
    }

    throw Exception('Unable to read Cherry backup file');
  }

  static Map<String, Map<String, dynamic>> _parseProviders(
    List<dynamic> cherryProviders,
  ) {
    // 构建导入的 id -> ProviderConfig 类 JSON 映射
    final imported = <String, Map<String, dynamic>>{};

    for (final p in cherryProviders) {
      if (p is! Map) continue;
      final id = (p['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final type = (p['type'] ?? '').toString().toLowerCase();
      final name = (p['name'] ?? id).toString();
      final apiKeyRaw = (p['apiKey'] ?? '').toString();
      final apiHostRaw = (p['apiHost'] ?? '').toString().trim();

      // 解析逗号分隔的 API keys（Cherry Studio 将多个 key 存储在一个字符串中）
      final apiKeys = _splitApiKeyString(apiKeyRaw);
      final apiKey = apiKeys.isNotEmpty ? apiKeys.first : '';
      final multiKeyEnabled = apiKeys.length > 1;

      // 确定 provider kind 映射
      String? kind;
      switch (type) {
        case 'openai':
          kind = 'openai';
          break;
        case 'anthropic':
          kind = 'claude';
          break;
        case 'gemini':
          kind = 'google';
          break;
        default:
          // 默认使用 OpenAI 兼容类型
          kind = 'openai';
      }

      // models 列表（仅包含 ids）
      final models = <String>[];
      final mlist = (p['models'] as List?) ?? const <dynamic>[];
      for (final m in mlist) {
        if (m is Map && m['id'] != null) models.add(m['id'].toString());
      }

      // 按 Cherry Studio 语义规范化 baseUrl：
      // - 在 Cherry 中，对于 OpenAI/Anthropic provider，如果 base_url 不以 '/' 结尾，它们会默认追加 '/v1'。
      // - 我们的 importer 之前原样保留 base，这可能遗漏 '/v1' 并导致请求失败。
      // - 这里在导入时对 'openai' 和 'claude' 复刻 Cherry 的行为。
      String base = apiHostRaw;
      if (base.isNotEmpty) {
        if (base.endsWith('/')) {
          // 为保持一致性去掉末尾斜杠；用户需负责在需要时自行包含版本号。
          base = base.substring(0, base.length - 1);
        } else {
          // 如果是 OpenAI/Claude/Google 且没有末尾斜杠，则在不存在后缀时追加默认版本。
          final lower = base.toLowerCase();
          final hasVersionSuffix = RegExp(
            r'/v\d([a-z0-9._-]+)?$',
          ).hasMatch(lower);
          if (!hasVersionSuffix) {
            if (kind == 'google') {
              base = '$base/v1beta';
            } else if (kind == 'openai' || kind == 'claude') {
              base = '$base/v1';
            }
          }
        }
      }

      // 组装 ProviderConfig json
      final map = <String, dynamic>{
        'id': id,
        'enabled': (p['enabled'] as bool?) ?? apiKey.isNotEmpty,
        'name': name,
        'apiKey': apiKey,
        'baseUrl': base.isNotEmpty
            ? base
            : (kind == 'google'
                  ? 'https://generativelanguage.googleapis.com/v1beta'
                  : (kind == 'claude'
                        ? 'https://api.anthropic.com/v1'
                        : 'https://api.openai.com/v1')),
        'providerType': kind == 'openai'
            ? 'openai'
            : kind == 'google'
            ? 'google'
            : 'claude',
        'chatPath': kind == 'openai' ? '/chat/completions' : null,
        'useResponseApi': kind == 'openai' ? false : null,
        'vertexAI': kind == 'google' ? false : null,
        'location': null,
        'projectId': null,
        'serviceAccountJson': null,
        'models': models,
        'modelOverrides': const <String, dynamic>{},
        'proxyEnabled': false,
        'proxyHost': '',
        'proxyPort': '8080',
        'proxyUsername': '',
        'proxyPassword': '',
        'multiKeyEnabled': multiKeyEnabled,
        'apiKeys': multiKeyEnabled
            ? apiKeys.map((k) => ApiKeyConfig.create(k).toJson()).toList()
            : const <dynamic>[],
        'keyManagement': const <String, dynamic>{},
      };
      imported[id] = map;
    }

    return imported;
  }

  static List<Map<String, dynamic>> _parseAssistants(
    List<dynamic> cherryAssistants,
  ) {
    // 映射到我们的 Assistant JSON 列表（与 Assistant.encodeList 存储的格式一致）
    final out = <Map<String, dynamic>>[];
    for (final a in cherryAssistants) {
      if (a is! Map) continue;
      final id = (a['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final name = (a['name'] ?? id).toString();
      final prompt = (a['prompt'] ?? '').toString();
      final settings = (a['settings'] as Map?)?.map(
        (k, v) => MapEntry(k.toString(), v),
      );
      final model = (a['model'] as Map?)?.map(
        (k, v) => MapEntry(k.toString(), v),
      );

      final temperature = (settings?['temperature'] as num?)?.toDouble();
      final topP = (settings?['topP'] as num?)?.toDouble();
      final ctxCount = (settings?['contextCount'] as num?)?.toInt();
      final streamOutput = settings?['streamOutput'] as bool?;
      final enableMaxTokens = settings?['enableMaxTokens'] as bool? ?? false;
      final maxTokens = enableMaxTokens
          ? (settings?['maxTokens'] as num?)?.toInt()
          : null;

      final json = <String, dynamic>{
        'id': id,
        'name': name,
        'avatar': null,
        'useAssistantAvatar': false,
        'useAssistantName': false,
        'chatModelProvider': model?['provider']?.toString(),
        'chatModelId': model?['id']?.toString(),
        'temperature': temperature,
        'topP': topP,
        'contextMessageSize': ctxCount ?? 64,
        'limitContextMessages': true,
        'streamOutput': streamOutput ?? true,
        'thinkingBudget': null,
        'maxTokens': maxTokens,
        'systemPrompt': prompt,
        'messageTemplate': '{{ message }}',
        'mcpServerIds': const <String>[],
        'background': null,
        'customHeaders': const <Map<String, String>>[],
        'customBody': const <Map<String, String>>[],
        'enableMemory': false,
        'allowPastConversationRecall': false,
      };
      out.add(json);
    }

    return out;
  }

  static Future<void> _importBusinessData({
    required BusinessRepository businessRepository,
    required RestoreMode mode,
    required Map<String, Map<String, dynamic>> providers,
    required List<Map<String, dynamic>> assistants,
  }) {
    return businessRepository.transformSnapshot((current) {
      final settings = BusinessSettingsRouter.exportSnapshot(current);
      if (mode == RestoreMode.overwrite) {
        settings[_providersKey] = jsonEncode(providers);
        settings[_providersOrderKey] = providers.keys.toList();
        settings[_assistantsKey] = jsonEncode(assistants);
        return BusinessSettingsRouter.normalizeAndRoute(settings);
      }

      final currentProviders = _jsonObjectMap(
        settings[_providersKey],
        _providersKey,
      );
      for (final entry in providers.entries) {
        final local = currentProviders[entry.key];
        if (local is! Map) {
          currentProviders[entry.key] = entry.value;
          continue;
        }
        final next = local.map((key, value) => MapEntry(key.toString(), value));
        for (final importedField in entry.value.entries) {
          final value = importedField.value;
          if (value == null || (value is String && value.trim().isEmpty)) {
            continue;
          }
          next[importedField.key] = value;
        }
        currentProviders[entry.key] = next;
      }
      settings[_providersKey] = jsonEncode(currentProviders);

      final order = List<String>.from(
        (settings[_providersOrderKey] as List).cast<String>(),
      );
      for (final providerId in providers.keys) {
        if (!order.contains(providerId)) order.add(providerId);
      }
      settings[_providersOrderKey] = order;

      final currentAssistants = _jsonObjectList(
        settings[_assistantsKey],
        _assistantsKey,
      );
      final assistantsById = <String, Map<String, dynamic>>{
        for (final assistant in currentAssistants)
          if (assistant['id'] != null) assistant['id'].toString(): assistant,
      };
      for (final assistant in assistants) {
        final id = assistant['id'] as String;
        final local = assistantsById[id];
        if (local == null) {
          assistantsById[id] = assistant;
          continue;
        }
        final prompt = (assistant['systemPrompt'] as String?)?.trim() ?? '';
        if (prompt.isNotEmpty) local['systemPrompt'] = prompt;
        if (assistant['chatModelProvider'] != null) {
          local['chatModelProvider'] = assistant['chatModelProvider'];
        }
        if (assistant['chatModelId'] != null) {
          local['chatModelId'] = assistant['chatModelId'];
        }
      }
      settings[_assistantsKey] = jsonEncode(assistantsById.values.toList());
      return BusinessSettingsRouter.normalizeAndRoute(settings);
    }, writeReceipt: true);
  }

  static Map<String, dynamic> _jsonObjectMap(Object? raw, String key) {
    if (raw is! String) throw FormatException(key);
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded.values.any((value) => value is! Map)) {
      throw FormatException(key);
    }
    return decoded.map((field, value) => MapEntry(field.toString(), value));
  }

  static List<Map<String, dynamic>> _jsonObjectList(Object? raw, String key) {
    if (raw is! String) throw FormatException(key);
    final decoded = jsonDecode(raw);
    if (decoded is! List || decoded.any((value) => value is! Map)) {
      throw FormatException(key);
    }
    return decoded
        .cast<Map>()
        .map(
          (value) => value.map(
            (field, fieldValue) => MapEntry(field.toString(), fieldValue),
          ),
        )
        .toList(growable: false);
  }

  static Future<Map<String, String>> _materializeFiles(
    Map<String, Map<String, dynamic>> filesById,
    Set<String> usedIds, {
    File? backupArchive,
  }) async {
    final uploadDir = await AppDirectories.getUploadDirectory();
    if (!await uploadDir.exists()) await uploadDir.create(recursive: true);

    final filesPayload = <String, Map<String, dynamic>>{
      for (final id in usedIds)
        if (filesById[id] != null)
          id: Map<String, dynamic>.from(filesById[id]!),
    };
    final backupPath = backupArchive?.path;
    final uploadDirPath = uploadDir.path;
    final used = usedIds.toList(growable: false);

    // ArchiveFile / InputFileStream 不可跨隔离区传递；仅在 isolate 内
    // 保持 ZIP 打开，并在边界两侧交换纯路径映射。
    return Isolate.run(
      () => _materializeFilesSync(
        backupPath: backupPath,
        uploadDirPath: uploadDirPath,
        filesById: filesPayload,
        usedIds: used,
      ),
    );
  }

  /// 同步附件物化 —— 在 [Isolate] 内运行。
  static Map<String, String> _materializeFilesSync({
    required String? backupPath,
    required String uploadDirPath,
    required Map<String, Map<String, dynamic>> filesById,
    required List<String> usedIds,
  }) {
    Map<String, ArchiveFile>? filesIndexByBase;
    Map<String, ArchiveFile>? filesIndexByRel;
    Map<String, ArchiveFile>? filesIndexById;
    Map<String, String>? diskFilesIndexByBase;
    Map<String, String>? diskFilesIndexByRel;
    Map<String, String>? diskFilesIndexById;

    InputFileStream? inputStream;
    Archive? archive;
    if (backupPath != null) {
      try {
        inputStream = InputFileStream(backupPath);
        archive = ZipDecoder().decodeStream(inputStream);
        final byBase = <String, ArchiveFile>{};
        final byRel = <String, ArchiveFile>{};
        final byId = <String, ArchiveFile>{};
        final uuidLike = RegExp(r'^[0-9a-fA-F-]{10,}$');
        for (final e in archive) {
          if (!e.isFile) continue;
          final norm = _normalizeZipEntryPath(e.name);
          final base = p.basename(norm);
          byBase[base] = e;
          final l = norm.toLowerCase();
          int idx = l.indexOf('/data/files/');
          if (idx != -1) {
            byRel[l.substring(idx + 1)] = e;
          }
          idx = l.indexOf('/files/');
          if (idx != -1) {
            byRel[l.substring(idx + 1)] = e;
          }
          final noExt = base.contains('.')
              ? base.substring(0, base.lastIndexOf('.'))
              : base;
          if (uuidLike.hasMatch(noExt)) {
            byId[noExt] = e;
          }
        }
        if (byBase.isNotEmpty) filesIndexByBase = byBase;
        if (byRel.isNotEmpty) filesIndexByRel = byRel;
        if (byId.isNotEmpty) filesIndexById = byId;
      } catch (_) {
        // 不是 zip，忽略
        archive = null;
        try {
          inputStream?.closeSync();
        } catch (_) {}
        inputStream = null;
      }

      try {
        final parent = Directory(p.dirname(backupPath));
        final candidates = <Directory>[
          Directory(p.join(parent.path, 'Data', 'Files')),
          Directory(p.join(parent.path, 'Files')),
          Directory(p.join(parent.path, 'files')),
        ];
        final byBase = <String, String>{};
        final byRel = <String, String>{};
        final byId = <String, String>{};
        final uuidLike = RegExp(r'^[0-9a-fA-F-]{10,}$');
        for (final dir in candidates) {
          if (!dir.existsSync()) continue;
          for (final ent in dir.listSync(recursive: true, followLinks: false)) {
            if (ent is! File) continue;
            final abs = ent.path;
            final base = p.basename(abs);
            byBase[base] = abs;
            final l = _normalizeZipEntryPath(abs).toLowerCase();
            int idx = l.indexOf('/data/files/');
            if (idx != -1) {
              byRel[l.substring(idx + 1)] = abs;
            }
            idx = l.indexOf('/files/');
            if (idx != -1) {
              byRel[l.substring(idx + 1)] = abs;
            }
            final noExt = base.contains('.')
                ? base.substring(0, base.lastIndexOf('.'))
                : base;
            if (uuidLike.hasMatch(noExt)) {
              byId[noExt] = abs;
            }
          }
        }
        if (byBase.isNotEmpty) diskFilesIndexByBase = byBase;
        if (byRel.isNotEmpty) diskFilesIndexByRel = byRel;
        if (byId.isNotEmpty) diskFilesIndexById = byId;
      } catch (_) {}
    }

    try {
      final result = <String, String>{};
      for (final id in usedIds) {
        final meta = filesById[id];
        if (meta == null) continue;
        final name = (meta['origin_name'] ?? meta['name'] ?? 'file').toString();
        final ext = (meta['ext'] ?? '').toString();
        final safeName = name.replaceAll(RegExp(r'[/\\\0]'), '_');
        final fn = safeName.isNotEmpty
            ? safeName
            : (ext.isNotEmpty ? 'file.$ext' : 'file');
        // `id` 直接来自导入归档的 JSON。要像显示名称一样对它进行清理：
        // 诸如 `x/../../y` 这样的 id 在 Windows 上会逃逸上传目录，因为其
        // Win32 路径规范化会按词法解析 `..`，而不要求中间目录
        // 实际存在。
        final safeId = id.replaceAll(RegExp(r'[/\\\0]'), '_');
        final fileName = 'cherry_${safeId}_$fn';
        final outPath = p.join(uploadDirPath, fileName);
        // 纵深防御：即使未来的重构削弱了上面的清理逻辑，
        // 也绝不要写出上传目录之外。
        if (!p.isWithin(p.normalize(uploadDirPath), p.normalize(outPath))) {
          continue;
        }

        if (File(outPath).existsSync()) {
          result[id] = outPath;
          continue;
        }

        final base64Str = (meta['base64'] ?? '') as String;
        final contentStr = (meta['content'] ?? '') as String;
        try {
          if (base64Str.isNotEmpty) {
            String b64 = base64Str;
            final idx = b64.indexOf('base64,');
            if (idx != -1) b64 = b64.substring(idx + 7);
            File(outPath).writeAsBytesSync(base64.decode(b64));
            result[id] = outPath;
            continue;
          }
        } catch (_) {}

        try {
          if (contentStr.isNotEmpty) {
            File(outPath).writeAsStringSync(contentStr);
            result[id] = outPath;
            continue;
          }
        } catch (_) {}

        try {
          final mp = (meta['path'] ?? '').toString();
          if (mp.isNotEmpty) {
            String rel = _normalizeZipEntryPath(mp).trim();
            if (rel.startsWith('file://')) {
              rel = rel.substring('file://'.length);
            }
            if (rel.startsWith('/')) rel = rel.substring(1);
            final lowerRel = rel.toLowerCase();
            final relKeys = <String>{
              lowerRel,
              lowerRel.startsWith('files/') ? lowerRel : 'files/$lowerRel',
              lowerRel.startsWith('data/files/')
                  ? lowerRel
                  : 'data/files/$lowerRel',
            };
            var done = false;
            for (final key in relKeys) {
              if (!done &&
                  filesIndexByRel != null &&
                  filesIndexByRel.containsKey(key)) {
                if (_writeArchiveEntryToFile(filesIndexByRel[key]!, outPath)) {
                  result[id] = outPath;
                  done = true;
                }
              }
              if (!done &&
                  diskFilesIndexByRel != null &&
                  diskFilesIndexByRel.containsKey(key)) {
                if (_copyDiskFileToUpload(diskFilesIndexByRel[key]!, outPath)) {
                  result[id] = outPath;
                  done = true;
                }
              }
              if (done) break;
            }
            if (done) continue;
          }
        } catch (_) {}

        try {
          final candidates = <String>{};
          void add(String? s) {
            if (s != null && s.trim().isNotEmpty) {
              candidates.add(p.basename(s));
            }
          }

          add(meta['name']?.toString());
          add(meta['origin_name']?.toString());
          add(meta['path']?.toString());
          var done = false;
          for (final base in candidates) {
            if (!done &&
                filesIndexByBase != null &&
                filesIndexByBase.containsKey(base)) {
              if (_writeArchiveEntryToFile(filesIndexByBase[base]!, outPath)) {
                result[id] = outPath;
                done = true;
              }
            }
            if (!done &&
                diskFilesIndexByBase != null &&
                diskFilesIndexByBase.containsKey(base)) {
              if (_copyDiskFileToUpload(diskFilesIndexByBase[base]!, outPath)) {
                result[id] = outPath;
                done = true;
              }
            }
            if (done) break;
          }
          if (done) continue;
        } catch (_) {}

        try {
          String fileExt = (meta['ext'] ?? '').toString().trim();
          if (fileExt.isEmpty) {
            final n = (meta['name'] ?? '').toString();
            final b = p.basename(n);
            if (b.contains('.')) fileExt = b.substring(b.lastIndexOf('.') + 1);
          }
          final extNoDot = fileExt.startsWith('.')
              ? fileExt.substring(1)
              : fileExt;
          final idPlus = extNoDot.isNotEmpty ? '$id.$extNoDot' : id;
          if (filesIndexById != null && filesIndexById.containsKey(id)) {
            if (_writeArchiveEntryToFile(filesIndexById[id]!, outPath)) {
              result[id] = outPath;
              continue;
            }
          }
          if (filesIndexByBase != null &&
              filesIndexByBase.containsKey(idPlus)) {
            if (_writeArchiveEntryToFile(filesIndexByBase[idPlus]!, outPath)) {
              result[id] = outPath;
              continue;
            }
          }
          if (diskFilesIndexById != null &&
              diskFilesIndexById.containsKey(id)) {
            if (_copyDiskFileToUpload(diskFilesIndexById[id]!, outPath)) {
              result[id] = outPath;
              continue;
            }
          }
          if (diskFilesIndexByBase != null &&
              diskFilesIndexByBase.containsKey(idPlus)) {
            if (_copyDiskFileToUpload(diskFilesIndexByBase[idPlus]!, outPath)) {
              result[id] = outPath;
              continue;
            }
          }
        } catch (_) {}
      }
      return result;
    } finally {
      try {
        archive?.clearSync();
      } catch (_) {}
      try {
        inputStream?.closeSync();
      } catch (_) {}
    }
  }

  /// ZIP 条目名称和磁盘路径可能使用 `\`（Windows）或 `/`。
  static String _normalizeZipEntryPath(String name) {
    return name.replaceAll('\\', '/');
  }

  static bool _writeArchiveEntryToFile(ArchiveFile entry, String outPath) {
    final output = _ExactSizeOutputFileStream(
      outPath,
      expectedBytes: entry.size,
    );
    var written = false;
    try {
      entry.writeContent(output);
      output.verifyComplete();
      written = true;
    } catch (_) {
      // 流关闭后，会在下方清理部分写入。
    } finally {
      output.closeSync();
    }
    if (!written) {
      try {
        File(outPath).deleteSync();
      } catch (_) {}
      return false;
    }
    // 磁盘复制回退会保留源时间戳；请让二者保持一致。
    final dt = _decodeDosDateTime(entry.lastModTime);
    if (dt != null) {
      try {
        File(outPath).setLastModifiedSync(dt);
      } catch (_) {}
    }
    return true;
  }

  /// 将 DOS 日期/时间压缩值（来自 ZIP 条目的 `lastModTime`）
  /// 解码为 [DateTime]。日期部分为零（未设置）时返回 null。
  static DateTime? _decodeDosDateTime(int packed) {
    final dosDate = packed >> 16;
    final dosTime = packed & 0xFFFF;
    if (dosDate == 0) return null;
    final year = ((dosDate >> 9) & 0x7f) + 1980;
    final month = (dosDate >> 5) & 0x0f;
    final day = dosDate & 0x1f;
    final hour = (dosTime >> 11) & 0x1f;
    final minute = (dosTime >> 5) & 0x3f;
    final second = (dosTime & 0x1f) * 2;
    try {
      return DateTime(year, month, day, hour, minute, second);
    } catch (_) {
      return null;
    }
  }

  static bool _copyDiskFileToUpload(String srcPath, String outPath) {
    try {
      final src = File(srcPath);
      src.copySync(outPath);
      try {
        File(outPath).setLastModifiedSync(src.lastModifiedSync());
      } catch (_) {}
      return true;
    } catch (_) {
      return false;
    }
  }

  // 返回 (conversations, messages, extraFilesSaved)
  static Future<(int, int, int)> _importConversations({
    required Map<String, Map<String, dynamic>> topicMeta,
    required Map<String, List<Map<String, dynamic>>> topicMessages,
    required Map<String, String> filePaths,
    required ChatService chatService,
    required RestoreMode mode,
    required Map<String, String> blockTexts,
    required Map<String, List<_PendingAttachmentRef>>
    pendingAttachmentsByMessage,
  }) async {
    if (!chatService.initialized) await chatService.init();

    // 构建现有 conv id 映射，用于合并
    final existingConvs = chatService.getAllCompleteConversations();
    final existingConvIds = existingConvs.map((c) => c.id).toSet();
    final existingMsgIds = <String>{};
    if (mode == RestoreMode.merge) {
      // 只取 Id：完整消息加载会无谓地刷新 LRU 缓存。
      for (final c in existingConvs) {
        existingMsgIds.addAll(await chatService.getMessageIds(c.id));
      }
    }

    int convCount = 0;
    int msgCount = 0;
    int extraSaved = 0; // 从 base64/data url 保存的文件数量

    final topicIds = <String>{...topicMeta.keys, ...topicMessages.keys};
    for (final topicId in topicIds) {
      final msgsRaw = topicMessages[topicId] ?? const <Map<String, dynamic>>[];
      final meta = topicMeta[topicId] ?? const <String, dynamic>{};
      final title = (meta['name'] ?? 'Imported').toString();
      final pinned = meta['pinned'] as bool? ?? false;
      final assistantId = (meta['assistantId'] ?? '').toString().trim().isEmpty
          ? null
          : meta['assistantId'].toString();
      // 从消息回退 created/updated
      DateTime createdAt;
      DateTime updatedAt;
      try {
        createdAt = DateTime.parse((meta['createdAt'] ?? '').toString());
      } catch (_) {
        createdAt = DateTime.now();
      }
      try {
        updatedAt = DateTime.parse((meta['updatedAt'] ?? '').toString());
      } catch (_) {
        updatedAt = createdAt;
      }

      // 转换消息
      final messages = <ChatMessage>[];
      for (final m in msgsRaw) {
        final msgId = (m['id'] ?? '').toString();
        if (msgId.isEmpty) continue;
        if (mode == RestoreMode.merge && existingMsgIds.contains(msgId)) {
          continue;
        }
        final roleRaw = (m['role'] ?? 'user').toString();
        final role = (roleRaw == 'system')
            ? 'assistant'
            : roleRaw; // 我们的模式只支持 'user'|'assistant'
        // 优先使用 message.content；如果为空，则回退到重建的块
        String content = '';
        final rawContent = m['content'];
        if (rawContent is String) {
          content = rawContent;
        } else if (rawContent != null) {
          content = rawContent.toString();
        }
        if (content.trim().isEmpty) {
          content = (blockTexts[msgId] ?? '').toString();
        }
        DateTime ts;
        try {
          ts = DateTime.parse((m['createdAt'] ?? '').toString());
        } catch (_) {
          ts = DateTime.now();
        }

        final modelId =
            (m['modelId'] ??
                    (m['model'] is Map
                        ? (m['model']['id'] ?? '').toString()
                        : null))
                as String?;
        final providerId = (m['model'] is Map
            ? (m['model']['provider'] ?? '').toString()
            : null);
        final usage = (m['usage'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v),
        );
        final totalTokens = (usage?['total_tokens'] as num?)?.toInt();

        // 附件 -> 结构化 ImagePart/FilePart（不含管线中间标记）
        final files = (m['files'] as List?) ?? const <dynamic>[];
        final attachmentParts = <MessagePart>[];
        for (final f in files) {
          if (f is! Map) continue;
          final fid = (f['id'] ?? '').toString();
          if (fid.isEmpty) continue;
          final name = (f['origin_name'] ?? f['name'] ?? 'file').toString();
          final mime = (f['type'] ?? '').toString();
          final savedPath = filePaths[fid];
          final isImageByMeta =
              mime.toLowerCase().startsWith('image') ||
              (name.toLowerCase().contains('.') &&
                  RegExp(
                    r"\.(png|jpg|jpeg|gif|webp)",
                  ).hasMatch(name.toLowerCase()));
          if (savedPath != null && savedPath.isNotEmpty) {
            attachmentParts.add(
              _attachmentPart(
                isImage: isImageByMeta,
                target: savedPath,
                name: name,
                mime: mime,
              ),
            );
          } else {
            // 如果存在 URL，则回退到 URL（不下载）
            final url = (f['url'] ?? '').toString();
            if (url.isNotEmpty) {
              // 即使是无扩展名或预签名 URL，也信任已知图片 MIME。
              final lowerUrl = url.toLowerCase();
              final isImage =
                  mime.toLowerCase().startsWith('image/') ||
                  RegExp(
                    r'\.(png|jpg|jpeg|gif|webp)(?:$|[?#])',
                  ).hasMatch(lowerUrl);
              attachmentParts.add(
                _attachmentPart(
                  isImage: isImage,
                  target: url,
                  name: name,
                  mime: mime,
                ),
              );
            } else {
              // 归档文件缺失且没有 URL —— 保留一个不可用部分，
              // 以免附件在历史记录中被静默丢弃。
              // 存在归档相对原始路径时优先使用它；否则使用
              // 稳定的非空占位符（uri 不能为空）。
              final originPath = (f['path'] ?? '').toString().trim();
              final placeholder = originPath.isNotEmpty
                  ? originPath
                  : 'cherry-missing:$fid';
              attachmentParts.add(
                _attachmentPart(
                  isImage: isImageByMeta,
                  target: placeholder,
                  name: name,
                  mime: mime,
                  unavailable: true,
                ),
              );
            }
          }
        }

        // 添加由消息块（image）和 message.metadata.generateImageResponse 引用的图片
        final extraAtt =
            pendingAttachmentsByMessage[msgId] ??
            const <_PendingAttachmentRef>[];
        for (final ref in extraAtt) {
          if (ref.fileId != null) {
            final savedPath = filePaths[ref.fileId!];
            final fileName = ref.name ?? (ref.isImage ? 'image' : 'file');
            final fileMime =
                ref.mime ??
                (ref.isImage ? 'image/png' : 'application/octet-stream');
            if (savedPath != null && savedPath.isNotEmpty) {
              attachmentParts.add(
                _attachmentPart(
                  isImage: ref.isImage,
                  target: savedPath,
                  name: fileName,
                  mime: fileMime,
                ),
              );
            } else {
              // 与 m['files'] 的约定相同：归档文件缺失时，
              // 保留不可用占位符。
              final originPath = (ref.originPath ?? '').trim();
              final placeholder = originPath.isNotEmpty
                  ? originPath
                  : 'cherry-missing:${ref.fileId}';
              attachmentParts.add(
                _attachmentPart(
                  isImage: ref.isImage,
                  target: placeholder,
                  name: fileName,
                  mime: fileMime,
                  unavailable: true,
                ),
              );
            }
          } else if (ref.dataUrl != null) {
            final savedPath = await _saveDataUrlToUpload(ref.dataUrl!);
            final fileName = ref.name ?? (ref.isImage ? 'image' : 'file');
            final fileMime =
                ref.mime ??
                (ref.isImage ? 'image/png' : 'application/octet-stream');
            if (savedPath != null) {
              extraSaved += 1;
              attachmentParts.add(
                _attachmentPart(
                  isImage: ref.isImage,
                  target: savedPath,
                  name: fileName,
                  mime: fileMime,
                ),
              );
            } else {
              attachmentParts.add(
                _attachmentPart(
                  isImage: ref.isImage,
                  target: 'cherry-missing:data-url',
                  name: fileName,
                  mime: fileMime,
                  unavailable: true,
                ),
              );
            }
          } else if (ref.url != null && ref.url!.isNotEmpty) {
            attachmentParts.add(
              _attachmentPart(
                isImage: ref.isImage,
                target: ref.url!,
                name: ref.name ?? (ref.isImage ? 'image' : 'file'),
                mime:
                    ref.mime ??
                    (ref.isImage ? 'image/png' : 'application/octet-stream'),
              ),
            );
          }
        }

        // metadata 中的 generateImageResponse
        final metadata = (m['metadata'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v),
        );
        final gen = (metadata?['generateImageResponse'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v),
        );
        if (gen != null) {
          final imgs = (gen['images'] as List?) ?? const <dynamic>[];
          for (final item in imgs) {
            final s = (item ?? '').toString();
            if (s.isEmpty) continue;
            if (s.startsWith('data:image')) {
              final saved = await _saveDataUrlToUpload(s);
              if (saved != null) {
                extraSaved += 1;
                attachmentParts.add(
                  _attachmentPart(
                    isImage: true,
                    target: saved,
                    name: 'image',
                    mime: 'image/png',
                  ),
                );
              }
            } else if (s.startsWith('http://') || s.startsWith('https://')) {
              attachmentParts.add(
                _attachmentPart(
                  isImage: true,
                  target: s,
                  name: 'image',
                  mime: 'image/png',
                ),
              );
            } else {
              // 不带前缀的原始 base64
              final saved = await _saveDataUrlToUpload(
                'data:image/png;base64,$s',
              );
              if (saved != null) {
                extraSaved += 1;
                attachmentParts.add(
                  _attachmentPart(
                    isImage: true,
                    target: saved,
                    name: 'image',
                    mime: 'image/png',
                  ),
                );
              }
            }
          }
        }

        // 提取 assistant 内容中内联的 data:image base64 URL，并转换为文件
        if (role == 'assistant' && content.contains('data:image')) {
          final dataUrls = _extractDataImageUrls(content);
          if (dataUrls.isNotEmpty) {
            for (final du in dataUrls) {
              final saved = await _saveDataUrlToUpload(du);
              if (saved != null) {
                extraSaved += 1;
                attachmentParts.add(
                  _attachmentPart(
                    isImage: true,
                    target: saved,
                    name: 'image',
                    mime: 'image/png',
                  ),
                );
              }
            }
            // 可选地从内容中剥离 base64 数据块，避免出现巨大的文本块
            content = _stripDataImageUrls(content);
          }
        }
        final parts = <MessagePart>[TextPart(content), ...attachmentParts];

        messages.add(
          ChatMessage(
            id: msgId,
            role: role,
            parts: parts,
            timestamp: ts,
            modelId: modelId,
            providerId: providerId,
            totalTokens: totalTokens,
            conversationId: topicId,
          ),
        );
      }

      // 缺少时间戳时进行推导
      if (messages.isNotEmpty) {
        final times = messages.map((m) => m.timestamp).toList()..sort();
        createdAt = times.first;
        updatedAt = times.last;
      }

      // 持久化
      if (mode == RestoreMode.merge && existingConvIds.contains(topicId)) {
        // 仅添加新消息
        for (final m in messages) {
          await chatService.addMessageDirectly(topicId, m);
          msgCount += 1;
        }
      } else {
        final conv = Conversation(
          id: topicId,
          title: title,
          createdAt: createdAt,
          updatedAt: updatedAt,
          isPinned: pinned,
          assistantId: assistantId,
        );
        await chatService.restoreConversation(conv, messages);
        convCount += 1;
        msgCount += messages.length;
      }
    }

    return (convCount, msgCount, extraSaved);
  }

  static MessagePart _attachmentPart({
    required bool isImage,
    required String target,
    required String name,
    required String mime,
    bool unavailable = false,
  }) {
    final uri = SandboxPathResolver.canonicalize(target);
    if (isImage) {
      return ImagePart(
        uri: uri,
        mime: mime.isNotEmpty ? mime : null,
        unavailable: unavailable,
      );
    }
    return FilePart(
      uri: uri,
      name: name.isNotEmpty ? name : 'file',
      mime: mime.isNotEmpty ? mime : 'application/octet-stream',
      unavailable: unavailable,
    );
  }

  static List<String> _extractDataImageUrls(String text) {
    final re = RegExp(
      r'data:image\/[a-zA-Z0-9.+-]+;base64,[a-zA-Z0-9+\/\=\r\n]+',
    );
    return re.allMatches(text).map((m) => m.group(0)!).toList();
  }

  static String _stripDataImageUrls(String text) {
    final re = RegExp(
      r'data:image\/[a-zA-Z0-9.+-]+;base64,[a-zA-Z0-9+\/\=\r\n]+',
    );
    return text.replaceAll(re, '');
  }

  static Future<String?> _saveDataUrlToUpload(String dataUrl) async {
    try {
      final upload = await AppDirectories.getUploadDirectory();
      if (!await upload.exists()) await upload.create(recursive: true);
      // 提取 mime 和 data
      String mime = 'image/png';
      String payload = dataUrl;
      final colon = dataUrl.indexOf(':');
      final semi = dataUrl.indexOf(';');
      final base = dataUrl.indexOf('base64,');
      if (colon >= 0 && semi > colon) {
        mime = dataUrl.substring(colon + 1, semi);
      }
      if (base >= 0) {
        payload = dataUrl.substring(base + 7);
      }
      final bytes = base64.decode(payload.replaceAll('\n', ''));
      String ext = 'png';
      switch (mime.toLowerCase()) {
        case 'image/jpeg':
        case 'image/jpg':
          ext = 'jpg';
          break;
        case 'image/webp':
          ext = 'webp';
          break;
        case 'image/gif':
          ext = 'gif';
          break;
        default:
          ext = 'png';
      }
      final fname =
          'cherry_img_${DateTime.now().millisecondsSinceEpoch}_${bytes.length}.$ext';
      final out = File(p.join(upload.path, fname));
      await out.writeAsBytes(bytes);
      return out.path;
    } catch (_) {
      return null;
    }
  }
}

/// 验证归档条目恰好写入了 [expectedBytes]。
class _ExactSizeOutputFileStream extends OutputFileStream {
  _ExactSizeOutputFileStream(String path, {required this.expectedBytes})
    : super.withFileHandle(FileHandle(path, mode: FileAccess.write));

  final int expectedBytes;
  int _writtenBytes = 0;

  void _reserve(int bytes) {
    if (bytes < 0 || _writtenBytes + bytes > expectedBytes) {
      throw const FormatException('zip_entry_size');
    }
    _writtenBytes += bytes;
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final writeLength = length ?? bytes.length;
    if (writeLength < 0 || writeLength > bytes.length) {
      throw RangeError.range(writeLength, 0, bytes.length, 'length');
    }
    _reserve(writeLength);
    super.writeBytes(bytes, length: writeLength);
  }

  @override
  void writeStream(InputStream stream) {
    const chunkSize = 1024 * 1024;
    while (!stream.isEOS) {
      final readSize = stream.length < chunkSize ? stream.length : chunkSize;
      final bytes = stream.readBytes(readSize).toUint8List();
      if (bytes.isEmpty) break;
      writeBytes(bytes);
    }
  }

  void verifyComplete() {
    if (_writtenBytes != expectedBytes) {
      throw const FormatException('zip_entry_size');
    }
  }
}

class _PendingAttachmentRef {
  final String? fileId; // 如果存在，则通过 filePaths 解析
  final String? dataUrl; // 如果存在，则保存为文件
  final String? url; // 远程 URL
  final String? name;
  final String? mime;
  final String? originPath; // 可用时为压缩包内的相对路径
  final bool isImage;
  const _PendingAttachmentRef({
    this.fileId,
    this.dataUrl,
    this.url,
    this.name,
    this.mime,
    this.originPath,
    this.isImage = true,
  });
}

/// 将逗号分隔的 API key 字符串拆分为 key 列表。处理转义逗号（\,）并去除空白。
/// 与 Cherry Studio 的 splitApiKeyString 行为保持一致。
List<String> _splitApiKeyString(String keyStr) {
  if (keyStr.trim().isEmpty) return const <String>[];

  // 使用占位符处理转义逗号（避免正则后行断言以兼容 Web）
  const placeholder = '\x00';
  final escaped = keyStr.replaceAll(r'\,', placeholder);
  final parts = escaped.split(',');

  final result = <String>[];
  for (final part in parts) {
    // 还原转义逗号并去除空白
    final key = part.replaceAll(placeholder, ',').trim();
    if (key.isNotEmpty) {
      result.add(key);
    }
  }

  return result;
}
