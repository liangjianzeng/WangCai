/// dartssh2 错误收口（2026-10-28 真机事故定案）。
///
/// 真机截图：「发送失败: SftpStatusError: No such file(code 2)」+ 对话区一排空气泡。
/// 根因不在业务代码，而在**类型系统**：dartssh2 的 `SSHError` / `SftpError` 都是
/// 裸类（`abstract class SSHError {}`、`class SftpError { ... }`），**没有实现
/// Exception**，于是 Dart 的 `on Exception` 对它们完全不生效 —— 远端少一个
/// AGENTS.md 就能穿过 chat_provider 的「失败静默降级」兜底，把整条消息发送打死。
library;

import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/dev/ssh/ssh_environment.dart';

void main() {
  group('哨兵：dartssh2 的错误不是 Exception（这正是全app 兜底失效的原因）', () {
    test('SftpStatusError 不实现 Exception —— 机检 dartssh2 的坑还在不在', () {
      // 若哪天升级 dartssh2 让它 implements Exception，本用例会红：
      // 那时可以删掉 sshServiceFailure 的包装并简化各处裸 catch。
      expect(SftpStatusError(2, 'No such file'), isNot(isA<Exception>()));
      expect(SSHAuthFailError('Authentication failed'),
          isNot(isA<Exception>()));
      expect(SSHSocketError(const SocketException('boom')),
          isNot(isA<Exception>()));
    });

    test('事故复现：`on Exception` 抓不住它，裸 catch 才拦得住', () async {
      Object? leaked;
      try {
        throw SftpStatusError(2, 'No such file');
      } on Exception catch (_) {
        fail('dartssh2 错误若能被 on Exception 抓到，说明上游已修，请简化收口层');
      } catch (e) {
        leaked = e; // 真机里没人接 ⇒ 一路撞到消息发送
      }
      expect(leaked, isNotNull);
    });
  });

  group('sshServiceFailure：换成 Dart 认识、且说得清的异常', () {
    test('包装后 on Exception 真的能抓到（消息发送不再被打死）', () {
      Object? caught;
      try {
        throw sshServiceFailure(SftpStatusError(2, 'No such file'),
            context: '读不到远端文件 /root/projects/demo/AGENTS.md');
      } on Exception catch (e) {
        caught = e;
      }
      expect(caught, isA<SshServiceException>());
    });

    test('SFTP code 2（真机那条）翻成中文，且不再泄漏类名给用户', () {
      final e = sshServiceFailure(SftpStatusError(2, 'No such file'),
          context: '读不到远端文件 /root/x.md');
      expect(e.message, contains('远端文件或目录不存在'));
      expect(e.message, startsWith('读不到远端文件 /root/x.md：'));
      expect(e.message, contains('code 2'));
      expect(e.message, isNot(contains('SftpStatusError')),
          reason: '英文类名对用户是噪音；原始对象留在 cause 里供日志排障');
      expect(e.cause, isA<SftpStatusError>());
    });

    test('常见 code 各有专属指引（用户能自己下一步）', () {
      String m(int code) => sshServiceFailure(SftpStatusError(code, 'x')).message;
      expect(m(3), contains('权限不足'));
      expect(m(8), contains('Subsystem sftp'), reason: '远端没开 sftp 是常见配错');
      expect(m(4), contains('已存在'));
      expect(m(7), contains('连接中断'));
      expect(m(99), contains('错误码 99'));
    });

    test('SSH 层错误 → 认证/网络两大类', () {
      expect(
          sshServiceFailure(SSHAuthFailError('Authentication failed')).message,
          contains('认证失败'));
      expect(sshServiceFailure(SSHSocketError(const SocketException('x'))).message,
          contains('网络不可达'));
    });

    test('未知错误保留原文，不吞排障线索', () {
      final e = sshServiceFailure(SSHPacketError('bad packet'));
      expect(e.message, contains('远端操作失败'));
      expect(e.message, contains('bad packet'));
    });

    test('SshServiceException.toString 带类型名（日志可 grep）', () {
      expect(const SshServiceException('远端炸了').toString(),
          'SshServiceException: 远端炸了');
    });
  });
}
