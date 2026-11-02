/// prompt-JSON/XML 文本协议 —— 当前本地引擎的兜底工具协议。
///
/// 原理：把工具清单 + 调用协议注入系统提示，要求模型输出工具调用块：
/// - JSON：`{"tool_call": {"name": "get_time", "arguments": {}}}`
/// - XML：`<tool_call>web_search<arg_key>query<arg_value>今天天气</tool_call>`
/// （真机实测 Spark/Qwen 均输出 XML 原生格式 → 提示词以 XML 呈现，遵循率更高；
///  解析器双格式兼容。）
///
/// 生成侧从文本增量流中提取完整工具调用块，解析失败时**优雅降级**
/// 为普通文本回答 —— 模型没学会调用也不阻塞对话。
library;

import 'dart:convert';

import '../capability.dart';
import '../llm/adapter.dart' show LlmFailure, LlmFailureCode;
import '../tool_definition.dart';
import '../tool_registry.dart';
import 'tool_protocol.dart';

/// prompt-JSON/XML 文本协议。
class PromptJsonProtocol implements ToolProtocol {
  static const String kId = 'prompt-json';

  /// 精简档渲染（见 `agent_tier.dart`）：true 时工具清单压成"一行一名 +
  /// 描述首句"，并省掉 [沙箱说明] 段。只影响呈现，不影响解析侧。
  /// 默认 false = 与旧版逐字节一致。
  final bool compact;

  const PromptJsonProtocol({this.compact = false});

  /// 协议指令（模型看到的部分）：XML 格式（贴近端侧模型训练分布）。
  static const String kProtocolInstruction =
      '当你要调用工具时，输出以下 XML 格式（不要任何多余文字、不要思考过程、'
      '不要先回答再补调用）：\n'
      '无参数：<tool_call>get_time</tool_call>\n'
      '带参数：<tool_call>web_search<arg_key>query<arg_value>今天天气</tool_call>\n'
      '数组参数：<tool_call>todo_write<arg_key>todos<arg_value>[{"content": "明天开会", "status": "todo"}]</tool_call>\n'
      '键值规则：一个 <arg_key>键名</arg_key> 后面必须紧跟 <arg_value>值</arg_value>，'
      '先键后值、一个键配一个值，值不要放进 arg_key。\n'
      '必填参数必须完整给出（如 web_search 的 query），遗漏会导致工具失败。\n'
      '收到工具结果后，根据真实结果组织最终回答。'
      '若用户要求操作（如添加待办/便签/记忆）但你未调用工具，则视为任务未完成。';

  /// LFM 系模型指令：JSON 对象格式（<tool_call> 内嵌 JSON 是 Qwen/LFM 系
  /// chat template 训练分布，小模型对 XML <arg_key> 标签遵循度差，常直接
  /// 输出普通文本导致工具不执行）。
  static const String kProtocolInstructionJson =
      '当你要调用工具时，输出以下 JSON 格式（不要任何多余文字、不要思考过程、'
      '不要先回答再补调用）：\n'
      '无参数：{"name": "get_time", "arguments": {}}\n'
      '带参数：{"name": "web_search", "arguments": {"query": "今天天气"}}\n'
      '数组参数：{"name": "todo_write", "arguments": {"todos": [{"content": "明天开会", "status": "todo"}]}}\n'
      '必填参数必须完整给出（如 web_search 的 query），遗漏会导致工具失败。\n'
      '绝对不要输出 [get_time()] 这类函数签名文本——那样不会被当作工具调用，任务会失败。\n'
      '收到工具结果后，根据真实结果组织最终回答。'
      '若用户要求操作（如添加待办/便签/记忆）但你未调用工具，则视为任务未完成。';

