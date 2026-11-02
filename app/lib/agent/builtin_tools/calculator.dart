/// 内置工具：calculator —— 白名单安全四则运算求值（禁 eval）。
///
/// 只接受 `0-9 . + - * / ( )` 与空白；用递归下降解析器求值，
/// 不引入任意代码执行，杜绝注入风险。
library;

import '../tool_definition.dart';

/// 创建 calculator 工具。
ToolDefinition createCalculatorTool() {
  return ToolDefinition(
    name: 'calculator',
    description: '计算四则运算表达式。支持 + - * / 、括号与小数，如 "12*7+3"、"3.5*(2-1)"。',
    parameters: const {
      'type': 'object',
      'properties': {
        'expression': {
          'type': 'string',
          'description': '要计算的数学表达式',
        },
      },
      'required': ['expression'],
      'additionalProperties': false,
    },
    execute: (args) async {
      final raw = args['expression'];
      if (raw == null) {
        return ToolResult.error('缺少 expression 参数');
      }
      final expr = raw.toString().trim();
      if (expr.isEmpty) {
        return ToolResult.error('表达式无效：空表达式');
      }
      try {
        final value = SafeArithmetic.evaluate(expr);
        return ToolResult(content: '$expr = ${_formatNumber(value)}');
      } catch (e) {
        return ToolResult.error('表达式无效：$e');
      }
    },
  );
}

String _formatNumber(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsPrecision(12).replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

/// 白名单安全四则运算求值器。
class SafeArithmetic {
  static const String _allowedChars = '0123456789.+-*/()';

  static double evaluate(String expression) {
    final s = expression.replaceAll(RegExp(r'\s+'), '');
    if (s.isEmpty) throw FormatException('空表达式');
    for (var i = 0; i < s.length; i++) {
      if (!_allowedChars.contains(s[i])) {
        throw FormatException('非法字符 "${s[i]}"');
      }
    }
    final parser = _ArithmeticParser(s);
    final value = parser.parseExpr();
    if (!parser.atEnd) throw FormatException('存在多余内容');
    return value;
  }
}

class _ArithmeticParser {
  final String input;
  int pos = 0;

  _ArithmeticParser(this.input);

  bool get atEnd => pos >= input.length;

  double parseExpr() {
    var value = parseTerm();
    while (!atEnd) {
      final op = input[pos];
      if (op == '+') {
        pos++;
        value += parseTerm();
      } else if (op == '-') {
        pos++;
        value -= parseTerm();
      } else {
        break;
      }
    }
    return value;
  }

  double parseTerm() {
    var value = parseFactor();
    while (!atEnd) {
      final op = input[pos];
      if (op == '*') {
        pos++;
        value *= parseFactor();
      } else if (op == '/') {
        pos++;
        final divisor = parseFactor();
        if (divisor == 0) throw FormatException('除以零');
        value /= divisor;
      } else {
        break;
      }
    }
    return value;
  }

  double parseFactor() {
    if (atEnd) throw FormatException('表达式不完整');
    final ch = input[pos];
    if (ch == '(') {
      pos++;
      final v = parseExpr();
      if (atEnd || input[pos] != ')') throw FormatException('括号不匹配');
      pos++;
      return v;
    }
    if (ch == '+' || ch == '-') {
      pos++;
      final v = parseFactor();
      return ch == '-' ? -v : v;
    }
    return parseNumber();
  }

  double parseNumber() {
    final start = pos;
    var hasDot = false;
    while (pos < input.length) {
      final code = input.codeUnitAt(pos);
      if (code >= 0x30 && code <= 0x39) {
        pos++;
      } else if (code == 0x2E /* . */ && !hasDot) {
        hasDot = true;
        pos++;
      } else {
        break;
      }
    }
    if (pos == start) throw FormatException('需要数字');
    return double.parse(input.substring(start, pos));
  }
}
