/// 远程电脑「密码连接」支持（2026-10-27）回归：
/// 认证模型（密钥 / 密码 / 密钥+密码兜底）、凭据安全存储的保存与回填、
/// 以及连接失败诊断按目标类型 + 认证方式分流。
///
/// 背景（真机可用性评估）：远程电脑向导此前只会生成密钥，用户想直接用
/// 账号密码连做不到；且私钥/密码搬进安全存储后 `isComplete` 恒 false，
/// 表现为"配好了却报配置不完整"。
import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/dev/ssh/secret_store.dart';
import 'package:tongyi_lite/agent/dev/ssh/ssh_credentials.dart';
import 'package:tongyi_lite/agent/dev/ssh/ssh_diagnostics.dart';

SshConfig _pc({
  SshAuthType authType = SshAuthType.password,
  String? password,
  String? privateKeyPem,
  String id = 'remote-pc',
}) =>
    SshConfig(
      id: id,
      name: '远程电脑',
      host: '192.168.1.20',
      port: 22,
      username: 'alice',
      authType: authType,
      password: password,
      privateKeyPem: privateKeyPem,
    );

/// 安全存储不可用的场景（fail-open 必须保留明文，否则凭据直接丢）。
class _BrokenStore implements SshSecretStore {
  @override
  Future<Map<String, String>> read(String configId) async => const {};
  @override
  Future<void> write(String configId, Map<String, String> secrets) async {
    throw Exception('EncryptedSharedPreferences decryptKey failed');
  }

  @override
  Future<void> delete(String configId) async {}
  @override
  Future<void> deleteFields(String configId, Iterable<String> fields) async {}
}

