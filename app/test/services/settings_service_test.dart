import 'dart:convert';

import 'package:dartssh2/dartssh2.dart' show SSHKeyPair;
import 'package:flutter_test/flutter_test.dart';

import 'package:wangcai/agent/dev/ssh/ssh_credentials.dart';
import 'package:wangcai/models/local_model.dart';
import 'package:wangcai/services/settings_service.dart';

void main() {
  group('InferenceSettings 智能体配置默认值', () {
    test('默认值符合设计（智能体开启、循环 12 轮、nctx 8192）', () {
      const s = InferenceSettings();
      expect(s.agentEnabled, isTrue);
      expect(s.agentModelSource, isNull);
      expect(s.agentModelId, isNull);
      expect(s.agentNctx, 8192);
      expect(s.agentMaxRounds, 12);
      expect(s.agentTokensPerRound, 1024);
      expect(s.agentToolTimeoutMs, 15000);
      expect(s.agentAllowParallelTools, isFalse);
      expect(s.webSearchEnabled, isFalse);
      expect(s.agentShellEnabled, isTrue);
      expect(s.agentPythonEnabled, isTrue);
      expect(s.agentFullFileAccess, isFalse);
      // 长期记忆默认开启（2026-10-01 P1：自动注入【用户记忆】段）。
      expect(s.agentMemoryEnabled, isTrue);
      // 推理引擎扩展：投影器默认加载、监控默认开启、采样默认 1 秒（周期性，
      // 打开监控即可看到实时占比）。
      expect(s.autoLoadMmproj, isTrue);
      expect(s.showResourceMonitor, isTrue);
      expect(s.resourceSampleIntervalSec, 1);
      expect(s.agentToolsByModel, isEmpty);
      expect(s.agentByModel, isEmpty);
    });

    test('便捷读取：未配置工具/覆盖时返回空/空', () {
      const s = InferenceSettings();
      expect(s.agentToolsFor('any-model'), isEmpty);
      expect(s.agentConfigFor('any-model'), isNull);
    });
  });

  group('全局 ctx（2026-11-06 拍板：默认 4096，滑杆 512 一档至 16K）', () {
    test('默认档 = 4096「最基本」', () {
      const s = InferenceSettings();
      expect(s.contextSize, 4096);
      expect(InferenceSettings.kContextSizeDefault, 4096);
      expect(InferenceSettings.kContextSizeMin, 4096);
      expect(InferenceSettings.kContextSizeMax, 16384);
      expect(InferenceSettings.kContextSizeStep, 512);
    });

    test('snapContextSize：就近吸到 512 网格并夹进合法域', () {
      expect(InferenceSettings.snapContextSize(4300), 4096);
      expect(InferenceSettings.snapContextSize(4400), 4608);
      expect(InferenceSettings.snapContextSize(6144), 6144);
      expect(InferenceSettings.snapContextSize(99999), 16384);
      // 低于最基本档 → 抬回 4096（旧 1k 滑杆时代的低档回不来了）。
      expect(InferenceSettings.snapContextSize(512), 4096);
      expect(InferenceSettings.snapContextSize(100), 4096);
    });

    test('老 settings 历史档（1024/65536）fromJson 一律吸回合法网格', () {
      Map<String, dynamic> j(int v) => {'contextSize': v};
      expect(InferenceSettings.fromJson(j(1024)).contextSize, 4096);
      expect(InferenceSettings.fromJson(j(65536)).contextSize, 16384);
      expect(InferenceSettings.fromJson(j(5000)).contextSize, 5120);
      expect(InferenceSettings.fromJson({}).contextSize, 4096);
    });
  });

  group('InferenceSettings 智能体配置持久化', () {
    test('toJson → fromJson 往返一致', () {
      const s = InferenceSettings(
        agentEnabled: false,
        agentModelSource: 'local',
        agentModelId: 'spark-x2.6-4b-q4_k_m',
        agentNctx: 16384,
        agentMaxRounds: 8,
        agentTokensPerRound: 768,
        agentToolTimeoutMs: 30000,
        agentAllowParallelTools: true,
        webSearchEnabled: true,
        agentShellEnabled: false,
        agentPythonEnabled: false,
        agentFullFileAccess: true,
        agentMemoryEnabled: true,
        autoLoadMmproj: false,
        showResourceMonitor: false,
        resourceSampleIntervalSec: 10,
        agentToolsByModel: {
          'spark-x2.6-4b-q4_k_m': ['get_time', 'calculator'],
        },
        agentByModel: {
          'spark-x2.6-4b-q4_k_m': {'maxRounds': 4, 'nctx': 32768},
        },
      );

      final restored = InferenceSettings.fromJson(s.toJson());
      expect(restored.agentEnabled, isFalse);
      expect(restored.agentModelSource, 'local');
      expect(restored.agentModelId, 'spark-x2.6-4b-q4_k_m');
      expect(restored.agentNctx, 16384);
      expect(restored.agentMaxRounds, 8);
      expect(restored.agentTokensPerRound, 768);
      expect(restored.agentToolTimeoutMs, 30000);
      expect(restored.agentAllowParallelTools, isTrue);
      expect(restored.webSearchEnabled, isTrue);
      expect(restored.agentShellEnabled, isFalse);
      expect(restored.agentPythonEnabled, isFalse);
      expect(restored.agentFullFileAccess, isTrue);
      expect(restored.agentMemoryEnabled, isTrue);
      expect(restored.autoLoadMmproj, isFalse);
      expect(restored.showResourceMonitor, isFalse);
      expect(restored.resourceSampleIntervalSec, 10);
      expect(restored.agentToolsFor('spark-x2.6-4b-q4_k_m'),
          ['get_time', 'calculator']);
      expect(restored.agentConfigFor('spark-x2.6-4b-q4_k_m'),
          {'maxRounds': 4, 'nctx': 32768});
    });

    // v0.0.3 Phase 4：GPU 防闪纹/n_ubatch/vkNoSubgroup 等手机端引擎配置字段
    // 已删除（对应旧测试移除）；遗留 JSON key 的静默兼容由下方
    // 「旧配置（无 agent 字段）加载」用例覆盖。

    test('并发会话槽位：默认 1，往返一致，解析夹紧 1~4', () {
      const s = InferenceSettings();
      expect(s.agentMaxConcurrentTurns, 1);
      final restored = InferenceSettings.fromJson(s.toJson());
      expect(restored.agentMaxConcurrentTurns, 1);

      final custom = InferenceSettings.fromJson(
          {'agentMaxConcurrentTurns': 3});
      expect(custom.agentMaxConcurrentTurns, 3);
      expect(InferenceSettings.fromJson(custom.toJson()).agentMaxConcurrentTurns,
          3);
      // 越界值夹紧（手改 JSON 防御）。
      expect(
          InferenceSettings.fromJson({'agentMaxConcurrentTurns': 99})
              .agentMaxConcurrentTurns,
          4);
      expect(
          InferenceSettings.fromJson({'agentMaxConcurrentTurns': 0})
              .agentMaxConcurrentTurns,
          1);
    });

    test('API 上下文压缩预算：默认 32768，往返一致，解析夹紧 4096~200000', () {
      const s = InferenceSettings();
      expect(s.agentApiContextBudget, 32768);
      final restored = InferenceSettings.fromJson(s.toJson());
      expect(restored.agentApiContextBudget, 32768);

      final custom = InferenceSettings.fromJson({'agentApiContextBudget': 65536});
      expect(custom.agentApiContextBudget, 65536);
      expect(InferenceSettings.fromJson(custom.toJson()).agentApiContextBudget,
          65536);
      // 越界值夹紧（手改 JSON 防御）。
      expect(
          InferenceSettings.fromJson({'agentApiContextBudget': 999999})
              .agentApiContextBudget,
          200000);
      expect(
          InferenceSettings.fromJson({'agentApiContextBudget': 1})
              .agentApiContextBudget,
          4096);
    });

    test('ASR 热词差量覆盖：JSON 往返一致 + 非法输入不崩', () {
      const s = InferenceSettings(
        asrHotwordAdded: {
          'daily': ['新词甲'],
          'apps': ['高德地图'],
        },
        asrHotwordRemoved: {
          'daily': ['确认'],
        },
      );
      final back = InferenceSettings.fromJson(s.toJson());
      expect(back.asrHotwordAdded['daily'], ['新词甲']);
      expect(back.asrHotwordAdded['apps'], ['高德地图']);
      expect(back.asrHotwordRemoved['daily'], ['确认']);
      // 非法/缺失输入 → 空表（向后兼容，不崩）。
      expect(InferenceSettings.fromJson({}).asrHotwordAdded, isEmpty);
      final bad = InferenceSettings.fromJson({
        'asrHotwordAdded': 'not-a-map',
        'asrHotwordRemoved': {'x': 'not-a-list'},
      });
      expect(bad.asrHotwordAdded, isEmpty);
      expect(bad.asrHotwordRemoved['x'], isEmpty);
    });

    test('Edge TTS：默认关/晓晓/0 偏移，往返一致，数值夹紧', () {      const s = InferenceSettings();
      expect(s.edgeTtsEnabled, isFalse);
      expect(s.edgeTtsAutoSpeak, isFalse);
      expect(s.edgeTtsVoice, 'zh-CN-XiaoxiaoNeural');
      expect(s.edgeTtsRate, 0);
      expect(s.edgeTtsPitch, 0);
      expect(s.edgeTtsVolume, 0);

      final restored = InferenceSettings.fromJson(s.toJson());
      expect(restored.edgeTtsVoice, 'zh-CN-XiaoxiaoNeural');

      final custom = InferenceSettings.fromJson({
        'edgeTtsEnabled': true,
        'edgeTtsAutoSpeak': true,
        'edgeTtsVoice': 'zh-CN-YunxiNeural',
        'edgeTtsRate': 30,
        'edgeTtsPitch': -10,
        'edgeTtsVolume': 20,
      });
      final back = InferenceSettings.fromJson(custom.toJson());
      expect(back.edgeTtsEnabled, isTrue);
      expect(back.edgeTtsAutoSpeak, isTrue);
      expect(back.edgeTtsVoice, 'zh-CN-YunxiNeural');
      expect(back.edgeTtsRate, 30);
      expect(back.edgeTtsPitch, -10);
      expect(back.edgeTtsVolume, 20);
      // 越界值夹紧（手改 JSON 防御）。
      final clamped = InferenceSettings.fromJson({
        'edgeTtsRate': 999,
        'edgeTtsPitch': -999,
        'edgeTtsVolume': 999,
      });
      expect(clamped.edgeTtsRate, 100);
      expect(clamped.edgeTtsPitch, -50);
      expect(clamped.edgeTtsVolume, 50);
    });

    test('旧配置（无 agent 字段）加载 → 默认值，向后兼容', () {
      final old = InferenceSettings.fromJson({
        'enableGpu': true,
        'contextSize': 4096,
        'gpuBackend': 'auto',
      });
      expect(old.agentEnabled, isTrue);
      expect(old.agentNctx, 8192);
      // 无字段 → 新默认（12 轮 / 1024 token）。
      expect(old.agentMaxRounds, 12);
      expect(old.agentTokensPerRound, 1024);
      expect(old.agentToolsByModel, isEmpty);
    });

    test('旧默认值存量迁移：5→12、512→1024；显式设置过的值不动', () {
      // 存量配置等于旧默认 → 一次性抬到新默认。
      final migrated = InferenceSettings.fromJson({
        'agentMaxRounds': 5,
        'agentTokensPerRound': 512,
      });
      expect(migrated.agentMaxRounds, 12);
      expect(migrated.agentTokensPerRound, 1024);
      // 用户显式设置过的非默认值保持不动。
      final kept = InferenceSettings.fromJson({
        'agentMaxRounds': 3,
        'agentTokensPerRound': 768,
      });
      expect(kept.agentMaxRounds, 3);
      expect(kept.agentTokensPerRound, 768);
    });

    test('agentToolsByModel 解析非法格式不崩', () {
      final restored = InferenceSettings.fromJson({
        'agentToolsByModel': 'bad',
        'agentByModel': 42,
      });
      expect(restored.agentToolsByModel, isEmpty);
      expect(restored.agentByModel, isEmpty);
    });

    test('copyWith 取消指定模型（clearAgentModel）', () {
      const s = InferenceSettings(
        agentModelSource: 'api',
        agentModelId: 'abc',
      );
      final cleared = s.copyWith(clearAgentModel: true);
      expect(cleared.agentModelSource, isNull);
      expect(cleared.agentModelId, isNull);
      // 不传则保留旧值。
      expect(s.copyWith().agentModelId, 'abc');
    });
  });

  group('InferenceSettings 智能体引擎 v0.2.1 新键', () {
    test('默认值：温度 0.7 / 并发 4 / 子代理·压缩·溢写默认开', () {
      const s = InferenceSettings();
      expect(s.agentTemperature, 0.7);
      expect(s.agentMaxParallel, 4);
      expect(s.agentSubagentEnabled, isTrue);
      expect(s.agentCompactEnabled, isTrue);
      expect(s.agentSpillEnabled, isTrue);
    });

    test('toJson → fromJson 往返一致', () {
      const s = InferenceSettings(
        agentTemperature: 0.3,
        agentMaxParallel: 6,
        agentSubagentEnabled: false,
        agentCompactEnabled: false,
        agentSpillEnabled: false,
      );
      final restored = InferenceSettings.fromJson(s.toJson());
      expect(restored.agentTemperature, 0.3);
      expect(restored.agentMaxParallel, 6);
      expect(restored.agentSubagentEnabled, isFalse);
      expect(restored.agentCompactEnabled, isFalse);
      expect(restored.agentSpillEnabled, isFalse);
    });

    test('旧配置无新键 → 取安全默认（向后兼容）', () {
      final old = InferenceSettings.fromJson({'agentMaxRounds': 3});
      expect(old.agentTemperature, 0.7);
      expect(old.agentMaxParallel, 4);
      expect(old.agentSubagentEnabled, isTrue);
      expect(old.agentCompactEnabled, isTrue);
      expect(old.agentSpillEnabled, isTrue);
    });
  });

  group('InferenceSettings 开发模式（Dev Agent）', () {
    test('默认关闭（零回归）', () {
      const s = InferenceSettings();
      expect(s.devModeEnabled, isFalse);
      expect(s.devWorkspaceId, 'default');
      expect(s.sshConfigs, isEmpty);
      expect(s.dangerousCommandPolicy, 'deny');
    });

    test('toJson → fromJson 往返一致（含多 SSH 配置）', () {
      final s = InferenceSettings(
        devModeEnabled: true,
        devWorkspaceId: 'ws_1',
        sshConfigs: [
          const SshConfig(
            id: 'termux',
            name: 'Termux',
            host: '127.0.0.1',
            port: 8022,
            username: 'u0_a123',
            authType: SshAuthType.key,
            privateKeyPem: '-----BEGIN OPENSSH PRIVATE KEY-----',
          ),
          const SshConfig(
            id: 'remote-pc',
            name: '远程电脑',
            host: '192.168.1.100',
            port: 22,
            username: 'me',
            authType: SshAuthType.password,
            password: 'pw',
          ),
        ],
        dangerousCommandPolicy: 'ask',
      );
      final restored = InferenceSettings.fromJson(s.toJson());
      expect(restored.devModeEnabled, isTrue);
      expect(restored.devWorkspaceId, 'ws_1');
      expect(restored.sshConfigs.length, 2);
      expect(restored.sshConfigFor('termux')!.host, '127.0.0.1');
      expect(restored.sshConfigFor('termux')!.port, 8022);
      expect(restored.sshConfigFor('termux')!.username, 'u0_a123');
      expect(restored.sshConfigFor('termux')!.privateKeyPem,
          contains('BEGIN OPENSSH'));
      expect(restored.sshConfigFor('remote-pc')!.password, 'pw');
      expect(restored.sshConfigFor('missing'), isNull);
      expect(restored.dangerousCommandPolicy, 'ask');
    });

    test('旧版单配置 sshConfig 自动迁移为列表首项（向后兼容）', () {
      final migrated = InferenceSettings.fromJson({
        'sshConfig': {
          'host': '127.0.0.1',
          'port': 8022,
          'username': 'u0_a1',
          'authType': 'key',
          'privateKeyPem': 'KEY',
        },
      });
      expect(migrated.sshConfigs.length, 1);
      expect(migrated.sshConfigs.first.host, '127.0.0.1');
      expect(migrated.sshConfigs.first.username, 'u0_a1');
      // 迁移必须补稳定 id（否则删除失效/编辑变追加——2026-10-01 真机定案）。
      expect(migrated.sshConfigs.first.id, isNotEmpty);
    });

    test('迁移补 id 幂等：补完持久化后再次加载 id 不变', () {
      final migrated = InferenceSettings.fromJson({
        'sshConfig': {
          'host': 'h', 'port': 22, 'username': 'u', 'authType': 'password',
          'password': 'p',
        },
      });
      final firstId = migrated.sshConfigs.first.id;
      expect(firstId, isNotEmpty);
      // 迁移后的配置已带 id → 持久化后二次加载不再重新分配。
      final second = InferenceSettings.fromJson(migrated.toJson());
      expect(second.sshConfigs.single.id, firstId);
      // 空 id 的旧列表条目同样补齐。
      final list = InferenceSettings.fromJson({
        'sshConfigs': [
          {'host': 'a', 'port': 22, 'username': 'u', 'authType': 'key',
           'privateKeyPem': 'K'},
          {'host': 'b', 'port': 8022, 'username': 'u', 'authType': 'key',
           'privateKeyPem': 'K'},
        ],
      });
      expect(list.sshConfigs.every((c) => c.id.isNotEmpty), isTrue);
      expect(list.sshConfigs[0].id, isNot(list.sshConfigs[1].id));
    });

    test('旧配置无 Dev 键 → 默认关闭（向后兼容）', () {
      final old = InferenceSettings.fromJson({'agentMaxRounds': 3});
      expect(old.devModeEnabled, isFalse);
      expect(old.sshConfigs, isEmpty);
    });

    test('copyWith：clearSshConfig 清空 / 不传保留', () {
      final s = InferenceSettings(
        sshConfigs: const [
          SshConfig(
              id: 'a', host: 'h', port: 22, username: 'u',
              authType: SshAuthType.password, password: 'p'),
        ],
      );
      final cleared = s.copyWith(clearSshConfig: true);
      expect(cleared.sshConfigs, isEmpty);
      expect(s.copyWith().sshConfigs.length, 1);
    });

    test('sshConfigFor：空 id / 找不到返回 null', () {
      const s = InferenceSettings();
      expect(s.sshConfigFor(null), isNull);
      expect(s.sshConfigFor(''), isNull);
      expect(s.sshConfigFor('nope'), isNull);
    });
  });

  group('SshKeyGen 自动生成 ed25519 密钥', () {
    test('生成 OpenSSH 私钥 + ssh-ed25519 公钥', () {
      final keys = SshKeyGen.generate();
      expect(keys, isNotNull);
      expect(keys!.privateKeyPem, startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'));
      expect(keys.privateKeyPem, endsWith('-----END OPENSSH PRIVATE KEY-----\n'));
      expect(keys.publicKey, startsWith('ssh-ed25519 '));
      // 每次生成不同（随机种子）。
      final keys2 = SshKeyGen.generate();
      expect(keys2!.publicKey, isNot(keys.publicKey));
    });

    test('私钥可被 dartssh2 解析（SSHKeyPair.fromPem 往返）', () {
      final keys = SshKeyGen.generate();
      expect(keys, isNotNull);
      final pairs = SSHKeyPair.fromPem(keys!.privateKeyPem);
      expect(pairs, isNotEmpty);
    });

    test('公钥含 32 字节 ed25519（base64 解码校验）', () {
      final keys = SshKeyGen.generate();
      expect(keys, isNotNull);
      final parts = keys!.publicKey.split(' ');
      expect(parts.length, 2);
      expect(parts[0], 'ssh-ed25519');
      final decoded = base64Decode(parts[1]);
      // 规范 blob = string(type) + string(pub)：
      // 4 + 11（"ssh-ed25519"）+ 4 + 32（ed25519 公钥）= 51 字节。
      expect(decoded.length, 4 + 11 + 4 + 32);
      expect(utf8.decode(decoded.sublist(4, 4 + 11)), 'ssh-ed25519');
      expect(decoded.buffer.asByteData(15, 4).getUint32(0), 32);
    });
  });

  group('InferenceSettings 外观（themeMode）', () {
    test('默认跟随系统；合法值往返一致', () {
      expect(InferenceSettings().themeMode, 'system');
      for (final v in ['system', 'light', 'dark']) {
        final s = InferenceSettings(themeMode: v);
        final back = InferenceSettings.fromJson(s.toJson());
        expect(back.themeMode, v);
      }
    });

    test('非法值回落 system（白名单）', () {
      final back = InferenceSettings.fromJson(
          InferenceSettings(themeMode: 'night').toJson()
            ..['themeMode'] = 'night');
      expect(back.themeMode, 'system');
      expect(
        InferenceSettings.fromJson({'themeMode': 3}).themeMode,
        'system',
      );
    });

    test('copyWith：不传保留', () {
      final s = InferenceSettings(themeMode: 'dark');
      expect(s.copyWith().themeMode, 'dark');
      expect(s.copyWith(themeMode: 'light').themeMode, 'light');
    });
  });

  group('InferenceSettings 本地模型登记（v0.0.3 Phase 2）', () {
    LocalModelConfig sample() => LocalModelConfig(
          id: 'lm_1_aaaaaaaa',
          name: 'Qwen3-4B',
          modelPath: r'E:\models\qwen3-4b-q4_k_xl.gguf',
          engineId: 'wangcai-npu',
          customArgs: const ['-np', '  ', '--flash-attn'],
          mmprojPath: r'E:\models\qwen3-4b-mmproj.gguf',
          draftPath: null,
          ctx: 4096,
          chunk: 128,
          gpuLayers: 0,
        );

    test('默认空列表；登记/往返经真实 JSON 编解码保真', () {
      expect(const InferenceSettings().localModels, isEmpty);
      final s = InferenceSettings(
        localModels: [sample()],
        defaultModelId: 'lm_1_aaaaaaaa',
      );
      final back =
          InferenceSettings.fromJson(jsonDecode(jsonEncode(s.toJson())));
      expect(back.localModels.length, 1);
      final m = back.localModels.single;
      expect(m.id, 'lm_1_aaaaaaaa');
      expect(m.name, 'Qwen3-4B');
      expect(m.modelPath, r'E:\models\qwen3-4b-q4_k_xl.gguf');
      expect(m.engineId, 'wangcai-npu');
      // 空串/纯空白条目在编解码中被滤除，有效尾参保序保留。
      expect(m.customArgs, ['-np', '--flash-attn']);
      expect(m.mmprojPath, r'E:\models\qwen3-4b-mmproj.gguf');
      expect(m.hasDraft, isFalse);
      expect(m.ctx, 4096);
      expect(m.chunk, 128);
      expect(m.gpuLayers, 0);
      expect(back.defaultModelId, 'lm_1_aaaaaaaa');
    });

    test('null 字段不落 JSON 键；老配置缺 localModels 键 → 空列表', () {
      final minimal = LocalModelConfig(
        id: 'lm_2',
        name: 'M',
        modelPath: r'D:\m.gguf',
      );
      final json = minimal.toJson();
      for (final k in ['engineId', 'customArgs', 'mmprojPath', 'draftPath',
          'ctx', 'chunk', 'gpuLayers']) {
        expect(json.containsKey(k), isFalse, reason: k);
      }
      expect(
          InferenceSettings.fromJson(const <String, dynamic>{}).localModels,
          isEmpty);
    });

    test('坏条目静默丢弃（非 Map / 缺 id / 缺 modelPath / 类型错）', () {
      final back = InferenceSettings.fromJson({
        'localModels': [
          sample().toJson(),
          42,
          {'id': 'lm_x', 'name': 'no-path'}, // 缺 modelPath
          {'modelPath': 'd:\\a.gguf'}, // 缺 id
          {'id': 'lm_y', 'modelPath': 3.5}, // 类型错
          {'id': 'lm_z', 'modelPath': 'd:\\z.gguf', 'ctx': 'big'}, // ctx 坏
        ],
      });
      expect(back.localModels.map((e) => e.id), ['lm_1_aaaaaaaa', 'lm_z']);
      expect(back.localModels.last.ctx, isNull);
    });

    test('copyWith：id 锁定、clear 标记能真正清空可空字段', () {
      final m = sample();
      final edited = m.copyWith(
        name: '改名',
        ctx: 2048,
        clearEngineId: true,
        clearCustomArgs: true,
        clearMmprojPath: true,
        draftPath: r'D:\draft.gguf',
      );
      expect(edited.id, m.id);
      expect(edited.name, '改名');
      expect(edited.ctx, 2048);
      expect(edited.engineId, isNull);
      expect(edited.customArgs, isNull);
      expect(edited.mmprojPath, isNull);
      expect(edited.hasDraft, isTrue);
      // 不传 = 保留。
      expect(m.copyWith(chunk: null).chunk, 128);
      expect(m.copyWith().gpuLayers, 0);
    });

    test('displayName：name 空取文件名去扩展名；newLocalModelId 不撞且形态合规', () {
      expect(
        LocalModelConfig(id: 'i', name: '  ', modelPath: r'E:\a\lfm3.gguf')
            .displayName,
        'lfm3',
      );
      final ids = <String>{for (var i = 0; i < 100; i++) newLocalModelId()};
      expect(ids.length, greaterThan(98));
      expect(
          ids.every((e) => RegExp(r'^lm_[0-9]+_[0-9a-f]{1,8}$').hasMatch(e)),
          isTrue);
    });
  });

  group('InferenceSettings 引擎目录/镜像（v0.0.3 Phase 3c）', () {
    test('JSON 往返 + 空白清洗为 null（老 JSON 缺键 = null 不炸）', () {
      final s = const InferenceSettings()
          .copyWith(enginesDir: r'E:\my_engines ', engineMirror: ' https://gh/ ');
      final back = InferenceSettings.fromJson(s.toJson());
      expect(back.enginesDir, r'E:\my_engines', reason: '存储前 trim');
      expect(back.engineMirror, 'https://gh/');
      final legacy = InferenceSettings.fromJson(const {'gpuLayers': 12});
      expect(legacy.enginesDir, isNull);
      expect(legacy.engineMirror, isNull);
      // 空串/纯空白落盘读回 = null（等同未配置）
      final blank = InferenceSettings.fromJson(
          const {'enginesDir': '   ', 'engineMirror': ''});
      expect(blank.enginesDir, isNull);
      expect(blank.engineMirror, isNull);
    });

    test('copyWith clear 标记可复位默认（null 不可被 ?? 语义表达）', () {
      final s = const InferenceSettings()
          .copyWith(enginesDir: 'D:\\e', engineMirror: 'https://gh/');
      final cleared =
          s.copyWith(clearEnginesDir: true, clearEngineMirror: true);
      expect(cleared.enginesDir, isNull);
      expect(cleared.engineMirror, isNull);
      // 不传 = 保持
      expect(s.copyWith(gpuLayers: 8).enginesDir, 'D:\\e');
    });
  });
}