  /// Ling（Bailing V3）系模型指令：**原生 XML 带闭合标签格式**（官方
  /// chat_template.jinja 训练分布：`<tool_call>` 后换行写工具名，每个参数
  /// `<arg_key>k</arg_key>` + `<arg_value>v</arg_value>` 成对闭合，一个参数
  /// 一行。1.3B 激活的 tiny 对自带格式遵循度最高，改用半开标签格式反而
  /// 掉进非训练分布导致不调用/格式坏）。
  static const String kProtocolInstructionLing =
      '当你要调用工具时，输出以下格式（工具调用块前后可以有简短说明文字）：\n'
      '无参数：<tool_call>\nget_time\n</tool_call>\n'
      '带参数：<tool_call>\nweb_search\n<arg_key>query</arg_key>\n'
      '<arg_value>今天天气</arg_value>\n</tool_call>\n'
      '数组参数：<tool_call>\ntodo_write\n<arg_key>todos</arg_key>\n'
      '<arg_value>[{"content": "明天开会", "status": "todo"}]</arg_value>\n</tool_call>\n'
      '键值规则：每个参数写一行，<arg_key>参数名</arg_key> 与 '
      '<arg_value>参数值</arg_value> 必须成对闭合，先键后值。\n'
      '必填参数必须完整给出（如 web_search 的 query），遗漏会导致工具失败。\n'
      '收到工具结果后，根据真实结果组织最终回答。'
      '若用户要求操作（如添加待办/便签/记忆）但你未调用工具，则视为任务未完成。';

  @override
  String get id => kId;

  /// 兜底协议：任何能力都可用。
  @override
  bool supports(EngineCapabilities caps) => true;

  /// 最低优先级（原生/结构化协议存在时让位）。
  @override
  int priority(EngineCapabilities caps) => 0;

  @override
  String buildToolSection(ToolRegistry registry, {String modelId = ''}) {
    final tools = registry.visibleFor(modelId);
    if (tools.isEmpty) return '';
    final lines = <String>['[可用工具]'];
    for (final tool in tools) {
      // 文本格式（贴近端侧模型训练分布）：`- name: description`，
      // 而非完整 JSON Schema（小模型更易理解）。
      // 关键：列出必填参数名（对照 DSH 的 schema 呈现），
      // 让模型知道带参数工具必须给出哪些参数——根治「只调工具不带参数」。
      // 精简档只留描述首句（python_exec 295 字/shell_exec 273 字这类长描述
      // 是 tiny 档 prefill 的大头，且 tiny 模型并不会因为描述更细就填对参数）。
      final desc =
          compact ? _briefDescription(tool.description) : tool.description;
      lines.add('- ${tool.name}: $desc${_requiredParamsHint(tool)}');
    }

    // 沙箱升级说明（对照 DSH bashDescription）：带升级能力的工具默认在
    // workspace 沙盒内运行；确需完整文件系统访问时请求用户批准。
    // 精简档不注入：能触发升级的只有 python/shell/文件类工具，它们已被
    // 精简档工具白名单挡在门外，留着纯属白烧 token。
    if (!compact && tools.any(_hasEscalation)) {
      lines.add('');
      lines.add('[沙箱说明]');
      lines.add('文件/命令类工具默认在 app workspace 沙盒内运行，'
          '确需访问公共目录/完整文件系统时，在调用中带 '
          '<arg_key>sandbox_permissions<arg_value>danger-full-access</arg_value> '
          '和 <arg_key>justification<arg_value>一句话理由</arg_value> '
          '请求用户批准；批准后仅本次调用生效。被拒时不要偷偷绕过，先解释或放弃。');
    }

    lines.add('');
    lines.add('[工具调用协议]');
    // LFM 系（Qwen/LiquidAI 训练分布）主推 JSON 格式；spark/qwen 等主推
    // XML <arg_key> 格式（各自贴近训练分布，模型遵循度更高）。
    lines.add(_instructionFor(modelId));
    return lines.join('\n');
  }

  @override
  Future<StreamOutcome> parseStream(Stream<String> stream) async {
    final buffer = StringBuffer();
    await for (final token in stream) {
      if (token.isNotEmpty) buffer.write(token);
    }
    return _parseText(buffer.toString());
  }

