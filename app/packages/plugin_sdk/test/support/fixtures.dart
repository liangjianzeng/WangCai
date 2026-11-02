/// 一致性套件的被试插件：一个合规的、几个故意违规的。
///
/// 它们同时是**作者参考实现的活文档** —— 面板"体检"页展示的就是这些形状。
library;

import 'package:plugin_sdk/plugin_sdk.dart';

/// 合规插件：apply 只注册；run 全程走 Outcome；资源全走 `ctx.effect`。
class GoodPlugin implements AppPlugin {
  GoodPlugin({this.slotId = 'hello.action'});

  final String slotId;
  final List<String> disposed = [];

  @override
  PluginManifest get manifest => const PluginManifest(
        id: 'hello-plugin',
        name: '你好插件',
        description: '一致性套件的被试：验证平台契约本身',
        inject: ['app.store'],
        permissions: [PluginPermission.pluginStorage, PluginPermission.llmChat],
        enabledByDefault: true,
        source: PluginSource.builtin,
        trust: PluginTrust.trusted,
        params: [
          PluginParam(name: 'greetTimes', label: '打招呼次数', type: PluginParamType.number, defaultValue: 2, min: 1, max: 5),
        ],
      );

  @override
  Outcome<Disposable?> apply(PluginCtx ctx) {
    // 作者规约：apply 先自查 inject（内核也会按 inject 门控，双保险）。
    for (final id in manifest.inject) {
      if (!ctx.capabilities.isAvailable(id)) {
        return Err<Disposable?>(PluginFailure(
          code: PluginFailureKind.missingCapability,
          message: ctx.capabilities.unavailableReason(id) ?? '这台机器还缺 $id',
          hint: '看「设置」页对应开关，或在插件面板查看本机能力清单',
          pluginId: manifest.id,
        ));
      }
    }
    // 只做注册：填一个输入区图标槽（载荷用哨兵值，避免依赖 Flutter）。
    final reg = ctx.slots.register(SlotContribution<Object?>(
      slotId: 'input.right',
      pluginId: manifest.id,
      id: 'hello',
      label: '你好',
      payload: 'hello-icon',
      order: 10,
    ));
    if (reg.isErr) return Err<Disposable?>(reg.failureOrNull!);
    // 作者规约：**注册必须挂到 ctx.effect 上**，否则禁用插件后账本不清（回收组会红）。
    ctx.effect(reg.valueOrNull!);
    ctx.effect(() => disposed.add('slot'));
    return const Ok<Disposable?>(null);
  }

  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async {
    if (ctx.cancelToken.isCancelled) {
      return Err<PluginRunResult>.of(PluginFailureKind.cancelled, '已取消');
    }
    final store = ctx.capabilities.require<Store>(ServiceKeys.store);
    // 穷举 switch：编译器逼你处理失败分支（漏分支 = 编译期报错，这就是 sealed 的价值）。
    switch (store) {
      case Ok<Store>(:final value):
        final n = ctx.numberConfig('greetTimes', 2).toInt();
        final w = await value.write('greet', 'x' * n);
        return w.map((_) => PluginRunResult(summary: '打了 $n 次招呼', data: {'times': n}));
      case Err<Store>(:final failure):
        return Err<PluginRunResult>(failure);
    }
  }
}

/// 违规：`run` 里直接 throw（应被「状态与错误」组抓出）。
class ThrowingPlugin extends GoodPlugin {
  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async {
    throw StateError('我没走 Outcome');
  }
}

/// 违规：`apply` 里偷摸调能力做 IO（应被「生命周期」组抓出）。
class IoInApplyPlugin extends GoodPlugin {
  @override
  Outcome<Disposable?> apply(PluginCtx ctx) {
    final r = super.apply(ctx);
    // 预热属于 IO：必须挪到 run 或 warmUp，不能发生在 apply。
    ctx.capabilities.require<Store>(ServiceKeys.store);
    return r;
  }
}

/// 违规：往别人命名空间填/声明槽。
class WrongNamespacePlugin extends GoodPlugin {
  @override
  Outcome<Disposable?> apply(PluginCtx ctx) {
    // 违规：填到别人的命名空间里（应被「槽」组抓出）。
    ctx.slots.register(const SlotContribution<Object?>(
      slotId: 'someone-else.tray',
      pluginId: 'hello-plugin',
      id: 'squatter',
      label: '占别人的位置',
      payload: 'x',
    ));
    return const Ok<Disposable?>(null);
  }
}

/// 违规：manifest 不自洽（缺 inject、参数默认值越界、未知权限）。
class BadManifestPlugin implements AppPlugin {
  @override
  PluginManifest get manifest => PluginManifest(
        id: 'Bad Id Here',
        name: '',
        description: '',
        permissions: const [PluginPermission.camera], // 声明了 camera 却没有 capture 步骤
        params: const [
          PluginParam(name: 'gap', label: '间隔', type: PluginParamType.number, defaultValue: 99, min: 1, max: 10),
        ],
      );

  @override
  Outcome<Disposable?> apply(PluginCtx ctx) => const Ok<Disposable?>(null);

  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async =>
      const Ok<PluginRunResult>(PluginRunResult(summary: 'ok'));
}
