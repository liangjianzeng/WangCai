/// SSH 密钥/密码安全存储（P2-D3）。
///
/// 旧版把 `privateKeyPem/keyPassphrase/password` 明文存在 settings JSON。
/// 本模块提供：抽象 [SshSecretStore]（生产 = flutter_secure_storage，
/// Android EncryptedSharedPreferences；测试 = 内存实现）+ 三条核心链路：
/// - [saveSshSecrets]：**保存配置时**就把密钥/登录密码写进安全存储，并返回
///   可安全落 settings JSON 的剥离副本（保存即不落明文，不用等下次启动）；
/// - [migrateSshSecrets]：设置加载时把历史 JSON 里的明文密钥搬进安全存储，
///   settings 里只留空槽位（一次性迁移，幂等）；
/// - [resolveSshSecrets] / [resolveSshSecretsAll]：连接前回填凭据
///   （配置自带的值优先 = 本次输入；缺的从安全存储补 = 上次保存的）。
///
/// 凭据按认证方式裁剪（[secretFieldsFor]）：切换认证方式时不相关字段会被
/// 删除，避免"改成密码登录了却还被回填旧私钥"这类残留。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ssh_credentials.dart';

/// 密钥字段键名。
const String kSecretKeyPem = 'privateKeyPem';
const String kSecretKeyPass = 'keyPassphrase';
const String kSecretPassword = 'password';

/// 全部可托管的凭据字段。
const List<String> kAllSecretFields = [
  kSecretKeyPem,
  kSecretKeyPass,
  kSecretPassword,
];

/// 该认证方式真正需要的凭据字段（其余字段在保存时会被清理）。
Set<String> secretFieldsFor(SshAuthType type) => switch (type) {
      SshAuthType.key => {kSecretKeyPem, kSecretKeyPass},
      SshAuthType.password => {kSecretPassword},
      SshAuthType.keyThenPassword => {
        kSecretKeyPem,
        kSecretKeyPass,
        kSecretPassword
      },
    };

/// 抽象存储（键 = `ssh_<configId>_<field>`）。
abstract class SshSecretStore {
  Future<Map<String, String>> read(String configId);
  Future<void> write(String configId, Map<String, String> secrets);
  Future<void> delete(String configId);

  /// 只删指定字段（切换认证方式时清残留，保留仍在用的凭据）。
  Future<void> deleteFields(String configId, Iterable<String> fields);
}

/// 生产实现：flutter_secure_storage。
class FlutterSshSecretStore implements SshSecretStore {
  final FlutterSecureStorage _storage;
  FlutterSshSecretStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  /// 读缓存（只缓存**非空**结果）：EncryptedSharedPreferences 每次读都要解密，
  /// 而工具层自动连接 + 每回合远端 AGENTS.md 读取都会回填凭据，不缓存等于
  /// 每回合多打几次同步桥接。写/删立即失效，另设 TTL 兜底外部变更。
  final Map<String, ({Map<String, String> data, DateTime at})> _memo = {};
  static const Duration _memoTtl = Duration(seconds: 60);

  String _k(String configId, String field) => 'ssh_${configId}_$field';

  @override
  Future<Map<String, String>> read(String configId) async {
    final hit = _memo[configId];
    if (hit != null && DateTime.now().difference(hit.at) < _memoTtl) {
      return Map.of(hit.data);
    }
    final out = <String, String>{};
    for (final field in kAllSecretFields) {
      final v = await _storage.read(key: _k(configId, field));
      if (v != null && v.isNotEmpty) out[field] = v;
    }
    // 空结果不缓存：保存后的"回读校验"必须真的读存储，
    // 缓存空值会把 fail-open 保护变成误判（"密钥丢了"）。
    if (out.isNotEmpty) _memo[configId] = (data: out, at: DateTime.now());
    return out;
  }

  @override
  Future<void> write(String configId, Map<String, String> secrets) async {
    for (final e in secrets.entries) {
      await _storage.write(key: _k(configId, e.key), value: e.value);
    }
    _memo.remove(configId);
  }

