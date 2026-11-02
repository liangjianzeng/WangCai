import 'dart:io';

import 'package:test/test.dart';

/// 把「用户可见文案必须有测试引用」这条门禁挂进测试套件，让它**不依赖有人记得去跑脚本**。
///
/// 唯一真源仍然是 `tool/check_fail_texts.py`（判据、基线、欠账清单都在那儿）——
/// 这里只负责"跑它并看退出码"，绝不在 Dart 里再抄一份判据（两份判据迟早分叉，见 §11-A 第 7/17 条）。
void main() {
  group('文案门禁进门禁（check_fail_texts.py）', () {
    // `dart test` / `flutter test` 的工作目录是包目录，脚本在仓库根的 tool/ 下。
    final candidates = <String>[
      '../../tool/check_fail_texts.py',
      'tool/check_fail_texts.py',
    ];
    final script = candidates.firstWhere(
      (p) => File(p).existsSync(),
      orElse: () => candidates.first,
    );

    test('没有新增"没人引用"的用户可见文案（新文案必须配测试，不是塞基线）', () async {
      if (!File(script).existsSync()) {
        return; // 从别的目录跑：不假红也不假绿，直接放过（真跑在 CI 的仓库根下）
      }
      final r = await Process.run('python3', [script]);
      if (r.exitCode == 127 || '${r.stderr}'.contains('No such file')) {
        return; // 没装 python3 的机器：这条不该把整套测试带崩，交给人工/CI 跑
      }
      expect(
        r.exitCode,
        0,
        reason: '新增的用户可见失败文案没有任何测试引用。正解是给这句话写一条测试引用，\n'
            '而不是把它加进 tool/fail_text_baseline.txt（那是历史欠账的明账，不是垃圾桶）。\n'
            '--- 脚本输出 ---\n${r.stdout}\n${r.stderr}',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  // 「断言质量」这条线也进门禁：判据只在 `tool/check_weak_asserts.py` 里，这里只看退出码。
  // 上限给 **0**（当前全仓实测就是 0 处，4 处正当写法已写 `参谋保留：理由` 登记明账）：
  // 留余量等于没门禁 —— 第 73 轮我先写 `--max 4`，注入 1 条骨头断言照样绿，就是因为余量吞掉了它。
  // 正解是补原句断言，或在断言贴着的地方写 `参谋保留：理由`，不是调高上限。
  group('断言质量哨兵（check_weak_asserts.py --max）', () {
    final candidates = <String>[
      '../../tool/check_weak_asserts.py',
      'tool/check_weak_asserts.py',
    ];
    final script = candidates.firstWhere(
      (p) => File(p).existsSync(),
      orElse: () => candidates.first,
    );

    test('骨头断言（isNotNull 当判词 / contains 两三个字）一条都不许有', () async {
      if (!File(script).existsSync()) return;
      final r = await Process.run('python3', [script, '--max', '0']);
      if (r.exitCode == 127 || '${r.stderr}'.contains('No such file')) return;
      expect(
        r.exitCode,
        0,
        reason: '出现了"看着像断言、其实什么都没过"的测试。正解：把产品那句话原样断出来，\n'
            '或写 `参谋保留：理由` 登记明账 —— 判据分叉与调高上限都不算修好。\n'
            '--- 脚本输出 ---\n${r.stdout}\n${r.stderr}',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  // 第 87 轮：`message` 的**形状**判据（≤120 字、不许夹异常原文）也挂进来。
  // 光断退出码不够 —— 把脚本里那一整段 shape 检查删掉，它照样退出 0。
  // 按第 81 轮的教训：钉的是「该出现的东西出现了」，不是 `isNot(contains('❌'))`（那类负向断言是假断言）。
  group('message 形状判据必须活着（超长 / 夹异常原文）', () {
    final candidates = <String>[
      '../../tool/check_fail_texts.py',
      'tool/check_fail_texts.py',
    ];
    final script = candidates.firstWhere(
      (p) => File(p).existsSync(),
      orElse: () => candidates.first,
    );

    test('脚本必须报出形状这一节的判决，不许静默跳过', () async {
      if (!File(script).existsSync()) return;
      final r = await Process.run('python3', [script]);
      if (r.exitCode == 127 || '${r.stderr}'.contains('No such file')) return;
      final out = '${r.stdout}';
      expect(
        out,
        contains('message 形状不合格'),
        reason: '这一行是形状判据存在过的凭据。整段消失 = 有人删了判据（契约里那条 assert 在 release 会被剥掉，'
            '静态扫是唯一的兜底）。\n--- 脚本输出 ---\n$out\n${r.stderr}',
      );
      expect(
        out,
        matches(RegExp(r'(没有新增不合格的 message|新增 \d+ 条不合格 message)')),
        reason: '必须给出明确判决（OK 或逐条点名）；静默跳过与没跑过等价。',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  // 第 90 轮：**门禁的门禁** —— §11-A 那份「已机检」名册自己也要跑一遍。
  // 名册最坏的失效不是漏一条约束，而是某行写"机检在某处"而那处其实什么都没测：
  // 文件改名、测试删了、台账少一行，读者却照着名册放心改代码 —— 没有任何测试会为此变红。
  group('§11 名册自检（check_gate_index.py）', () {
    final candidates = <String>[
      '../../tool/check_gate_index.py',
      'tool/check_gate_index.py',
    ];
    final script = candidates.firstWhere(
      (p) => File(p).existsSync(),
      orElse: () => candidates.first,
    );

    test('名册每一行都对得上真实文件、证红台账与 §10 轮次', () async {
      if (!File(script).existsSync()) return;
      final r = await Process.run('python3', [script]);
      if (r.exitCode == 127 || '${r.stderr}'.contains('No such file')) return;
      expect(
        r.exitCode,
        0,
        reason: '「已机检」名册与仓库对不上了：要么引用了不存在的文件（改名/删除后名册就是假账），'
            '要么某行没有证红台账（不许只靠印象挂着），要么 §10 里没有那一轮。\n'
            '--- 脚本输出 ---\n${r.stdout}\n${r.stderr}',
      );
      expect(r.stdout, contains('名册每一行都对得上'),
          reason: '必须给出明确判决；静默跳过（比如文档锚点被改动后脚本直接 return）与没跑过等价');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