  /// 从全文解析：优先 XML `<tool_call>`（llama.cpp 原生格式），
  /// 再试 JSON 对象；都失败则整段作为普通文本回答（优雅降级）。
  StreamOutcome _parseText(String text) {
    // 0) 截断兜底（先于一切降级）：文本以未闭合的工具调用块开头
    //    （生成 token 预算不足，JSON/`</tool_call>` 被拦腰截断）。旧行为是
    //    整段当普通回答 → turn 静默"完成"，任务半途而废且无提示——
    //    正是"迭代一两下就停、输出没完成任务"的静默卡死路径。现在按
    //    完整性分类：结构完整（仅缺收尾括号）→ 补全执行；断在参数内容里
    //    → 抛 toolCallTruncated 失败，交失败瀑布重试并在 UI 明确报错；
    //    补完括号仍非法的语法错误 → 继续走下面的容错解析（不误报截断）。
    final truncation = _truncatedToolCall(text);
    if (truncation != null) {
      final repaired = truncation.repairedJson;
      if (repaired == null) {
        // 断在字符串/参数内容内部：内容真丢了，不可修复。
        throw toolCallTruncatedFailure();
      }
      final call = _decodeToolCallAnyForm(repaired);
      if (call != null) {
        final head = text.substring(0, truncation.start);
        return StreamOutcome(text: head, toolCalls: [call]);
      }
      // 补齐收尾括号后仍解不出 JSON ⇒ 这不是预算截断，而是模型自己的
      // 语法错误（如用 `;` 代替 `,`）。预算截断只有两种形态：断在字符串
      // 内部（上面已抛）、纯缺收尾括号（补全后即可解码），都不会落到这里。
      // 语法错误落回下方容错解析 —— 保持"解析失败优雅降级为文本"的
      // 协议契约，不误报"token 预算不足"误导用户去调设置。
    }

    // 1) XML tool_call 格式（Spark/Hunyuan 训练分布常见）。
    final xmlCall = _extractXmlToolCall(text);
    if (xmlCall != null) {
      return StreamOutcome(
        text: xmlCall.before + xmlCall.after,
        toolCalls: [xmlCall.call],
      );
    }

    // 1b) 属性式 <function name=…><parameter name=…> 格式（MiniCPM5/Hunyuan
    //     系原生工具标记，特殊 token 渲染后可见）。有无 <tool_call> 包裹均可。
    final funcCall = _extractFunctionToolCall(text);
    if (funcCall != null) {
      return StreamOutcome(
        text: funcCall.before + funcCall.after,
        toolCalls: [funcCall.call],
      );
    }

    // 2) [tool_name(arg)] 函数签名式调用（LFM 等模型退化输出，
    //    如 [get_time()]、[web_search("今天天气")]）。
    final bracketCall = _matchBracketCall(text);
    if (bracketCall != null) {
      return StreamOutcome(
        text: bracketCall.before + bracketCall.after,
        toolCalls: [bracketCall.call],
      );
    }

    // 3) JSON 格式（提示词约定的主格式）。
    final extracted = _extractFirstJsonObject(text);
    if (extracted == null) {
      _noLeakFallback(text);
      return StreamOutcome(text: text);
    }

    final (:json, :before, :after) = extracted;
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      // JSON 解析失败 → 整段视为普通回答。
      return StreamOutcome(text: text);
    }

    if (decoded is Map<String, dynamic>) {
      // 格式 1：{"tool_call": {"name": ..., "arguments": {...}}}（提示词约定）。
      final toolCall = decoded['tool_call'];
      if (toolCall is Map<String, dynamic>) {
        final name = toolCall['name'];
        if (name is String && name.isNotEmpty) {
          final args = toolCall['arguments'];
          return StreamOutcome(
            text: before + after,
            toolCalls: [
              ToolCall(
                id: 'tool_${DateTime.now().microsecondsSinceEpoch}',
                name: name,
                arguments: args is Map<String, dynamic> ? args : null,
              ),
            ],
          );
        }
      }

      // 格式 2：顶层 {"name": ..., "arguments": {...}}（OpenAI/LFM 风格）。
      final topLevel = _decodeJsonToolCall(json);
      if (topLevel != null) {
        return StreamOutcome(
          text: before + after,
          toolCalls: [topLevel],
        );
      }
    }

