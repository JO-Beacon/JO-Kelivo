import 'package:dio/dio.dart' show CancelToken;
import 'package:http/http.dart' as http;

import '../../providers/settings_provider.dart';
import 'dio_http_client.dart';

/// 全局代理设置对应的网络配置；未启用或配置不完整时返回 null。
///
/// 供没有供应商归属的请求使用（例如模型目录刷新）。
NetworkProxyConfig? globalProxyConfigFor(SettingsProvider settings) {
  if (!settings.globalProxyEnabled) return null;
  final host = settings.globalProxyHost.trim();
  final port = settings.globalProxyPort.trim();
  if (host.isEmpty || port.isEmpty) return null;
  final user = settings.globalProxyUsername.trim();
  final pass = settings.globalProxyPassword.trim();
  return NetworkProxyConfig(
    enabled: true,
    type: ProviderConfig.resolveProxyType(settings.globalProxyType),
    host: host,
    port: int.tryParse(port) ?? 8080,
    username: user.isEmpty ? null : user,
    password: pass.isEmpty ? null : pass,
  );
}

/// 发往 [config] 端点的 HTTP 客户端；配置了代理时经供应商代理转发。
http.Client providerHttpClient(
  ProviderConfig config, {
  CancelToken? cancelToken,
}) {
  final host = (config.proxyHost ?? '').trim();
  final port = (config.proxyPort ?? '').trim();
  if (config.proxyEnabled == true && host.isNotEmpty && port.isNotEmpty) {
    final user = (config.proxyUsername ?? '').trim();
    final pass = (config.proxyPassword ?? '').trim();
    return DioHttpClient(
      proxy: NetworkProxyConfig(
        enabled: true,
        type: ProviderConfig.resolveProxyType(config.proxyType),
        host: host,
        port: int.tryParse(port) ?? 8080,
        username: user.isEmpty ? null : user,
        password: pass.isEmpty ? null : pass,
      ),
      cancelToken: cancelToken,
    );
  }
  return DioHttpClient(cancelToken: cancelToken);
}
