/// Dev 安全护栏（Dev Agent Phase B）—— 危险命令黑名单（deny 档，全通道共用）。
///
/// **2026-10-20 可用性评估后重写**
/// （见 `docs/开发者模式可用性全面评估_2026-10-20.md` §四·六）。
/// 旧版对**未分词的整条 shell 串**跑 13 条正则，实测误杀 45–65% 的正常开发命令
/// （`dart format lib/`、`npm run sync`、`git commit -m "fix mount bug"`、
/// `git push --force-with-lease`、Termux 下 `rm -rf .../build`），
/// 而 `\rm -rf /`、`/bin/rm -rf /`、`bash -c "rm -rf /"`、`git push -f` 全部放行
/// —— 拦不住真要命的，专拦天天用的。
///
/// 新版三条原则：
/// 1. **只在命令位判定**：先按 `;` `&&` `||` `|` 换行 切段，取每段首 token
///    （去引号、去 `\` 转义、取 basename、跳过 `env`/`command`/`nohup` 等包装），
///    参数位与引号内字符串一律不参与关键词匹配 —— 于是 `dart format`（格式化代码）
///    与 `mkfs`（格式化磁盘）、`npm run sync`（脚本名）与 `sync`（刷盘）不再混为一谈，
///    提交信息 / grep 参数 / 工作区名也不再毒化判定。
/// 2. **只拦真破坏性形态**：越界 `rm`/`find -delete`、`mkfs`、`dd of=/dev/…`、
///    重启关机、`su`/`sudo`、git 硬重置与**真**强推（放行 `--force-with-lease`）、
///    管道进 shell、写系统文件、系统路径递归 `chmod 777`。
/// 3. **宁可漏杀，不可误杀**：本文件只是最后一道粗筛，**不是权限边界**；
///    真正的边界是工作区 jail + 分级授权（评估报告 §六 第 1 批）。
///
/// 回归：`test/agent/dev_safety_matrix_test.dart`（误杀表断言放行 / 漏杀表断言拦截，
/// 双向锁死）。**改这里的规则必须同步改那个表。**
library;

/// 危险命令策略。
///
/// 注意：`ask` 档需要审批链接线才生效（评估报告 P0-13：`preListeners` 生产从不传，
/// 工具级审批框永不触发）。接线落地前，本文件只做 deny 判定。
enum DangerousCommandPolicy { deny, ask }

/// 拒绝原因统一后缀：给模型收敛指令，避免同一条命令反复重试烧 round。
const String kDangerousCommandHint =
    '。请勿用同一条命令重试：改用工作区内的相对路径、拆成更安全的等价命令，或向用户说明需求';

/// 包装命令：判定命令位时跳过（`env rm`、`command rm`、`nohup rm` 都算 `rm`）。
const Set<String> _wrapperCommands = {
  'env', 'command', 'exec', 'time', 'nohup', 'nice', 'stdbuf', 'busybox', 'setsid',
};

/// 管道目标即视为"下载/生成脚本后执行"的解释器。
const Set<String> _shellInterpreters = {
  'sh', 'bash', 'dash', 'ksh', 'zsh', 'node',
};

/// 仅当被管道喂入时才判危的脚本解释器。
const Set<String> _scriptInterpreters = {'python', 'python3', 'perl', 'ruby', 'php'};

/// 管道喂给脚本解释器时判危的来源命令。
const Set<String> _untrustedPipeSources = {'curl', 'wget', 'base64'};

/// 可用 `-c` / `-e` 携带一段脚本的解释器（子 shell 逃逸的常见载体）。
const Set<String> _scriptCarriers = {
  'sh', 'bash', 'dash', 'ksh', 'zsh', 'busybox',
  'python', 'python3', 'perl', 'ruby', 'node',
};

/// 只在「解释器 -c 的参数」这个**窄位置**使用的兜底正则。
///
/// 与旧版的区别：旧版拿类似正则去扫**未分词的整条命令**，于是 `dart format`、
/// `git commit -m "…format…"` 全被误杀；这里只看解释器参数内部。
/// 只在「解释器 -c 的参数」这个**窄位置**使用的兜底正则。
///
/// 与旧版的区别：旧版拿类似正则去扫**未分词的整条命令**，于是 `dart format`、
/// `git commit -m "…format…"` 全被误杀；这里只看解释器参数内部。
/// 只保留"递归看不到"的形态（嵌在别的语言字符串里的 rm / 写块设备 / 格式化），
/// `reboot` 这类命令位形态交给递归判定，不进兜底正则 —— 避免
/// `bash -c "echo 'reboot required'"` 这种被误杀。
final RegExp _nestedDangerousRegex = RegExp(
  r'''\brm\s+(-\w+\s+)*(-rf|-fr|-r\s+-f|-f\s+-r)\s+(/|~|\$HOME)(\s|$|/|\*|['")])'''
  r'''|\bmkfs(\.\w+)?\s|\bmke2fs\b|\bdd\s+[^|;]*of=/dev/''',
  caseSensitive: false,
);

