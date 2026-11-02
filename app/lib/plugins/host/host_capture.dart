/// 宿主接缝：把"拍照 / 相册选图"适配成平台的 `app.capture` 能力。
///
/// 为什么不用 `home_screen._pickImage`：那是 screens 层的私有方法，插件伸手拿它 =
/// 输入区逻辑被复制两份（架构门 B/C 拦的就是这个）。这里直接用 `image_picker`，
/// 参数与首页保持一致（`imageQuality: 90`、原图构图、相机先过权限）。
library;

import 'package:image_picker/image_picker.dart';
import 'package:plugin_kernel/plugin_kernel.dart';

import '../../services/storage_permission_service.dart';

/// 取图端口（测试注入用；真机走 [ImagePickerPort]）。
abstract interface class ImagePickPort {
  /// 拍一张。
  Future<String?> takePhoto();

  /// 相册多选，返回路径（用户取消 = 空表）。
  Future<List<String>> pickFromGallery({required int maxCount});

  /// 相机权限（true = 可以拍）。
  Future<bool> ensureCameraPermission();
}

final class ImagePickerPort implements ImagePickPort {
  ImagePickerPort([ImagePicker? picker]) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  /// 与首页一致：**只压体积不改构图**。不要加 maxWidth —— 长截图会被挤成糊图，
  /// 模型反馈过"分辨率太低无法识别"（听写拍课本尤其吃这条）。
  static const int _quality = 90;

  @override
  Future<String?> takePhoto() async {
    final f = await _picker.pickImage(source: ImageSource.camera, imageQuality: _quality);
    return f?.path;
  }

  @override
  Future<List<String>> pickFromGallery({required int maxCount}) async {
    final files = await _picker.pickMultiImage(imageQuality: _quality);
    return files.map((e) => e.path).take(maxCount).toList();
  }

  @override
  Future<bool> ensureCameraPermission() => StoragePermissionService.requestCameraPermission();
}

/// `app.capture` 的宿主实现。
final class HostCapture with CapabilityBase implements Capture {
  HostCapture(this._port);

  final ImagePickPort _port;

  @override
  final ServiceKey<Capture> key = ServiceKeys.capture;

  @override
  bool get available => true;

  @override
  String? get unavailableReason => null;

  @override
  Future<Outcome<List<String>>> pickImages({
    required int maxCount,
    required bool preferCamera,
  }) async {
    final limit = maxCount.clamp(1, 10); // 与首页一致：模型侧最多收 10 张
    try {
      if (preferCamera) {
        if (!await _port.ensureCameraPermission()) {
          return Err<List<String>>(PluginFailure(
            code: PluginFailureKind.permissionDenied,
            message: '相机权限被拒绝',
            hint: '在系统设置里允许本应用使用相机，或改用相册选图',
          ));
        }
        final one = await _port.takePhoto();
        if (one == null) return const Ok<List<String>>([]); // 用户中途放弃 = 空，不是错误
        return Ok<List<String>>([one]);
      }
      final many = await _port.pickFromGallery(maxCount: limit);
      return Ok<List<String>>(many);
    } catch (e) {
      return Err<List<String>>(PluginFailure(
        code: PluginFailureKind.runtimeError,
        message: '没能取到图片',
        hint: '再试一次，或先在相册里准备好照片',
        cause: '$e',
      ));
    }
  }
}
