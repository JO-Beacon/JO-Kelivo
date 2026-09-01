import 'package:mcp_client/mcp_client.dart' as mcp;

import 'kelivo_fetch_server.dart';

/// 构建一个便于函数调用的工具名称（类似 Cherry Studio 的策略）
String buildFunctionCallToolName(String serverName, String toolName) {
  String sanitizedServer = serverName.trim().replaceAll('-', '_');
  String sanitizedTool = toolName.trim().replaceAll('-', '_');
  String name = sanitizedTool;
  if (!sanitizedTool.contains(
    sanitizedServer.substring(0, sanitizedServer.length.clamp(0, 7)),
  )) {
    final head = sanitizedServer.length >= 7
        ? sanitizedServer.substring(0, 7)
        : sanitizedServer;
    name =
        '${head.isNotEmpty ? head : ''}-${sanitizedTool.isNotEmpty ? sanitizedTool : ''}';
  }
  name = name.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  if (!RegExp(r'^[a-zA-Z]').hasMatch(name)) {
    name = 'tool-$name';
  }
  name = name.replaceAll(RegExp(r'[_-]{2,}'), '_');
  if (name.length > 63) {
    name = name.substring(0, 63);
  }
  if (name.endsWith('_') || name.endsWith('-')) {
    name = name.substring(0, name.length - 1);
  }
  return name;
}

/// 启动内存中的 @kelivo/fetch MCP 服务器并连接一个客户端。
/// 返回已连接的客户端以及用于释放两端的 stop()。
Future<({mcp.Client client, Future<void> Function() stop})>
startFetchMcpInMemory() async {
  final server = KelivoFetchMcpServerEngine();
  final transport = KelivoInMemoryClientTransport(server);

  final client = mcp.McpClient.createClient(
    mcp.McpClient.simpleConfig(name: 'JO-AIClient', version: '1.0.0'),
  );
  await client.connect(transport);

  return (
    client: client,
    stop: () async {
      try {
        client.disconnect();
      } catch (_) {}
      try {
        transport.close();
      } catch (_) {}
    },
  );
}

/// 从已连接的内存客户端列出工具，并可选择映射到稳定 id。
Future<List<(mcp.Tool tool, String id)>> listFetchTools(
  mcp.Client client,
) async {
  final tools = await client.listTools();
  const serverName = '@kelivo/fetch';
  return tools
      .map((t) => (t, buildFunctionCallToolName(serverName, t.name)))
      .toList(growable: false);
}

/// 通过内存工具获取 URL，并限制输出大小。
Future<mcp.CallToolResult> callFetchTool(
  mcp.Client client, {
  required String url,
  Map<String, String>? headers,
  int? maxLength,
  int? startIndex,
  bool raw = false,
}) async {
  final result = await client.callTool('kelivo_fetch', {
    'url': url,
    if (headers != null && headers.isNotEmpty) 'headers': headers,
    if (maxLength != null) 'max_length': maxLength,
    if (startIndex != null) 'start_index': startIndex,
    if (raw) 'raw': true,
  });
  return result;
}
