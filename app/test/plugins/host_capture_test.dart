// app.capture 宿主适配器的语义钉死（听写的"拍照"入口）。
// 用 `flutter test test/plugins` 跑。
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_sdk/plugin_sdk.dart';
import 'package:tongyi_lite/plugins/host/host_capture.dart';

class _FakePort implements ImagePickPort {
  _FakePort({this.photos = const ['/sdcard/DCIM/1.jpg'], this.gallery = const [], this.granted = true, this.throws});

  final List<String> photos;
  final List<String> gallery;
  final bool granted;
  final Object? throws;

  int cameraAsks = 0;
  int? lastGalleryMax;

  @override
  Future<String?> takePhoto() async {
    if (throws != null) throw throws!;
    return photos.isEmpty ? null : photos.first;
  }

  @override
  Future<List<String>> pickFromGallery({required int maxCount}) async {
    lastGalleryMax = maxCount;
    if (throws != null) throw throws!;
    return gallery.take(maxCount).toList();
  }

  @override
  Future<bool> ensureCameraPermission() async {
    cameraAsks++;
    return granted;
  }
}

void main() {
  test('拍照：先要权限，拿到一张就收', () async {
    final port = _FakePort();
    final r = await HostCapture(port).pickImages(maxCount: 4, preferCamera: true);
    expect(r.isOk, isTrue);
    expect(r.valueOrNull, ['/sdcard/DCIM/1.jpg']);
    expect(port.cameraAsks, 1, reason: '拍照前必须先过权限，不能直接拉相机');
  });

  test('权限被拒：permissionDenied + 可行动的出路（不是"取图失败"）', () async {
    final r = await HostCapture(_FakePort(granted: false)).pickImages(maxCount: 4, preferCamera: true);
    expect(r.isErr, isTrue);
    expect(r.failureOrNull!.code, PluginFailureKind.permissionDenied);
    expect(r.failureOrNull!.hint, contains('允许本应用使用相机'),
      reason: '两字「设置」可以指 app 里任何一个设置页；要说破是系统设置里的相机权限');
  });

  test('用户中途放弃 = 空表，不是失败（否则插件会把取消报成错误）', () async {
    final r = await HostCapture(_FakePort(photos: const [])).pickImages(maxCount: 4, preferCamera: true);
    expect(r.isOk, isTrue);
    expect(r.valueOrNull, isEmpty);
  });

  test('相册多选按 maxCount 截断，且不超过 10 张（模型侧上限）', () async {
    final port = _FakePort(gallery: [for (var i = 0; i < 30; i++) '/p/$i.jpg']);
    final r = await HostCapture(port).pickImages(maxCount: 99, preferCamera: false);
    expect(r.valueOrNull, hasLength(10));
    expect(port.lastGalleryMax, 10);
  });

  test('取图炸了：runtimeError + 技术细节进 cause，用户只看人话', () async {
    final r = await HostCapture(_FakePort(throws: Exception('picker died')))
        .pickImages(maxCount: 2, preferCamera: false);
    expect(r.isErr, isTrue);
    expect(r.failureOrNull!.code, PluginFailureKind.runtimeError);
    expect(r.failureOrNull!.message, isNot(contains('picker died')));
    expect(r.failureOrNull!.cause, contains('picker died'));
  });
}
