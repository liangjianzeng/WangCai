// 绑定表（设计 §7.2）：路由的真源 —— 每 (引擎实例 × 模型) 一条，记实测
// decode/prefill t/s、最大稳定 ctx、质量门与状态。由每次成功推理回写
// （recordRun），由路由三档（routing_policy.dart）读取决策。
// sqlite 文件独立于 App 会话库（dataDir/bindings.db），工厂可注入便于
// 测试（databaseFactoryFfi + inMemoryDatabasePath）。
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'engine_paths.dart';

class BindingStatus {
  static const unknown = 'unknown';
  static const usable = 'usable';
  static const recommended = 'recommended';
  static const broken = 'broken';
}

class Binding {
  Binding({
    required this.engineId,
    required this.modelId,
    this.device,
    this.presetJson,
    this.lastDecodeTps,
    this.lastPrefillTps,
    this.maxStableCtx,
    this.qualityPass = false,
    this.lastUsedAt,
    this.status = BindingStatus.unknown,
  });

  final String engineId;
  final String modelId;
  String? device;
  String? presetJson;
  double? lastDecodeTps;
  double? lastPrefillTps;
  int? maxStableCtx;
  bool qualityPass;
  int? lastUsedAt; // millisSinceEpoch
  String status;

  factory Binding.fromRow(Map<String, Object?> r) => Binding(
        engineId: r['engineId'] as String,
        modelId: r['modelId'] as String,
        device: r['device'] as String?,
        presetJson: r['presetJson'] as String?,
        lastDecodeTps: (r['lastDecodeTps'] as num?)?.toDouble(),
        lastPrefillTps: (r['lastPrefillTps'] as num?)?.toDouble(),
        maxStableCtx: (r['maxStableCtx'] as num?)?.toInt(),
        qualityPass: (r['qualityPass'] as int? ?? 0) != 0,
        lastUsedAt: (r['lastUsedAt'] as num?)?.toInt(),
        status: r['status'] as String? ?? BindingStatus.unknown,
      );

  Map<String, Object?> toRow() => {
        'engineId': engineId,
        'modelId': modelId,
        'device': device,
        'presetJson': presetJson,
        'lastDecodeTps': lastDecodeTps,
        'lastPrefillTps': lastPrefillTps,
        'maxStableCtx': maxStableCtx,
        'qualityPass': qualityPass ? 1 : 0,
        'lastUsedAt': lastUsedAt,
        'status': status,
      };
}

class BindingsStore {
  BindingsStore(this._db);

  final Database _db;

  static Future<BindingsStore> open(EnginePaths paths,
      {DatabaseFactory? factory}) async {
    await paths.ensureDirs();
    final f = factory ?? databaseFactory;
    final db = await f.openDatabase(
      '${paths.dataDir.path}${Platform.pathSeparator}bindings.db',
      options: OpenDatabaseOptions(version: 1, onCreate: _onCreate),
    );
    return BindingsStore(db);
  }

  /// 内存库（测试用）。
  static Future<BindingsStore> inMemory({DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactoryFfiForTest;
    final db = await f.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(version: 1, onCreate: _onCreate));
    return BindingsStore(db);
  }

  static Future<void> _onCreate(Database db, int v) => db.execute('''
      CREATE TABLE bindings(
        engineId TEXT NOT NULL,
        modelId TEXT NOT NULL,
        device TEXT,
        presetJson TEXT,
        lastDecodeTps REAL,
        lastPrefillTps REAL,
        maxStableCtx INTEGER,
        qualityPass INTEGER NOT NULL DEFAULT 0,
        lastUsedAt INTEGER,
        status TEXT NOT NULL DEFAULT 'unknown',
        PRIMARY KEY (engineId, modelId)
      )
    ''');

  /// 测试注入点：默认走全局 factory（desktop main 已置 ffi）。
  static DatabaseFactory databaseFactoryFfiForTest = databaseFactory;

  Future<Binding?> get(String engineId, String modelId) async {
    final rows = await _db.query('bindings',
        where: 'engineId = ? AND modelId = ?', whereArgs: [engineId, modelId]);
    return rows.isEmpty ? null : Binding.fromRow(rows.first);
  }

  Future<List<Binding>> forModel(String modelId) async {
    final rows =
        await _db.query('bindings', where: 'modelId = ?', whereArgs: [modelId]);
    return rows.map(Binding.fromRow).toList();
  }

  Future<List<Binding>> all() async =>
      (await _db.query('bindings')).map(Binding.fromRow).toList();

  Future<void> put(Binding b) => _db.insert('bindings', b.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace);

  /// 一次成功推理的回写：t/s 覆盖、maxStableCtx 取单调最大值、
  /// unknown→usable（成功跑通即升；broken/recommended 不自动降级）。
  Future<void> recordRun({
    required String engineId,
    required String modelId,
    String? device,
    String? presetJson,
    double? decodeTps,
    double? prefillTps,
    int? ctx,
    int? now,
  }) async {
    final b = await get(engineId, modelId) ??
        Binding(engineId: engineId, modelId: modelId);
    b.device = device ?? b.device;
    b.presetJson = presetJson ?? b.presetJson;
    b.lastDecodeTps = decodeTps ?? b.lastDecodeTps;
    b.lastPrefillTps = prefillTps ?? b.lastPrefillTps;
    if (ctx != null && (b.maxStableCtx == null || ctx > b.maxStableCtx!)) {
      b.maxStableCtx = ctx;
    }
    b.lastUsedAt = now ?? DateTime.now().millisecondsSinceEpoch;
    if (b.status == BindingStatus.unknown) b.status = BindingStatus.usable;
    await put(b);
  }

  /// 失败回退（世代自适应，2026-11-05）：驱动在 [failedCtx] 报
  /// OUT_OF_HOST_MEMORY（NPU 驱动 per-process 预算，非系统内存，HANDOFF
  /// 2026-11-02 深夜定案）→ 收回被证伪的实测上抬：`maxStableCtx ≥
  /// failedCtx` 说明上抬值不再可信，直接弃回 null（clamp 回落到 preset
  /// 出厂先验）；实测值低于失败值时不动（失败不证伪更低的已验证档位）。
  Future<void> demoteCtx({
    required String engineId,
    required String modelId,
    required int failedCtx,
  }) async {
    final b = await get(engineId, modelId);
    if (b == null || b.maxStableCtx == null || b.maxStableCtx! < failedCtx) {
      return;
    }
    b.maxStableCtx = null;
    await put(b);
  }

  Future<void> setStatus(String engineId, String modelId, String status,
      {bool? qualityPass}) async {
    final b = await get(engineId, modelId);
    if (b == null) return;
    b.status = status;
    if (qualityPass != null) b.qualityPass = qualityPass;
    await put(b);
  }

  Future<void> remove(String engineId, {String? modelId}) => _db.delete(
        'bindings',
        where: modelId == null ? 'engineId = ?' : 'engineId = ? AND modelId = ?',
        whereArgs: modelId == null ? [engineId] : [engineId, modelId],
      );

  Future<void> close() => _db.close();
}
