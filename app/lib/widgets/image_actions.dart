/// 图片动作（复制进剪贴板 / 另存为）共享件。
///
/// 气泡缩略图长按菜单、消息动作行的可见图标、全屏预览工具栏三处共用
/// （用户 2026-11-10：生图要能直接复制/另存——此前只有长按/右键**图片
/// 本身**才弹的隐藏菜单，零可见性，动作行上的复制键只管文本）。
/// 剪贴板落地在 [ImageClipboardService]，本文件只管交互层：结果 toast、
/// 保存对话框、多图时的选张。
library;

import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/image_clipboard_service.dart';

/// [runImageAction] 的动作类型。
enum ImageActionKind { copy, save }

/// 把 [path] 图片复制进系统剪贴板（图像内容，非文件引用），toast 结果。
Future<void> copyImageToClipboard(BuildContext context, String path) async {
  final ok = await ImageClipboardService.copyImageFile(path);
  if (!context.mounted) return;
  _toast(context, ok ? '已复制到剪贴板' : '复制失败（系统剪贴板不可用）');
}

/// [path] 图片另存为到自选位置（取消 = 静默返回），toast 结果。
Future<void> saveImageAs(BuildContext context, String path) async {
  try {
    // p.basename 更稳（处理 Windows 反斜杠与混合分隔符）。
    final defaultName = p.basename(path.replaceAll('\\', '/'));
    final dest = await FilePicker.platform.saveFile(
      dialogTitle: '图片另存为',
      fileName: defaultName,
      type: FileType.image,
      lockParentWindow: true,
    );
    if (!context.mounted) return;
    if (dest == null || dest.isEmpty) return; // 用户取消
    final src = File(path);
    final dst = File(dest);
    // Windows saveFile 只回路径不建文件；个别平台可能预建空文件，覆盖写。
    if (src.path != dst.path) {
      await dst.writeAsBytes(await src.readAsBytes(), flush: true);
      if (!context.mounted) return; // 写盘也是一个 async gap，toast 前复查
    }
    _toast(context, '已保存：$dest');
  } catch (e) {
    if (!context.mounted) return;
    _toast(context, '另存失败：$e');
  }
}

/// 对消息图片执行 [action]：单图直接做；多图先弹选张（缩略图列表）。
Future<void> runImageAction(
  BuildContext context,
  List<String> paths,
  ImageActionKind action,
) async {
  void go(String path) => action == ImageActionKind.copy
      ? copyImageToClipboard(context, path)
      : saveImageAs(context, path);
  if (paths.length == 1) return go(paths.first);
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetCtx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < paths.length; i++)
            ListTile(
              leading: SizedBox(
                width: 40,
                height: 40,
                child: Image.file(File(paths[i]),
                    fit: BoxFit.cover,
                    // 缓存被清/文件已删 → 灰块占位，不炸选张（与预览一致）。
                    errorBuilder: (_, __, ___) => const ColoredBox(
                        color: Colors.black12,
                        child: Icon(Icons.broken_image_outlined, size: 20))),
              ),
              title: Text('图片 ${i + 1}'),
              onTap: () {
                Navigator.pop(sheetCtx);
                go(paths[i]);
              },
            ),
        ],
      ),
    ),
  );
}

void _toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white))));
}