  @override
  Future<void> delete(String configId) async {
    for (final field in kAllSecretFields) {
      await _storage.delete(key: _k(configId, field));
    }
    _memo.remove(configId);
  }

  @override
  Future<void> deleteFields(String configId, Iterable<String> fields) async {
    for (final field in fields) {
      await _storage.delete(key: _k(configId, field));
    }
    _memo.remove(configId);
  }
}

/// 内存实现（测试/无平台通道场景）。
class InMemorySshSecretStore implements SshSecretStore {
  final Map<String, Map<String, String>> _data = {};
  @override
  Future<Map<String, String>> read(String configId) async =>
      Map.of(_data[configId] ?? const {});
  @override
  Future<void> write(String configId, Map<String, String> secrets) async =>
      _data[configId] = Map.of(secrets);
  @override
  Future<void> delete(String configId) async => _data.remove(configId);
  @override
  Future<void> deleteFields(String configId, Iterable<String> fields) async {
    _data[configId]?.removeWhere((k, _) => fields.contains(k));
    if (_data[configId]?.isEmpty ?? false) _data.remove(configId);
  }
}

/// 可注入的全局存储（默认 flutter_secure_storage；测试可替换）。
SshSecretStore sshSecretStore = FlutterSshSecretStore();

/// 配置里是否带了明文密钥（待迁移）。
bool hasPlaintextSecrets(SshConfig c) =>
    ((c.privateKeyPem ?? '').isNotEmpty) ||
    ((c.keyPassphrase ?? '').isNotEmpty) ||
    ((c.password ?? '').isNotEmpty);

/// 提取配置中的非空密钥字段。
Map<String, String> _extractSecrets(SshConfig c) => {
      if ((c.privateKeyPem ?? '').isNotEmpty)
        kSecretKeyPem: c.privateKeyPem!,
      if ((c.keyPassphrase ?? '').isNotEmpty)
        kSecretKeyPass: c.keyPassphrase!,
      if ((c.password ?? '').isNotEmpty) kSecretPassword: c.password!,
    };

/// 凭据全清空的配置副本（明文不再落 settings JSON）。
SshConfig _withoutSecrets(SshConfig c) => SshConfig(
      id: c.id,
      name: c.name,
      host: c.host,
      port: c.port,
      username: c.username,
      authType: c.authType,
    );

/// 读取配置某凭据字段的当前值。
String? _fieldOf(SshConfig c, String field) => switch (field) {
      kSecretKeyPem => c.privateKeyPem,
      kSecretKeyPass => c.keyPassphrase,
      kSecretPassword => c.password,
      _ => null,
    };

/// 保存配置：凭据写入安全存储，返回剥离后的配置（供 settings JSON 落盘）。
///
/// 与 [migrateSshSecrets] 同一套回读校验铁律：EncryptedSharedPreferences
/// 异常时写入"成功"却读不回，只有**逐字段回读一致**才允许剥离明文，
/// 否则原样返回（明文留在 JSON，连接仍可用 = fail-open）。
Future<SshConfig> saveSshSecrets(SshConfig config,
    {SshSecretStore? store}) async {
  final st = store ?? sshSecretStore;
  final id = config.id.trim();
  if (id.isEmpty) return config; // 无稳定 id 的临时配置：不进安全存储。
  final needed = secretFieldsFor(config.authType);
  final all = _extractSecrets(config);
  final toWrite = <String, String>{
    for (final e in all.entries)
      if (needed.contains(e.key)) e.key: e.value,
  };
  final stale =
      kAllSecretFields.where((f) => !toWrite.containsKey(f)).toList();
  try {
    // 先清残留（例：密钥 → 密码登录，旧私钥不该再被回填）。
    if (stale.isNotEmpty) await st.deleteFields(id, stale);
    if (toWrite.isEmpty) return _withoutSecrets(config);
    await st.write(id, toWrite);
    final readBack = await st.read(id);
    if (!toWrite.entries.every((e) => readBack[e.key] == e.value)) {
      debugPrint('[SecretStore] 回读校验失败，保留明文（id=$id）');
      return config;
    }
    return _withoutSecrets(config);
  } on Exception catch (e) {
    debugPrint('[SecretStore] save failed for $id: $e（回退明文存储）');
    return config;
  }
}

