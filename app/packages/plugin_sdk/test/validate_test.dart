import 'dart:convert';
import 'dart:io';  // 覆盖率机检要读本文件自己的源码

import 'package:plugin_sdk/plugin_sdk.dart';
import 'package:test/test.dart';

Map<String, dynamic> validDeclarative() => {
      'manifestVersion': 1,
      'id': 'english-dictation',
      'name': '英语听写',
      'description': '拍照抽词并按间隔逐词朗读',
      'whenToUse': '用户说"给我听写单词"时',
      'trust': 'declarative',
      'inject': ['llm.vision', 'app.speak', 'app.capture', 'app.interact'],
      'permissions': ['camera', 'photo_library', 'llm:vision', 'tts', 'network', 'storage:plugin'],
      'params': [
        {'name': 'gapSeconds', 'label': '间隔秒数', 'type': 'number', 'default': 5, 'min': 1, 'max': 30, 'askAtStart': true},
        {'name': 'readChinese', 'label': '念中文释义', 'type': 'boolean', 'default': false},
        {'name': 'voice', 'label': '音色', 'type': 'choice', 'default': 'female', 'options': ['female', 'male']},
      ],
      'flow': {
        'name': '听写一轮',
        'description': '拍照 → 抽词 → 确认 → 按间隔朗读',
        'whenToUse': '听写',
        'phases': [
          {'id': 'extract', 'title': '识别单词'},
          {'id': 'play', 'title': '逐词朗读'},
        ],
        'steps': [
          {'id': 'shoot', 'op': 'capture', 'phase': 'extract', 'params': {'preferCamera': true}},
          {'id': 'extract', 'op': 'llm_extract', 'phase': 'extract', 'params': {'promptFile': 'prompt.md'}},
          {'id': 'confirm', 'op': 'review', 'phase': 'extract'},
          {'id': 'ask', 'op': 'ask_params', 'phase': 'play', 'params': {'names': ['gapSeconds']}},
          // 注意不写 `"gapSeconds": "{{config.gapSeconds}}"`：speak_sequence 不读那个键
        // （它按 `gapParam` 的名字去问到的值/配置里取），写了会被 `unknownOpParam` 提醒 —— 这条夹具是"全绿样板"。
          {'id': 'play', 'op': 'speak_sequence', 'phase': 'play'},
        ],
      },
    };

ValidationReport validate(Map<String, dynamic> m, {Set<String>? known, List<DeprecatedField>? deprecations}) =>
    validateManifest(m, knownCapabilityIds: known ?? const {}, deprecations: deprecations);

Iterable<ValidationIssueCode> codes(ValidationReport r) => r.issues.map((e) => e.code);

