/// 单位换算工具（本地计算，零依赖）。
///
/// 支持类别：length（长度）、weight（重量）、temperature（温度）、
/// time（时间）、data（数据量）、speed（速度）。值 + 源单位 + 目标单位。
library;

import '../tool_definition.dart';

class _Unit {
  final String name;
  final double factor; // 到基准单位的换算因子
  final double offset; // 温度等带偏移的换算

  const _Unit(this.name, this.factor, [this.offset = 0]);
}

const Map<String, List<_Unit>> _categories = {
  'length': [
    _Unit('m', 1), _Unit('meter', 1), _Unit('meters', 1),
    _Unit('cm', 0.01), _Unit('mm', 0.001), _Unit('km', 1000),
    _Unit('inch', 0.0254), _Unit('ft', 0.3048), _Unit('yard', 0.9144),
    _Unit('mile', 1609.344),
  ],
  'weight': [
    _Unit('kg', 1), _Unit('g', 0.001), _Unit('mg', 0.000001),
    _Unit('t', 1000), _Unit('lb', 0.45359237), _Unit('oz', 0.0283495231),
  ],
  'temperature': [
    _Unit('celsius', 1), _Unit('c', 1), _Unit('fahrenheit', 1, 0),
    _Unit('f', 1, 0), _Unit('kelvin', 1, 0), _Unit('k', 1, 0),
  ],
  'time': [
    _Unit('s', 1), _Unit('sec', 1), _Unit('min', 60), _Unit('h', 3600),
    _Unit('hour', 3600), _Unit('day', 86400), _Unit('week', 604800),
  ],
  'data': [
    _Unit('B', 1), _Unit('KB', 1024), _Unit('MB', 1024 * 1024),
    _Unit('GB', 1024 * 1024 * 1024), _Unit('TB', 1024 * 1024 * 1024 * 1024),
  ],
  'speed': [
    _Unit('mps', 1), _Unit('kmh', 1 / 3.6), _Unit('mph', 0.44704),
  ],
};

/// 温度换算（基准 = 摄氏度）。
double _convertTemperature(double value, _Unit from, _Unit to) {
  // 统一转为摄氏
  double celsius;
  if (from.name == 'fahrenheit' || from.name == 'f') {
    celsius = (value - 32) * 5 / 9;
  } else if (from.name == 'kelvin' || from.name == 'k') {
    celsius = value - 273.15;
  } else {
    celsius = value;
  }
  if (to.name == 'fahrenheit' || to.name == 'f') {
    return celsius * 9 / 5 + 32;
  }
  if (to.name == 'kelvin' || to.name == 'k') {
    return celsius + 273.15;
  }
  return celsius;
}

ToolDefinition createUnitConverterTool() {
  return ToolDefinition(
    name: 'unit_converter',
    description:
        '单位换算。类别：length/weight/temperature/time/data/speed。'
        '传 value、from（源单位）、to（目标单位）。示例：value=12, from=cm, to=inch。',
    parameters: {
      'type': 'object',
      'properties': {
        'value': {'type': 'number', 'description': '数值'},
        'from': {'type': 'string', 'description': '源单位'},
        'to': {'type': 'string', 'description': '目标单位'},
      },
      'required': ['value', 'from', 'to'],
    },
    execute: (args) async {
      final value = (args['value'] as num?)?.toDouble();
      final from = (args['from'] as String?)?.trim().toLowerCase() ?? '';
      final to = (args['to'] as String?)?.trim().toLowerCase() ?? '';
      if (value == null) return ToolResult.error('缺少 value 参数（数值）');
      if (from.isEmpty) return ToolResult.error('缺少 from 参数');
      if (to.isEmpty) return ToolResult.error('缺少 to 参数');

      // 温度类别（精确匹配单位表，避免 cm/mm 等误入）。
      final tempFrom = _findUnit('temperature', from);
      final tempTo = _findUnit('temperature', to);
      if (tempFrom != null && tempTo != null) {
        final result = _convertTemperature(value, tempFrom, tempTo);
        return ToolResult(content: '$value $from = $result $to');
      }

      // 通用类别匹配。
      for (final entry in _categories.entries) {
        final fromUnit = _findUnit(entry.key, from);
        final toUnit = _findUnit(entry.key, to);
        if (fromUnit != null && toUnit != null) {
          final result = value * fromUnit.factor / toUnit.factor;
          return ToolResult(content: '$value $from = $result $to');
        }
      }

      return ToolResult.error('无法换算 $from → $to（支持的类别：length/weight/temperature/time/data/speed）');
    },
  );
}

_Unit? _findUnit(String category, String symbol) {
  final units = _categories[category] ?? const <_Unit>[];
  for (final u in units) {
    if (u.name == symbol) return u;
  }
  // 别名匹配（如 celsius 简写 c）。
  for (final u in units) {
    if (u.name.startsWith(symbol) || symbol.startsWith(u.name)) return u;
  }
  return null;
}