/// 取解释器 `-c` / `-e` 后面那段脚本。
String? _carrierScript(List<String> args) {
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '-c' || args[i] == '-e') return args[i + 1];
  }
  return null;
}

/// 可自由读写的暂存/共享前缀：这些前缀下的路径**不算**越界（否则 Termux home、
/// 共享交换目录、/tmp 清理全被误杀）。
const List<String> _scratchPrefixes = [
  '/tmp/', '/var/tmp/', '/sdcard/', '/storage/', '/data/data/',
  '/home/', '/mnt/', '/media/', '/mnt/sdcard/',
];

/// 引号内空格的哨兵（保持引号串是单个 token，不参与 `&&`/`|` 切段）。
const String _spaceSentinel = '\u0000';

/// 把命令切成「段 × token」：按未加引号的 `;` `&&` `||` `|` 换行 切段。
///
/// - 引号内的 `;`/`|`/空格 不切段（哨兵替代空格，保持单 token）；
/// - 反斜杠转义在切段前剥掉（`\rm` → `rm`，堵最常见的绕过）；
/// - 保留 token 原始引号，供 [ _cmdName ] 与目标判定各自处理。
List<List<String>> tokenizeSegments(String input) {
  final segments = <List<String>>[];
  var current = <String>[];
  final buf = StringBuffer();
  String? quote;

  void flushToken() {
    if (buf.isNotEmpty) {
      current.add(buf.toString());
      buf.clear();
    }
  }

  void flushSegment() {
    flushToken();
    if (current.isNotEmpty) {
      segments.add(current);
      current = <String>[];
    }
  }

  for (var i = 0; i < input.length; i++) {
    final c = input[i];
    if (quote != null) {
      if (c == r'\' && quote == '"' && i + 1 < input.length) {
        buf.write(c);
        buf.write(input[++i]);
        continue;
      }
      if (c == quote) {
        quote = null;
        buf.write(c);
        continue;
      }
      buf.write(c == ' ' ? _spaceSentinel : c);
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      buf.write(c);
      continue;
    }
    if (c == r'\' && i + 1 < input.length) {
      buf.write(input[++i]); // \rm → rm
      continue;
    }
    if (c == ';' || c == '\n' || c == '\r') {
      flushSegment();
      continue;
    }
    if (c == '|' || c == '&') {
      if (i + 1 < input.length && input[i + 1] == c) i++; // 折叠 && / ||
      flushSegment();
      continue;
    }
    if (c == ' ' || c == '\t') {
      flushToken();
      continue;
    }
    buf.write(c);
  }
  flushSegment();
  return segments;
}

/// 去掉 token 外层引号并把哨兵还原为空格。
String _unquote(String token) {
  var t = token;
  if (t.length >= 2) {
    final first = t[0];
    final last = t[t.length - 1];
    if ((first == "'" && last == "'") || (first == '"' && last == '"')) {
      t = t.substring(1, t.length - 1);
    }
  }
  return t.replaceAll(_spaceSentinel, ' ').trim();
}

/// 取命令名：剥引号、剥路径前缀（basename）、小写。
/// `/bin/rm`、`/system/bin/rm` 都归一成 `rm` —— 这是旧版漏杀
/// `/bin/rm -rf /`、`env rm -rf /` 的根因。
String _cmdName(String token) {
  var t = _unquote(token).toLowerCase();
  final slash = t.lastIndexOf('/');
  if (slash >= 0) t = t.substring(slash + 1);
  return t;
}

