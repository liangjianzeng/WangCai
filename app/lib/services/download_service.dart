import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import '../models/model_info.dart';
import 'model_manager.dart';
import 'model_storage_service.dart';

class _CapturingSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

/// Runs inside an Isolate: sha256 of a file as lowercase hex. Several GB per
/// model, so it must never hash on the UI isolate.
Future<String> _computeSha256OfFile(String path) async {
  final sink = _CapturingSink();
  final input = crypto.sha256.startChunkedConversion(sink);
  await for (final chunk in File(path).openRead()) {
    input.add(chunk);
  }
  input.close();
  return sink.value.toString();
}

class DownloadService {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService() => _instance;
  DownloadService._internal();

  // Extended timeouts for large model downloads (up to 2GB+)
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(minutes: 3),
    receiveTimeout: const Duration(hours: 2), // Very long timeout for large files
    sendTimeout: const Duration(minutes: 5),
  ));

  // 最多同时下载 2 个模型（CDN 实测可承受）。注意：每个视觉模型内部是「主 gguf
  // + mmproj」顺序下载，占用同一槽位；故 2 并发 = 最多 2 个模型并行。
  static const int maxConcurrentDownloads = 2;

  final Map<String, _ActiveDownload> _activeDownloads = {};
  final Map<String, DateTime> _lastProgressTime = {};

  /// 单次下载允许的最大自动重试次数（含首次）。网络抖动/连接被 CDN 中途
  /// 关闭时，会自动断点续传重试，不必用户手动点「重试」。
  static const int _maxAttempts = 8;

  List<DownloadTask> get activeTasks =>
      _activeDownloads.values.map((d) => d.task).toList();

  Future<void> download(
    ModelConfig model, {
    required void Function(DownloadTask) onProgress,
    Duration progressInterval = const Duration(milliseconds: 500),
    DownloadTask? existingTask, // Optional task to reuse (e.g., from provider's initialTask)
  }) async {
    // ---- Concurrency guard ----
    final sameModel = _activeDownloads[model.id];
    if (sameModel != null) {
      // Already tracked for this model: ignore a duplicate start while it is
      // still downloading; clear a stale (paused/completed) entry so a resume
      // or retry can proceed without tripping the capacity guard.
      if (sameModel.task.state == DownloadState.downloading) return;
      _activeDownloads.remove(model.id);
    }
    if (_activeDownloads.length >= maxConcurrentDownloads) {
      throw DownloadException('Only one download at a time.');
    }

    // 多文件模型（主 gguf + mmproj + dspark + 拆分专家包）：进度按总字节
    // 累计显示，避免阶段切换时进度「重头」（此前每阶段把 downloadedBytes
    // 重置为 0）。
    final totalAll = model.totalBytes;
    final task = existingTask ?? DownloadTask(
      modelId: model.id,
      state: DownloadState.downloading,
      totalBytes: totalAll > 0 ? totalAll : model.sizeBytes,
      startTime: DateTime.now(),
    );

    _activeDownloads[model.id] = _ActiveDownload(task: task);
    onProgress(task);

    final dir = await _getModelsDir();
    await dir.create(recursive: true);

    try {
      // ---- 主模型 gguf ----
      // 若主 gguf 已在磁盘且完整（存在、大小达标、无残留 .tmp），则跳过下载，
      // 直接进入 mmproj 阶段。这样「已下主模型、缺投影器」的视觉模型点「下载」
      // 时只补下 mmproj，不会把多 GB 的主 gguf 再拉一遍。
      final ggufTarget = _DownloadTarget(
        mirrors: model.mirrors, sizeBytes: model.sizeBytes, suffix: '.gguf',
        sha256Hash: model.sha256Hash,
      );
      final ggufTemp = File(p.join(dir.path, model.id + ggufTarget.suffix + '.tmp'));
      final ggufFinal = File(p.join(dir.path, model.id + ggufTarget.suffix));
      // 完成判定：存在、无残留 .tmp、非空，且（catalog 配了 sha256 时）哈希相符。
      // catalog 估算大小不可靠（常与实际不符），配了哈希就以哈希为准——损坏的
      // 「缓存完成」文件会被删除重下，而不是永远加载出乱码。
      final ggufComplete = !(await ggufTemp.exists()) &&
          await _trustedOrClean(ggufFinal, model.sha256Hash, '主 gguf');
      task.stage = '主模型';
      if (ggufComplete) {
        debugPrint('[DownloadService] ${model.id} 主 gguf 已完整，跳过主模型下载');
      } else {
        await _runDownloadLoop(
          model, task, ggufTarget, ggufTemp, ggufFinal, onProgress, progressInterval,
          baseBytes: 0,
        );
      }

      // ---- mmproj 投影器（text+mmproj 两文件形态）----
      // 主模型完成后顺序下载投影器。mmproj 下载失败不删除已下好的主 gguf
      // （模型仍可文本推理），但整任务标记为失败。
      final mm = model.mmproj;
      if (mm != null) {
        // 进度累计：从主模型已完成字节起，不再重置（否则 UI 显示「重头」）。
        final mmBase = await ggufFinal.length();
        task.stage = '投影器';
        task.state = DownloadState.downloading;
        onProgress(task);
        final mmprojTarget = _DownloadTarget(
          mirrors: mm.mirrors, sizeBytes: mm.sizeBytes, suffix: '.mmproj',
        );
        final mmprojTemp = File(p.join(dir.path, model.id + mmprojTarget.suffix + '.tmp'));
        final mmprojFinal = File(p.join(dir.path, model.id + mmprojTarget.suffix));
        // 与主 gguf 同样的「已完整则跳过」（mmproj 无 sha256 字段，按存在判定）。
        final mmprojComplete = !(await mmprojTemp.exists()) &&
            await _trustedOrClean(mmprojFinal, null, 'mmproj');
        if (mmprojComplete) {
          final done = await mmprojFinal.length();
          debugPrint('[DownloadService] ${model.id} mmproj 已完整，跳过投影器下载');
          task.downloadedBytes = mmBase + done;
          task.state = DownloadState.completed;
          task.endTime = DateTime.now();
          onProgress(task);
        } else {
          await _runDownloadLoop(
            model, task, mmprojTarget, mmprojTemp, mmprojFinal, onProgress, progressInterval,
            baseBytes: mmBase,
          );
        }
      }

      // ---- dspark 投机草稿头（模型目录声明时）----
      // 主模型 + mmproj 完成后顺序下载草稿头。dspark 下载失败不删除已下好的
      // 主 gguf（模型仍可推理，仅无投机加速），但整任务标记为失败。
      final ds = model.dspark;
      if (ds != null) {
        // 进度累计：从主 + mmproj 已完成字节起。
        var dsBase = await ggufFinal.length();
        if (mm != null) {
          final mmprojDone = File(p.join(dir.path, model.id + '.mmproj'));
          if (await mmprojDone.exists()) dsBase += await mmprojDone.length();
        }
        task.stage = '加速头';
        task.state = DownloadState.downloading;
        onProgress(task);
        final dsparkTarget = _DownloadTarget(
          mirrors: ds.mirrors, sizeBytes: ds.sizeBytes, suffix: '.dspark.gguf',
        );
        final dsparkTemp = File(p.join(dir.path, model.id + dsparkTarget.suffix + '.tmp'));
        final dsparkFinal = File(p.join(dir.path, model.id + dsparkTarget.suffix));
        final dsparkComplete = !(await dsparkTemp.exists()) &&
            await _trustedOrClean(dsparkFinal, null, 'dspark 草稿头');
        if (dsparkComplete) {
          final done = await dsparkFinal.length();
          debugPrint('[DownloadService] ${model.id} dspark 已完整，跳过草稿头下载');
          task.downloadedBytes = dsBase + done;
          task.state = DownloadState.completed;
          task.endTime = DateTime.now();
          onProgress(task);
        } else {
          await _runDownloadLoop(
            model, task, dsparkTarget, dsparkTemp, dsparkFinal, onProgress, progressInterval,
            baseBytes: dsBase,
          );
        }
      }
      // ---- splitMoe 拆分专家包（超大 MoE 统一承载形态）----
      // 主 gguf（-les，专家已剥离）完成后顺序下载 manifest + N 个专家分片，
      // 落在 `{modelId}.experts/` 子目录（官方 MiniCPM-V Apps 布局对齐）。
      // 单分片失败只影响该分片（断点续传按分片粒度），不删主文件。
      // inplaceFullGguf 形态（方案 C）专家就在整包主文件里，无额外下载。
      final sm = model.splitMoe;
      if (sm != null && !sm.inplaceFullGguf) {
        final expertsDir = Directory(p.join(dir.path, '${model.id}.experts'));
        await expertsDir.create(recursive: true);

        // 进度基线：主 gguf（+ mmproj/dspark 若有）已完成字节。
        var smBase = await ggufFinal.length();

        // ---- manifest.json ----
        task.stage = '专家清单';
        task.state = DownloadState.downloading;
        onProgress(task);
        final manifestFinal = File(p.join(expertsDir.path, 'manifest.json'));
        final manifestTemp = File('${manifestFinal.path}.tmp');
        final manifestComplete = !(await manifestTemp.exists()) &&
            await _trustedOrClean(manifestFinal, null, '专家清单');
        if (manifestComplete) {
          debugPrint('[DownloadService] ${model.id} manifest 已完整，跳过');
          smBase += await manifestFinal.length();
        } else {
          await _runDownloadLoop(
            model,
            task,
            _DownloadTarget(
              mirrors: sm.manifestMirrors,
              sizeBytes: sm.manifestSizeBytes,
              suffix: '.experts/manifest.json',
            ),
            manifestTemp,
            manifestFinal,
            onProgress,
            progressInterval,
            baseBytes: smBase,
          );
          if (_isTerminalPause(task)) return;
          smBase += await manifestFinal.length();
        }

        // ---- 专家分片 ×N ----
        for (var i = 0; i < sm.layerBinCount; i++) {
          // 上一阶段把任务标记为 completed（_runDownloadLoop Step 5），
          // 每个分片开始前重置为 downloading，进度不重头（字节累计）。
          task.stage = '专家分片 ${i + 1}/${sm.layerBinCount}';
          task.state = DownloadState.downloading;
          onProgress(task);

          final rel = sm.layerBinRelativePath(i); // experts/layer_007.bin
          final name = p.basename(rel); // layer_007.bin
          final binFinal = File(p.join(expertsDir.path, name));
          final binTemp = File('${binFinal.path}.tmp');
          // 分片完整性：存在、非空、大小与 manifest 精确字节数一致
          //（layerBinSizeBytes 是精确值而非估算，可做强校验）。
          final binComplete = !(await binTemp.exists()) &&
              await _isExactSize(binFinal, sm.layerBinSizeBytes);
          if (binComplete) {
            smBase += await binFinal.length();
            task.downloadedBytes = smBase;
            onProgress(task);
            continue;
          }
          await _runDownloadLoop(
            model,
            task,
            _DownloadTarget(
              mirrors: _joinBaseMirrors(sm.expertsBaseMirrors, rel),
              sizeBytes: sm.layerBinSizeBytes,
              suffix: '.$name',
            ),
            binTemp,
            binFinal,
            onProgress,
            progressInterval,
            baseBytes: smBase,
          );
          // 用户暂停/取消 → 停止后续分片；resume 时跳过已完整分片继续。
          if (_isTerminalPause(task)) return;
          smBase += await binFinal.length();
        }

        task.stage = null;
        task.state = DownloadState.completed;
        task.endTime = DateTime.now();
        task.downloadedBytes = model.totalBytes;
        onProgress(task);
      }
    } finally {
      // CRITICAL: the entry must be dropped no matter how we leave, otherwise
      // the `maxConcurrentDownloads` guard stays permanently saturated after
      // the first finished download and every later start throws
      // "Only one download at a time." — which looked like a dead button.
      // Exception: a *paused* task keeps its slot so resume() can reuse it.
      if (task.state != DownloadState.paused) {
        _activeDownloads.remove(model.id);
      }
    }
  }

  Future<void> _runDownloadLoop(
    ModelConfig model,
    DownloadTask task,
    _DownloadTarget target,
    File tempFile,
    File finalFile,
    void Function(DownloadTask) onProgress,
    Duration progressInterval,
    {int baseBytes = 0}
  ) async {
    // ---- 自动重试循环：连接中断时保留已下载的 .tmp 并断点续传 ----
    for (int attempt = 1; attempt <= _maxAttempts; attempt++) {
      final cancelToken = CancelToken();
      _activeDownloads[model.id] = _ActiveDownload(task: task, cancelToken: cancelToken);

      try {
        // Step 1: 解析镜像（是否支持 HTTP Range）。
        // 若磁盘已有部分 .tmp 且长度 > 0，则必须选支持 Range 的镜像才能续传；
        // 没有这样的镜像时退回「整段重下」并丢弃旧 .tmp。
        final hasPartial = await tempFile.exists() && (await tempFile.length()) > 0;

        _UrlInfo? urlInfo;
        bool supportsRange = false;
        int downloadedSoFar = 0;

        if (hasPartial) {
          downloadedSoFar = await tempFile.length();
          task.downloadedBytes = baseBytes + downloadedSoFar;
          // 仅单文件模型（baseBytes==0）按目标大小校准 totalBytes；
          // 多文件模型保持 download() 预设的累计总字节，避免续传时进度
          // 「跳变」（此前会把累计 total 覆盖成单文件大小）。
          if (baseBytes == 0 && target.sizeBytes > 0) {
            task.totalBytes = target.sizeBytes;
          }
          onProgress(task);

          urlInfo = await _resolveUrl(target.mirrors, requireRange: true);
          if (urlInfo != null) {
            supportsRange = true;
            debugPrint('[DownloadService] Attempt $attempt: resuming '
                'from ${_formatBytes(downloadedSoFar)} via Range-capable mirror');
          } else {
            // 没有支持 Range 的镜像 → 无法续传，整段重下。
            debugPrint('[DownloadService] Attempt $attempt: no Range mirror, '
                'restarting fresh');
            await tempFile.delete();
            downloadedSoFar = 0;
            task.downloadedBytes = baseBytes;
            urlInfo = await _resolveUrl(target.mirrors, requireRange: false);
          }
        } else {
          urlInfo = await _resolveUrl(target.mirrors, requireRange: false);
        }

        if (urlInfo == null) {
          throw DownloadException('所有镜像当前不可达，请检查网络后重试。');
        }

        // Step 2: 已有残留且达到估算大小？哈希（配置了的话）相符才提升为最终文件。
        // 哈希不符 = 损坏/旧版本残留，删除整段重下——此前这里直接 rename，
        // 造成「尺寸达标但内容损坏」的文件被当已下载（catalog 尺寸常与实际不符）。
        if (hasPartial && target.sizeBytes > 0 &&
            (await tempFile.length()) >= target.sizeBytes) {
          bool hashOk = true;
          if (target.sha256Hash != null) {
            hashOk = await _hashMatches(tempFile, target.sha256Hash);
          }
          if (hashOk) {
            // 用实文件大小（可能大于估算的 sizeBytes），进度恒为 100%。
            final done = await tempFile.length();
            task.downloadedBytes = baseBytes + done;
            await tempFile.rename(finalFile.path);
            task.state = DownloadState.completed;
            task.endTime = DateTime.now();
            onProgress(task);
            return;
          }
          debugPrint('[DownloadService] Step 2: .tmp sha256 不符，丢弃后整段重下');
          try { await tempFile.delete(); } catch (_) {}
          downloadedSoFar = 0;
          supportsRange = false;
          task.downloadedBytes = baseBytes;
          onProgress(task);
        }

        // Step 3: 下载主体。支持 Range 且有残留则断点续传，否则整段下载。
        if (supportsRange && downloadedSoFar > 0) {
          await _downloadRange(
            urlInfo.url,
            tempFile,
            downloadedSoFar,
            target.sizeBytes,
            task,
            cancelToken,
            onProgress,
            progressInterval,
          );
        } else {
          if (task.totalBytes == 0) task.totalBytes = target.sizeBytes;
          final response = await _dio.get<ResponseBody>(
            urlInfo.url,
            options: Options(
              responseType: ResponseType.stream,
              receiveTimeout: const Duration(hours: 2),
            ),
            cancelToken: cancelToken,
          );

          final body = response.data;
          if (body == null) throw DownloadException('Empty response body.');

          // 服务器返回的实际 Content-Length（catalog 的 sizeBytes 只是估算，可能
          // 偏小导致进度超 100%，也可能偏大导致完整度误判，因此以服务器为准）。
          final headerTotalStr = response.headers.value('content-length');
          int? headerTotal;
          if (headerTotalStr != null) {
            headerTotal = int.tryParse(headerTotalStr);
            if (headerTotal != null && headerTotal > 0) {
              // 单文件模型（baseBytes==0）用服务器大小校准 totalBytes；多文件
              // 模型保持 download() 预设的总字节（进度连续不重头）。
              if (baseBytes == 0) task.totalBytes = headerTotal;
              debugPrint('[DownloadService] Using Content-Length from headers: $headerTotal bytes');
            }
          }

          final raf = tempFile.openSync(mode: FileMode.writeOnlyAppend);
          int received = downloadedSoFar;
          DateTime? lastProgress;
          try {
            await for (final chunk in body.stream) {
              if (cancelToken.isCancelled) break;
              await raf.writeFrom(chunk);
              received += chunk.length;
              task.downloadedBytes = baseBytes + received;
              final now = DateTime.now();
              if (lastProgress == null ||
                  now.difference(lastProgress) >= progressInterval) {
                lastProgress = now;
                onProgress(task);
              }
            }
          } finally {
            await raf.close();
          }

          // 完整度校验：若服务器给出 Content-Length 但实际字节数不足，说明连接
          // 中途被静默截断（无异常直接结束流）。此时绝不能把残缺文件提升为
          // 最终 .gguf/.mmproj —— 否则缓存发现会把它当成「已缓存」，或尺寸
          // 不达标被误判「未下载」。抛异常走重试/清理 .tmp 路径。
          if (headerTotal != null && headerTotal > 0 && received < headerTotal) {
            throw DownloadException(
              '下载不完整（${_formatBytes(received)}/${_formatBytes(headerTotal)}），自动续传重试',
            );
          }

          // 整段下载结束后，单文件模型用实际写入字节数校准 totalBytes。
          if (baseBytes == 0) task.totalBytes = baseBytes + received;
          onProgress(task);
        }

        // Step 4: 校验产物非空。
        final actualSize = await tempFile.length();
        if (actualSize == 0) {
          throw DownloadException('Download produced empty file');
        }

        // Step 4.5: 配置了 sha256 的条目强制校验（CDN 静默截断/串内容不能把
        // 损坏文件提升为最终文件——那正是推理乱码/空输出的来源）。
        if (target.sha256Hash != null &&
            !await _hashMatches(tempFile, target.sha256Hash)) {
          try { await tempFile.delete(); } catch (_) {}
          throw DownloadException('文件校验失败（sha256 不符，下载损坏），已丢弃，自动重新下载');
        }

        // Step 5: 提升 .tmp 为最终文件。
        await tempFile.rename(finalFile.path);
        // 完成态以实文件大小为准（累计到 baseBytes），进度恒为 100%。
        task.downloadedBytes = baseBytes + actualSize;
        task.totalBytes = actualSize > task.totalBytes ? actualSize : task.totalBytes;
        task.state = DownloadState.completed;
        task.endTime = DateTime.now();
        _lastProgressTime.remove(model.id);
        onProgress(task);
        return; // 成功
      } on DioException catch (e) {
        // 用户暂停/取消：保留 .tmp 以便后续续传，直接退出（不标记为失败）。
        if (CancelToken.isCancel(e) || cancelToken.isCancelled) {
          return;
        }
        if (attempt < _maxAttempts) {
          // 瞬时连接中断：保留 .tmp，短暂停顿后断点续传重试。
          task.errorMessage = '连接中断，正在自动重试 ($attempt/${_maxAttempts - 1})…';
          onProgress(task);
          await Future.delayed(const Duration(seconds: 3));
          // 若重试等待期间用户点了暂停，则中止重试。
          if (task.state == DownloadState.paused) return;
          continue;
        }
        await _fail(task, _cleanErrorMessage(e.toString()), model.id, deletePartial: true);
        onProgress(task);
      } on DownloadException catch (e) {
        // 校验类失败（哈希不符等）：tmp 已被清理，重试即整段重下。
        if (attempt < _maxAttempts) {
          task.errorMessage = '${e.message}（第 $attempt/${_maxAttempts - 1} 次重试）';
          onProgress(task);
          await Future.delayed(const Duration(seconds: 1));
          if (task.state == DownloadState.paused) return;
          continue;
        }
        await _fail(task, e.message, model.id, deletePartial: true);
        onProgress(task);
      } catch (e) {
        if (attempt < _maxAttempts) {
          task.errorMessage = '下载中断，正在自动重试 ($attempt/${_maxAttempts - 1})…';
          onProgress(task);
          await Future.delayed(const Duration(seconds: 3));
          if (task.state == DownloadState.paused) return;
          continue;
        }
        await _fail(task, _cleanErrorMessage(e.toString()), model.id, deletePartial: true);
        onProgress(task);
      }
    }
  }

  /// sha256 校验（isolate 内跑，几 GB 文件十几~几十秒）。相符返回 true。
  Future<bool> _hashMatches(File f, String? expected) async {
    if (expected == null) return true;
    try {
      final actual = await Isolate.run(() => _computeSha256OfFile(f.path));
      final ok = actual.toLowerCase() == expected.toLowerCase();
      debugPrint('[DownloadService] sha256 校验${ok ? "通过" : "不符"}: '
          '${p.basename(f.path)} actual=$actual');
      return ok;
    } catch (e) {
      debugPrint('[DownloadService] sha256 计算异常: $e');
      return false;
    }
  }

  /// 「磁盘上已完整」可信判定：存在且非空，配置了 sha256 还必须哈希相符；
  /// 哈希不符时删除损坏文件并返回 false（调用方随即重新下载）。
  Future<bool> _trustedOrClean(File f, String? sha, String label) async {
    if (!await f.exists() || (await f.length()) == 0) return false;
    if (sha == null) return true;
    debugPrint('[DownloadService] $label: 校验 sha256（可能需要十几秒）…');
    if (await _hashMatches(f, sha)) return true;
    debugPrint('[DownloadService] $label: sha256 不符，已删除损坏文件，将重新下载');
    try { await f.delete(); } catch (_) {}
    return false;
  }

  /// 分片/清单下载是否因用户暂停或取消而终止（true → 不继续后续分片）。
  bool _isTerminalPause(DownloadTask task) =>
      task.state == DownloadState.paused || task.state == DownloadState.idle;

  /// 精确大小完整性判定：存在且（配置了预期大小时）字节数完全一致。
  /// split-moe 分片大小来自 manifest 的 exact_byte_length（精确值），
  /// 可做强校验——这是分片损坏最廉价可靠的拦截点。
  Future<bool> _isExactSize(File f, int expectedBytes) async {
    try {
      if (!await f.exists()) return false;
      final len = await f.length();
      if (len == 0) return false;
      if (expectedBytes > 0 && len != expectedBytes) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 把专家分片相对路径拼到各镜像 base URL 上
  ///（splitMoe 的 expertsBaseMirrors 是目录级 base，非单文件 URL）。
  List<MirrorEntry> _joinBaseMirrors(List<MirrorEntry> bases, String rel) =>
      bases
          .map((m) => MirrorEntry(
                m.url.endsWith('/') ? '${m.url}$rel' : '${m.url}/$rel',
                m.source,
              ))
          .toList();

  /// 标记任务失败并（可选）清理残留 .tmp。
  Future<void> _fail(DownloadTask task, String message, String modelId, {bool deletePartial = true}) async {
    task.state = DownloadState.failed;
    task.errorMessage = message;
    task.endTime = DateTime.now();
    _lastProgressTime.remove(modelId);
    if (deletePartial) {
      try {
        final dir = await _getModelsDir();
        // 同时清理主模型 / mmproj / dspark 草稿头的残留 .tmp（已重命名的最终
        // 文件不删，以便 mmproj 失败时主 gguf 仍可文本推理）。
        for (final suffix in ['.gguf.tmp', '.mmproj.tmp', '.dspark.gguf.tmp']) {
          final tmp = File(p.join(dir.path, modelId + suffix));
          if (await tmp.exists()) await tmp.delete();
        }
      } catch (_) {}
    }
  }

  /// Download a byte range [start, ∞) and append to [file]. Correctly implements
  /// resume over mirrors that return 206 (e.g. hf-mirror.com / HuggingFace CDN).
  /// 若服务器忽略 Range（返回 200）则退回整段写入。
  Future<void> _downloadRange(
    String url,
    File file,
    int start,
    int total,
    DownloadTask task,
    CancelToken cancelToken,
    void Function(DownloadTask) onProgress,
    Duration progressInterval,
  ) async {
    final response = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        headers: {'Range': 'bytes=$start-'},
        receiveTimeout: const Duration(hours: 2),
      ),
      cancelToken: cancelToken,
    );
    final body = response.data;
    if (body == null) throw DownloadException('Empty response body on resume.');

    // 206 = 部分内容（按 Range 续传）；200 = 服务器忽略 Range，整段重下。
    final isPartial = response.statusCode == 206;
    // 服务器 Content-Length：206 时是「剩余字节」，整文件应为 start + 该值。
    final headerTotalStr = response.headers.value('content-length');
    final headerTotal = int.tryParse(headerTotalStr ?? '');
    final expectedTotal =
        (isPartial && headerTotal != null) ? (start + headerTotal) : headerTotal;
    final raf = file.openSync(mode: isPartial ? FileMode.append : FileMode.write);
    try {
      int received = isPartial ? start : 0;
      if (!isPartial) task.downloadedBytes = 0;
      await for (final chunk in body.stream) {
        if (cancelToken.isCancelled) break;
        await raf.writeFrom(chunk);
        received += chunk.length;
        task.downloadedBytes = received;
        if (task.totalBytes == 0) task.totalBytes = total;
        _emitProgress(task, progressInterval, onProgress);
      }
      // 完整度校验：服务器给出 Content-Length 但实际字节不足 → 流被静默截断。
      // 不提升为最终文件，抛异常走重试/清理路径，避免残缺文件被当「已缓存」。
      if (expectedTotal != null && expectedTotal > 0 && received < expectedTotal) {
        throw DownloadException(
          '续传不完整（${_formatBytes(received)}/${_formatBytes(expectedTotal)}），自动续传重试',
        );
      }
      // 续传结束后用实际累计字节数作为 totalBytes，与 downloadedBytes 一致。
      task.totalBytes = received;
    } finally {
      await raf.close();
    }
  }

  void _emitProgress(
    DownloadTask task,
    Duration interval,
    void Function(DownloadTask) onProgress,
  ) {
    final now = DateTime.now();
    final last = _lastProgressTime[task.modelId];
    if (last == null || now.difference(last) >= interval) {
      _lastProgressTime[task.modelId] = now;
      onProgress(task);
    }
  }

  Future<void> pause(String modelId) async {
    final active = _activeDownloads[modelId];
    if (active != null && active.task.state == DownloadState.downloading) {
      active.cancelToken?.cancel('Paused by user');
      active.task.state = DownloadState.paused;
      // Keep .tmp file for resume on next retry
    }
  }

  Future<void> resume(String modelId, {required void Function(DownloadTask) onProgress}) async {
    final model = ModelManager().getModel(modelId);
    if (model == null) throw DownloadException('Model not found: $modelId');

    // Reuse the unified [download] entry point. It detects the existing `.tmp`
    // partial on disk and resumes from there (the .tmp holds the true resume
    // data, so we don't need to carry progress in memory).
    final task = DownloadTask(
      modelId: model.id,
      state: DownloadState.downloading,
      totalBytes: model.totalBytes,
      startTime: DateTime.now(),
    );

    await download(model, existingTask: task, onProgress: onProgress);
  }

  /// 取消下载：中止传输 + 清掉该模型的全部产物（不可续传，显式取消即放弃）。
  Future<List<String>> cancel(String modelId) async {
    final active = _activeDownloads[modelId];
    if (active != null) {
      try { active.cancelToken?.cancel('Cancelled by user'); } catch (_) {}
      active.task.state = DownloadState.idle;
      _activeDownloads.remove(modelId);
    }

    // Delete ALL files on cancel — no resume possible after explicit cancel.
    // 走 [ModelStorageService.deleteModelArtifacts]：遍历全部候选目录 + 含
    // dspark 草稿头与拆分专家包目录（旧实现只删主目录、且漏删草稿头）。
    return ModelStorageService().deleteModelArtifacts(modelId);
  }

  /// 删除模型的全部产物（主 gguf / mmproj / dspark 草稿头 / 拆分专家包目录）。
  ///
  /// **多目录**清扫，判据与「是否已缓存」一致——旧实现只删 `getModelsRootDir()`
  /// 一个目录，别的候选目录（`app_flutter/models`、`Download`、`DCIM`）里的
  /// 文件删不掉，界面上就是「删除点了没反应，再进列表还在」（2026-10-30 反馈）。
  /// 返回真正删掉的路径，供 UI 如实反馈。
  Future<List<String>> deleteModel(String modelId) async {
    return ModelStorageService().deleteModelArtifacts(modelId);
  }

  /// Resolve a reachable mirror, returning whether it supports HTTP Range.
  ///
  /// When [requireRange] is true, a mirror that is reachable but does NOT
  /// support Range requests is skipped (we keep looking), because the caller
  /// needs to resume a partial download and must issue a `Range` request.
  ///
  /// 探测用一次极小的 `Range: bytes=0-0` 请求完成：既验证可达性，也顺带确认
  /// Range 支持，避免像旧实现那样用 GET + ResponseType.bytes 把整个多 GB
  /// 文件拉进内存只为读响应头（Bonsai 27B 等大模型会直接 OOM）。
  Future<_UrlInfo?> _resolveUrl(List<MirrorEntry> mirrors, {bool requireRange = false}) async {
    for (final mirror in mirrors) {
      final info = await _probeMirror(mirror);
      if (info == null) continue;
      if (requireRange && !info.supportsRange) {
        debugPrint('[DownloadService] Mirror ${mirror.source} reachable but no Range support, skipping');
        continue;
      }
      return info;
    }
    return null; // All mirrors unreachable
  }

  /// 用 `Range: bytes=0-0` 探测单个镜像：一次只取 1 字节。
  /// 返回 206 → 支持 Range；200 → 不支持（整段下载）；其余/异常 → 不可达。
  Future<_UrlInfo?> _probeMirror(MirrorEntry mirror) async {
    try {
      final response = await _dio.get<ResponseBody>(
        mirror.url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Range': 'bytes=0-0'},
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
      _UrlInfo? info;
      if (response.statusCode == 206) {
        info = _UrlInfo(url: mirror.url, supportsRange: true);
      } else if (response.statusCode == 200) {
        // 服务器忽略了 Range 头 → 仅支持整段下载，无断点续传。
        info = _UrlInfo(url: mirror.url, supportsRange: false);
      }
      // 排空极小的响应体，释放连接。
      try { await response.data?.stream.drain<void>(); } catch (_) {}
      if (info != null) {
        debugPrint('[DownloadService] Mirror ${mirror.source} OK '
            '(status ${response.statusCode}, Range: ${info.supportsRange})');
        return info;
      }
    } catch (e) {
      debugPrint('[DownloadService] Mirror ${mirror.source} probe error: $e');
    }
    return null;
  }

  Future<Directory> _getModelsDir() async {
    final storage = ModelStorageService();
    return await storage.getModelsRootDir();
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
    if (bytes >= 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  String _cleanErrorMessage(String error) {
    // 连接被 CDN 中途关闭 —— 现在已经内置自动断点续传重试，
    // 只有多次重试仍失败才会走到这里，不再误导用户是「CDN 不支持续传」。
    if (error.contains('Connection closed while receiving data')) {
      return '下载连接多次中断，已自动续传仍失败，请稍后重试';
    }
    if (error.contains('timeout')) {
      return '下载超时，请检查网络连接后重试';
    }
    if (error.length > 200) {
      // Truncate very long error messages
      final parts = error.split(':');
      if (parts.length >= 3) {
        return '${parts[0]}: ${parts[1]}: ... (${parts.last})';
      }
    }
    return error;
  }
}

class _UrlInfo {
  final String url;
  final bool supportsRange;

  const _UrlInfo({required this.url, required this.supportsRange});
}

/// 一次下载目标：主模型 `.gguf` 或 mmproj 投影器 `.mmproj`。
class _DownloadTarget {
  final List<MirrorEntry> mirrors;
  final int sizeBytes;
  final String suffix;

  /// catalog 给出的 sha256（可空）。非空时下载完成后强制校验，损坏文件不落最终名。
  final String? sha256Hash;

  const _DownloadTarget({
    required this.mirrors,
    required this.sizeBytes,
    required this.suffix,
    this.sha256Hash,
  });
}

class _ActiveDownload {
  final DownloadTask task;
  final CancelToken? cancelToken;

  _ActiveDownload({required this.task, this.cancelToken});
}

class DownloadException implements Exception {
  final String message;
  DownloadException(this.message);
  @override
  String toString() => 'DownloadError: $message';
}
