import 'dart:io';
import 'package:flutter/material.dart';

/// 全屏图片预览：黑色遮罩 + 双指/双击缩放（InteractiveViewer），
/// 多图可左右滑动翻页；点击空白处或 ✕ 退出。
///
/// 消息气泡缩略图与输入区附件缩略图共用——拍照/上传图片后
/// 点一下就能看清原图内容。
Future<void> showImagePreview(
  BuildContext context, {
  required List<String> imagePaths,
  int initialIndex = 0,
}) async {
  final paths = imagePaths.where((p) => p.isNotEmpty).toList();
  if (paths.isEmpty) return;
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.92),
    builder: (_) => _ImagePreviewDialog(
      imagePaths: paths,
      initialIndex: initialIndex.clamp(0, paths.length - 1),
    ),
  );
}

class _ImagePreviewDialog extends StatefulWidget {
  final List<String> imagePaths;
  final int initialIndex;

  const _ImagePreviewDialog({
    required this.imagePaths,
    required this.initialIndex,
  });

  @override
  State<_ImagePreviewDialog> createState() => _ImagePreviewDialogState();
}

class _ImagePreviewDialogState extends State<_ImagePreviewDialog> {
  late final PageController _controller;
  late int _page;

  @override
  void initState() {
    super.initState();
    _page = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final multi = widget.imagePaths.length > 1;
    return Dialog(
      insetPadding: EdgeInsets.zero,
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: GestureDetector(
        // 点击任意空白/图片区域退出预览。
        onTap: () => Navigator.of(context).maybePop(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            PageView.builder(
              controller: _controller,
              physics:
                  multi ? const PageScrollPhysics() : const NeverScrollableScrollPhysics(),
              itemCount: widget.imagePaths.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (context, index) => InteractiveViewer(
                minScale: 1.0,
                maxScale: 5.0,
                child: Center(
                  child: Image.file(
                    File(widget.imagePaths[index]),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => const ColoredBox(
                      color: Colors.transparent,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.broken_image_outlined,
                                size: 48, color: Colors.white54),
                            SizedBox(height: 8),
                            Text('图片加载失败',
                                style: TextStyle(color: Colors.white70)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 顶部：多图页码 + 关闭按钮
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    if (multi)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${_page + 1} / ${widget.imagePaths.length}',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                        ),
                      ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
