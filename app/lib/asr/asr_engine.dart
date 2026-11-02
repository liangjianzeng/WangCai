/// 端侧流式语音识别引擎抽象：按住说话 → 实时 partial → 松手取终稿。
///
/// 现有两个实现：
/// - [SherpaStreamingAsr]：sherpa-onnx 流式 Zipformer（模型下载后启用）；
/// - `speech_to_text` 系统识别（`voice_input.dart` 的 VoiceInputDialog），
///   作为 sherpa 模型不可用时的兜底（UI 层直接复用现有对话框，不封装此接口）。
abstract interface class StreamingAsrEngine {
  /// 开始录音与识别。调用前模型必须已就绪（[SherpaStreamingAsr.ensureLoaded]）。
  Future<void> start();

  /// 实时转写流：已断句定稿文本 + 当前未定稿 partial，随说话持续更新。
  Stream<String> get partialText;

  /// 停止录音并返回最终完整转写文本。
  Future<String> stop();

  /// 释放会话资源（识别流保留，识别器进程内复用）。
  Future<void> dispose();
}
