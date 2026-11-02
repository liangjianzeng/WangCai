/// 内置示例插件「记事小卡」（P2 冒烟件）。
///
/// 它存在的意义不是功能，而是**证明整条链在真 app 里是通的**：
/// 输入框右侧出现图标（填宿主槽）→ 点它 → 平台弹框问一个数（`app.interact`）→
/// 存进该插件自己的 KV（`app.store`，前缀由平台加）→ 活动条上说出上次存了什么（`app.input.activity`）。
///
/// 同时它也是**架构纪律的活样本**：只 import `plugin_kernel` 与本目录，
/// 不碰 screens/providers/agent/tts/services（`architecture_test.dart` 会当场拦住）。
library;

import 'package:flutter/material.dart';
import 'package:plugin_kernel/plugin_kernel.dart';

import '../../plugin_input_icon.dart';
import '../../slot_outlet.dart';

final class HelloBuiltinPlugin implements AppPlugin {
  static const PluginManifest manifestDef = PluginManifest(
    id: 'hello-note',
    name: '记事小卡',
    description: '平台冒烟件：问一个数、存起来、下次报给你',
    icon: 'icons.sticky_note_2_outlined',
    inject: ['app.store', 'app.interact'],
    permissions: [PluginPermission.pluginStorage],
    trust: PluginTrust.trusted,
    enabledByDefault: true, // 平台冒烟件：装机就能看到图标，证明整条链通了
    params: [
      PluginParam(
        name: 'note',
        label: '便签内容',
        type: PluginParamType.text,
        defaultValue: '',
        description: '留空则运行时问你',
      ),
    ],
  );

  @override
  PluginManifest get manifest => manifestDef;

  @override
  Outcome<Disposable?> apply(PluginCtx ctx) {
    // 能力不齐就当场失败：面板显示「缺：app.store」，而不是等 run 的时候莫名其妙。
    final ready = ensureDeclaredCapabilities(ctx);
    if (ready.isErr) return Err<Disposable?>(ready.failureOrNull!);

    // apply 里**只注册**：不调能力、不做 IO（conformance 的「生命周期」组数得出来）。
    final chip = ctx.slots.register(SlotContribution<Object?>(
      slotId: 'app.input.right',
      pluginId: ctx.manifest.id,
      id: 'note-chip',
      label: '记事小卡',
      priority: 40,
      payload: _NoteChip(pluginId: ctx.manifest.id),
    ));
    if (chip.isErr) return Err<Disposable?>(chip.failureOrNull!);

    final activity = ctx.slots.register(SlotContribution<Object?>(
      slotId: 'app.input.activity',
      pluginId: ctx.manifest.id,
      id: 'note-activity',
      label: '记事状态',
      payload: const _NoteActivity(),
    ));
    if (activity.isErr) return Err<Disposable?>(activity.failureOrNull!);

    // 贡献物必须挂进 effect，否则关掉插件后槽里会留幽灵 —— 作者纪律第 3 条。
    ctx.effect(chip.valueOrNull!);
    ctx.effect(activity.valueOrNull!);
    return const Ok<Disposable?>(null);
  }

  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async {
    final store = ctx.capabilities.require<Store>(ServiceKeys.store);
    if (store.isErr) return Err<PluginRunResult>(store.failureOrNull!);
    final interact = ctx.capabilities.require<Interact>(ServiceKeys.interact);
    if (interact.isErr) return Err<PluginRunResult>(interact.failureOrNull!);

    ctx.cancelToken.throwIfCancelled();

    final saved = await store.valueOrNull!.read('last');
    if (saved.isErr) return Err<PluginRunResult>(saved.failureOrNull!);

    var note = ctx.stringConfig('note', '');
    if (note.isEmpty) {
      final asked = await interact.valueOrNull!.askNumber(
        question: '记一个什么数？（上次：${saved.valueOrNull ?? '还没记过'}）',
        defaultValue: 5,
        min: 0,
        max: 9999,
      );
      if (asked.isErr) return Err<PluginRunResult>(asked.failureOrNull!);
      final v = asked.valueOrNull;
      if (v == null) return const Ok<PluginRunResult>(PluginRunResult(summary: '没记，已取消', userVisible: false));
      note = '$v';
    }

    ctx.cancelToken.throwIfCancelled();
    final wrote = await store.valueOrNull!.write('last', note);
    if (wrote.isErr) return Err<PluginRunResult>(wrote.failureOrNull!);
    ctx.log.info('记事小卡记下：$note（入口 ${input.entry.name}）');

    return Ok<PluginRunResult>(PluginRunResult(summary: '已记下：$note', data: {'note': note}));
  }
}

/// 图标：点它 = 通过平台入口跑自己（拿 dispatcher，而不是伸手拿宿主）。
class _NoteChip extends StatelessWidget {
  const _NoteChip({required this.pluginId});
  final String pluginId;

  @override
  Widget build(BuildContext context) {
    // 外壳统一走 `PluginInputIcon`（以前这里手抄了一遍宿主输入区的数值，
    // 听写那边漏抄 → 两个插件的图标一个样一个不像，2026-10-24 用户实测指出）。
    return PluginInputIcon(
      tooltip: '记事小卡（插件平台冒烟件）',
      icon: Icons.sticky_note_2_outlined,
      onPressed: () async {
        final dispatcher = PluginDispatcherScope.of(context);
        if (dispatcher == null) return;
        final r = await dispatcher.run(pluginId, const PluginInput(entry: PluginEntryKind.composerAction));
        if (!context.mounted) return;
        final text = r.fold(
          (v) => v.summary,
          // 连同 hint（下一步）一起显示：见 `describePluginFailure` 的由来。
          describePluginFailure,
        );
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
      },
    );
  }
}

/// 活动条：现场读自己的存储，不缓存第二份真相。
class _NoteActivity extends StatelessWidget {
  const _NoteActivity();

  @override
  Widget build(BuildContext context) {
    final dispatcher = PluginDispatcherScope.of(context);
    return FutureBuilder<String?>(
      future: dispatcher?.readPluginValue('hello-note', 'last'),
      builder: (context, snap) {
        final v = snap.data;
        if (v == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sticky_note_2_outlined, size: 12),
              const SizedBox(width: 4),
              Text('小卡：$v', style: const TextStyle(fontSize: 11)),
            ],
          ),
        );
      },
    );
  }
}
