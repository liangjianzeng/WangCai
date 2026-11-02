/// SSH 开发环境配置（Dev Agent Phase B）—— 多目标（Termux / 远程 PC）。
///
/// 每个配置带 id + name（如 "Termux" / "远程电脑"），工作区通过
/// [DevWorkspace.sshConfigId] 绑定。认证三种模式（[SshAuthType]）：
/// - [SshAuthType.key]：ed25519 密钥（app 可自动生成，见 [SshKeyGen]）；
/// - [SshAuthType.password]：**账号密码登录**（远程电脑最常见，无需往对端
///   装公钥；服务端需开 `PasswordAuthentication yes`）；
/// - [SshAuthType.keyThenPassword]：密钥优先、失败自动回落密码（两套凭据）。
///
/// 密钥/密码明文只在内存与向导流程里存在；落 settings JSON 前由
/// `secret_store.dart` 搬进 flutter_secure_storage（不可用时 fail-open 保留明文）。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pinenacl/ed25519.dart';

/// SSH 认证类型。
enum SshAuthType {
  /// 仅密钥（ed25519）。
  key,

  /// 仅密码（用户名 + 登录密码）。
  password,

  /// 密钥优先，认证失败自动回落密码（需同时配好密钥与密码）。
  keyThenPassword,
}

/// SSH 连接配置。
final class SshConfig {
  /// 配置 id（稳定标识，工作区绑定用）；空 = 临时配置。
  final String id;

  /// 配置显示名（如 "Termux"、"远程电脑"）。
  final String name;

  final String host;
  final int port;
  final String username;
  final SshAuthType authType;
  final String? privateKeyPem;
  final String? keyPassphrase;
  final String? password;

  const SshConfig({
    this.id = '',
    this.name = '',
    this.host = '127.0.0.1',
    this.port = 8022,
    this.username = '',
    this.authType = SshAuthType.key,
    this.privateKeyPem,
    this.keyPassphrase,
    this.password,
  });

  /// Termux 默认配置模板（sshd 默认 127.0.0.1:8022）。
  static const SshConfig termuxTemplate = SshConfig(
    id: 'termux',
    name: 'Termux',
    host: '127.0.0.1',
    port: 8022,
  );

  /// 远程电脑模板（OpenSSH 默认 22）。
  ///
  /// host 故意留空：真机评估记录里，预填的占位 IP 常被用户原样提交，
  /// 得到一句"连不上 192.168.1.100"的死胡同报错——地址必须由用户填，
  /// 空 host 会被 `isComplete` 当场拦下（向导按钮就点不动）。
  static const SshConfig remotePcTemplate = SshConfig(
    id: 'remote-pc',
    name: '远程电脑',
    host: '',
    port: 22,
  );

  bool get isComplete =>
      host.trim().isNotEmpty &&
      port > 0 &&
      username.trim().isNotEmpty &&
      switch (authType) {
        SshAuthType.key => hasKey,
        SshAuthType.password => hasPassword,
        SshAuthType.keyThenPassword => hasKey && hasPassword,
      };

  /// 是否带私钥（PEM 非空）。
  bool get hasKey => (privateKeyPem ?? '').trim().isNotEmpty;

  /// 是否带登录密码。
  bool get hasPassword => (password ?? '').isNotEmpty;

  /// 本次认证是否需要用密钥。
  bool get usesKey =>
      (authType == SshAuthType.key || authType == SshAuthType.keyThenPassword) &&
      hasKey;

  /// 本次认证是否需要用密码。
  bool get usesPassword =>
      (authType == SshAuthType.password ||
          authType == SshAuthType.keyThenPassword) &&
      hasPassword;

  /// 切到另一种认证方式，并清掉该方式用不到的凭据（避免旧凭据残留复用）。
  SshConfig withAuth(SshAuthType type) => copyWith(
        authType: type,
        clearPrivateKey: !switch (type) {
          SshAuthType.key => true,
          SshAuthType.password => false,
          SshAuthType.keyThenPassword => true,
        },
        clearPassword: type != SshAuthType.password &&
            type != SshAuthType.keyThenPassword,
      );

  SshConfig copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? username,
    SshAuthType? authType,
    String? privateKeyPem,
    String? keyPassphrase,
    String? password,
    bool clearPrivateKey = false,
    bool clearKeyPassphrase = false,
    bool clearPassword = false,
  }) {
    return SshConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authType: authType ?? this.authType,
      privateKeyPem:
          clearPrivateKey ? null : (privateKeyPem ?? this.privateKeyPem),
      keyPassphrase: clearKeyPassphrase
          ? null
          : (keyPassphrase ?? this.keyPassphrase),
      password: clearPassword ? null : (password ?? this.password),
    );
  }

  Map<String, dynamic> toJson() => {
        if (id.isNotEmpty) 'id': id,
        if (name.isNotEmpty) 'name': name,
        'host': host,
        'port': port,
        if (username.isNotEmpty) 'username': username,
        'authType': authType.name,
        if (privateKeyPem != null) 'privateKeyPem': privateKeyPem,
        if (keyPassphrase != null) 'keyPassphrase': keyPassphrase,
        if (password != null) 'password': password,
      };

  static SshConfig? fromJson(Map<String, dynamic> json) {
    final host = (json['host'] as String?)?.trim() ?? '';
    if (host.isEmpty) return null;
    final auth = SshAuthType.values
        .where((t) => t.name == json['authType'])
        .firstOrNull;
    return SshConfig(
      id: (json['id'] as String?)?.trim() ?? '',
      name: (json['name'] as String?)?.trim() ?? '',
      host: host,
      port: (json['port'] as num?)?.toInt() ?? 8022,
      username: (json['username'] as String?)?.trim() ?? '',
      // 旧版 JSON 缺 authType 且带 password → 识别为密码登录，别回落成密钥。
      authType: auth ??
          ((json['privateKeyPem'] as String?)?.trim().isNotEmpty ?? false
              ? SshAuthType.key
              : ((json['password'] as String?)?.isNotEmpty ?? false
                  ? SshAuthType.password
                  : SshAuthType.key)),
      privateKeyPem: (json['privateKeyPem'] as String?)?.trim(),
      keyPassphrase: (json['keyPassphrase'] as String?)?.trim(),
      password: (json['password'] as String?)?.trim(),
    );
  }
}