void main() {
  group('SshConfig 认证方式', () {
    test('密码模式：必须有密码才算完整（host/port/username 也必填）', () {
      expect(_pc(password: 's3cret').isComplete, isTrue);
      expect(_pc(password: '').isComplete, isFalse);
      expect(_pc(password: null).isComplete, isFalse);
      expect(_pc(password: 'x').copyWith(username: ' ').isComplete, isFalse);
      expect(_pc(password: 'x').copyWith(port: 0).isComplete, isFalse);
    });

    test('密钥模式：必须有私钥；密码不参与判定', () {
      final cfg = _pc(authType: SshAuthType.key, privateKeyPem: '-----PEM---');
      expect(cfg.isComplete, isTrue);
      expect(cfg.usesKey, isTrue);
      expect(cfg.usesPassword, isFalse);
      expect(
          _pc(authType: SshAuthType.key, privateKeyPem: null).isComplete,
              isFalse, reason: '只有密码不算密钥模式完整');
    });

    test('密钥+密码兜底：两者齐了才完整，且两通道都启用', () {
      final both = _pc(
          authType: SshAuthType.keyThenPassword,
          privateKeyPem: 'PEM',
          password: 'pw');
      expect(both.isComplete, isTrue);
      expect(both.usesKey, isTrue);
      expect(both.usesPassword, isTrue);
      expect(
          _pc(authType: SshAuthType.keyThenPassword, privateKeyPem: 'PEM')
              .isComplete,
          isFalse);
    });

    test('withAuth 切换认证方式时清掉用不到的凭据（不残留旧凭据）', () {
      final both = _pc(
          authType: SshAuthType.keyThenPassword,
          privateKeyPem: 'PEM',
          password: 'pw');
      final toPwd = both.withAuth(SshAuthType.password);
      expect(toPwd.privateKeyPem, isNull);
      expect(toPwd.password, 'pw');
      final toKey = both.withAuth(SshAuthType.key);
      expect(toKey.password, isNull);
      expect(toKey.privateKeyPem, 'PEM');
      // 切到兜底模式两套凭据都保留。
      expect(both.withAuth(SshAuthType.keyThenPassword).hasKey, isTrue);
    });

    test('JSON 往返：authType 三种都能存回；旧 JSON 缺字段按凭据推断', () {
      for (final t in SshAuthType.values) {
        final cfg = _pc(
            authType: t,
            password: t == SshAuthType.key ? null : 'pw',
            privateKeyPem: t == SshAuthType.password ? null : 'PEM');
        final back = SshConfig.fromJson(cfg.toJson())!;
        expect(back.authType, t);
        expect(back.isComplete, isTrue);
      }
      // 旧版 JSON：没有 authType 字段但带 password → 识别为密码登录。
      final legacy = SshConfig.fromJson({
        'host': '10.0.0.5',
        'port': 22,
        'username': 'bob',
        'password': 'old-pw',
      })!;
      expect(legacy.authType, SshAuthType.password);
      expect(legacy.isComplete, isTrue);
      // 旧版 JSON：没有 authType 但带私钥 → 密钥登录。
      final legacyKey = SshConfig.fromJson({
        'host': '10.0.0.5',
        'port': 22,
        'username': 'bob',
        'privateKeyPem': 'PEM',
      })!;
      expect(legacyKey.authType, SshAuthType.key);
    });
  });

  group('凭据安全存储：保存 / 回填 / 清理', () {
    late InMemorySshSecretStore store;
    setUp(() => store = InMemorySshSecretStore());

    test('saveSshSecrets：密码进安全存储，返回的配置无明文（可安全落 JSON）',
        () async {
      final saved = await saveSshSecrets(_pc(password: 'pw123'), store: store);
      expect(saved.password, isNull, reason: '明文不得进 settings JSON');
      expect(saved.authType, SshAuthType.password, reason: '认证方式要保住');
      expect((await store.read('remote-pc'))[kSecretPassword], 'pw123');
    });

    test('回填：剥离后的密码配置补齐后即可判定完整（连接可用）', () async {
      final saved = await saveSshSecrets(_pc(password: 'pw123'), store: store);
      expect(saved.isComplete, isFalse, reason: '剥离后是空槽位');
      final resolved = await resolveSshSecrets(saved, store: store);
      expect(resolved.password, 'pw123');
      expect(resolved.isComplete, isTrue, reason: '完整性必须在回填之后判');
    });

    test('批量回填：多条配置各自补齐', () async {
      await saveSshSecrets(_pc(password: 'a'), store: store);
      await saveSshSecrets(
          _pc(id: 'termux', authType: SshAuthType.key, privateKeyPem: 'PEM'),
          store: store);
      final list = await resolveSshSecretsAll([
        _pc(password: null),
        _pc(id: 'termux', authType: SshAuthType.key, privateKeyPem: null),
      ], store: store);
      expect(list[0].isComplete, isTrue);
      expect(list[1].isComplete, isTrue);
    });

    test('本次输入优先于已存凭据（用户刚改的密码立刻生效）', () async {
      await saveSshSecrets(_pc(password: 'old'), store: store);
      final resolved =
          await resolveSshSecrets(_pc(password: 'new'), store: store);
      expect(resolved.password, 'new');
    });

    test('切换认证方式：不用的凭据被删除，不会被回填复用', () async {
      await saveSshSecrets(
          _pc(authType: SshAuthType.keyThenPassword,
              privateKeyPem: 'PEM', password: 'pw'),
          store: store);
      expect((await store.read('remote-pc')).keys, containsAll(<String>{
        kSecretKeyPem,
        kSecretPassword
      }));
      // 改回纯密码登录 → 私钥字段应被清掉。
      await saveSshSecrets(_pc(authType: SshAuthType.password, password: 'pw'),
          store: store);
      final left = await store.read('remote-pc');
      expect(left.containsKey(kSecretKeyPem), isFalse);
      expect(left[kSecretPassword], 'pw');
    });

    test('安全存储不可用 → fail-open 保留明文（连接不中断）', () async {
      final cfg = _pc(password: 'pw123');
      final saved = await saveSshSecrets(cfg, store: _BrokenStore());
      expect(saved.password, 'pw123', reason: '写不进安全存储就不能剥明文');
    });

    test('无 id 的临时配置不入安全存储', () async {
      final saved =
          await saveSshSecrets(_pc(id: '', password: 'pw'), store: store);
      expect(saved.password, 'pw');
      expect(await store.read('remote-pc'), isEmpty);
    });

    test('deleteSshSecrets：删配置时凭据一并清掉', () async {
      await saveSshSecrets(_pc(password: 'pw'), store: store);
      await deleteSshSecrets('remote-pc', store: store);
      expect(await store.read('remote-pc'), isEmpty);
      final resolved = await resolveSshSecrets(_pc(), store: store);
      expect(resolved.isComplete, isFalse);
    });
  });

  group('连接失败诊断分流（电脑 ≠ Termux，密码 ≠ 密钥）', () {
    test('目标推断：环回/8022 = Termux，其余 = 远程电脑', () {
      expect(
          sshTargetKindOf(const SshConfig(
              host: '127.0.0.1', port: 8022, username: 'u')),
          SshTargetKind.termux);
      expect(
          sshTargetKindOf(const SshConfig(
              host: '192.168.1.20', port: 22, username: 'u')),
          SshTargetKind.remotePc);
      expect(
          sshTargetKindOf(const SshConfig(
              name: 'Termux', host: '10.0.0.9', port: 22, username: 'u')),
          SshTargetKind.termux);
    });

    test('远程电脑 + 端口没监听 → 讲 OpenSSH 服务，不讲 Termux', () {
      final msg = classifySshFailure('SocketException: Connection refused',
          target: SshTargetKind.remotePc, passwordAuth: true, keyAuth: false);
      expect(msg, contains('sshd'));
      expect(msg, contains('OpenSSH'));
      expect(msg.contains('Termux'), isFalse, reason: '电脑失败不该讲 Termux');
    });

    test('Termux + 端口没监听 → 沿用 Termux 修复话术', () {
      final msg = classifySshFailure('SocketException: Connection refused',
          target: SshTargetKind.termux);
      expect(msg, contains('Termux'));
    });

    test('密码认证失败 → 提示密码/PasswordAuthentication，不讲公钥', () {
      final msg = classifySshFailure(
          'SSHAuthFailError: All authentication methods failed',
          target: SshTargetKind.remotePc,
          passwordAuth: true,
          keyAuth: false);
      expect(msg, contains('密码'));
      expect(msg, contains('PasswordAuthentication'));
      expect(msg.contains('authorized_keys'), isFalse);
    });

    test('密钥认证失败（电脑）→ 提示公钥没装上，并给出改用密码的出路', () {
      final msg = classifySshFailure('Permission denied (publickey)',
          target: SshTargetKind.remotePc, passwordAuth: false, keyAuth: true);
      expect(msg, contains('authorized_keys'));
      expect(msg, contains('密码'));
    });

    test('配置不完整（密码模式）→ 让用户补用户名/密码', () {
      final msg = classifySshFailure('SSH 配置不完整（host/port/username/认证）',
          target: SshTargetKind.remotePc, passwordAuth: true, keyAuth: false);
      expect(msg, contains('密码'));
      expect(msg.contains('私钥'), isFalse);
    });

    test('主机密钥指纹变化 → 指向清除指纹', () {
      final msg = classifySshFailure('主机密钥指纹与上次不一致（ssh-ed25519），已拒绝连接',
          target: SshTargetKind.remotePc);
      expect(msg, contains('清除指纹'));
    });
  });
}
