import '../../../core/providers/settings_provider.dart';
import '../../../core/models/assistant.dart';

/// 用于提取模型显示信息的辅助类。
///
/// 此类消除了在 home_page.dart 多处重复出现的供应商或模型信息获取模式。
class ModelDisplayInfo {
  const ModelDisplayInfo({
    this.providerName,
    this.modelDisplay,
    this.providerKey,
    this.modelId,
  });

  /// 供应商显示名（例如 "OpenAI"、"Anthropic"）
  final String? providerName;

  /// 模型显示名（来自覆盖项、apiModelId 或原始 modelId）
  final String? modelDisplay;

  /// 设置中使用的原始供应商键
  final String? providerKey;

  /// 原始模型 ID
  final String? modelId;

  /// 检查供应商和模型是否都已配置
  bool get isConfigured => providerKey != null && modelId != null;

  /// 获取此模型的 ProviderConfig（已配置时）
  ProviderConfig? getConfig(SettingsProvider settings) {
    if (providerKey == null) return null;
    return settings.getProviderConfig(providerKey!);
  }
}

/// 从设置和助手中提取模型显示信息。
///
/// 统一了以下重复模式：
/// ```dart
/// final providerKey = assistant?.chatModelProvider ?? settings.currentModelProvider;
/// final modelId = assistant?.chatModelId ?? settings.currentModelId;
/// if (providerKey != null && modelId != null) {
///   final cfg = settings.getProviderConfig(providerKey);
///   final ov = cfg.modelOverrides[modelId] as Map?;
///   // ...处理覆盖项
/// }
/// ```
ModelDisplayInfo getModelDisplayInfo(
  SettingsProvider settings, {
  Assistant? assistant,
}) {
  // 从助手或全局默认值确定供应商和模型
  final providerKey =
      assistant?.chatModelProvider ?? settings.currentModelProvider;
  final modelId = assistant?.chatModelId ?? settings.currentModelId;

  if (providerKey == null || modelId == null) {
    return const ModelDisplayInfo();
  }

  final cfg = settings.getProviderConfig(providerKey);
  final providerName = cfg.name.isNotEmpty ? cfg.name : providerKey;

  // 从覆盖项提取模型显示名，否则使用原始 modelId
  String modelDisplay = modelId;
  final ov = cfg.modelOverrides[modelId] as Map?;
  if (ov != null) {
    // 优先级：覆盖名称 > apiModelId > api_model_id > 原始 modelId
    final overrideName = (ov['name'] as String?)?.trim();
    if (overrideName != null && overrideName.isNotEmpty) {
      modelDisplay = overrideName;
    } else {
      final apiId = (ov['apiModelId'] ?? ov['api_model_id'])?.toString().trim();
      if (apiId != null && apiId.isNotEmpty) {
        modelDisplay = apiId;
      }
    }
  }

  return ModelDisplayInfo(
    providerName: providerName,
    modelDisplay: modelDisplay,
    providerKey: providerKey,
    modelId: modelId,
  );
}

/// 只获取供应商键和模型 ID，不做显示格式化。
/// 当只需要 API 调用的原始标识时使用。
({String? providerKey, String? modelId}) getActiveModelIds(
  SettingsProvider settings, {
  Assistant? assistant,
}) {
  return (
    providerKey: assistant?.chatModelProvider ?? settings.currentModelProvider,
    modelId: assistant?.chatModelId ?? settings.currentModelId,
  );
}

/// 获取当前模型的 ProviderConfig。
ProviderConfig? getActiveProviderConfig(
  SettingsProvider settings, {
  Assistant? assistant,
}) {
  final providerKey =
      assistant?.chatModelProvider ?? settings.currentModelProvider;
  if (providerKey == null) return null;
  return settings.getProviderConfig(providerKey);
}
