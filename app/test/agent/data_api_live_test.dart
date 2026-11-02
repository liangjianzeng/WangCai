import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/builtin_tools/data_api/data_api_tool.dart';

const String _liveEnv = 'TONGYI_LIVE_DATA_API';

void main() {
  final enabled = Platform.environment[_liveEnv] == '1';

  group('data_api live（真实网络，门控）', () {
    test('A股 K线+实时（sz000157 三源热备）', () async {
      final r = await stockProvider()
          .execute({'symbol': 'sz000157', 'action': 'both', 'count': 30});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('"returned":30'));
      expect(r.content, contains('中联重科'));
      expect(r.content, contains('"price":'));
      // 热备有效性：即使腾讯偶发限频，合并后仍应足量或带 note 诊断。
    }, skip: !enabled ? '设置 $_liveEnv=1 启用（会发真实网络请求）' : false);

    test('港股（hk00700）K线', () async {
      final r = await stockProvider()
          .execute({'symbol': 'hk00700', 'action': 'kline', 'count': 5});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('"returned":5'));
    }, skip: !enabled ? '设置 $_liveEnv=1 启用（会发真实网络请求）' : false);
  });
}
