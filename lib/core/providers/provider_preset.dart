import '../../l10n/app_localizations.dart';

/// 添加供应商时可选的厂商预设。
///
/// 这里只列「提供哪些厂商」与展示顺序。接口地址与协议类型统一由
/// `ProviderConfig.defaultsFor` 与 `ProviderConfig.classify` 给出，避免出现
/// 第二份「厂商 → 地址」的表；供应商方言也是按域名识别的，所以预设的价值在于
/// 把地址填对，名字只是便利。
abstract final class ProviderPreset {
  /// 可选厂商，按展示顺序。键名同时作为默认名称（未本地化的那些）。
  static const List<String> vendorKeys = <String>[
    'OpenAI',
    'Gemini',
    'Claude',
    'SiliconFlow',
    'DeepSeek',
    'OpenRouter',
    'AIhubmix',
    'Aliyun',
    'Zhipu AI',
    'Grok',
    'ByteDance',
    'KelivoIN',
    'Tensdaq',
  ];

  /// 预设的显示名；只有几个厂商有本地化名字，其余直接用键名。
  static String label(String key, AppLocalizations l10n) {
    switch (key) {
      case 'SiliconFlow':
        return l10n.providersPageSiliconFlowName;
      case 'Aliyun':
        return l10n.providersPageAliyunName;
      case 'Zhipu AI':
        return l10n.providersPageZhipuName;
      case 'ByteDance':
        return l10n.providersPageByteDanceName;
    }
    return key;
  }
}
