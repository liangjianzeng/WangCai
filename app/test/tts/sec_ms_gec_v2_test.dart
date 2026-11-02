import 'package:edge_tts/src/constants.dart';
import 'package:edge_tts/src/drm.dart';
import 'package:edge_tts/src/gec_v2.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sec-MS-GEC **v2** token golden 校验。
///
/// 背景：2026-10-10 起微软免费 readaloud 端点强制 v2 token，v1（纯 SHA-256）
/// 一律 403 —— 表现为「TTS 完全没声音」。v2 是魔改 SHA-256 + CS64，移植自上游
/// python edge-tts PR #492，任何一个常量/移位写错都只会得到「服务端 403」这种
/// 静默结果，所以必须用抓包 golden 值钉死，不能只测「跑得出字符串」。
///
/// golden 值来源：上游 PR #492 的抓包值 + 上游 drm.py 参考实现对同一时间戳的
/// 输出（`generate_sec_ms_gec_v2(unix)`，含 0 与随机时间戳）。
void main() {
  // <unix 秒, 期望 token>
  const golden = <int, String>{
    // 上游 PR #492 抓包实锤值（Edge 155，2026-10-13T10:40:00Z 窗口）
    1791888000:
        '492D7694A183A45E-56E821F95D4579C5B7C7E33DC7303FF379EC36D510213555BBBB9EB17EF15876',
    0: '52BC7A17B50DFEC9-28C4394775C8751CD2F6859C030C06DB1489ACAB3B3A7651831FC26895177ED6',
    999999999:
        '5E9153719FADA922-14D2A75113EC5862E17303287DCDB197E3A671DF9FCC53C100D6B27928384B98',
    1234567890:
        'BA405D1577B8E0CE-61F01E88539977A1A1E969572D82EECFA45FB1E5DEBD122D6ACBAF0054F959E5',
    1760000000:
        '6D50DDDB91812C33-DD68EFB01898B0750C9797D51A5FF93471DFDAE6888A1039D532CBDCCE54545D',
    1760000300:
        'BAF4076F572BFE4E-2D6FBE5C0E24F56622EB94F37395F2D153C6C0C451DAAE2249A459BB3AFAD62C',
    1846809161:
        'F22A0A239FE26927-C8D2BB1AA41DCC1CFE41FD029EC43D32C76C285CACD76A84CD21BBA087563DCE',
    1768428921:
        'E82DE7D89BE7B886-3D5FD1567F38F83E4935F05043FDE2E1721A424399BB2FDF19E4B799FF1519DB',
    1714153003:
        '72F74C9637192BC7-6D9BFE7CB2D872140D83341CDDFCA37FC4703C64D3F641C40E2ED29E12C5E8CF',
    1858436640:
        'BCC0C9B0A03447AA-BD7DFCA99A95064CC56954FDA3E1EF1086405E5ED3B8AA8DDBD69DAE9006BFD4',
    1633481396:
        '7521662FD7D15A5C-10026AD61001189DC868AA0EAFD06DF956C5040CBFA1FEC95EFA8C7710F8D6FA',
    1865863138:
        'FF8F53C66B8E6294-1D254FECFDCA23E01C6FA0A98DEB69849D4FBDBE5D12365C48F1563318F83DF1',
    1643948984:
        '3FE8B28550F05854-98DB8366C09EF5B4C5571CE82DB43564DCD54A20C8D4CA1B2BAD49BD298DF5B0',
    1679469777:
        '72777D1A7920A76B-3C202B5C308CEC8DC499975BFEABC2B8A992AB351CF3D97C3A6C713B48370253',
  };

  test('v2 token 与上游参考实现逐字节一致（golden）', () {
    golden.forEach((unix, expected) {
      expect(generateSecMsGecV2(unix, trustedClientToken), equals(expected),
          reason: 'unix=$unix 的 v2 token 与上游 drm.py 不一致');
    });
  });

  test('token 形状 = <16hex>-<64hex>，且随 5 分钟窗口变化、同窗口内稳定', () {
    final t = generateSecMsGecV2(1791888000, trustedClientToken);
    expect(RegExp(r'^[0-9A-F]{16}-[0-9A-F]{64}$').hasMatch(t), isTrue);
    // 同一 5 分钟窗口（1791888000 与 1791888299 同窗）→ 同 token
    expect(generateSecMsGecV2(1791888299, trustedClientToken), equals(t));
    // 跨窗口 → 变 token
    expect(generateSecMsGecV2(1791888300, trustedClientToken), isNot(equals(t)));
  });

  test('Sec-MS-GEC-Version 前缀必须是 2-（与 token 成对切换，否则服务端 403）',
      () {
    expect(secMsGecVersion, startsWith('2-'));
  });

  test('默认 token 走 v2（形状含连字符，不是 v1 的裸 64 hex）', () {
    final t = generateSecMsGec();
    expect(RegExp(r'^[0-9A-F]{16}-[0-9A-F]{64}$').hasMatch(t), isTrue,
        reason: 'generateSecMsGec() 必须返回 v2 token，否则合成端点 403 全哑');
    expect(generateSecMsGecV1(), matches(RegExp(r'^[0-9A-F]{64}$')));
  });
}
