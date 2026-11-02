/// P2-D 批次测试：SSH 密钥安全存储迁移/回填、Dev 工具逐组开关设置往返、
/// workspace_sync 参数校验、MCP 设置往返。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/builtin_tools/builtin_tools.dart';
import 'package:tongyi_lite/agent/dev/ssh/secret_store.dart';
import 'package:tongyi_lite/agent/dev/ssh/ssh_credentials.dart';
import 'package:tongyi_lite/agent/mcp/mcp_client.dart';
import 'package:tongyi_lite/services/settings_service.dart';

void main() {
  group('P2-D3 SSH 密钥安全存储', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('secret_test');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('迁移：明文密钥搬进存储、settings 剥离；幂等（二次 null）', () async {
      final store = InMemorySshSecretStore();
      final cfg = SshConfig(
        id: 'termux',
        name: 'Termux',
        host: '127.0.0.1',
        port: 8022,
        username: 'u0_a1',
        authType: SshAuthType.key,
        privateKeyPem: '-----BEGIN PRIVATE KEY-----\nabc\n',
        keyPassphrase: 'pp',
      );
      final out = await migrateSshSecrets([cfg], store: store);
      expect(out, isNotNull);
      final stripped = out![0];
      expect(stripped.privateKeyPem, isNull);
      expect(stripped.keyPassphrase, isNull);
      final secrets = await store.read('termux');
      expect(secrets[kSecretKeyPem], contains('BEGIN PRIVATE KEY'));
      expect(secrets[kSecretKeyPass], 'pp');
      // 幂等：已无明文 → null
      expect(await migrateSshSecrets([stripped], store: store), isNull);
    });

    test('回填：剥离后的配置 + 存储 → 连接用配置带密钥', () async {
      final store = InMemorySshSecretStore();
      await store.write('termux', {
        kSecretKeyPem: 'PEM-DATA',
        kSecretPassword: 'pw',
      });
      final stripped = SshConfig(
          id: 'termux', username: 'u', authType: SshAuthType.key);
      final resolved = await resolveSshSecrets(stripped, store: store);
      expect(resolved.privateKeyPem, 'PEM-DATA');
      expect(resolved.password, 'pw');
      expect(resolved.isComplete, isTrue);
    });

    test('回填：配置自带密钥时直通（不读存储）', () async {
      final store = InMemorySshSecretStore();
      final full = SshConfig(
          id: 'x',
          username: 'u',
          authType: SshAuthType.key,
          privateKeyPem: 'FRESH');
      final resolved = await resolveSshSecrets(full, store: store);
      expect(resolved.privateKeyPem, 'FRESH');
    });

    test('无 id / 无密钥：迁移跳过', () async {
      final store = InMemorySshSecretStore();
      final cfg = SshConfig(username: 'u', authType: SshAuthType.key);
      expect(await migrateSshSecrets([cfg], store: store), isNull);
    });
  });

  group('P2-D1/D 设置往返（devToolToggles / mcpServers / goal / trace）', () {
    test('copyWith + toJson + fromJson 往返', () {
      const base = InferenceSettings();
      final s = base.copyWith(
        devToolToggles: const {'git': false, 'sync': false},
        mcpServers: [
          const McpServerConfig(
              id: 'm1', name: 'tools', url: 'http://x:3000/mcp'),
        ],
        agentGoalMaxRounds: 12,
        agentTraceExportEnabled: true,
        agentCompressionApiModelId: 'api-1',
      );
      final json = jsonEncode(s.toJson());
      final parsed = InferenceSettings.fromJson(
          jsonDecode(json) as Map<String, dynamic>);
      expect(parsed.devToolGroupEnabled('git'), isFalse);
      expect(parsed.devToolGroupEnabled('ssh'), isTrue, reason: '缺省 = 开');
      expect(parsed.devToolGroupEnabled('sync'), isFalse);
      expect(parsed.mcpServers.length, 1);
      expect(parsed.mcpServers[0].name, 'tools');
      expect(parsed.agentGoalMaxRounds, 12);
      expect(parsed.agentTraceExportEnabled, isTrue);
      expect(parsed.agentCompressionApiModelId, 'api-1');
      // 旧 JSON（无新字段）→ 默认值
      final legacy = InferenceSettings.fromJson(
          jsonDecode(jsonEncode(base.toJson())) as Map<String, dynamic>);
      expect(legacy.devToolGroupEnabled('git'), isTrue);
      expect(legacy.mcpServers, isEmpty);
      expect(legacy.agentGoalMaxRounds, 8);
      expect(legacy.agentTraceExportEnabled, isFalse);
    });
  });

  group('P2-D4 workspace_sync 参数校验', () {
    test('默认工作区 → 明确报错；非法 direction → 报错', () async {
      final tool = createWorkspaceSyncTool();
      final r1 = await tool.execute({'direction': 'push'});
      expect(r1.isError, isTrue);
      expect(r1.content, contains('本地默认工作区'));
      final r2 = await tool.execute({'direction': 'sideways'});
      expect(r2.isError, isTrue);
      expect(r2.content, contains('push 或 pull'));
    });

    test('工具注册在 Dev 组（includeDevTools）', () {
      final tools = createBuiltinTools(includeDevTools: true);
      expect(tools.any((t) => t.name == 'workspace_sync'), isTrue);
      final plain = createBuiltinTools();
      expect(plain.any((t) => t.name == 'workspace_sync'), isFalse);
    });
  });
}