void main() {
  group('合法样本', () {
    test('一份写得对的声明式插件全绿', () {
      final r = validate(validDeclarative(), known: {'llm.vision', 'app.speak', 'app.capture', 'app.interact'});
      expect(r.issues.map((e) => e.toString()), isEmpty);
      expect(r.ok, isTrue);
    });
  });

  group('必填与格式', () {
    test('缺 id / id 非法', () {
      final m = validDeclarative()..remove('id');
      expect(codes(validate(m)), contains(ValidationIssueCode.missingField));
      for (final bad in ['A', 'ab', 'English Dictation', 'a' * 70]) {
        expect(codes(validate(validDeclarative()..['id'] = bad)), contains(ValidationIssueCode.badFormat), reason: bad);
      }
    });

    test('缺 name / 缺 description（后者只是提醒）', () {
      final m = validDeclarative()..remove('name');
      expect(codes(validate(m)), contains(ValidationIssueCode.missingField));
      final d = validDeclarative()..['description'] = '';
      expect(validate(d).warnings.map((e) => e.code), contains(ValidationIssueCode.missingField));
      expect(validate(d).ok, isTrue, reason: '缺描述不该拦加载');
    });

    test('声明格式版本超前：拒绝加载并说清怎么办', () {
      final r = validate(validDeclarative()..['manifestVersion'] = 99);
      expect(r.ok, isFalse);
      final i = r.errors.firstWhere((e) => e.code == ValidationIssueCode.unsupportedVersion);
      expect(i.hint, contains('升级 app'));
    });

    test('未知字段只提醒不拦（前向兼容：契约只加不改）', () {
      final r = validate(validDeclarative()..['someFutureField'] = 1);
      expect(r.ok, isTrue);
      expect(r.warnings.map((e) => e.code), contains(ValidationIssueCode.unknownField));
    });

    test('engines.app 写法不对只是提醒', () {
      expect(validate(validDeclarative()..['engines'] = {'app': '0.3.x'}).warnings.map((e) => e.code),
          contains(ValidationIssueCode.badFormat));
    });
  });

  group('能力与权限', () {
    test('本机没有的能力 → 明确说"永远不会启动"', () {
      final r = validate(validDeclarative(), known: {'app.speak', 'app.capture', 'app.interact'});
      final i = r.errors.firstWhere((e) => e.code == ValidationIssueCode.unknownCapability);
      expect(i.message, contains('llm.vision'));
      expect(i.hint, contains('能力清单'));
    });

    test('未知权限名报错并列出可用值', () {
      final r = validate(validDeclarative()..['permissions'] = ['camera', 'read_contacts']);
      final i = r.errors.firstWhere((e) => e.code == ValidationIssueCode.unknownPermission);
      expect(i.hint, contains('camera'));
    });

    test('能力 id 写成驼峰/单段 → badFormat', () {
      expect(codes(validate(validDeclarative()..['inject'] = ['Vision'])), contains(ValidationIssueCode.badFormat));
    });
  });

  group('参数契约', () {
    test('参数名重复只报一次并指名', () {
      final m = validDeclarative();
      (m['params'] as List).add({'name': 'gapSeconds', 'label': '再来一个', 'type': 'number'});
      expect(codes(validate(m)), contains(ValidationIssueCode.duplicateParam));
    });

    test('min > max 被抓', () {
      final m = validDeclarative();
      (m['params'] as List)[0] = {'name': 'gapSeconds', 'label': '间隔', 'type': 'number', 'default': 5, 'min': 10, 'max': 2};
      expect(codes(validate(m)), contains(ValidationIssueCode.paramOutOfRange));
    });

    test('choice 必须有候选项，且默认值必须在候选项里', () {
      final m = validDeclarative();
      (m['params'] as List)[2] = {'name': 'voice', 'label': '音色', 'type': 'choice', 'default': 'child'};
      final r = validate(m);
      expect(codes(r), contains(ValidationIssueCode.missingField)); // 没 options
      expect(codes(r), contains(ValidationIssueCode.defaultValueRejected));
    });

    test('默认值类型不符被拒', () {
      final m = validDeclarative();
      (m['params'] as List)[1] = {'name': 'readChinese', 'label': '念中文', 'type': 'boolean', 'default': 'yes'};
      expect(codes(validate(m)), contains(ValidationIssueCode.defaultValueRejected));
    });

    test('config 覆盖未声明的参数 = 提醒；覆盖成非法值 = 错误', () {
      final w = validate(validDeclarative()..['config'] = {'typoName': 3});
      expect(w.ok, isTrue);
      expect(w.warnings.map((e) => e.code), contains(ValidationIssueCode.unknownField));

      final e = validate(validDeclarative()..['config'] = {'gapSeconds': 999});
      expect(e.ok, isFalse);
      expect(codes(e), contains(ValidationIssueCode.paramOutOfRange));
    });
  });

  group('flow 契约', () {
    test('声明式插件没有 flow → 拒（它的全部能力面就是 steps）', () {
      final m = validDeclarative()..remove('flow');
      final i = validate(m).errors.firstWhere((e) => e.code == ValidationIssueCode.flowRequired);
      expect(i.hint, contains('plugin_scaffold'));
    });

    test('未知 op 报错并列出白名单', () {
      final m = validDeclarative();
      ((m['flow'] as Map)['steps'] as List)[0]['op'] = 'hack_the_planet';
      final i = validate(m).errors.firstWhere((e) => e.code == ValidationIssueCode.unknownStepOp);
      expect(i.hint, contains('capture'));
    });

    test('步骤用到没声明的权限 → boot 期就报错，而不是跑到一半炸', () {
      final m = validDeclarative();
      m['permissions'] = ['camera', 'photo_library', 'llm:vision', 'network', 'storage:plugin']; // 少了 tts
      final i = validate(m).errors.firstWhere((e) => e.code == ValidationIssueCode.missingImpliedPermission);
      expect(i.message, contains('speak_sequence'));
      expect(i.hint, contains('"tts"'));
    });

    test('纯文本 llm_extract 不逼作者声明 llm:vision（平台不许权限膨胀）', () {
      final m = validDeclarative();
      m['permissions'] = ['llm:chat', 'network', 'storage:plugin'];
      (m['flow'] as Map)['steps'] = [
        {'id': 'ask', 'op': 'ask_params'},
        {'id': 'pick', 'op': 'llm_extract'},
      ];
      expect(validate(m).errors.map((e) => e.message), isNot(contains(contains('llm:vision'))));
      expect(codes(validate(m)), isNot(contains(ValidationIssueCode.missingImpliedPermission)));
    });

    test('流程里有 capture ⇒ llm_extract 就必须声明 llm:vision', () {
      final m = validDeclarative();
      m['permissions'] = ['camera', 'photo_library', 'llm:chat', 'network', 'tts', 'storage:plugin'];
      (m['flow'] as Map)['steps'] = [
        {'id': 'shot', 'op': 'capture'},
        {'id': 'pick', 'op': 'llm_extract'},
        {'id': 'say', 'op': 'speak_sequence'},
      ];
      final i = validate(m).errors.firstWhere((e) => e.code == ValidationIssueCode.missingImpliedPermission);
      expect(i.message, contains('llm_extract'));
      expect(i.message, contains('llm:vision'));
    });

    test('useImages:true 的纯文本流程也按视觉要求权限', () {
      final m = validDeclarative();
      m['permissions'] = ['llm:chat', 'network', 'storage:plugin'];
      (m['flow'] as Map)['steps'] = [
        {'id': 'pick', 'op': 'llm_extract', 'params': {'useImages': true}},
      ];
      expect(codes(validate(m)), contains(ValidationIssueCode.missingImpliedPermission));
    });

    test('ask_params 键写成 params.params → 拦下，并说中"一个都不问"的后果', () {
      final m = validDeclarative();
      (m['flow'] as Map)['steps'] = [
        {'id': 'ask', 'op': 'ask_params', 'params': {'params': ['gapSeconds']}},
        {'id': 'play', 'op': 'speak_sequence'},
      ];
      final r = validate(m);
      final i = r.errors.firstWhere((e) => e.code == ValidationIssueCode.askParamsWrongKey);
      expect(i.message, contains('params.names'), reason: '要说清正确的键');
      expect(i.message, contains('一个问题都不问'), reason: '只说"键写错"作者不知道代价，代价是听写变连珠炮');
      expect(i.hint, contains('names'));
      expect(r.ok, isFalse, reason: '静默降级的声明不许放行');
    });

    test('ask_params 什么都没写、也没有 askAtStart 参数 → 只提醒，不判死', () {
      final m = validDeclarative();
      // 把参数改成"不主动问"的样子：这一步于是确实一个问题都不会问。
      m['params'] = [
        {'name': 'gapSeconds', 'label': '间隔秒数', 'type': 'number', 'default': 5, 'min': 1, 'max': 30},
      ];
      (m['flow'] as Map)['steps'] = [
        {'id': 'ask', 'op': 'ask_params'},
        {'id': 'play', 'op': 'speak_sequence'},
      ];
      final r = validate(m);
      expect(r.warnings.map((e) => e.code), contains(ValidationIssueCode.askParamsEmpty), reason: '空步骤是可疑，不是非法');
      expect(r.errors.map((e) => e.code), isNot(contains(ValidationIssueCode.askParamsEmpty)));
      expect(r.warnings.firstWhere((e) => e.code == ValidationIssueCode.askParamsEmpty).hint, contains('names'));
    });

    test('ask_params 的 names 引用没定义过的参数 → 当场报错（运行时也是失败，别等到跑）', () {
      final m = validDeclarative();
      (m['flow'] as Map)['steps'] = [
        {'id': 'ask', 'op': 'ask_params', 'params': {'names': ['gapSeconds', 'nope']}},
        {'id': 'play', 'op': 'speak_sequence'},
      ];
      final r = validate(m);
      final i = r.errors.firstWhere((e) => e.code == ValidationIssueCode.unknownParamName);
      expect(i.message, contains('nope'));
      expect(i.hint, contains('params'));
    });

    test('names 写法正确 + 参数都定义过 → 不许误报（门禁不能把作者逼疯）', () {
      final m = validDeclarative();
      (m['flow'] as Map)['steps'] = [
        {'id': 'ask', 'op': 'ask_params', 'params': {'names': ['gapSeconds', 'readChinese']}},
        {'id': 'play', 'op': 'speak_sequence'},
      ];
      final r = validate(m);
      expect(r.errors, isEmpty, reason: r.format());
      expect(codes(r), isNot(anyOf(contains(ValidationIssueCode.askParamsWrongKey),
          contains(ValidationIssueCode.askParamsEmpty), contains(ValidationIssueCode.unknownParamName))));
    });

    test('声明式插件声明了没人用的参数 → 提醒（面板上摆了个改了没反应的开关）', () {
      final m = validDeclarative();
      (m['params'] as List).add({'name': 'debugLevel', 'label': '调试级别', 'type': 'number', 'default': 0});
      (m['flow'] as Map)['steps'] = [
        {'id': 'play', 'op': 'speak_sequence', 'params': {'items': ['a']}},
      ];
      final r = validate(m);
      // 用 `any` 而不是 `firstWhere`：这条流程里 `readChinese` 也算没人用（没有 extract 步），
      // 取第一条会取到它，测的就不是我要测的那个参数了。
      final unused = r.warnings.where((e) => e.code == ValidationIssueCode.unusedParam).map((e) => e.message).toList();
      expect(unused.any((m) => m.contains('debugLevel')), isTrue, reason: unused.join(' / '));
      final w = r.warnings.firstWhere((e) => e.code == ValidationIssueCode.unusedParam && e.message.contains('debugLevel'));
      expect(w.hint, anyOf(contains('config'), contains('删掉')), reason: '要给出路：引用它或删掉');
      expect(r.ok, isTrue, reason: '没人用的参数是可疑，不是非法 —— 不许因此把插件判死');
    });

    test('volatile 参数豁免：面板本来就不显示它，不能反过来骂它"摆着没人用"', () {
      final m = validDeclarative();
      // 脚手架生成的骨架就带一个 volatile 参数（`lastGapSeconds`）—— 这条同时也是脚手架的护栏。
      (m['params'] as List).add({
        'name': 'lastGapSeconds',
        'label': '上次用的间隔',
        'type': 'number',
        'default': 5,
        'volatile': true,
      });
      (m['flow'] as Map)['steps'] = [
        {'id': 'say', 'op': 'speak_sequence', 'params': {'items': ['a']}},
      ];
      final unused = validate(m).warnings.where((e) => e.code == ValidationIssueCode.unusedParam).toList();
      expect(unused.any((e) => e.message.contains('lastGapSeconds')), isFalse, reason: unused.map((e) => e.message).join(' / '));
    });

    test('隐式读到的参数不许误报：voice / gapSeconds / readChinese 由原语自己读 config', () {
      final m = validDeclarative();
      // 步骤里一个 `{{config.*}}` 都没写，全靠原语的隐式读取 —— 这是最常见的合法写法。
      (m['flow'] as Map)['steps'] = [
        {'id': 'pick', 'op': 'llm_extract', 'params': {'promptFile': 'prompt.md'}},
        {'id': 'say', 'op': 'speak_sequence', 'params': {'items': ['a']}},
      ];
      final r = validate(m);
      expect(r.warnings.where((e) => e.code == ValidationIssueCode.unusedParam), isEmpty,
          reason: 'voice / gapSeconds / readChinese 都是原语会自己去 config 取的');
    });

    test('代码级插件不做"参数没人用"检查（它在 Dart 里读 config，静态看不见）', () {
      final m = validDeclarative();
      m['trust'] = 'trusted';
      m['entry'] = 'lib/main.dart';
      m['capabilities'] = ['app.store'];
      m.remove('flow');
      final r = validate(m);
      expect(codes(r), isNot(contains(ValidationIssueCode.unusedParam)));
    });

    test('步骤参数写错键 → 提醒"写了等于没写"，并列出这个原语真正读的键', () {
      final m = validDeclarative();
      (m['flow'] as Map)['steps'] = [
        {'id': 'say', 'op': 'speak_sequence', 'params': {'items': ['a'], 'gapSecond': 5, 'label': '念一遍'}},
      ];
      final r = validate(m);
      final paths = r.warnings.where((e) => e.code == ValidationIssueCode.unknownOpParam).map((e) => e.path).toList();
      expect(paths.any((p) => p.endsWith('gapSecond')), isTrue, reason: paths.join(' / '));
      expect(paths.any((p) => p.endsWith('label')), isTrue, reason: '把 title 写成 label 是最常见的一种');
      final one = r.warnings.firstWhere((e) => e.path.endsWith('gapSecond'));
      expect(one.message, contains('写了等于没写'), reason: '要说清后果：运行时静默忽略，作者却以为生效');
      expect(one.hint, contains('gapParam'), reason: '出路 = 这个原语真正读的那些键');
    });

    test('llm_extract 的多余键是提示词变量（{{count}} 那一层），不能当拼错键误报', () {
      final m = validDeclarative();
      (m['flow'] as Map)['steps'] = [
        {'id': 'pick', 'op': 'llm_extract', 'params': {'promptFile': 'prompt.md', 'count': 5, 'withExample': true}},
      ];
      final r = validate(m);
      expect(r.warnings.where((e) => e.code == ValidationIssueCode.unknownOpParam), isEmpty, reason: r.format());
    });

    test('把 boolean 塞进 ask_params 的 names → 提醒"这一步问不出来"', () {
      final m = validDeclarative();
      (m['flow'] as Map)['steps'] = [
        {'id': 'ask', 'op': 'ask_params', 'params': {'names': ['readChinese']}},
        {'id': 'say', 'op': 'speak_sequence', 'params': {'items': ['a']}},
      ];
      final r = validate(m);
      final w = r.warnings.where((e) => e.code == ValidationIssueCode.askParamNotAskable).toList();
      expect(w, hasLength(1), reason: r.format());
      expect(w.single.message, contains('readChinese'));
      expect(w.single.message, contains('静默跳过'), reason: '要说中后果：作者以为会问，其实什么都不问');
      expect(w.single.hint, contains('number'), reason: '出路 = 只问得出 number 与 choice');
      // 问不出来 = 没被用到，所以 `unusedParam` 也该同时提醒（两处判据不许互相打掩护）。
      expect(r.warnings.map((e) => e.code), contains(ValidationIssueCode.unusedParam));
    });

    test('names 全是问不出来的参数 → 整步等于没问，提醒空步骤', () {
      final m = validDeclarative();
      // 两个都改成"问不出来"的类型：boolean 与 text 原语都只用配置值。
      (m['params'] as List)[2] = {'name': 'voice', 'label': '备注', 'type': 'text', 'default': 'x'};
      (m['flow'] as Map)['steps'] = [
        {'id': 'ask', 'op': 'ask_params', 'params': {'names': ['readChinese', 'voice']}},
        {'id': 'say', 'op': 'speak_sequence', 'params': {'items': ['a']}},
      ];
      final codes = validate(m).warnings.map((e) => e.code).toList();
      expect(codes, contains(ValidationIssueCode.askParamsEmpty), reason: codes.join(' / '));
    });

    test('boolean 标 askAtStart = 标了等于没标 → 提醒（与 names 同一条判据）', () {
      final m = validDeclarative();
      (m['flow'] as Map)['steps'] = [
        {'id': 'pick', 'op': 'llm_extract', 'params': {'promptFile': 'prompt.md'}},
        {'id': 'ask', 'op': 'ask_params'},
        {'id': 'say', 'op': 'speak_sequence', 'params': {'items': ['a']}},
      ];
      (m['params'] as List)[1]['askAtStart'] = true; // readChinese：boolean
      final w = validate(m).warnings.where((e) => e.code == ValidationIssueCode.askParamNotAskable).toList();
      expect(w, hasLength(1), reason: '标了个问不出来的问题');
      expect(w.single.message, contains('askAtStart'));
      expect(w.single.message, contains('标了等于没标'), reason: '要说中后果');
    });

    test('标了 askAtStart 却没有 ask_params 步骤 → 提醒（开场什么都不会问）', () {
      final m = validDeclarative();
      // gapSeconds 本来就标了 askAtStart；这里把问的那一步删掉。
      (m['flow'] as Map)['steps'] = [
        {'id': 'pick', 'op': 'llm_extract', 'params': {'promptFile': 'prompt.md'}},
        {'id': 'say', 'op': 'speak_sequence', 'params': {'items': ['a']}},
      ];
      final r = validate(m);
      expect(r.warnings.map((e) => e.code), contains(ValidationIssueCode.askParamsEmpty));
      final w = r.warnings.firstWhere((e) => e.code == ValidationIssueCode.askParamsEmpty);
      expect(w.hint, contains('ask_params'), reason: '出路 = 把问的那一步补回去（并说清插在哪）');
    });

    test('flow.steps 为空 → flowEmpty；步骤 id 重复 → duplicateParam', () {
      final m = validDeclarative();
      (m['flow'] as Map)['steps'] = [];
      expect(codes(validate(m)), contains(ValidationIssueCode.flowEmpty));
      final m2 = validDeclarative();
      (m2['flow'] as Map)['steps'] = [
        {'id': 'a', 'op': 'capture'},
        {'id': 'a', 'op': 'ask_params'},
      ];
      m2['permissions'] = ['camera', 'photo_library'];
      expect(codes(validate(m2)), contains(ValidationIssueCode.duplicateParam));
    });

    test('引用没声明的 phase 只提醒', () {
      final m = validDeclarative();
      ((m['flow'] as Map)['steps'] as List)[0]['phase'] = 'nope';
      expect(validate(m).warnings.map((e) => e.code), contains(ValidationIssueCode.unknownPhase));
    });

    test('trusted 插件可以没有 flow', () {
      final m = validDeclarative()
        ..['trust'] = 'trusted'
        ..remove('flow');
      expect(validate(m).ok, isTrue);
    });
  });

  group('文本入口与预算', () {
    test('不是合法 JSON / 超 64KB', () {
      expect(validateManifestText('{,}').issues.single.code, ValidationIssueCode.notJson);
      final huge = jsonEncode(validDeclarative()..['description'] = 'x' * (65 * 1024));
      expect(validateManifestText(huge).issues.single.code, ValidationIssueCode.tooLarge);
    });

    test('最外层不是对象', () {
      expect(validateManifestText('[]').issues.single.code, ValidationIssueCode.badType);
    });

    test('prompt.md 过长 / 为空', () {
      expect(validatePrompt('x' * (33 * 1024), pluginId: 'p').issues.single.code, ValidationIssueCode.tooLarge);
      expect(validatePrompt('   ', pluginId: 'p').issues.single.isError, isFalse, reason: '空提示词只提醒');
    });

    test('子槽命名非法被抓（插件自己拥有槽的情况）', () {
      expect(codes(validate(validDeclarative()..['ownsSlots'] = ['WordAction'])), contains(ValidationIssueCode.badFormat));
    });
  });

  group('一次报全', () {
    test('多个问题一起报（对齐 cordis ValidationError 聚合，不是遇错即停）', () {
      final r = validate({
        'id': 'BAD',
        'name': '',
        'trust': 'declarative',
        'permissions': ['nope'],
        'params': [
          {'name': 'a', 'type': 'number', 'min': 5, 'max': 1},
          {'name': 'a', 'type': 'number'},
        ],
      });
      expect(r.errors.length, greaterThanOrEqualTo(5));
      expect(r.format(), contains('个错误'));
    });
  });

  group('弃用（登记表目前是空的，整条通道以前一次都没被执行过）', () {
    const voice = DeprecatedField(
      path: 'ttsVoice',
      since: '0.4.0',
      willRemoveIn: '0.6.0',
      replacement: 'params[].name == "voice"',
      message: '顶层 ttsVoice 已弃用，请改为声明一个参数',
    );
    const nested = DeprecatedField(path: 'tts.voice', since: '0.4.0', message: 'tts.voice 已弃用');
    const inList = DeprecatedField(path: 'params[*].legacyName', since: '0.4.0', message: 'legacyName 已弃用');

    test('当前清单为空时不产生任何噪音', () {
      expect(deprecationIssues(validDeclarative()), isEmpty);
    });

    test('命中旧键 → warning 级 + 说清从哪版弃用、几版移除、怎么改', () {
      final raw = validDeclarative()..['ttsVoice'] = 'female';
      final issues = deprecationIssues(raw, table: const [voice]);
      expect(issues, hasLength(1));
      expect(issues.single.code, ValidationIssueCode.deprecation);
      expect(issues.single.severity, IssueSeverity.warning, reason: '弃用期内仍可用，不许因弃用拒绝加载');
      expect(issues.single.message, contains('自 0.4.0 弃用'));
      expect(issues.single.message, contains('计划 0.6.0 移除'), reason: '作者要知道什么时候必须改');
      expect(issues.single.hint, contains('替代写法：'), reason: '面板直接渲染成"改成这样"');
      expect(issues.single.hint, contains('params[].name == "voice"'));
    });

    test('嵌套路径 a.b 命中', () {
      final raw = validDeclarative()..['tts'] = {'voice': 'male', 'gap': 5};
      expect(deprecationIssues(raw, table: const [nested]), hasLength(1));
    });

    test('数组路径 a[*].b 命中 —— 这条最容易写错（写错了就是提醒永远不响）', () {
      final raw = validDeclarative()
        ..['params'] = [
          {'name': 'gapSeconds', 'label': '间隔秒数', 'type': 'number', 'default': 5, 'min': 1, 'max': 30},
          {'name': 'x', 'label': 'X', 'type': 'number', 'default': 1, 'min': 1, 'max': 9, 'legacyName': 'oldX'},
        ];
      final hits = deprecationIssues(raw, table: const [inList]);
      expect(hits, hasLength(1), reason: '数组里有一处用了旧键就该响；不响 = 登记表白写');
      expect(hits.single.path, 'params[*].legacyName');
    });

    test('数组是空的 / 没用到旧键 → 不许误报', () {
      expect(deprecationIssues(validDeclarative()..['params'] = <Object?>[], table: const [inList]), isEmpty);
      expect(deprecationIssues(validDeclarative(), table: const [nested, inList, voice]), isEmpty,
          reason: '没写旧键却提醒"你用了已弃用字段"，比不提醒更坏');
    });

    test('弃用只提醒不判坏：带旧键的合法 manifest 照样 ok', () {
      final raw = validDeclarative()..['ttsVoice'] = 'female';
      final r = validate(raw,
          known: {'llm.vision', 'app.speak', 'app.capture', 'app.interact'}, deprecations: const [voice]);
      expect(r.ok, isTrue, reason: r.errors.map((e) => '${e.path}:${e.message}').join('；'));
      expect(r.warnings.any((i) => i.code == ValidationIssueCode.deprecation), isTrue,
          reason: '不判坏不等于不说 —— 黄条与 doctor 的「声明提醒」靠这条');
    });

    test('登记表本身要过卫生检查（将来加条目时替作者把关）', () {
      for (final d in kL1Deprecations) {
        expect(d.path, isNotEmpty);
        expect(d.message, isNotEmpty);
        expect(d.since, matches(RegExp(r'^\d+\.\d+\.\d+$')), reason: 'since 必须是三段版本号，面板要说"自 X 弃用"');
        expect(RegExp(r'^[a-zA-Z0-9.*\[\]]+$').hasMatch(d.path), isTrue, reason: '路径形状错了 = 提醒永不响');
        expect(d.message.endsWith('。'), isFalse, reason: '渲染进句子末尾，别带句号');
      }
    });
  });

  group('预算（超了就不许加载）', () {
    test('plugin.json 超过 64KB → error，并说清超了多少', () {
      final m = validDeclarative();
      m['description'] = '字' * (200 * 1024); // 中文一个字符三个字节，撑爆得更快
      final r = validateManifestText(jsonEncode(m));
      expect(r.ok, isFalse);
      expect(r.errors.map((e) => e.message).join(' '), contains('64KB'));
    });

    test('按 **UTF-8 字节**算，不是按字符数（中文清单绕不过预算）', () {
      // 按字符数算的话，6 万汉字的清单（18 万字节）会被判"没超"，等于没预算。
      final m = validDeclarative();
      m['description'] = '汉' * 40000; // 40000 字 < 65536，UTF-8 却 120000 字节 > 64KB
      final r = validateManifestText(jsonEncode(m));
      expect(r.errors.map((e) => e.message).join(' '), contains('64KB'),
          reason: '必须按字节判，否则中文插件天然绕过这条预算');
    });

    test('没超预算的正常清单不受影响', () {
      final r = validateManifestText(jsonEncode(validDeclarative()));
      expect(r.errors.where((e) => e.message.contains('64KB')), isEmpty);
    });

    test('prompt.md 超过 32KB → 说清会挤掉模型上下文', () {
      final r = validatePrompt('apple 苹果\n' * 8000, pluginId: 'english-dictation');
      final msg = r.errors.map((e) => e.message).join(' ');
      expect(msg, contains('32KB'));
      expect(msg, contains('上下文'), reason: '要说人话：为什么超了不行');
    });

    test('prompt.md 用了没人提供的占位符 → 提醒（它会原样留在提示词里送给模型）', () {
      final r = validatePrompt(
        '从{{userInstruction}}里抽单词，年级：{{grade}}，每张卡带 {{withExample}} 个例句',
        pluginId: 'english-dictation',
        providedPlaceholders: {'userInstruction', 'withExample'},
      );
      final w = r.warnings.where((e) => e.code == ValidationIssueCode.unknownPlaceholder).toList();
      expect(w, hasLength(1), reason: r.format());
      expect(w.single.message, contains('grade'), reason: '只点名真没人提供的那个');
      expect(w.single.message, isNot(contains('withExample')), reason: '提供了的不能一起骂');
      expect(w.single.hint, contains('之前'), reason: '出路要说清顺序：ask_params 得排在 llm_extract 之前');
      expect(w.single.hint, contains('withExample'), reason: '还要给出"现在给得出什么"');
      expect(r.ok, isTrue, reason: '写法可疑不等于非法，插件还能跑');
    });

    test('不传 providedPlaceholders 就不查（代码级插件的变量由 Dart 自己填，静态看不见）', () {
      final r = validatePrompt('年级：{{grade}}', pluginId: 'english-dictation');
      expect(r.warnings.where((e) => e.code == ValidationIssueCode.unknownPlaceholder), isEmpty);
    });

    test('占位符能替换什么，与解释器同源：步骤自己的 params、之前问出的值才算', () {
      PluginManifest m(List<FlowStep> steps) => PluginManifest(
            id: 'english-dictation',
            name: '英语听写',
            description: 'd',
            whenToUse: 'w',
            icon: 'icons.menu_book_outlined',
            trust: PluginTrust.declarative,
            inject: const ['llm.complete', 'app.interact', 'app.speak'],
            permissions: const [PluginPermission.llmChat, PluginPermission.speechSynthesis, PluginPermission.network],
            params: const [
              PluginParam(name: 'count', label: '几张卡', type: PluginParamType.number, defaultValue: 8),
              PluginParam(name: 'loud', label: '念大声点', type: PluginParamType.boolean, defaultValue: false),
            ],
            flow: FlowMeta(name: 'n', description: 'd', whenToUse: 'w', phases: const [FlowPhase(id: 'p1', title: '跑')], steps: steps),
          );

      // `count` 在抽取步之前问 → 进得了提示词。
      final before = providedPromptPlaceholders(m([
        const FlowStep(id: 'ask', op: FlowStepOp.askParams, params: {'names': ['count', 'loud']}),
        const FlowStep(id: 'gen', op: FlowStepOp.llmExtract, params: {'promptFile': 'prompt.md', 'grade': '三年级'}),
      ]));
      expect(before, containsAll(<String>['count', 'grade', 'userInstruction']));
      expect(before, isNot(contains('loud')), reason: 'boolean 问不出来，也就进不了提示词');
      expect(before, isNot(contains('promptFile')), reason: '那是步骤自己的元数据，不是提示词变量');

      // 同一个 ask 步排在抽取**之后** → 值进不去（运行时一声不吭，只能靠这里抓）。
      final after = providedPromptPlaceholders(m([
        const FlowStep(id: 'gen', op: FlowStepOp.llmExtract, params: {'promptFile': 'prompt.md'}),
        const FlowStep(id: 'ask', op: FlowStepOp.askParams, params: {'names': ['count']}),
      ]));
      expect(after, isNot(contains('count')), reason: '排错顺序 = 提示词里的 {{count}} 原样送给模型');
    });

    test('排错顺序的插件：validatePrompt 与解释器口径一致（同一个 {{count}} 两边都判没有）', () {
      final m = PluginManifest(
        id: 'english-dictation',
        name: '英语听写',
        description: 'd',
        whenToUse: 'w',
        icon: 'icons.menu_book_outlined',
        trust: PluginTrust.declarative,
        inject: const ['llm.complete', 'app.interact'],
        permissions: const [PluginPermission.llmChat, PluginPermission.network],
        params: const [
          PluginParam(name: 'count', label: '几张卡', type: PluginParamType.number, defaultValue: 8),
        ],
        flow: FlowMeta(
          name: 'n',
          description: 'd',
          whenToUse: 'w',
          phases: const [FlowPhase(id: 'p1', title: '跑')],
          steps: const [
          FlowStep(id: 'gen', op: FlowStepOp.llmExtract, params: {'promptFile': 'prompt.md'}),
          FlowStep(id: 'ask', op: FlowStepOp.askParams, params: {'names': ['count']}),
        ],
        ),
      );
      final r = validatePrompt('做 {{count}} 张卡', pluginId: m.id, providedPlaceholders: providedPromptPlaceholders(m));
      expect(r.warnings.map((e) => e.code), contains(ValidationIssueCode.unknownPlaceholder));
    });
  });

  test('每个 ValidationIssueCode 都必须被用例真逼出来过（§11-A 第 23 条）', () {
    // 覆盖率机检：拿枚举全集回本文件源码里逐个点名。新增罪名却不配夹具，这里立刻红 ——
    // 一个从没被触发过的罪名等于没有那个罪名：作者收不到它，平台也不会因为它报错。
    final candidates = ['test/validate_test.dart', '../plugin_sdk/test/validate_test.dart'];
    final self = candidates.firstWhere((p) => File(p).existsSync(), orElse: () => '');
    expect(self, isNotEmpty,
        reason: '读不到自己这份测试文件：路径变了就连着改这条门禁，不许悄悄跳过（跳过 = 没门禁）。');
    final src = File(self).readAsStringSync();
    final missing = <String>[
      for (final code in ValidationIssueCode.values)
        if (!src.contains('ValidationIssueCode.${code.name}')) code.name,
    ];
    expect(missing, isEmpty,
        reason: '这些罪名从没被任何用例逼出来过：${missing.join('、')}。'
            '新增罪名必须带一份故意坏的夹具 —— 否则它只是字典里一个永不生效的摆设。');
  });
}
