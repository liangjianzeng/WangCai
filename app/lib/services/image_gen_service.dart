/// 图像生成服务（Unsloth Studio Qwen-Image-2.1-Turbo，OpenAI 兼容
/// `/v1/images/generations`，b64_json 返回）。方案见
/// docs/image-gen-integration-plan.md（2026-11-09 评审定案落地版）。
///
/// 纪律与裁决：
/// - **纯 Dart + dio，零原生依赖**，不进平台网关（inference_gateway 的
///   「平台分支只允许出现在这里」不适用于纯 HTTP 客户端）——Windows /
///   Linux(ARM) 同一份代码。
/// - **单飞队列**：服务端单卡串行；客户端 Future 链排队防连点打爆。
///   不用 package:synchronized（仅 transitive 依赖，直接 import 会挂
///   depend_on_referenced_packages lint）。
/// - 取消用 dio CancelToken（2048² 一张 ~105s，前端取消必须真的掐断请求）。
/// - 超时按尺寸分档：512/1024 → 120s，2048 → 300s（首请求含模型加载也归入
///   该预算，占位文案提示「首次约 1 分钟」）。
/// - 配置快照（[ImageGenConfig]）由调用方每次传入——服务不持有全局可变
///   设置状态，测试直接构造 config 注入。
/// - **密钥不进 [ImageGenConfig] 持久化**：调用方从 SecureApiKeyStore
///   （id = [kImageGenApiKeyId]）读出后放进内存快照；落盘设置 JSON 永远
///   不含 key（api_key_store 分叉 #9 同一口径）。
library;

import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Windows 本机默认地址（Unsloth Studio Desktop 后端）。Linux 端无默认，
/// 需在设置里手填局域网地址（服务端开启 LAN + 防火墙放行 8888）。
const String kImageGenDefaultBaseUrl = 'http://127.0.0.1:8888';

/// 生图请求的斜杠命令前缀（入口①之一；全库此前无斜杠命令机制，
/// 由 home_screen 在发送入口处消费）。
const String kImageGenSlashPrefix = '/图 ';

/// 允许的尺寸档位（设置页下拉；WxH 字符串，与 API 契约一致）。
const List<String> kImageGenSizes = [
  '512x512',
  '1024x1024',
  '1440x1440',
  '2048x2048',
];

/// 默认模型名。**空串 = 用服务端缺省模型**（generate 请求省略 model 字段）。
/// 终端配置页应经 `GET /v1/models` 下拉选模型，不要求人手填注册名
/// （2026-11-10 用户点单：旧默认值直接把服务端扫描目录路径
/// `E:/Unsloth/models` 当模型名露出，终端无从理解）。
const String kImageGenDefaultModel = '';

/// SecureApiKeyStore 的密钥 id（前缀 `wangcai.apikey.` 由 store 拼）。
const String kImageGenApiKeyId = 'unsloth-image';

/// 一次生图调用的配置快照（来自 InferenceSettings + 安全存储，调用方负责
/// 取新值；[apiKey] 仅内存态）。
class ImageGenConfig {
  final bool enabled;
  final String baseUrl;
  final String model;
  final String defaultSize;
  final String apiKey;

  const ImageGenConfig({
    required this.enabled,
    required this.baseUrl,
    this.model = kImageGenDefaultModel,
    this.defaultSize = '1024x1024',
    this.apiKey = '',
  });

  /// 生效地址：空串时 Windows 回落本机默认，其余平台视为未配置。
  String get effectiveBaseUrl {
    final t = baseUrl.trim();
    if (t.isNotEmpty) {
      return t.endsWith('/') ? t.substring(0, t.length - 1) : t;
    }
    if (Platform.isWindows) return kImageGenDefaultBaseUrl;
    return '';
  }

  bool get isConfigured => enabled && effectiveBaseUrl.isNotEmpty;

  /// 生效尺寸（脏值回落默认档）。
  String get effectiveSize =>
      kImageGenSizes.contains(defaultSize) ? defaultSize : '1024x1024';
}

/// 一次成功生图的结果（路径已落盘）。
class ImageGenResult {
  /// 本地 PNG 文件绝对路径（n 张）。
  final List<String> paths;

