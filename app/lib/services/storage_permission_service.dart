// ============================================================
// Storage Permission Service — 外部存储权限管理
// 
// 处理 Android 11+ 的 MANAGE_EXTERNAL_STORAGE 权限请求
// ============================================================

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class StoragePermissionService {
  /// 检查是否有外部存储访问权限
  static Future<bool> hasStoragePermission() async {
    if (Platform.isAndroid) {
      // Android 13+ 使用新的媒体权限
      final mediaPermission = await Permission.mediaLibrary.status;
      if (mediaPermission.isGranted) return true;
      
      // Android 12及以下使用传统存储权限
      final storagePermission = await Permission.storage.status;
      if (storagePermission.isGranted) return true;
    }
    return false;
  }

  /// 检查相机权限状态
  static Future<PermissionStatus> getCameraPermissionStatus() async {
    return await Permission.camera.status;
  }

  /// 请求相机权限
  static Future<bool> requestCameraPermission() async {
    final status = await Permission.camera.request();
    debugPrint('[StoragePermission] Camera permission: $status');
    return status.isGranted;
  }

  /// 请求麦克风权限（语音输入）
  static Future<bool> requestMicrophonePermission() async {
    final status = await Permission.microphone.request();
    debugPrint('[StoragePermission] Microphone permission: $status');
    return status.isGranted;
  }

  /// 请求外部存储访问权限
  static Future<bool> requestStoragePermission() async {
    if (!Platform.isAndroid) return true;

    // Android 11+ 尝试请求 MANAGE_EXTERNAL_STORAGE
    if (await Permission.manageExternalStorage.isDenied) {
      debugPrint('[StoragePermission] Requesting MANAGE_EXTERNAL_STORAGE');
      final status = await Permission.manageExternalStorage.request();
      
      if (status.isGranted) {
        debugPrint('[StoragePermission] MANAGE_EXTERNAL_STORAGE granted');
        return true;
      } else if (status.isPermanentlyDenied) {
        // 需要引导用户到系统设置
        debugPrint('[StoragePermission] MANAGE_EXTERNAL_STORAGE permanently denied, redirecting to settings');
        await openAppSettings();
        return false;
      }
    }

    // Fallback: 请求传统存储权限
    final storageStatus = await Permission.storage.request();
    if (storageStatus.isGranted) {
      debugPrint('[StoragePermission] Storage permission granted');
      return true;
    }

    debugPrint('[StoragePermission] Storage permission denied');
    return false;
  }

  /// 显示权限请求对话框（存储）
  static Future<void> showPermissionDialog(BuildContext context) async {
    final hasPermission = await hasStoragePermission();
    
    if (hasPermission) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('需要存储权限'),
        content: const Text(
          '为了保存下载的模型文件，需要访问设备存储空间。\n\n'
          '点击"前往设置"授予权限。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              await requestStoragePermission();
            },
            icon: const Icon(Icons.settings),
            label: const Text('前往设置'),
          ),
        ],
      ),
    );
  }

  /// 显示相机权限请求对话框
  static Future<void> showCameraPermissionDialog(BuildContext context) async {
    final status = await getCameraPermissionStatus();
    
    if (status.isGranted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('需要相机权限'),
        content: const Text(
          '为了使用拍照功能，需要访问相机。\n\n'
          '点击"前往设置"授予权限。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              await requestCameraPermission();
            },
            icon: const Icon(Icons.camera_alt),
            label: const Text('授予权限'),
          ),
        ],
      ),
    );
  }

  /// 检查是否需要请求权限（应用启动时调用）
  static Future<bool> checkAndRequestIfNeeded(BuildContext context) async {
    final hasPermission = await hasStoragePermission();
    
    if (!hasPermission) {
      await showPermissionDialog(context);
      return false;
    }
    
    return true;
  }
}
