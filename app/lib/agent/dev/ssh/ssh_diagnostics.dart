/// SSH 连接失败诊断（把底层异常翻译成人话 + 下一步动作）。
///
/// 可用性评估实锤（场景 C）：旧版只有一套 **Termux 话术** 的诊断文案，
/// 连"远程电脑"失败时也在教用户"打开 Termux 重新执行安装命令"，完全跑偏。
/// 这里按 **目标类型（手机 Termux / 远程电脑）+ 认证方式（密钥 / 密码）**
/// 分流，密钥失败不该讲密码，电脑失败不该讲 Termux。
library;

import 'ssh_credentials.dart';

/// 连接目标类型：决定失败话术与修复动作。
enum SshTargetKind {
  /// 手机自身 Termux sshd（127.0.0.1:8022）。
  termux,

  /// 局域网/内网远程电脑（OpenSSH Server、WSL、macOS 远程登录）。
  remotePc,
}

/// 从配置推断目标类型（Termux 向导固定 127.0.0.1:8022，其余按远程电脑处理）。
SshTargetKind sshTargetKindOf(SshConfig config) {
  final host = config.host.trim().toLowerCase();
  final name = config.name.toLowerCase();
  final loopback = host.isEmpty ||
      host == '127.0.0.1' ||
      host == 'localhost' ||
      host == '::1' ||
      host == '127.0.0.53';
  if (name.contains('termux')) return SshTargetKind.termux;
  if (loopback || config.port == 8022) return SshTargetKind.termux;
  return SshTargetKind.remotePc;
}

/// 是否走密码认证（决定"认证不通过"该讲密码还是讲公钥）。
bool sshUsesPasswordAuth(SshConfig config) =>
    config.authType == SshAuthType.password ||
    config.authType == SshAuthType.keyThenPassword;

/// 底层异常 → 用户可读诊断（含下一步动作，不甩原始堆栈）。
///
/// [target] 目标类型；[passwordAuth] 是否用了密码；[keyAuth] 是否用了密钥
/// （两者都为 false 时按"无凭据"提示）。
String classifySshFailure(
  String? raw, {
  SshTargetKind target = SshTargetKind.termux,
  bool passwordAuth = false,
  bool keyAuth = true,
}) {
  final msg = (raw ?? '').trim();
  if (msg.isEmpty) return '连接失败：未知原因（请在「设置 → 开发者」重新连接）';
  final lower = msg.toLowerCase();

  // 配置不完整（含"密钥只存了安全存储但读不回来"）。
  if (lower.contains('配置不完整')) {
    return passwordAuth
        ? '配置不完整：缺少用户名或登录密码。请在「设置 → 开发者」编辑该连接，'
            '填好「用户名 + 电脑登录密码」'
        : '配置不完整：缺少用户名或私钥。请在「设置 → 开发者」编辑该连接，'
            '或用向导重新生成密钥';
  }

  // 主机密钥指纹变化（TOFU 拦截）——与服务端重装/换密钥有关。
  if (lower.contains('主机密钥') || lower.contains('host key')) {
    return '主机密钥指纹与上次记录不一致（服务器重装或中间人风险）。'
        '确认是同一台机器后，在「设置 → 开发者 → 清除指纹」再连';
  }

  // 密钥本身解析失败（旧版向导生成的坏格式密钥）。
  if (lower.contains('密钥无法解析') || lower.contains('pem')) {
    return '私钥格式无法解析：请在「设置 → 开发者」重新生成密钥，'
        '并把新公钥装到对端 authorized_keys';
  }

  // 端口没监听。
  if (lower.contains('refused') || lower.contains('connection reset')) {
    return target == SshTargetKind.termux
        ? '连接失败：Termux 的 sshd 没在运行。打开 Termux 重新执行安装命令'
            '（自带重启 sshd），再点连接'
        : '连接失败：电脑上没有 sshd 在监听该端口。'
            '请先在电脑上开启 SSH 服务（Windows：设置→系统→「远程桌面/OpenSSH Server」'
            '并启动 sshd 服务；Linux：sudo systemctl start ssh；'
            'macOS：系统设置→通用→共享→远程登录），并核对端口（默认 22）';
  }

  // 端口无响应（防火墙/IP/拉黑）。
  if (lower.contains('timed out') || lower.contains('timeout')) {
    return target == SshTargetKind.termux
        ? '连接失败：端口无响应——多半是多次失败后被 Termux OpenSSH 临时拉黑。'
            '在 Termux 重新执行安装命令（自带重启 sshd 清拉黑），再点连接'
        : '连接失败：地址无响应。请核对电脑 IP 是否变化（两台设备需在同一网络）、'
            '端口是否正确、电脑防火墙是否放行该端口（Windows 防火墙常拦 22）';
  }

  // 认证阶段失败。
  if (lower.contains('auth') ||
      lower.contains('denied') ||
      lower.contains('permission') ||
      lower.contains('unauthenticated') ||
      lower.contains('no authentication methods')) {
    if (passwordAuth && !keyAuth) {
      return target == SshTargetKind.termux
        ? '认证失败：用户名或密码不对。Termux 用户名用 `whoami` 查看（形如 u0_aXXX）；'
            'Termux 默认无密码，请先在 Termux 里执行 passwd 设置登录密码'
        : '认证失败：用户名或登录密码不对。用户名是电脑上登录用的账号名'
            '（Windows 可用 Microsoft 账户邮箱前缀）；'
            '若确认密码正确，请检查服务端是否禁用了密码登录'
            '（sshd_config 里 `PasswordAuthentication yes`，改完重启 sshd）';
    }
    if (passwordAuth && keyAuth) {
      return '认证失败：密钥和密码都没通过。请确认用户名正确，'
          '并把向导里的公钥装到对端 authorized_keys；'
          '或改用「密码」登录并确认服务端允许密码认证'
          '（sshd_config：`PasswordAuthentication yes`、`PubkeyAuthentication yes`）';
    }
    return target == SshTargetKind.termux
        ? '认证失败：公钥没装上或用户名不对。重新执行 Termux 安装命令'
            '（把公钥写进 ~/.ssh/authorized_keys），用户名以命令输出 USER= 为准'
        : '认证失败：公钥没装到对端 ~/.ssh/authorized_keys，或用户名不对。'
            '请在电脑上重新执行向导里的公钥安装命令，用户名填电脑登录账号；'
            '不想装公钥可改用「密码」方式连接';
  }

  // 用户名/主机未知之类的解析失败。
  if (lower.contains('failed host lookup') ||
      lower.contains('name or service not known') ||
      lower.contains('nodename')) {
    return '找不到主机「地址」：请检查 IP/主机名是否写错（'
        '电脑 IP 可用 ipconfig / Windows「设置→WLAN」或 `hostname -I` 查看）';
  }

  return '连接失败：$msg';
}
