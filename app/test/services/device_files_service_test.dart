// 文件产物桥的**交付判据**：只有拿得到位置才算交付。
//
// 以前 `exportFile` 把 Kotlin 侧的 null 折算成 `''`（"成功，只是位置是空串"），
// 于是插件流程报"导出完成"、智能体回一句"已导出："后面什么都没有 —— 典型的
// "跑成功了但什么都没发生"。这一组用例钉死：**空串必须抛**，别让它冒充成功。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/services/device_files_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.dgxspark.tongyilite/files');
  Object? result; // 模拟 Kotlin 侧的返回：String / null / 抛 PlatformException

  void mock() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method != 'exportFile') return null;
      final r = result;
      if (r is PlatformException) throw r;
      return r as String?;
    });
  }

  setUp(() => result = null);
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Kotlin 给了 content URI → 原样返回（并把 name 传下去）', () async {
    Object? seenName;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      seenName = (call.arguments as Map?)?['name'];
      return 'content://download/练习单.txt';
    });

    final uri = await DeviceFilesService.instance.exportFile(src: '/data/x/练习单.txt', name: '练习单.txt');
    expect(uri, 'content://download/练习单.txt');
    expect(seenName, '练习单.txt', reason: '改名必须传到原生侧，否则下载目录里全是同名文件');
  });

  test('Kotlin 返回 null（MediaStore insert 失败）→ 抛，不返回空串冒充成功', () async {
    result = null;
    mock();
    Object? err;
    try {
      await DeviceFilesService.instance.exportFile(src: '/data/x/a.txt', name: 'a.txt');
    } catch (e) {
      err = e;
    }
    expect(err, isA<PlatformException>(), reason: '$err');
    final pe = err! as PlatformException;
    expect(pe.code, 'export_no_uri');
    expect(pe.message, contains('a.txt'), reason: '报错要说得出是哪个文件，否则用户与开发者都无从下手');
  });

  test('Kotlin 返回空白串同样算失败（有的 ROM 给 " "）', () async {
    result = '   ';
    mock();
    expect(
      () => DeviceFilesService.instance.exportFile(src: '/data/x/a.txt'),
      throwsA(isA<PlatformException>()),
    );
  });

  test('原生侧抛 PlatformException 原样上抛（调用方负责转成人话）', () async {
    result = PlatformException(code: 'storage_not_available', message: '存储不可用');
    mock();
    expect(
      () => DeviceFilesService.instance.exportFile(src: '/data/x/a.txt'),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'storage_not_available')),
    );
  });
}
