import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 端侧 ASR 模型管理：不打包进 APK，首次使用时按文件下载（断点续传），
/// 四个文件齐全后能力才启用（READY 状态）。
///
/// 模型：sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30（~160MB），
/// 主源 hf-mirror.com（国内可达），兜底 huggingface.co。
/// 断点续传由 background_downloader 提供：.part 持久化在私有目录，
/// 杀 App / 断网后重新入队自动从断点继续。
class AsrModelManager {
  AsrModelManager._();

  static const String modelId =
      'sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30';

  /// 仓库根（csukuangfj 官方导出仓库）
  static const String _repo = 'csukuangfj/$modelId';

  /// 下载顺序：小文件先行（秒级完成），encoder 最后（大头）。
  static const List<String> files = [
    'tokens.txt',
    'decoder.onnx',
    'joiner.int8.onnx',
    'encoder.int8.onnx',
  ];

  static const String _mirrorBase = 'https://hf-mirror.com';
  static const String _fallbackBase = 'https://huggingface.co';

  static final FileDownloader _downloader = FileDownloader();

  /// 全局更新流的常驻单订阅 → 广播分发。`FileDownloader().updates` 是
  /// 单订阅流，直接在每个下载任务里 listen 第二次会抛
  /// "Stream has already been listened to"（真机实测）。
  static StreamController<TaskUpdate>? _updateHub;

  static Stream<TaskUpdate> get _updates {
    _updateHub ??= () {
      final hub = StreamController<TaskUpdate>.broadcast();
      _downloader.updates.listen(hub.add, onError: hub.addError,
          onDone: hub.close, cancelOnError: false);
      return hub;
    }();
    return _updateHub!.stream;
  }

  /// 模型目录：`<app documents>/models/asr/<modelId>`。
  static Future<String> modelDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'models', 'asr', modelId);
  }

  /// 模型是否已就绪（四个文件全部存在）。
  static Future<bool> isReady() async {
    final dir = await modelDir();
    for (final f in files) {
      if (!File(p.join(dir, f)).existsSync()) return false;
    }
    return true;
  }

  static String _url(String file, {required bool mirror}) =>
      '${mirror ? _mirrorBase : _fallbackBase}/$_repo/resolve/main/$file';

  /// 下载缺失的模型文件（幂等：已存在的文件跳过）。
  ///
  /// [onProgress]：整体进度 0.0~1.0 与当前文件名（以字节计）。
  /// [isCancelled]：外部取消轮询（对话框关闭等），返回 true 时中止并抛
  /// [AsrDownloadCancelled]。
  ///
  /// 下载失败自动切换备用源重试一轮；仍失败抛 [AsrDownloadException]。
  static Future<void> download({
    required void Function(double progress, String currentFile) onProgress,
    required bool Function() isCancelled,
  }) async {
    final dir = await modelDir();
    await Directory(dir).create(recursive: true);

    final missing = [
      for (final f in files)
        if (!File(p.join(dir, f)).existsSync()) f,
    ];
    if (missing.isEmpty) return;

    // 文件字节数用于整体进度加权（encoder 占绝对大头）
    final totalBytes = await _missingBytes(missing);
    var doneBytes = 0;

    for (final file in missing) {
      if (isCancelled()) throw const AsrDownloadCancelled();
      await _downloadOne(
        file,
        dir: dir,
        onFileProgress: (fileDoneBytes) =>
            onProgress((doneBytes + fileDoneBytes) / totalBytes, file),
      );
      doneBytes += await File(p.join(dir, file)).length();
      debugPrint('[DSH][asr] downloaded: $file');
    }
  }

  /// 取消进行中的模型下载（对话框取消按钮）。
  static Future<void> cancelDownloads() async {
    for (final file in files) {
      for (final mirror in const [true, false]) {
        await _downloader.cancelTaskWithId(_taskId(file, mirror));
      }
    }
  }

  /// 单文件下载：主源失败 → 兜底源；两者都失败抛异常。
  /// 同源重试时 background_downloader 按 taskId 自动从 .part 断点续传。
  static Future<void> _downloadOne(
    String file, {
    required String dir,
    required void Function(int bytes) onFileProgress,
  }) async {
    Object? lastError;
    for (final mirror in const [true, false]) {
      try {
        final task = DownloadTask(
          url: _url(file, mirror: mirror),
          filename: file,
          baseDirectory: BaseDirectory.applicationDocuments,
          directory: p.join('models', 'asr', modelId),
          taskId: _taskId(file, mirror),
          updates: Updates.statusAndProgress,
          requiresWiFi: false,
          retries: 3,
        );
        final status = await _downloadWithProgress(task, onFileProgress);
        if (status == TaskStatus.complete) return;
        lastError = 'TaskStatus: $status';
        debugPrint('[DSH][asr] $file (mirror=$mirror) → $status');
        if (status == TaskStatus.canceled) throw const AsrDownloadCancelled();
      } on AsrDownloadCancelled {
        rethrow;
      } catch (e) {
        lastError = e;
        debugPrint('[DSH][asr] $file (mirror=$mirror) error: $e');
      }
    }
    throw AsrDownloadException('$file 下载失败: $lastError');
  }

  /// 订阅更新流直到该任务完结，透传字节进度。
  static Future<TaskStatus> _downloadWithProgress(
    DownloadTask task,
    void Function(int bytes) onFileProgress,
  ) async {
    final completer = Completer<TaskStatus>();
    late final StreamSubscription<TaskUpdate> sub;
    sub = _updates.listen((update) {
      if (update.task.taskId != task.taskId) return;
      switch (update) {
        case TaskProgressUpdate():
          onFileProgress(update.expectedFileSize > 0
              ? (update.progress * update.expectedFileSize).round()
              : 0);
        case TaskStatusUpdate():
          // 只在终态完成等待：enqueued/running/waitingForRetry 是中间态，
          // 首个收到的状态更新可能是 enqueued（时序竞态），当成结束会误报
          // "下载失败: TaskStatus.enqueued"（USB 真机实测）。
          const terminalStatuses = {
            TaskStatus.complete,
            TaskStatus.failed,
            TaskStatus.canceled,
            TaskStatus.notFound,
          };
          if (terminalStatuses.contains(update.status) &&
              !completer.isCompleted) {
            completer.complete(update.status);
            sub.cancel();
          }
      }
    });
    await _downloader.enqueue(task);
    return completer.future;
  }

  static String _taskId(String file, bool mirror) =>
      'asr-${mirror ? 'm' : 'f'}-$modelId-$file';

  /// HEAD 请求拿 missing 文件总大小；拿不到就用保守估计（~160MB）。
  static Future<int> _missingBytes(List<String> missing) async {
    var total = 0;
    for (final f in missing) {
      try {
        final client = HttpClient();
        final req =
            await client.headUrl(Uri.parse(_url(f, mirror: true)));
        final resp = await req.close();
        final len = resp.contentLength;
        client.close(force: true);
        total += len > 0 ? len : 0;
      } catch (_) {}
    }
    return total > 0 ? total : 167000000;
  }

  /// 删除模型目录（设置里的「清除模型」入口）。
  static Future<void> deleteModel() async {
    final dir = await modelDir();
    if (Directory(dir).existsSync()) {
      await Directory(dir).delete(recursive: true);
    }
  }
}

class AsrDownloadCancelled implements Exception {
  const AsrDownloadCancelled();
}

class AsrDownloadException implements Exception {
  const AsrDownloadException(this.message);
  final String message;

  @override
  String toString() => message;
}
