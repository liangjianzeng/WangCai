import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/agent.dart';

void main() {
  group('SandboxMode / 升级阶梯（对照 DSH WIDER_MODES）', () {
    test('字符串值与 DSH 一致', () {
      expect(SandboxMode.workspaceWrite.value, 'workspace-write');
      expect(SandboxMode.dangerFullAccess.value, 'danger-full-access');
    });

    test('fromValue 未知值返回 null', () {
      expect(SandboxMode.fromValue('root'), isNull);
      expect(SandboxMode.fromValue('danger-full-access'),
          SandboxMode.dangerFullAccess);
    });

    test('workspace-write → danger-full-access 是严格更宽', () {
      const e = SandboxEscalation(
        requestedMode: SandboxMode.dangerFullAccess,
        justification: '需要读公共目录',
      );
      expect(e.isStrictlyWider, isTrue);
    });

    test('同级/降级不是严格更宽', () {
      const same = SandboxEscalation(
        requestedMode: SandboxMode.workspaceWrite,
        justification: 'x',
      );
      expect(same.isStrictlyWider, isFalse);
      const down = SandboxEscalation(
        requestedMode: SandboxMode.workspaceWrite,
        justification: 'x',
        effectiveMode: SandboxMode.dangerFullAccess,
      );
      expect(down.isStrictlyWider, isFalse);
    });
  });

  group('extractEscalation（对照 DSH validateEscalationArgs）', () {
    test('无 sandbox_permissions → 返回 null', () {
      expect(extractEscalation({'command': 'ls'}), isNull);
    });

    test('单独 justification → FormatException', () {
      expect(
        () => extractEscalation({'justification': '要读文件'}),
        throwsFormatException,
      );
    });

    test('缺 justification → FormatException', () {
      expect(
        () => extractEscalation({'sandbox_permissions': 'danger-full-access'}),
        throwsFormatException,
      );
    });

    test('空 justification → FormatException', () {
      expect(
        () => extractEscalation({
          'sandbox_permissions': 'danger-full-access',
          'justification': '   ',
        }),
        throwsFormatException,
      );
    });

    test('未知模式 → FormatException', () {
      expect(
        () => extractEscalation({
          'sandbox_permissions': 'root',
          'justification': '要读文件',
        }),
        throwsFormatException,
      );
    });

    test('合法请求 → 返回 escalation 对象', () {
      final e = extractEscalation({
        'sandbox_permissions': 'danger-full-access',
        'justification': '需要读取 /sdcard 下的文件',
      });
      expect(e, isNotNull);
      expect(e!.requestedMode, SandboxMode.dangerFullAccess);
      expect(e.justification, contains('/sdcard'));
      expect(e.isStrictlyWider, isTrue);
    });
  });

  group('effectiveModeOf / 内部键传递', () {
    test('无内部键 → 默认 workspace-write', () {
      expect(effectiveModeOf({}), SandboxMode.workspaceWrite);
    });

    test('内部键 → 返回对应模式', () {
      expect(
        effectiveModeOf({kSandboxModeArgKey: 'danger-full-access'}),
        SandboxMode.dangerFullAccess,
      );
    });
  });

  group('拒绝/升级标记（对照 DSH 文案）', () {
    test('sandboxDenialMarker 含模式名', () {
      final marker = sandboxDenialMarker(SandboxMode.workspaceWrite);
      expect(marker, contains('[sandbox: file access denied'));
      expect(marker, contains('workspace-write'));
    });

    test('escalationHintMarker 含升级指引', () {
      final hint = escalationHintMarker('command');
      expect(hint, contains('escalation available'));
      expect(hint, contains('sandbox_permissions'));
      expect(hint, contains('justification'));
    });
  });
}
