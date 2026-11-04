// 宿主 seam 的**行为级**证明：平台 provider 被丢弃时，fiber 必须真的被卸干净。
//
// 为什么单独一个文件、为什么值得跑整条装配：内核那条「shutdown 必须真的被调用」
// （`loader_service_test`）是**自己直接调 `service.shutdown()`** 的，它证明的是"shutdown 好用"，
// 不是"宿主真会调它"。第 77 轮把 `plugin_host.dart` 里那句
// `ref.onDispose(() => unawaited(service.shutdown()))` 删掉，全量 app 测试一声不响 ——
// 泄漏类缺陷全程没有症状（重扫一次多漏一份 Timer/订阅），所以这条测试必须存在。
//
// 它跑的是真装配：`pluginHostProvider` 内部 try/catch 会把异常吞成 null，
// 因此 service 拿到 null 一律判失败（**不许"拿不到就跳过"** —— 那等于把门禁做成摆设）。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_sdk/plugin_sdk.dart';
import 'package:wangcai/plugins/plugin_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    // path_provider 在测试里用假目录顶掉（与 plugin_files_test 同一套写法）。
    tmp = Directory.systemTemp.createTempSync('plugin_host_dispose');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => tmp.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
    // Windows 分叉：宿主 dispose 后仍可能迟写缓存文件，与递归删除竞争（errno 145 目录非空），
    // 重试到删净为止；1s 内删不掉则放过（残留Temp不判失败）。
    for (var i = 0; i < 20 && tmp.existsSync(); i++) {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  test('丢弃 pluginHostProvider 必须把 fiber 全卸（宿主 seam 行为级）', () async {
    // 测试中途失败也不能漏掉 dispose（Riverpod 2.6.1 没有 `debugDisposed` 可问，只能自己记账）。
    var disposed = false;
    final container = ProviderContainer();
    addTearDown(() {
      if (!disposed) container.dispose();
    });

    final service = await container.read(pluginHostProvider.future);
    expect(
      service,
      isNotNull,
      reason: '真装配没起来（看上面的 [plugin-host] 装配异常）—— 这条测试的价值就在于跑真装配，'
          '拿不到 service 就判失败，不许悄悄跳过。',
    );

    const id = 'en-dictation';
    final on = await service!.setEnabled(id, true);
    expect(on.isOk, isTrue, reason: '启用不成功，后面的断言就成了空的');
    await service.reload();
    // 真跑一次：能力缺不缺不要紧（听写缺相机/视觉时会返回 Err），要紧的是 fiber 真的建起来了。
    await service.run(id, const PluginInput(entry: PluginEntryKind.composerAction));
    expect(
      service.diagnostics(id)['state'],
      isNotNull,
      reason: 'fiber 没建起来 = 这条测试什么都没测（假断言）',
    );
    final beforeDispose = service.diagnostics(id)['state'];

    container.dispose();
    disposed = true;

    // `ref.onDispose` 里是 `unawaited(service.shutdown())`：卸载是异步的，按条件轮询等它落定。
    var state = service.diagnostics(id)['state'];
    for (var i = 0; i < 200 && state != null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      state = service.diagnostics(id)['state'];
    }
    expect(
      state,
      isNull,
      reason: 'provider 都丢弃了，fiber 还在（丢弃前是 $beforeDispose）—— '
          '说明 ref.onDispose 里那句 shutdown 没跑或被删了：插件的 Timer / 订阅 / provide 出去的能力'
          '就一直挂着，重扫一次多一份，全程没有任何症状。',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
