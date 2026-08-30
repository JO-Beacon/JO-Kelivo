import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:io';
import '../database/business_preferences.dart';
import '../../utils/sandbox_path_resolver.dart';
import '../../utils/avatar_cache.dart';
import '../../utils/app_directories.dart';
import '../models/avatar_transform.dart';

class UserProvider extends ChangeNotifier {
  static const String _prefsUserNameKey = 'user_name';
  static const String _prefsAvatarTypeKey =
      'avatar_type'; // emoji | url | file | null
  static const String _prefsAvatarValueKey = 'avatar_value';
  static const String _prefsAvatarTransformKey = 'avatar_transform_v1';

  final BusinessPreferences preferences;
  String _name = 'User';
  String get name => _name;
  bool _hasSavedName = false;

  String? _avatarType; // 'emoji', 'url', 'file'
  String? _avatarValue;
  AvatarTransform? _avatarTransform;
  String? get avatarType => _avatarType;
  String? get avatarValue => _avatarValue;
  AvatarTransform? get avatarTransform => _avatarTransform;

  UserProvider({required this.preferences}) {
    _load();
  }

  Future<void> _load() async {
    await preferences.load();
    final n = preferences.getString(_prefsUserNameKey);
    if (n != null && n.isNotEmpty) {
      _name = n;
      _hasSavedName = true;
      notifyListeners();
    }
    _avatarType = preferences.getString(_prefsAvatarTypeKey);
    final rawAvatar = preferences.getString(_prefsAvatarValueKey);
    _avatarValue = rawAvatar == null
        ? null
        : SandboxPathResolver.fix(rawAvatar);
    // 如果固定路径发生变化，将其写回持久化（便于桌面端导入后使用）
    if (rawAvatar != null &&
        _avatarValue != null &&
        rawAvatar != _avatarValue) {
      try {
        await preferences.setString(_prefsAvatarValueKey, _avatarValue!);
      } catch (_) {}
    }
    final rawTransform = preferences.getString(_prefsAvatarTransformKey);
    if (rawTransform != null) {
      try {
        _avatarTransform = AvatarTransform.fromJson(jsonDecode(rawTransform));
      } catch (_) {
        _avatarTransform = null;
      }
    }
    // 仅在头像存在时通知；否则依赖上面的名称通知
    if (_avatarType != null && _avatarValue != null) {
      notifyListeners();
    }
  }

  // 如果用户尚未保存自定义名称，则设置本地化默认名称
  void setDefaultNameIfUnset(String localizedDefaultName) {
    if (_hasSavedName) return;
    final v = localizedDefaultName.trim();
    if (v.isEmpty) return;
    if (_name != v) {
      _name = v;
      notifyListeners();
    }
  }

  Future<void> setName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == _name) return;
    _name = trimmed;
    notifyListeners();
    await preferences.setString(_prefsUserNameKey, _name);
  }

  Future<void> setAvatarEmoji(String emoji) async {
    final e = emoji.trim();
    if (e.isEmpty) return;
    _avatarType = 'emoji';
    _avatarValue = e;
    _avatarTransform = null;
    notifyListeners();
    await preferences.setString(_prefsAvatarTypeKey, _avatarType!);
    await preferences.setString(_prefsAvatarValueKey, _avatarValue!);
    await preferences.remove(_prefsAvatarTransformKey);
  }

  Future<void> setAvatarUrl(String url) async {
    final u = url.trim();
    if (u.isEmpty) return;
    _avatarType = 'url';
    _avatarValue = u;
    _avatarTransform = null;
    notifyListeners();
    await preferences.setString(_prefsAvatarTypeKey, _avatarType!);
    await preferences.setString(_prefsAvatarValueKey, _avatarValue!);
    await preferences.remove(_prefsAvatarTransformKey);
    // 预取，以便稍后离线显示
    try {
      await AvatarCache.getPath(u);
    } catch (_) {}
  }

  Future<void> setAvatarFilePath(
    String path, {
    AvatarTransform? transform,
  }) async {
    final p = path.trim();
    if (p.isEmpty) return;
    final fixedInput = SandboxPathResolver.fix(p);
    // 将所选图片复制到应用持久化存储中，以便重装或更新后仍能保留
    try {
      final src = File(fixedInput);
      if (!await src.exists()) return;
      final avatars = await AppDirectories.getAvatarsDirectory();
      if (!await avatars.exists()) {
        await avatars.create(recursive: true);
      }
      String ext = '';
      final dot = fixedInput.lastIndexOf('.');
      if (dot != -1 && dot < p.length - 1) {
        ext = fixedInput.substring(dot + 1).toLowerCase();
        // 基本清理
        if (ext.length > 6) ext = 'jpg';
      } else {
        ext = 'jpg';
      }
      final filename = 'avatar_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final dest = File('${avatars.path}/$filename');
      await src.copy(dest.path);

      // 如果旧本地头像存储在我们的 avatars 文件夹中，则视情况清理它
      if (_avatarType == 'file' && _avatarValue != null) {
        try {
          final old = File(_avatarValue!);
          if ((old.path.contains('/avatars/') ||
                  old.path.contains('\\avatars\\')) &&
              await old.exists()) {
            await old.delete();
          }
        } catch (_) {}
      }

      _avatarType = 'file';
      _avatarValue = dest.path;
      _avatarTransform = transform;
      notifyListeners();
      await preferences.setString(_prefsAvatarTypeKey, _avatarType!);
      await preferences.setString(_prefsAvatarValueKey, _avatarValue!);
      await _persistTransform();
    } catch (_) {
      // 如果复制失败，回退到原始路径（可能仍是临时路径）
      _avatarType = 'file';
      _avatarValue = fixedInput;
      _avatarTransform = transform;
      notifyListeners();
      await preferences.setString(_prefsAvatarTypeKey, _avatarType!);
      await preferences.setString(_prefsAvatarValueKey, _avatarValue!);
      await _persistTransform();
    }
  }

  Future<void> resetAvatar() async {
    _avatarType = null;
    _avatarValue = null;
    _avatarTransform = null;
    notifyListeners();
    await preferences.remove(_prefsAvatarTypeKey);
    await preferences.remove(_prefsAvatarValueKey);
    await preferences.remove(_prefsAvatarTransformKey);
  }

  Future<void> _persistTransform() async {
    if (_avatarTransform == null) {
      await preferences.remove(_prefsAvatarTransformKey);
    } else {
      await preferences.setString(
        _prefsAvatarTransformKey,
        jsonEncode(_avatarTransform!.toJson()),
      );
    }
  }
}