/// 删除一条配置的全部托管凭据（删除配置时调用，避免孤儿密钥残留）。
Future<void> deleteSshSecrets(String configId, {SshSecretStore? store}) async {
  final id = configId.trim();
  if (id.isEmpty) return;
  try {
    await (store ?? sshSecretStore).delete(id);
  } on Exception catch (e) {
    debugPrint('[SecretStore] delete failed for $id: $e');
  }
}

/// 迁移一批配置：带明文密钥的写入安全存储并剥离；
/// 返回剥离后的配置列表（无变化时返回 null，调用方免 persist）。
Future<List<SshConfig>?> migrateSshSecrets(List<SshConfig> configs,
    {SshSecretStore? store}) async {
  final st = store ?? sshSecretStore;
  var changed = false;
  final out = <SshConfig>[];
  for (final c in configs) {
    if (c.id.isEmpty || !hasPlaintextSecrets(c)) {
      out.add(c);
      continue;
    }
    final secrets = _extractSecrets(c);
    try {
      await st.write(c.id, secrets);
      // 回读校验（真机实锤：EncryptedSharedPreferences decryptKey 失败时
      // 写入"成功"但读不回——直接剥明文 = 密钥丢失、认证必败）。只有
      // 回读逐字段一致才允许剥离明文；否则 fail-open 保留明文。
      final readBack = await st.read(c.id);
      final verified =
          secrets.entries.every((e) => readBack[e.key] == e.value);
      if (!verified) {
        out.add(c);
        continue;
      }
    } on Exception {
      // 安全存储不可用（极少见）：保留明文，连接仍可用（fail-open）。
      out.add(c);
      continue;
    }
    changed = true;
    out.add(_withoutSecrets(c));
  }
  return changed ? out : null;
}

/// 连接/判定完整性前回填凭据：本次配置自带的值优先，缺的从安全存储补。
///
/// 实锤修复：`isComplete` 必须在**回填之后**判——密钥/密码搬进安全存储后
/// settings 里只剩空槽位，直接判 `isComplete` 永远 false，表现为
/// "重启后点连接说配置不完整 / ssh 工具报未配置"（密码登录尤其致命，
/// 因为密码永远是被剥离的那个字段）。
Future<SshConfig> resolveSshSecrets(SshConfig config,
    {SshSecretStore? store}) async {
  if (config.id.isEmpty) return config;
  final needed = secretFieldsFor(config.authType);
  final missing =
      needed.where((f) => (_fieldOf(config, f) ?? '').isEmpty).toList();
  if (missing.isEmpty) {
    // 已带完整凭据（向导刚填好/刚生成）直接用，不读存储。
    return config;
  }
  final Map<String, String> secrets;
  try {
    secrets = await (store ?? sshSecretStore).read(config.id);
  } on Exception catch (e) {
    debugPrint('[SecretStore] read failed for ${config.id}: $e '
        '(安全存储不可用，回退配置自带密钥)');
    return config;
  }
  if (secrets.isEmpty) {
    debugPrint('[SecretStore] no secrets stored for ${config.id} '
        '(迁移未发生或安全存储为空)');
    return config;
  }
  return SshConfig(
    id: config.id,
    name: config.name,
    host: config.host,
    port: config.port,
    username: config.username,
    authType: config.authType,
    privateKeyPem: config.privateKeyPem ?? secrets[kSecretKeyPem],
    keyPassphrase: config.keyPassphrase ?? secrets[kSecretKeyPass],
    password: config.password ?? secrets[kSecretPassword],
  );
}

/// 批量回填（工具层"按工作区绑定配置自动连接"前用）。
Future<List<SshConfig>> resolveSshSecretsAll(List<SshConfig> configs,
    {SshSecretStore? store}) async {
  final out = <SshConfig>[];
  for (final c in configs) {
    try {
      out.add(await resolveSshSecrets(c, store: store));
    } on Exception {
      out.add(c);
    }
  }
  return out;
}