    // 是合法 JSON 但不是工具调用 → 整段视为普通回答。
    _noLeakFallback(text);
    return StreamOutcome(text: text);
  }

  /// 防泄漏兜底（2026-09-30 真机定案）：所有容错解析都解不开，但文本里
  /// 明确有工具调用标记——模型**想调用工具但格式坏了**。此时绝不把原始
  /// 工具标签当普通回答漏给用户（用户看到的就是一串 tool 标签），改抛
  /// [LlmFailureCode.toolCallSyntax] 进入可重试失败瀑布：重新采样 +
  /// 「上次尝试失败」反思注记，模型按正确格式重写。
  /// 纯文本回答（无工具标记）不受影响。
  void _noLeakFallback(String text) {
    if (RegExp(r'<\s*/?\s*(tool_call|function|parameter)\b').hasMatch(text)) {
      throw const LlmFailure(
        code: LlmFailureCode.toolCallSyntax,
        message: '工具调用块语法错误（<tool_call>/<function> 格式坏），无法解析执行。'
            '请严格按约定格式重写：无参数 <tool_call>get_time</tool_call>；'
            '带参数 <tool_call>web_search<arg_key>query<arg_value>…</tool_call>'
            '（或 JSON {"name":…,"arguments":…}），不要混入多余字符。',
      );
    }
  }

  /// 提取属性式工具调用（MiniCPM5/Hunyuan 原生格式）：
  /// `<tool_call><function name="get_weather"><parameter name="city">南宁</parameter></function></tool_call>`
  /// `<tool_call>` 包裹与 `</function>` 闭合均可缺省（特殊 token 渲染残缺时容错）。
  ({String before, String after, ToolCall call})? _extractFunctionToolCall(
      String text) {
    final fn = RegExp(r'<function\s+name\s*=\s*"([^"]+)"\s*>').firstMatch(text);
    if (fn == null) return null;
    final name = fn.group(1)!.trim();
    if (name.isEmpty) return null;

    final arguments = <String, dynamic>{};
    final params = RegExp(
      r'<parameter\s+name\s*=\s*"([^"]+)"\s*>(.*?)(?:</parameter>|(?=<parameter)|$)',
      dotAll: true,
    ).allMatches(text.substring(fn.end));
    for (final p in params) {
      final k = p.group(1)!.trim();
      var v = p.group(2)?.trim() ?? '';
      if (k.isEmpty) continue;
      // 值尽量还原类型：数组/对象走 JSON，数字/布尔按字面量，其余字符串。
      final decoded = _tryDecodeScalar(v);
      arguments[k] = decoded ?? v;
    }

    // 回答文本 = 块之前的文本 + 块结束（</function> 或 </tool_call>）之后的残留。
    var after = text.substring(fn.end);
    final fnClose = after.indexOf('</function>');
    if (fnClose >= 0) {
      after = after.substring(fnClose + '</function>'.length);
    } else {
      final tcClose = after.indexOf('</tool_call>');
      if (tcClose >= 0) after = after.substring(tcClose + '</tool_call>'.length);
    }
    return (
      before: text.substring(0, fn.start),
      after: after,
      call: ToolCall(
        id: 'tool_${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        arguments: arguments,
      ),
    );
  }

  /// 标量值还原：JSON 可解（数组/对象/带引号字符串）→ 解码；纯数字/布尔 →
  /// 对应类型；否则保持字符串。
  Object? _tryDecodeScalar(String v) {
    if (v.isEmpty) return v;
    if (v.startsWith('[') || v.startsWith('{')) {
      try {
        return jsonDecode(v);
      } catch (_) {
        return v;
      }
    }
    if (v == 'true') return true;
    if (v == 'false') return false;
    final n = num.tryParse(v);
    if (n != null && RegExp(r'^-?\d+(\.\d+)?$').hasMatch(v)) return n;
    return v;
  }

  /// 提取 XML 格式的工具调用（llama.cpp 原生 / Spark 训练分布）：
  /// `<tool_call>name<arg_key>k1<arg_value>v1</arg_value></arg_key>...</tool_call>`
  /// 兼容半开标签（无 `</arg_key>`/`</arg_value>` 闭合）与 MiniCPM5 特殊
  /// 标记 `<|tool_call_start|>` / `<|tool_call_end|>`（两者等价处理）。
  ({String before, String after, ToolCall call})? _extractXmlToolCall(
      String text) {
    const openTag = '<tool_call>';
    const miniOpenTag = '<|tool_call_start|>';
    const closeTag = '</tool_call>';
    const miniCloseTag = '<|tool_call_end|>';
    // 取更早出现的开标签，闭合按同族匹配。
    final openPlain = text.indexOf(openTag);
    final openMini = text.indexOf(miniOpenTag);
    final bool useMini;
    final int open;
    if (openPlain < 0 && openMini < 0) return null;
    if (openPlain < 0) {
      useMini = true;
      open = openMini;
    } else if (openMini < 0) {
      useMini = false;
      open = openPlain;
    } else if (openMini < openPlain) {
      useMini = true;
      open = openMini;
    } else {
      useMini = false;
      open = openPlain;
    }
    final String effOpenTag = useMini ? miniOpenTag : openTag;
    final String effCloseTag = useMini ? miniCloseTag : closeTag;

    final close = text.indexOf(effCloseTag, open + effOpenTag.length);
    var bodyEnd = close;
    var altClosed = false;
    if (close < 0) {
      // 坏格式兼容：模型常漏 `</tool_call>`，以最后一个 `</arg_value>` /
      // `</arg_key>` 收尾（如 `<tool_call>web_search<arg_key>query<arg_key>
      // AI news today</arg_value></arg_key>`）。无任何闭合标签则不解析。
      final lastValue = text.lastIndexOf('</arg_value>');
      final lastKey = text.lastIndexOf('</arg_key>');
      final altEnd = lastValue > lastKey ? lastValue : lastKey;
      if (altEnd >= open + effOpenTag.length) {
        bodyEnd = altEnd;
        altClosed = true;
      } else {
        // 再退一步：闭合标签漏了 `>`（`</tool_call`）也能定位块尾；
        // MiniCPM5 系漏 `<|tool_call_end|>` 尾段同理。
        final loose = useMini
            ? text.indexOf('<|tool_call_end', open + effOpenTag.length)
            : text.indexOf('</tool_call', open + effOpenTag.length);
        if (loose < 0) return null;
        bodyEnd = loose;
        altClosed = true;
      }
    }

    final body = text.substring(open + effOpenTag.length, bodyEnd);
    final trimmed = body.trim();

    // JSON-in-XML：`<tool_call>{"name": ..., "arguments": {...}}</tool_call>`
    // （Qwen/LFM 系 chat template 训练分布：函数调用为 XML 标签内嵌 JSON
    // 对象，而非 <arg_key> 标签）。LFM2.5 / MiniCPM5 等模型原生输出这种格式。
    if (trimmed.startsWith('{')) {
      final jsonCall = _decodeJsonToolCall(trimmed);
      if (jsonCall != null) {
        return (
          before: text.substring(0, open),
          after: altClosed
              ? text.substring(bodyEnd)
              : text.substring(close + effCloseTag.length),
          call: jsonCall,
        );
      }
      // JSON 解析失败 → 落到下方 XML 解析（容错）。
    }

    // 工具名：到第一个 <arg_key> 或 <arg_value> 之前。
    // 容错（2026-09-30 真机定案）：2B 级模型常在名字前后混入杂散标签字符
    // （实测 `<tool_call><get_time</tool_call>`），先剥掉名字前的
    // `<`/`>`/`/`/空白再提取；剥完若是 arg_key/arg_value 说明模型没写
    // 工具名、直接进了参数区 → 无法解析。
    final cleanedBody =
        body.trim().replaceAll(RegExp(r'^[<>/\s]+'), '').trim();
    final nameMatch = RegExp(r'^([A-Za-z_][A-Za-z0-9_.\-]*)').firstMatch(cleanedBody);
    if (nameMatch == null) return null;
    final name = nameMatch.group(1)!.trim();
    if (name.isEmpty ||
        name == 'arg_key' ||
        name == 'arg_value' ||
        name == 'tool_call' ||
        // `<function name=…>` 属性式格式 → 交给 _extractFunctionToolCall。
        name == 'function' ||
        name == 'parameter') {
      return null;
    }

    // 参数对：顺序扫描 <arg_key>/<arg_value>，兼容闭合/半开标签，并**容错
    // 坏格式**——模型常见错误是把值文本直接塞进 <arg_key>（如
    // `<arg_key>query<arg_key>AI news today</arg_value>`），此时把第二个
    // <arg_key> 的文本当作 value 配对给前面的 key，一次调用即可成功。
    final arguments = _parseXmlArgs(body);

    return (
      before: text.substring(0, open),
      after: altClosed
          ? text.substring(bodyEnd) // 坏格式：闭合标签之后的残留文本
          : text.substring(close + effCloseTag.length),
      call: ToolCall(
        id: 'tool_${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        arguments: arguments,
      ),
    );
  }

  /// 按模型选择指令：LFM 系（id 以 lfm 开头）用 JSON 风格；Ling/Bailing 系
  /// （id 以 ling 开头）用原生闭合标签 XML 风格（Bailing V3 训练分布）；
  /// 其余用半开标签 XML 风格。
  String _instructionFor(String modelId) {
    final lower = modelId.toLowerCase();
    if (lower.startsWith('lfm')) {
      return kProtocolInstructionJson;
    }
    if (lower.startsWith('ling')) {
      return kProtocolInstructionLing;
    }
    return kProtocolInstruction;
  }

  /// 工具是否声明了沙箱升级能力（含 `sandbox_permissions` 字段）。
  bool _hasEscalation(ToolDefinition tool) {
    final props = tool.parameters['properties'];
    return props is Map && props['sandbox_permissions'] != null;
  }

  /// 精简档描述压缩：只留描述首句（按换行/。/；/括号断句，保底 12 字不被切没，
  /// 上限 48 字）。必填参数标注由 [_requiredParamsHint] 单独追加，不受瘦身影响
  /// ——「参数填不全」是端侧头号失败模式，宁可砍描述也不砍必填提示。
  static const int _kBriefDescriptionMaxChars = 48;

  String _briefDescription(String description) {
    var s = description.trim();
    final nl = s.indexOf('\n');
    if (nl > 0) s = s.substring(0, nl);
    for (final sep in const ['。', '；', ';', '（必填', '（注意', '(必填']) {
      final i = s.indexOf(sep);
      if (i >= 12) s = s.substring(0, i);
    }
    s = s.trim();
    if (s.length > _kBriefDescriptionMaxChars) {
      s = s.substring(0, _kBriefDescriptionMaxChars).trim();
    }
    return s.isEmpty ? description.trim() : s;
  }

  /// 生成必填参数提示（对照 DSH schema 呈现）：`（必填: command: string）`。
  /// 带类型让模型首次调用就能填对（根治「只调工具不带参数」）。
  String _requiredParamsHint(ToolDefinition tool) {
    final required = tool.parameters['required'];
    if (required is! List || required.isEmpty) return '';
    final props = tool.parameters['properties'];
    final parts = required.map((r) {
      final name = r.toString();
      if (props is Map && props[name] is Map) {
        final type = (props[name] as Map)['type']?.toString();
        if (type != null) return '$name: $type';
      }
      return name;
    }).toList();
    return '（必填: ${parts.join(', ')}）';
  }

  /// 签名式单参工具的命名参数映射：`[web_search("x")]` → {query: "x"}。
  static const Map<String, String> _bracketArgKeys = {
    'web_search': 'query',
    'get_weather': 'location',
    'calculator': 'expression',
  };

  /// 匹配 [tool_name(arg)] 函数签名式调用（LFM 等模型退化输出，如
  /// `[get_time()]`、`[web_search("今天天气")]`）。无参数 → 空参数调用；
  /// 单参数 → 按映射表对应命名参数；多参数/未知工具不解析（避免错误执行）。
  ({String before, String after, ToolCall call})? _matchBracketCall(String text) {
    final re = RegExp(r'\[\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)\s*\]');
    final m = re.firstMatch(text);
    if (m == null) return null;
    final name = m.group(1)!.trim();
    if (name.isEmpty) return null;
    final argsStr = m.group(2)!.trim();
    Map<String, dynamic>? arguments;
    if (argsStr.isNotEmpty) {
      // 逗号分隔多个参数 → 无法可靠映射命名参数，不解析（避免错误执行）。
      if (argsStr.contains(',')) return null;
      final key = _bracketArgKeys[name];
      if (key == null) return null; // 未知工具参数名映射 → 不解析
      final value = argsStr.trim();
      // 去掉首尾引号（单/双引号）。
      final unquoted = value.length >= 2 &&
              ((value.startsWith('"') && value.endsWith('"')) ||
                  (value.startsWith("'") && value.endsWith("'")))
          ? value.substring(1, value.length - 1)
          : value;
      arguments = {key: unquoted};
    }
    return (
      before: text.substring(0, m.start),
      after: text.substring(m.end),
      call: ToolCall(
        id: 'tool_${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        arguments: arguments,
      ),
    );
  }

  /// 解码 JSON 对象形式的工具调用：`{"name": ..., "arguments": {...}}`。
  /// 用于 `<tool_call>{...}</tool_call>`（Qwen/LFM 系）与顶层 JSON 对象。
  /// 结构不符（缺 name / name 非字符串）返回 null。
  ToolCall? _decodeJsonToolCall(String jsonText) {
    Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final name = decoded['name'];
    if (name is! String || name.isEmpty) return null;
    final args = decoded['arguments'];
    return ToolCall(
      id: 'tool_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      arguments: args is Map<String, dynamic> ? args : null,
    );
  }

  /// 宽容解码：先试 `{"tool_call": {...}}` 包裹式，再试顶层
  /// `{"name": ...}` 式（提示词约定的两种格式）。用于截断修复路径。
  ToolCall? _decodeToolCallAnyForm(String jsonText) {
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is Map<String, dynamic>) {
        final wrapped = decoded['tool_call'];
        if (wrapped is Map<String, dynamic>) {
          return _decodeJsonToolCall(jsonEncode(wrapped));
        }
      }
    } catch (_) {
      // 落到顶层解码（其内部自带 try-catch）。
    }
    return _decodeJsonToolCall(jsonText);
  }

  /// 顺序解析 XML 参数对（容错坏格式）。
  ///
  /// 正常：`<arg_key>key<arg_value>value` 或带闭合标签；
  /// 坏格式：`<arg_key>key<arg_key>value文本</arg_value>`（值误塞进 key 标签）
  /// → 第二个 <arg_key> 的文本被配对给 pendingKey。
  /// 孤立 value（key 缺失）忽略；残留 pendingKey（有 key 无 value）丢弃。
  Map<String, dynamic> _parseXmlArgs(String body) {
    final args = <String, dynamic>{};
    final tagRe = RegExp(r'<(arg_key|arg_value)>');
    final tags = tagRe.allMatches(body).toList();
    if (tags.isEmpty) return args;

    String? pendingKey;
    for (var i = 0; i < tags.length; i++) {
      final tag = tags[i].group(1)!;
      final valueStart = tags[i].end;
      // 标签后的文本：到下一个 '<'（含闭合标签）为止。
      final nextLt = body.indexOf('<', valueStart);
      final end = nextLt < 0 ? body.length : nextLt;
      final text = body.substring(valueStart, end).trim();
      if (text.isEmpty) continue;

      if (tag == 'arg_key') {
        if (pendingKey != null) {
          // 连续 arg_key（无中间 arg_value）= 坏格式：当前文本是值，
          // 配对给 pendingKey（如 `<arg_key>query<arg_key>AI news today</arg_value>`）。
          args[pendingKey] = _decodeXmlArgValue(text);
          pendingKey = null;
        } else {
          // 正常：文本是 key。
          pendingKey = text;
        }
      } else {
        // arg_value：文本是值，配对给 pendingKey；孤立 value 忽略。
        if (pendingKey != null) {
          args[pendingKey] = _decodeXmlArgValue(text);
          pendingKey = null;
        }
      }
    }
    return args;
  }

  /// 解码 XML 工具参数值：以 `[`/`{` 开头且以 `]`/`}` 结尾的字符串按 JSON 解析
  /// （数组/对象参数，如 todo_write 的 todos），解析失败保留原字符串。
  dynamic _decodeXmlArgValue(String raw) {
    final trimmed = raw.trim();
    if ((trimmed.startsWith('[') || trimmed.startsWith('{')) &&
        (trimmed.endsWith(']') || trimmed.endsWith('}'))) {
      try {
        return jsonDecode(trimmed);
      } catch (_) {
        return raw;
      }
    }
    return raw;
  }

  /// 提取文本中第一个完整的 JSON 对象。
  ///
  /// 返回 `(jsonText, 前导文本, 尾随文本)`；找不到完整对象时返回 null。
  /// 平衡括号扫描会跳过字符串字面量内的 `{`/`}`（含转义）。
  ({String json, String before, String after})? _extractFirstJsonObject(
      String text) {
    final open = text.indexOf('{');
    if (open < 0) return null;

    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = open; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == r'\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      switch (ch) {
        case '"':
          inString = true;
          break;
        case '{':
          depth++;
          break;
        case '}':
          depth--;
          if (depth == 0) {
            return (
              json: text.substring(open, i + 1),
              before: text.substring(0, open),
              after: text.substring(i + 1),
            );
          }
          break;
      }
    }
    // 括号不平衡（模型输出被截断）→ 视为无完整 JSON。
    return null;
  }

  // ---------------------------------------------------------------------------
  // 截断工具调用检测与修复（token 预算不足的静默卡死根治）
  // ---------------------------------------------------------------------------

  /// 检测文本中的**截断工具调用**：XML 有 `<tool_call>` 但整个文本没有
  /// 收尾（`</tool_call>` / `</arg_key>` / `</arg_value>`），或 JSON 从
  /// `{"name"` 起手但括号/字符串未闭合。
  ///
  /// 返回 null = 不存在截断的调用（正常文本 / 完整调用，走原解析）。
  /// 返回非 null：`repairedJson` 非空 = 结构完整可补全（仅缺收尾括号，
  /// 未断在字符串内部，参数无损）；为空 = 参数内容真丢了，不可修复。
  ({int start, String? repairedJson})? _truncatedToolCall(String text) {
    // XML：有开标签且全文无任何收尾标记（有收尾时即便格式坏也走原容错解析；
    // `</tool_call` 漏 `>` 与 `<|tool_call_end|>` 系都算有收尾，交回 XML 容错）。
    final xmlOpen = text.indexOf('<tool_call>');
    final miniOpen = text.indexOf('<|tool_call_start|>');
    if ((xmlOpen >= 0 || miniOpen >= 0) &&
        !text.contains('</tool_call') &&
        !text.contains('<|tool_call_end') &&
        !text.contains('</arg_key>') &&
        !text.contains('</arg_value>')) {
      final head = xmlOpen >= 0 ? xmlOpen : miniOpen;
      final tagLen = xmlOpen >= 0 ? '<tool_call>'.length : '<|tool_call_start|>'.length;
      final body = text.substring(head + tagLen).trimLeft();
      // JSON-in-XML 且结构只差收尾 → 可补全。
      if (body.startsWith('{')) {
        final rep = _repairTruncatedJsonObject(body);
        return (start: head, repairedJson: rep);
      }
      return (start: head, repairedJson: null);
    }

    // JSON：首个平衡对象缺失时，若文本以 `{"name"` 或 `{"tool_call"`
    // 起手则判为截断调用（两种提示词约定格式都覆盖）。
    final open = text.indexOf('{');
    if (open < 0) return null;
    if (_extractFirstJsonObject(text) != null) return null; // 有完整对象
    final afterBrace = text.substring(open + 1);
    if (!RegExp(r'^\s*"(?:name|tool_call)"\s*:').hasMatch(afterBrace)) {
      return null;
    }
    final rep = _repairTruncatedJsonObject(text.substring(open));
    return (start: open, repairedJson: rep);
  }

  /// 修复只差收尾括号/逗号的 JSON 对象文本：字符串字面量未闭合（参数断在
  /// 内容中间）→ 返回 null（不可修复，绝不伪造半截参数去执行）；
  /// 否则按括号栈补 `"]}` 等收尾返回修复文本（纯语法补全，是否真能解出
  /// 工具调用由调用方解码判定）。
  String? _repairTruncatedJsonObject(String src) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = 0; i < src.length; i++) {
      final ch = src[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == r'\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      switch (ch) {
        case '"':
          inString = true;
          break;
        case '{':
        case '[':
          depth++;
          break;
        case '}':
        case ']':
          depth--;
          break;
      }
    }
    if (depth <= 0) return null; // 并非"只差收尾"（或本就平衡），交回原逻辑
    if (inString) return null; // 断在字符串内部：参数内容丢失，不可修复
    var trimmed = src.trimRight();
    while (trimmed.endsWith(',')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    // 按"先闭合未闭合容器"朴素补全（对象/数组统一用栈计数补全括号种类，
    // 但小模型工具调用几乎恒为纯对象嵌套，直接按剩余层数补 '}' 即可）。
    // 只补括号、不做解码：能否真正解出工具调用由调用方判定（区分
    // "预算截断"与"模型语法错误"）。
    return '$trimmed${'}' * depth}';
  }
}

/// 工具调用截断失败（协议 → 主循环失败瀑布的约定信号）。
LlmFailure toolCallTruncatedFailure() => const LlmFailure(
      code: LlmFailureCode.toolCallTruncated,
      message: '工具调用生成不完整（输出 token 预算不足被截断）：'
          '请在设置中调大「智能体每轮生成 token」后重试',
    );