/// 判定绝对/相对目标路径是否**逃出工作区语义**（越界 = 系统路径或上跳多级）。
///
/// 注意 Termux home 是 `/data/data/com.termux/files/home/…`，与系统目录 `/data`
/// 字面撞车 —— 旧版据此把 Termux 清构建产物一律判危。这里用"深度 + 暂存前缀"放过。
bool _isEscapingTarget(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return false;
  // 命令替换无法静态判定目标，一律按越界处理（`rm -rf $(echo /)`、反引号形态）。
  if (t.contains(r'$(') || t.contains('`')) return true;
  // 家目录形态（Termux 下含 ~/.ssh 私钥，属工作区外）。
  if (t == '~' || t == '~/' || t == '~/*') return true;
  if (t == r'$HOME' || t == r'${HOME}') return true;
  if (t.startsWith('~/') && t.substring(2).replaceAll('*', '').trim().isEmpty) {
    return true;
  }
  if (t.startsWith(r'$HOME/') || t.startsWith(r'${HOME}/')) {
    final rest = t.startsWith(r'$HOME/')
        ? t.substring(6)
        : t.substring(7);
    return rest.replaceAll('*', '').trim().isEmpty;
  }
  // 上跳两级以上 = 逃出工作区。
  if (t.startsWith('../') || t == '..') {
    var depth = 0;
    var rest = t;
    while (rest.startsWith('../')) {
      depth++;
      rest = rest.substring(3);
    }
    if (rest == '..') depth++;
    return depth >= 2;
  }
  if (!t.startsWith('/')) return false; // 相对路径交给 jail
  final cleaned = t.replaceAll(RegExp(r'[*?\[\]]'), '');
  // 暂存/共享根：**其子路径**自由读写（/tmp/…、/sdcard/TongYiLite、Termux home…），
  // 但裸根目录本身（/data/data 这种）仍按越界判。
  for (final p in _scratchPrefixes) {
    final root = p.substring(0, p.length - 1); // 去掉尾部 '/'
    if (cleaned == root) continue;
    if (cleaned.startsWith('$root/')) return false;
  }
  if (cleaned == '/tmp' ||
      cleaned == '/var/tmp' ||
      cleaned == '/sdcard' ||
      cleaned == '/storage') {
    return false;
  }
  final segs = cleaned.split('/').where((s) => s.isNotEmpty).toList();
  if (segs.isEmpty) return true; // `/` 或 `/*`
  if (segs.length <= 2) return true; // /bin /usr /etc /data /system /data/data 等
  if (cleaned.startsWith('/proc/sys/') ||
      cleaned.startsWith('/system/') ||
      cleaned.startsWith('/dev/')) {
    return true;
  }
  return false;
}

/// 逐段判定；命中返回拒绝原因（不含统一后缀），否则 null。
String? _checkSegment(List<String> seg,
    {required bool piped, required int depth}) {
  if (seg.isEmpty) return null;

  // 定位命令位：跳过包装命令；`su`/`sudo` 本身即判危。
  var i = 0;
  while (i < seg.length) {
    final n = _cmdName(seg[i]);
    if (n == 'su' || n == 'sudo') return '提权（$n）';
    if (_wrapperCommands.contains(n) && i + 1 < seg.length) {
      i++;
      continue;
    }
    break;
  }
  if (i >= seg.length) return null;
  final name = _cmdName(seg[i]);
  final args = seg.sublist(i + 1).map(_unquote).toList();
  final lowerArgs = args.map((a) => a.toLowerCase()).toList();

  // 子 shell 逃逸：`bash -c "rm -rf /"`、`python -c "os.system('rm -rf /')"`。
  // 只对 `-c`/`-e` 携带的那段脚本递归判定 —— 绝不扫整条命令串（那是旧版误杀之源）。
  if (_scriptCarriers.contains(name) && depth < 2) {
    final nested = _carrierScript(args);
    if (nested != null && nested.trim().isNotEmpty) {
      final inner = _scan(nested, depth + 1);
      if (inner != null) return '$inner（子 shell 内）';
      if (_nestedDangerousRegex.hasMatch(nested)) {
        return '子 shell 内藏破坏性命令（$name -c …）';
      }
    }
  }

  // mkfs 系常带后缀（mkfs.ext4 / mkfs.vfat），前缀判定。
  if (name.startsWith('mkfs') ||
      name == 'mke2fs' ||
      name == 'mkswap' ||
      name == 'wipefs') {
    return '格式化磁盘（$name）';
  }

  switch (name) {
    case 'rm':
      for (final a in args) {
        if (a.startsWith('-')) continue;
        if (_isEscapingTarget(a)) return '删除越界路径（rm $a）';
      }
      return null;
    case 'find':
      if (args.isNotEmpty &&
          lowerArgs.contains('-delete') &&
          _isEscapingTarget(args.first)) {
        return '删除越界路径（find ${args.first} -delete）';
      }
      return null;
    case 'dd':
      for (final a in lowerArgs) {
        if (a.startsWith('of=/dev/') || a.startsWith('--of=/dev/')) {
          return '直写块设备（${a}）';
        }
      }
      return null;
    case 'reboot':
    case 'shutdown':
    case 'poweroff':
    case 'halt':
      return '重启/关机（$name）';
    case 'init':
    case 'telinit':
      if (lowerArgs.isNotEmpty && (lowerArgs.first == '0' || lowerArgs.first == '6')) {
        return '重启/关机（$name ${lowerArgs.first}）';
      }
      return null;
    case 'chmod':
      final recursive = lowerArgs.any((a) => a == '-r' || a == '--recursive');
      final permissive = lowerArgs
          .any((a) => RegExp(r'^[0-7]*777[0-7]*$').hasMatch(a) || a == 'a+rwx');
      if (recursive && permissive) {
        for (final a in args) {
          if (a.startsWith('-')) continue;
          if (_isEscapingTarget(a)) return '权限全开（chmod -R $a）';
        }
      }
      return null;
    case 'tee':
      for (final a in args) {
        if (a.startsWith('-')) continue;
        if (_isEscapingTarget(a)) return '系统文件直写（tee $a）';
      }
      return null;
    case 'git':
      return _checkGit(args);
    default:
      break;
  }

  // 管道进解释器：`curl x | bash`、`echo … | sh`、`base64 -d | sh`。
  if (piped) {
    if (_shellInterpreters.contains(name)) return '管道进 shell 执行（$name）';
    if (_scriptInterpreters.contains(name)) return null; // 单独跑脚本是正常开发
  }
  // 重定向写系统文件：`echo x > /etc/hosts`、`printf y >/proc/sys/vm/…`。
  for (var k = 0; k < seg.length; k++) {
    final t = _unquote(seg[k]);
    String? target;
    // 先判独立的重定向符（`echo x > /etc/hosts`），再判粘连形态（`y>/proc/sys/…`）：
    // 顺序反了会把 `>` 自己当成"目标为空"而漏掉下一个 token。
    if (t == '>' || t == '>>') {
      target = k + 1 < seg.length ? _unquote(seg[k + 1]) : null;
    } else if (t.startsWith('>>')) {
      target = t.substring(2);
    } else if (t.startsWith('>')) {
      target = t.substring(1);
    }
    if (target != null && target.isNotEmpty && _isEscapingTarget(target)) {
      return '系统文件直写（重定向 $target）';
    }
  }
  return null;
}