/// 自动生成 ed25519 密钥对（pinenacl TweetNaCl 移植，无需外部依赖）。
///
/// - [privateKeyPem]：OpenSSH 私钥格式（`-----BEGIN OPENSSH PRIVATE KEY-----`），
///   可直接粘贴到 Termux/PC 的 `authorized_keys` 安装命令里；
/// - [publicKey]：`ssh-ed25519 AAAA...`（一行），写入对端 `~/.ssh/authorized_keys`。
final class SshKeyGen {
  SshKeyGen._();

  /// 生成新密钥对；返回 null 表示失败（随机源异常等）。
  static ({String privateKeyPem, String publicKey})? generate() {
    try {
      final signing = SigningKey.generate();
      final seed = signing.seed.asTypedList;
      final pub = signing.verifyKey.asTypedList;
      if (seed.length != 32 || pub.length != 32) return null;

      final privateKeyPem = _encodeOpenSshPrivate(seed, pub);
      final publicKey = _encodeOpenSshPublic(pub);
      if (privateKeyPem.isEmpty || publicKey.isEmpty) return null;
      return (privateKeyPem: privateKeyPem, publicKey: publicKey);
    } catch (_) {
      return null;
    }
  }

  static const String _type = 'ssh-ed25519';

  /// OpenSSH 私钥格式编码（openssh-key-v1，无口令 none/none）。
  static String _encodeOpenSshPrivate(Uint8List seed, Uint8List pub) {
    final b = BytesBuilder(copy: false);
    // magic "openssh-key-v1\0"
    b.add(utf8.encode('openssh-key-v1'));
    b.addByte(0);
    // ciphername "none"
    _writeString(b, 'none');
    // kdfname "none"
    _writeString(b, 'none');
    // kdf options (empty)
    b.add(_u32(0));
    // number of keys
    b.add(_u32(1));
    // publicKeys[0]：完整 key blob = string(type) + string(pub)
    // （openssh 格式：数组元素是嵌套 blob，不是裸 type 串）。
    final pubBlob = BytesBuilder(copy: false);
    _writeString(pubBlob, _type);
    _writeString(pubBlob, pub);
    _writeString(b, pubBlob.toBytes());
    // privateKeysBlob（整体包成一个 string）：
    //   checkint×2（同一 64 位随机；openssh 官方为 32 位随机转 64 位）
    //   + string(type) + string(pub) + string(priv) + comment + padding
    final privBlob = BytesBuilder(copy: false);
    // checkint = 同一 32 位随机写两次（openssh-key-v1 规范，非 uint64）
    final check = Random.secure().nextInt(0xFFFFFFFF);
    privBlob.add(_u32(check));
    privBlob.add(_u32(check));
    final priv = Uint8List.fromList([...seed, ...pub]);
    _writeString(privBlob, _type);
    _writeString(privBlob, pub);
    _writeString(privBlob, priv);
    _writeString(privBlob, '');
    // padding：填充至 8 字节块（至少 1 字节），第 i 字节值 = i+1
    // （openssh-key-v1 规范如此，新版 OpenSSH 会逐字节校验，填错直接拒收）
    final padLen = 8 - (privBlob.length % 8);
    for (var i = 0; i < padLen; i++) {
      privBlob.addByte(i + 1);
    }
    _writeString(b, privBlob.toBytes());
    final body = base64Encode(b.toBytes());
    // 70 列换行
    final lines = <String>[
      for (var i = 0; i < body.length; i += 70)
        body.substring(i, (i + 70).clamp(0, body.length)),
    ];
    return '-----BEGIN OPENSSH PRIVATE KEY-----\n'
        '${lines.join('\n')}\n'
        '-----END OPENSSH PRIVATE KEY-----\n';
  }

  /// OpenSSH 公钥格式：`ssh-ed25519 <base64(string(type) + string(pub))>`。
  static String _encodeOpenSshPublic(Uint8List pub) {
    final b = BytesBuilder(copy: false);
    _writeString(b, _type);
    _writeString(b, pub);
    return '$_type ${base64Encode(b.toBytes())}';
  }

  /// SSH string：uint32 长度 + 原始字节。
  static void _writeString(BytesBuilder b, Object data) {
    final bytes = data is Uint8List
        ? data
        : Uint8List.fromList(utf8.encode(data as String));
    b.add(_u32(bytes.length));
    b.add(bytes);
  }

  static Uint8List _u32(int v) => Uint8List.fromList([
        (v >> 24) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 8) & 0xFF,
        v & 0xFF,
      ]);
}
