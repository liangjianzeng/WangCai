import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/engine/bundled_manifests.dart';
import 'package:wangcai/engine/engine_config.dart';
import 'package:wangcai/engine/engine_manifest.dart';

void main() {
  group('模板渲染', () {
    test('必填占位符 + 默认值 + 可选成对删除', () {
      final args = renderArgsTemplate(
        [
          '-m', '{model}',
          '--mmproj', '{mmproj?}',
          '-c', '{ctx=1024}',
          '--port', '{port}',
        ],
        {'model': 'a.gguf', 'port': '8123'},
      );
      expect(args, ['-m', 'a.gguf', '-c', '1024', '--port', '8123']);
    });

    test('提供 mmproj 则成对保留', () {
      final args = renderArgsTemplate(
          ['-m', '{model}', '--mmproj', '{mmproj?}'],
          {'model': 'a.gguf', 'mmproj': 'm.gguf'});
      expect(args, ['-m', 'a.gguf', '--mmproj', 'm.gguf']);
    });

    test('必填缺值抛错', () {
      expect(() => renderArgsTemplate(['-m', '{model}'], {}),
          throwsArgumentError);
    });
  });

  group('内置 manifest', () {
    test('P14e 钉死：KV_HOST_WRITE 模板默认 0，任何 preset 不得翻 1（缺陷回归锚）', () {
      // 根因与证据：docs/defect-npu-p14e-kvhostwrite.md——Nov 5 引擎 DLL 默认 ON
      // 致 NPU 全线垃圾文本（Omni/1.7B 复读、Spark 乱码）；引擎侧修复并过文本闸
      // 之前，清单必须显式压 0。渲染语义 {name=default} 由上方「模板渲染」组锁定。
      final npu = bundledManifests()['wangcai-npu']!;
      expect(npu.envTemplate['GGML_OPENVINO_KV_HOST_WRITE'], '{kvHostWrite=0}',
          reason: 'envTemplate 必须自带显式 0 默认（未注入也压过 DLL 默认 ON）');
      for (final p in npu.presets) {
        expect(p.extraEnv['GGML_OPENVINO_KV_HOST_WRITE'], isNot('1'),
            reason: 'preset ${p.name} 重新打开了 P14e');
      }
    });

    test('四个驱动可解析且关键字段正确', () {
      final m = bundledManifests();
      expect(m.keys, containsAll(['wangcai-npu', 'llamacpp-vulkan', 'llamacpp-cuda', 'openai-remote']));
      final npu = m['wangcai-npu']!;
      expect(npu.kind, 'llamaServer');
      // M0-3 实测校正：server 参数集不含 -st
      expect(npu.argsTemplate, isNot(contains('-st')));
      expect(npu.argsTemplate, containsAll(<String>['-np', '1', '-fa', '1', '--jinja']));
      expect(npu.capabilities.nativeToolCall, isTrue);
      // 1fa151d（2026-11-05）：实测冷编 130–420s，预算钉 600s —— 旧值 81s/36s
      // 会硬杀编译导致 blob 永不落盘。
      expect(npu.timingHints.coldCompileMs, 600000);
      expect(m['openai-remote']!.kind, 'remote');
    });

    test('admission（2026-11-07 收紧）：4B 级 ctx≤512 放行、>512 拦；1.7B@16384 放行', () {
      // 2026-11-07 本机实锤翻转旧口径（「4096 实测放行」不成立）：
      // Qwen3-4B@4096 首请求即 L0 UNINITIALIZED 500、Spark@4096 预算非确定性
      // 塌 0.42（bindings 旧档已按 stable 语义收回）；4B 确定档 = ctx≤512
      // （Spark warm ≈6 t/s 复测）。1.7B/2B 不受影响（22+ t/s 全 ctx 健康）。
      final npu = bundledManifests()['wangcai-npu']!;
      expect(npu.checkAdmission(ctx: 512, paramsB: 4.0), isEmpty,
          reason: 'ctx≤512 是 4B 确定可用档');
      expect(npu.checkAdmission(ctx: 768, paramsB: 4.0), isNotEmpty,
          reason: '768 即需 level 1024 图——4B 预算墙');
      expect(npu.checkAdmission(ctx: 8192, paramsB: 4.0), isNotEmpty);
      expect(npu.checkAdmission(ctx: 16384, paramsB: 1.7), isEmpty);
    });

    test('admission 模型维度（2026-11-07）：Spark 4B 在 NPU 深上下文拦、ctx≤512 放行，CUDA/Vulkan 不受影响', () {
      // defect-npu-spark-b12034：decode-levels 在对话深度到 level 1024 档时撞
      // 设备预算，全局回退 0.42 t/s 地板（智能体场景实锤）——ctx>512 拦。
      // 2026-11-07 复测修正：ctx≤512 档 level 图健康（warm ≈6 t/s，零预算
      // 异常），不再是全 ctx 禁入——方向语义：modelFile 未知/不命中 glob →
      // 豁免（错放危害 < 错拦）。
      final npu = bundledManifests()['wangcai-npu']!;
      const spark = 'spark-x2.6-4b-q4_k_m.gguf';
      final v = npu.checkAdmission(
          ctx: 4096, paramsB: 4.0, modelFile: spark, generation: 'ultra1');
      expect(v, isNotEmpty, reason: 'Spark@NPU@4096 必须前置拦（智能体已实测歇菜）');
      expect(v.join(), contains('512'),
          reason: '改道建议必须给出可操作的出路（模型级 ctx≤512）');
      // ctx≤512 放行：level 256/512 图实测健康。
      expect(
          npu.checkAdmission(
              ctx: 512, paramsB: 4.0, modelFile: spark, generation: 'ultra1'),
          isEmpty,
          reason: 'Spark@NPU@512 是保守可用档，不拦');
      // 768 会需要 level 1024 图（256×2^k 上取整）——同在拦内。
      expect(
          npu.checkAdmission(
              ctx: 768, paramsB: 4.0, modelFile: spark, generation: 'ultra1'),
          isNotEmpty);
      // 非 Spark 模型同条件照常放行（glob 不豁免错拦；ctx≤512 线内）。
      expect(
          npu.checkAdmission(
              ctx: 512, paramsB: 4.0, modelFile: 'Qwen3-4B-Q4_K_M.gguf'),
          isEmpty);
      // modelFile 未知（旧调用路径）不触发模型禁令，但通用 4B ctx 线（>512）
      // 仍然生效——旧口径的「无 modelFile 全放行」随 2026-11-07 实锤翻转。
      expect(npu.checkAdmission(ctx: 4096, paramsB: 4.0), isNotEmpty);
      // CUDA manifest 无此规则：Spark 换引擎后同 ctx 照常放行。
      final cuda = bundledManifests()['llamacpp-cuda'];
      if (cuda != null) {
        expect(cuda.checkAdmission(ctx: 4096, paramsB: 4.0, modelFile: spark),
            isEmpty);
      }
    });

    test('admission 模型维度（2026-11-07b）：Qwen3.5-4B 在 NPU 禁入（driver opset 未支持），GPU 放行', () {
      // defect-npu-qwen35-b12034：GatedDeltaNet 融合算子以自定义 opset 序列化，
      // NPU driver VCL 反序列化失败（graph 编译期死；ref 分解/CPU 分段/naive
      // 分段三路收口均不可行后引擎回滚 pristine）——模型级禁入 + 改道建议，
      // 与 Spark 锚同形态。
      final npu = bundledManifests()['wangcai-npu']!;
      const qwen35 = 'Qwen3.5-4B-Q4_K_M.gguf';
      final v = npu.checkAdmission(
          ctx: 4096, paramsB: 4.0, modelFile: qwen35, generation: 'ultra1');
      expect(v, isNotEmpty, reason: 'Qwen3.5@NPU 必须前置拦（编译期死，不放进推理）');
      expect(v.join(), contains('CUDA/Vulkan'),
          reason: '改道建议必须给出可操作的出路');
      // glob 大小写不敏感：用户盘内小写文件名同样命中。
      expect(
          npu.checkAdmission(
              ctx: 4096, paramsB: 4.0, modelFile: 'qwen3.5-4b-q4_k_m.gguf'),
          isNotEmpty);
      // Qwen3（非 3.5）不受 qwen35 规则牵连：glob 只匹配 Qwen3.5 前缀
      // （ctx 用 512 避开通用 4B ctx 线，隔离 glob 语义本身）。
      expect(
          npu.checkAdmission(
              ctx: 512, paramsB: 4.0, modelFile: 'Qwen3-4B-Q4_K_M.gguf'),
          isEmpty);
      // Vulkan manifest 无此规则；GPU preset 已在 vulkan/cuda 各留一档。
      final vulkan = bundledManifests()['llamacpp-vulkan'];
      if (vulkan != null) {
        expect(vulkan.checkAdmission(ctx: 4096, paramsB: 4.0, modelFile: qwen35),
            isEmpty);
        expect(vulkan.presetByName('qwen3.5-4b-gpu'), isNotNull);
      }
      expect(bundledManifests()['llamacpp-cuda']!.presetByName('qwen3.5-4b-gpu'),
          isNotNull);
    });

    test('视觉能力声明（2026-11-07 第二幕）：NPU vision=true 回填，门改 per-model mmproj 判定', () {
      // defect-npu-mtmd 引擎修复（sched 切段尾段无 inp_pos → naive 分流；
      // NPU 带图三线 E2E 全绿：mtmd-cli 128px、mtmd-cli 1920×1200、
      // llama-server OpenAI 格式带图）。引擎能力声明翻回 true；带图前置门
      // 不再只看引擎声明，而是按「本次启动是否挂 mmproj」per-model 判定
      // （local_server_inference._visionGateErrorIfAny）——没挂视觉塔的
      // 模型发图仍明确报错不放行。
      final npu = bundledManifests()['wangcai-npu']!;
      expect(npu.capabilities.vision, isTrue,
          reason: 'NPU mtmd 引擎修复（defect-npu-mtmd 第二幕），声明回填 true；'
              'per-model 判定在带图前置门');
      expect(bundledManifests()['llamacpp-cuda']!.capabilities.vision, isTrue);
      expect(bundledManifests()['llamacpp-vulkan']!.capabilities.vision, isTrue);
    });

    test('neohorse-1-4b 留位（2026-11-07 用户点单）：glob 对准目录文件名，通用 4B admission 接管', () {
      // NeoHorse-1 4B（TokenRhythm，Q4_K_M 2.5GB，262k ctx，原生工具调用）：
      // 下载目录 models_catalog.json 已在架，本次只补 NPU preset 留位——
      // 尚未本机实测，性能/稳定性不预设结论；paramsB 4.0 自动落入通用 4B
      // 规则（ctx≤512 放行、>512 拦+改道建议），实测后按结果补注。
      final npu = bundledManifests()['wangcai-npu']!;
      final p = npu.presetByName('neohorse-1-4b');
      expect(p, isNotNull);
      expect(p!.modelGlob, 'NeoHorse-1-4B*.gguf');
      expect(p.paramsB, 4.0);
      expect(p.chunk, 128, reason: 'chunk128 对齐 4B 家族先例（qwen3-4b 同款）');
      // glob 大小写不敏感，对准目录下载产物的真实文件名。
      expect(modelGlobMatches(p.modelGlob!, 'NeoHorse-1-4B-Q4_K_M.gguf'), isTrue);
      // admission 语义：ctx≤512 放行（保守可用档），>512 被通用 4B 规则拦。
      expect(
          npu.checkAdmission(
              ctx: 512, paramsB: 4.0, modelFile: 'NeoHorse-1-4B-Q4_K_M.gguf'),
          isEmpty);
      expect(
          npu.checkAdmission(
              ctx: 4096, paramsB: 4.0, modelFile: 'NeoHorse-1-4B-Q4_K_M.gguf'),
          isNotEmpty,
          reason: '4B 级 ctx>512 前置拦（通用规则，未实测前照常生效）');
    });

    test('qwen3.5-2b 留位（2026-11-07 用户点单）：glob 对准目录条目，2B 不落 4B 拦截', () {
      // unsloth Qwen3.5-2B-MTP UD-Q4_K_XL（目录已在架）：同 qwen35 混合架构，
      // GatedDeltaNet opset 风险与 4B 同源（defect-npu-qwen35-b12034）——
      // 2B 未单独实测，不预设结论也不加家族级禁入（错放危害<错拦语义）。
      final npu = bundledManifests()['wangcai-npu']!;
      final p = npu.presetByName('qwen3.5-2b');
      expect(p, isNotNull);
      expect(p!.modelGlob, 'Qwen3.5-2B*.gguf');
      expect(p.paramsB, 2.0);
      expect(p.chunk, 128, reason: 'chunk128 对齐 2B 先例（Omni 同款）');
      // 目录落盘名 {qwen3.5-2b-mtp-ud-q4_k_xl}.gguf 必须在 glob 射程内。
      expect(modelGlobMatches(p.modelGlob!, 'qwen3.5-2b-mtp-ud-q4_k_xl.gguf'),
          isTrue);
      // paramsB 2.0 < 3.5 → 通用 4B 规则不牵连，全 ctx 放行（未实测前不预设）。
      expect(
          npu.checkAdmission(
              ctx: 4096,
              paramsB: 2.0,
              modelFile: 'qwen3.5-2b-mtp-ud-q4_k_xl.gguf'),
          isEmpty);
      // 4B 邻档（qwen3.5-4b）在 ctx>512 照常被 qwen35 专属规则拦，不受影响。
      expect(
          npu.checkAdmission(
              ctx: 4096, paramsB: 4.0, modelFile: 'Qwen3.5-4B-Q4_K_M.gguf'),
          isNotEmpty);
    });

    test('全局 ctx 口径（2026-11-06）：preset 不再携带 ctx；deep 档位已退役', () {
      // per-model ctx 退役：ctx 只有一个口子（设置页滑杆 → routing.json，
      // 见 local_server_inference.setGlobalCtx）；preset 只剩质量臂数据
      // （chunk/device/paramsB/extraEnv）。16K 深档 = 网关 ctx>4096 自动挂
      // NPUW_FOLD=YES，不再是一条 preset。
      final npu = bundledManifests()['wangcai-npu']!;
      for (final p in npu.presets) {
        expect(p.ctx, isNull, reason: 'preset ${p.name} 又带上 ctx 了');
      }
      expect(npu.presetByName('lfm3-1.7b-deep'), isNull);
      // 2026-11-06 换机矩阵翻转（defect-npu-spark-b12034）：b12034 引擎上
      // DDL=1 对 Spark 4B 直接 ZE_RESULT_ERROR_UNINITIALIZED（Compute error
      // 500，两跑复现）；摘掉后 0.42 t/s 引擎地板（不崩不 OOM → 按 HANDOFF
      // §4 条款拍板摘除）。与 Omni 同锁：永远不得加回。
      expect(
          npu.presetByName('spark-x2.6-4b')!
              .extraEnv['GGML_OPENVINO_DISABLE_DECODE_LEVELS'],
          isNull,
          reason: 'DDL=1 在 b12034 上对 Spark 4B 是 Compute error（缺陷单锚）');
      // 回归锁（2026-11-06 omni-matrix 实锤）：Omni 带上 DDL=1 就深层崩速
      // （4096 档 1.7 t/s vs 摘除后 19.8），永远不得加回来。
      expect(
          npu.presetByName('lfm3-omni-2b')!
              .extraEnv['GGML_OPENVINO_DISABLE_DECODE_LEVELS'],
          isNull,
          reason: 'Omni 深层崩速元凶，2026-11-06 矩阵实锤后已摘除');
    });

    test('admission 世代条件（2026-11-05）：appliesGenerations 名单外豁免', () {
      const rule = AdmissionRule(
          ifCtxGt: 512,
          appliesGenerations: ['ultra1'],
          message: 'm',
          suggestion: 's');
      expect(rule.triggers(ctx: 1024, paramsB: 4.0, generation: 'ultra1'),
          isTrue);
      expect(rule.triggers(ctx: 1024, paramsB: 4.0, generation: 'ultra2'),
          isFalse);
      expect(rule.triggers(ctx: 1024, paramsB: 4.0, generation: null), isTrue,
          reason: '未探测 → 保守全量生效');
      // 默认（无 appliesGenerations）全世代适用 —— 现有 4B 规则即此形态。
      const plain = AdmissionRule(ifCtxGt: 512, message: 'm', suggestion: 's');
      expect(plain.triggers(ctx: 1024, paramsB: 4.0, generation: 'ultra3'),
          isTrue);
    });

    test('admission 实测豁免：ctx 门槛规则让位实测档，非 ctx 规则不让位', () {
      const rule = AdmissionRule(
          ifCtxGt: 512, ifParamsBAtLeast: 3.5, message: 'm', suggestion: 's');
      expect(rule.triggers(ctx: 1024, paramsB: 4.0, measuredCtx: 1024), isFalse,
          reason: '该机已在 1024 跑成功过 → 先验被实测证伪，放行');
      expect(rule.triggers(ctx: 1024, paramsB: 4.0, measuredCtx: 512), isTrue,
          reason: '实测只到 512，1024 仍按先验拦');
      const pureParam =
          AdmissionRule(ifParamsBAtLeast: 7.0, message: 'm', suggestion: 's');
      expect(pureParam.triggers(ctx: 1024, paramsB: 8.0, measuredCtx: 4096),
          isTrue, reason: '纯参数量禁令与实测 ctx 无关，不让位');
      // 无参数量条件的纯 ctx 规则同样豁免（实测就是 ctx 的证据）。
      const ctxOnly = AdmissionRule(ifCtxGt: 2048, message: 'm', suggestion: 's');
      expect(ctxOnly.triggers(ctx: 4096, paramsB: null, measuredCtx: 4096),
          isFalse);
    });

    test('兜底准入（2026-11-09）：4B 线规则声明 fallbackCtx=512，全禁入规则不声明', () {
      // 用户拍板「问题模型先兜底定制 ctx，确保先能用」：ctx 门槛类规则（实测
      // 存在安全档）触发时网关不拒载、把 ctx 收敛到 fallbackCtx 继续加载；
      // 无实测安全档的模型（Qwen3.5-4B 编译即死 / MiniCPM5 全矩阵仅 1 点可用
      // 2.0 t/s，禁入拍板在案）不声明 → 维持硬拒载。
      final npu = bundledManifests()['wangcai-npu']!;
      // 规则 1（Spark）与规则 3（通用 4B）带兜底档；规则 2（Qwen3.5-4B）与
      // 规则 4（MiniCPM5）不带。
      final fallbacks = {
        for (final r in npu.admission)
          if (r.ifModelGlob != null) r.ifModelGlob!: r.fallbackCtx,
      };
      expect(fallbacks['Spark-X2.6-4B*.gguf'], 512);
      expect(fallbacks['MiniCPM5-2B*.gguf'], isNull);
      expect(fallbacks['Qwen3.5-4B*.gguf'], isNull);
      // 通用 4B 规则没有 glob 键，单独按条件找。
      expect(
          npu.admission
              .firstWhere((r) => r.ifCtxGt == 512 && r.ifModelGlob == null)
              .fallbackCtx,
          512);
      // 声明纪律：兜底档必须 ≤ ifCtxGt（兜底档就是门槛本身）。
      for (final r in npu.admission) {
        if (r.fallbackCtx != null && r.ifCtxGt != null) {
          expect(r.fallbackCtx! <= r.ifCtxGt!, isTrue,
              reason: '规则 ${r.ifModelGlob ?? r.ifParamsBAtLeast} 兜底档越过了门槛');
        }
      }
    });

    test('兜底准入 evaluateAdmission：4B@4096 → 收敛 512；全禁入 → fallback null（硬拒载）', () {
      final npu = bundledManifests()['wangcai-npu']!;
      // Qwen3-4B@4096（通用 4B 规则触发）：有兜底档。
      final q4 = npu.evaluateAdmission(
          ctx: 4096, paramsB: 4.0, modelFile: 'Qwen3-4B-Q4_K_M.gguf');
      expect(q4.violations, isNotEmpty);
      expect(q4.fallbackCtx, 512, reason: '收敛到实测安全档 512，而非拒载');
      // 收敛后重评：规则不再触发（ctx≤512 确定可用档）。
      expect(
          npu.evaluateAdmission(
                  ctx: q4.fallbackCtx!,
                  paramsB: 4.0,
                  modelFile: 'Qwen3-4B-Q4_K_M.gguf')
              .violations,
          isEmpty);
      // Spark@4096（规则 1+3 双触发，兜底档同 512）：取最小。
      final spark = npu.evaluateAdmission(
          ctx: 4096, paramsB: 4.0, modelFile: 'spark-x2.6-4b-q4_k_m.gguf');
      expect(spark.violations, isNotEmpty);
      expect(spark.fallbackCtx, 512);
      // 无规则触发 → violations 空且 fallback null（不 clamp）。
      final ok = npu.evaluateAdmission(
          ctx: 512, paramsB: 4.0, modelFile: 'Qwen3-4B-Q4_K_M.gguf');
      expect(ok.violations, isEmpty);
      expect(ok.fallbackCtx, isNull);
      // 全禁入模型：任一触发规则缺 fallbackCtx → fallback null（硬拒载）。
      const qwen35 = 'Qwen3.5-4B-Q4_K_M.gguf';
      final ban = npu.evaluateAdmission(
          ctx: 512, paramsB: 4.0, modelFile: qwen35, generation: 'ultra1');
      expect(ban.violations, isNotEmpty);
      expect(ban.fallbackCtx, isNull,
          reason: 'Qwen3.5-4B 无任何实测安全档（编译即死），必须硬拒载');
      final mini = npu.evaluateAdmission(
          ctx: 512, paramsB: 2.6, modelFile: 'MiniCPM5-2B-Q4_K_M.gguf');
      expect(mini.violations, isNotEmpty);
      expect(mini.fallbackCtx, isNull,
          reason: 'MiniCPM5 全矩阵仅 1 点可用（2.0 t/s），禁入拍板在案');
      // 实测豁免联运：该机实测跑通过 4096 → ctx 门槛规则让位 → 无兜底需求
      //（规则豁免条件是 ctx ≤ measuredCtx；实测 1024 只豁免 ≤1024 的请求，
      // 更高请求仍触发、由网关按 max(兜底档, 实测档) 收敛——网关锚在
      // npu_generation_adapt_test）。
      final measured = npu.evaluateAdmission(
          ctx: 4096,
          paramsB: 4.0,
          modelFile: 'Qwen3-4B-Q4_K_M.gguf',
          measuredCtx: 4096);
      expect(measured.violations, isEmpty,
          reason: '实测上探闭环不受兜底影响：measuredCtx ≥ ctx 规则让位');
      // 1.7B 主打线不受兜底机制影响（全 ctx 健康）。
      final lfm = npu.evaluateAdmission(
          ctx: 16384, paramsB: 1.7, modelFile: 'LFM3-1.7B-Q4_K_M.gguf');
      expect(lfm.violations, isEmpty);
      expect(lfm.fallbackCtx, isNull);
    });
  });

  group('profileId（D6 缓存目录隔离）', () {
    EngineConfig cfg({int? ctx, int? chunk, String? dev}) => EngineConfig(
        engineId: 'wangcai-npu',
        modelPath: 'models/LFM3.gguf',
        ctx: ctx ?? 1024,
        chunk: chunk,
        device: dev ?? 'NPU');

    test('同参数同 id；影响编译的参数变 → id 变', () {
      expect(cfg().profileId, cfg().profileId);
      expect(cfg().profileId, isNot(cfg(ctx: 512).profileId));
      expect(cfg().profileId, isNot(cfg(chunk: 128).profileId));
      expect(cfg().profileId, isNot(cfg(dev: 'CPU').profileId));
    });

    test('extraEnv 顺序无关同 id', () {
      final a = EngineConfig(
          engineId: 'e',
          modelPath: 'm',
          extraEnv: const {'A': '1', 'B': '2'});
      final b = EngineConfig(
          engineId: 'e',
          modelPath: 'm',
          extraEnv: const {'B': '2', 'A': '1'});
      expect(a.profileId, b.profileId);
    });
  });
}