  /// 实际使用的随机种子（客户端生成并随消息存 genMeta，支持同 seed 重生成）。
  final int seed;
  final String size;
  final int ms;

  const ImageGenResult({
    required this.paths,
    required this.seed,
    required this.size,
    required this.ms,
  });

  /// 溯源元数据（ChatMessage.genMeta 的 JSON 结构，单真源）。
  Map<String, dynamic> metaJson(String prompt, String model) => {
        'seed': seed,
        'size': size,
        'ms': ms,
        'model': model,
        'prompt': prompt,
      };
}

class ImageGenErrorKind {
  final String name;
  const ImageGenErrorKind._(this.name);

  static const notConfigured = ImageGenErrorKind._('notConfigured');
  static const unreachable = ImageGenErrorKind._('unreachable');
  static const timeout = ImageGenErrorKind._('timeout');
  static const unauthorized = ImageGenErrorKind._('unauthorized');
  static const serverBusy = ImageGenErrorKind._('serverBusy');
  static const server = ImageGenErrorKind._('server');
  static const decode = ImageGenErrorKind._('decode');
  static const cancelled = ImageGenErrorKind._('cancelled');

  @override
  String toString() => name;
}

class ImageGenException implements Exception {
  final ImageGenErrorKind kind;
  final String message;
  ImageGenException(this.kind, this.message);

  @override
  String toString() => 'ImageGenException(${kind.name}: $message)';
}

/// 健康检查结果（设置页「测试连接」/chip 置灰依据）。
class ImageGenHealth {
  final bool reachable;

  /// /v1/models（需 Bearer）是否通过；reachable 但 false = 密钥错误。
  final bool authorized;
  final int modelCount;

  /// /v1/models 返回的模型 id 列表（设置页下拉数据源；拿不到时空表）。
  final List<String> models;

  /// 人读诊断（绿/红文案直接用）。
  final String message;
  const ImageGenHealth({
    required this.reachable,
    required this.authorized,
    this.modelCount = 0,
    this.models = const [],
    required this.message,
  });

  bool get ok => reachable && authorized;
}