/// git 专项：只拦**真**破坏性形态。
///
/// 旧版反向：拦官方推荐的 `--force-with-lease`，放行真正危险的 `-f` / `+ref`。
String? _checkGit(List<String> args) {
  if (args.isEmpty) return null;
  final sub = args.first.toLowerCase();
  final rest = args.skip(1).toList();
  final lower = rest.map((a) => a.toLowerCase()).toList();
  if (sub == 'reset' && lower.contains('--hard')) {
    return '丢弃提交（git reset --hard）';
  }
  if (sub == 'push') {
    for (final raw in rest) {
      final a = raw.toLowerCase();
      if (a == '--force' || a == '-f') {
        return '强制推送（git push $raw）';
      }
      if (a.startsWith('--force') &&
          !a.startsWith('--force-with-lease') &&
          !a.startsWith('--force-if-includes')) {
        return '强制推送（git push $raw）';
      }
      // `git push origin +main` 形式的 refspec 强推。
      if (raw.startsWith('+') && raw.length > 1 && !raw.contains(' ')) {
        return '强制推送（git push $raw）';
      }
    }
  }
  return null;
}

/// 内部扫描：命中返回简要原因（不含片段回显与统一后缀），否则 null。
String? _scan(String command, int depth) {
  final segments = tokenizeSegments(command);
  for (var i = 0; i < segments.length; i++) {
    final seg = segments[i];
    if (seg.isEmpty) continue;
    final piped = i > 0;
    String? hit;
    try {
      hit = _checkSegment(seg, piped: piped, depth: depth);
      if (hit == null && piped && _scriptInterpreters.contains(_cmdName(seg.first))) {
        final prevName = _cmdName(segments[i - 1].first);
        if (_untrustedPipeSources.contains(prevName)) {
          hit = '管道进解释器执行（$prevName | ${_cmdName(seg.first)}）';
        }
      }
    } catch (_) {
      // 解析异常一律放行（fail-open 于模型）：宁漏杀不误杀，越界由 jail/审批兜底。
      return null;
    }
    if (hit != null) return hit;
  }
  return null;
}

/// 检查命令是否命中黑名单；命中返回可读拒绝原因（含命中片段与收敛指引），否则 null。
///
/// 判定只看**命令位**：参数位与引号内字符串不参与关键词匹配。
String? checkDangerousCommand(String command) {
  final trimmed = command.trim();
  if (trimmed.isEmpty) return null;
  final hit = _scan(trimmed, 0);
  if (hit == null) return null;
  // 回显被拦的具体片段：旧版只说"危险命令被拒绝：挂载"，模型只能瞎猜改法。
  final segment = tokenizeSegments(trimmed)
      .firstWhere((s) => s.isNotEmpty, orElse: () => const <String>[]);
  final brief = segment.join(' ');
  final shown = brief.length > 80 ? '${brief.substring(0, 80)}…' : brief;
  return '$hit｜命中命令：$shown$kDangerousCommandHint';
}
