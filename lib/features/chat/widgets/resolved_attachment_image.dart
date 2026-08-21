import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../utils/sandbox_path_resolver.dart';

final Map<String, Uint8List?> _dataUriBytesCache = <String, Uint8List?>{};
const int _dataUriBytesCacheLimit = 24;
const int _dataUriBytesCacheMaxBytes = 16 << 20;
int _dataUriBytesCacheBytes = 0;

Uint8List? _decodeDataUriBytes(String path) {
  if (_dataUriBytesCache.containsKey(path)) {
    final cached = _dataUriBytesCache.remove(path);
    _dataUriBytesCache[path] = cached;
    return cached;
  }

  Uint8List? bytes;
  try {
    const marker = 'base64,';
    final index = path.indexOf(marker);
    if (index != -1) {
      bytes = base64Decode(path.substring(index + marker.length));
    }
  } catch (_) {
    bytes = null;
  }

  _dataUriBytesCache[path] = bytes;
  _dataUriBytesCacheBytes += bytes?.length ?? 0;
  while (_dataUriBytesCache.length > 1 &&
      (_dataUriBytesCache.length > _dataUriBytesCacheLimit ||
          _dataUriBytesCacheBytes > _dataUriBytesCacheMaxBytes)) {
    final evicted = _dataUriBytesCache.remove(_dataUriBytesCache.keys.first);
    _dataUriBytesCacheBytes -= evicted?.length ?? 0;
  }
  return bytes;
}

/// 在聊天和编辑界面中一致地渲染已持久化的附件 URI。
class ResolvedAttachmentImage extends StatelessWidget {
  const ResolvedAttachmentImage({
    super.key,
    required this.uri,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.placeholder,
    this.localIoOnly = false,
  });

  final String uri;
  final double? width;
  final double? height;
  final BoxFit fit;
  final WidgetBuilder? placeholder;

  /// 当图片是可编辑附件时，避免旧的 basename 回退。
  final bool localIoOnly;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget errorWidget() =>
        placeholder?.call(context) ??
        Container(
          width: width ?? (height != null ? height! * 0.67 : 120),
          height: height ?? 180,
          color: cs.surfaceContainerHighest,
          alignment: Alignment.center,
          child: Icon(
            Lucide.ImageOff,
            size: 24,
            color: cs.onSurface.withValues(alpha: 0.5),
          ),
        );

    final path = uri.trim();
    if (path.isEmpty) return errorWidget();

    if (path.startsWith('http://') || path.startsWith('https://')) {
      return Image.network(
        path,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, __, ___) => errorWidget(),
      );
    }

    if (path.startsWith('data:')) {
      final bytes = _decodeDataUriBytes(path);
      if (bytes == null) return errorWidget();
      return Image.memory(
        bytes,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, __, ___) => errorWidget(),
      );
    }

    final resolved = localIoOnly
        ? SandboxPathResolver.resolveForIo(path)
        : SandboxPathResolver.fix(path);
    if (resolved == null || resolved.isEmpty) return errorWidget();
    return Image.file(
      File(resolved),
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (_, __, ___) => errorWidget(),
    );
  }
}