class ImageGenService {
  ImageGenService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              // 有意不设 receiveTimeout（openai_service 同款口径）：生成本身
              // 就是分钟级长请求，超时分档在请求级 Future.timeout 控制。
            ));

  static final ImageGenService instance = ImageGenService();

  final Dio _dio;

  /// 测试注入口：覆盖**文档目录**（单测不走 path_provider 插件）；
  /// imagegen/YYYYMMDD 子目录结构照常生效（测试顺带覆盖落盘布局）。
  static Future<Directory> Function()? docsDirOverride;

  // ---- 单飞队列（Future 链；服务端单卡串行）----
  Future<void> _queueTail = Future<void>.value();
  CancelToken? _activeToken;

  /// 当前是否有请求在飞。
  bool get hasActive => _activeToken != null;

  /// 取消当前在飞请求（排队中的不取消——P0 队列深度通常为 0/1）。
  void cancelActive() {
    _activeToken?.cancel('用户取消');
  }

  /// 队列化执行一次生图；返回已落盘的本地 PNG 路径与溯源参数。
  Future<ImageGenResult> generate({
    required ImageGenConfig config,
    required String prompt,
    String? size,
    String? negative,
    int? seed,
    int n = 1,
  }) {
    return _enqueue(() =>
        _generate(config, prompt, size, negative, seed, n));
  }

  Future<T> _enqueue<T>(Future<T> Function() job) {
    final run = _queueTail.then((_) => job());
    // 链继续挂接：本任务失败（含取消）不断链——后续任务照常执行。
    _queueTail = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<ImageGenResult> _generate(
    ImageGenConfig config,
    String prompt,
    String? size,
    String? negative,
    int? seed,
    int n,
  ) async {
    final promptTrimmed = prompt.trim();
    if (promptTrimmed.isEmpty) {
      throw ImageGenException(ImageGenErrorKind.notConfigured, '提示词为空');
    }
    if (!config.isConfigured) {
      throw ImageGenException(
          ImageGenErrorKind.notConfigured,
          config.enabled
              ? '未配置服务地址（设置 → API 接入 → 图像生成）'
              : '图像生成未启用（设置 → API 接入 → 图像生成）');
    }
    final base = config.effectiveBaseUrl;
    final model = config.model.trim(); // 空 = 省略 model 字段，走服务端缺省
    final effectiveSize =
        kImageGenSizes.contains(size) ? size! : config.effectiveSize;
    final count = n.clamp(1, 4);
    final actualSeed = seed ?? Random().nextInt(1 << 31);

    final token = CancelToken();
    _activeToken = token;
    final sw = Stopwatch()..start();
    try {
      final Response<dynamic> resp;
      try {
        resp = await _dio
            .post<dynamic>(
              '$base/v1/images/generations',
              options: Options(
                headers: {
                  if (config.apiKey.isNotEmpty)
                    'Authorization': 'Bearer ${config.apiKey}',
                },
                responseType: ResponseType.json,
                sendTimeout: const Duration(seconds: 30),
              ),
              cancelToken: token,
              data: {
                if (model.isNotEmpty) 'model': model,
                'prompt': promptTrimmed,
                if (negative != null && negative.trim().isNotEmpty)
                  'negative_prompt': negative.trim(),
                'n': count,
                'size': effectiveSize,
                'response_format': 'b64_json',
                'seed': actualSeed,
              },
            )
            .timeout(timeoutForSize(effectiveSize));
      } on TimeoutException {
        throw ImageGenException(
            ImageGenErrorKind.timeout,
            '生成超时（$effectiveSize 预算 '
            '${timeoutForSize(effectiveSize).inSeconds}s，可去设置换小尺寸）');
      } on DioException catch (e) {
        throw _fromDio(e);
      }
      final dynamic data = resp.data;
      final dynamic list = data is Map ? data['data'] : null;
      if (list is! List || list.isEmpty) {
        throw ImageGenException(
            ImageGenErrorKind.decode, '响应缺少 data 数组');
      }
      final dir = await _dayDir();
      final paths = <String>[];
      final ts = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < list.length; i++) {
        final entry = list[i];
        final dynamic b64 = entry is Map ? entry['b64_json'] : null;
        if (b64 is! String || b64.isEmpty) {
          throw ImageGenException(
              ImageGenErrorKind.decode, '第 ${i + 1} 张缺少 b64_json');
        }
        final List<int> bytes;
        try {
          bytes = base64Decode(b64);
        } on FormatException catch (e) {
          throw ImageGenException(
              ImageGenErrorKind.decode, 'base64 解码失败: $e');
        }
        final file = File(
            p.join(dir.path, 'img-$ts-${actualSeed}_${i + 1}.png'));
        await file.writeAsBytes(bytes, flush: true);
        paths.add(file.path);
      }
      sw.stop();
      return ImageGenResult(
        paths: paths,
        seed: actualSeed,
        size: effectiveSize,
        ms: sw.elapsedMilliseconds,
      );
    } finally {
      _activeToken = null;
    }
  }

  /// DioException → 带口径的 ImageGenException（错误文案区分 unreachable /
  /// unauthorized / 429 排队 / 超时，设置页与聊天报错共用）。
  ImageGenException _fromDio(DioException e) {
    if (CancelToken.isCancel(e)) {
      return ImageGenException(ImageGenErrorKind.cancelled, '已取消');
    }
    final code = e.response?.statusCode ?? 0;
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      // dio 存量别名（等同 receiveTimeout，仍枚举在类型里）。
      case DioExceptionType.transformTimeout:
        return ImageGenException(
            ImageGenErrorKind.timeout, '连接超时（服务可能未启动）');
      case DioExceptionType.connectionError:
        return ImageGenException(ImageGenErrorKind.unreachable,
            '服务不可达（请确认 Unsloth 已启动；跨机访问需防火墙放行 8888）');
      case DioExceptionType.badResponse:
        if (code == 401 || code == 403) {
          return ImageGenException(
              ImageGenErrorKind.unauthorized, '鉴权失败（API key 错误或已吊销）');
        }
        if (code == 429) {
          return ImageGenException(
              ImageGenErrorKind.serverBusy, '服务端正忙（429），请稍后重试');
        }
        return ImageGenException(
            ImageGenErrorKind.server, '服务端错误（HTTP $code）');
      case DioExceptionType.cancel:
        return ImageGenException(ImageGenErrorKind.cancelled, '已取消');
      case DioExceptionType.badCertificate:
        return ImageGenException(
            ImageGenErrorKind.unreachable, '证书校验失败');
      case DioExceptionType.unknown:
        return ImageGenException(
            ImageGenErrorKind.unreachable, '网络错误：${e.message ?? e.error ?? ''}');
    }
  }

  /// 超时预算按尺寸分档：>=2048 → 300s，否则 120s。
  static Duration timeoutForSize(String size) {
    final parts = size.split('x');
    final w = int.tryParse(parts.first) ?? 1024;
    final h = parts.length > 1 ? (int.tryParse(parts[1]) ?? w) : w;
    return max(w, h) >= 2048
        ? const Duration(seconds: 300)
        : const Duration(seconds: 120);
  }

  /// 健康检查：`GET {base}/api/health`（免鉴权）测可达性；
  /// `GET {base}/v1/models`（需 Bearer）测密钥并顺带数模型。
  /// 任一步网络异常都折算成可达性结论，绝不抛——设置页绿灯/红灯直接消费。
  Future<ImageGenHealth> checkHealth(ImageGenConfig config) async {
    final base = config.effectiveBaseUrl;
    if (!config.enabled || base.isEmpty) {
      return const ImageGenHealth(
          reachable: false,
          authorized: false,
          message: '未启用或未配置地址');
    }
    try {
      await _dio.get<dynamic>('$base/api/health',
          options: Options(
              receiveTimeout: const Duration(seconds: 6),
              sendTimeout: const Duration(seconds: 6)));
    } on DioException catch (e) {
      final ex = _fromDio(e);
      return ImageGenHealth(
          reachable: false,
          authorized: false,
          message: ex.kind == ImageGenErrorKind.timeout
              ? '服务无响应（超时）'
              : '服务不可达：${ex.message}');
    } catch (e) {
      return ImageGenHealth(
          reachable: false, authorized: false, message: '服务不可达：$e');
    }
    try {
      final resp = await _dio.get<dynamic>('$base/v1/models',
          options: Options(headers: {
            if (config.apiKey.isNotEmpty)
              'Authorization': 'Bearer ${config.apiKey}',
          }, receiveTimeout: const Duration(seconds: 6)));
      final dynamic d = resp.data;
      final dynamic list = d is Map ? d['data'] : null;
      final ids = <String>[];
      if (list is List) {
        for (final e in list) {
          final dynamic id = e is Map ? (e['id'] ?? e['name']) : null;
          if (id is String && id.isNotEmpty) ids.add(id);
        }
      }
      return ImageGenHealth(
          reachable: true,
          authorized: true,
          modelCount: ids.isEmpty ? (list is List ? list.length : 0) : ids.length,
          models: ids,
          message: '已连接（${ids.isEmpty ? (list is List ? list.length : 0) : ids.length} 个模型）');
    } on DioException catch (e) {
      final code = e.response?.statusCode ?? 0;
      if (code == 401 || code == 403) {
        return const ImageGenHealth(
            reachable: true,
            authorized: false,
            message: '服务可达，但 API key 无效（401）');
      }
      // /v1/models 个别网关实现缺失：health 已过即视为可用（保守放行）。
      return ImageGenHealth(
          reachable: true, authorized: true, message: '已连接（模型列表不可用：HTTP $code）');
    } catch (e) {
      return ImageGenHealth(
          reachable: true, authorized: true, message: '已连接（模型列表不可用：$e）');
    }
  }

  /// 落盘目录：documents/imagegen/YYYYMMDD/（对齐 export_file 的公共产物
/// 思路；Linux 走 XDG 自动正确）。先只增不删（P2 再定清理策略）。
  static Future<Directory> _dayDir() async {
    final override = docsDirOverride;
    final docs = override != null ? await override() : await getApplicationDocumentsDirectory();
    final now = DateTime.now();
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    final dir = Directory(p.join(docs.path, 'imagegen',
        '${now.year}$mm$dd'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }
}
