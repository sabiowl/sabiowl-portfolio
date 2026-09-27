// 【BUG-147 Phase C (2026-08-20)】疎通確認が認証インターセプタを通らないことを縛る。
//
// ## なぜソース走査なのか
//
// 「認証ヘッダが**付いていない**こと」は起きなかった副作用なので、振る舞い
// テストだけだと「たまたま観測しなかった」と区別しにくい。しかも probe は
// `validateStatus: (_) => true` を使っており、**Dio が 401 をエラー扱いしない**
// ため、`client.dio` に戻しても overlay の挙動は一見変わらない
// (=「動いているように見えるまま壊れる」)。
//
// Phase A / A-2 で backend 側の `authentication_classes = []` を宣言したので
// 今は 401 にならないが、それは backend を直せる場合の話であって、
// **クライアントが probe に認証を混ぜている構造そのもの**は別の穴である。
// 実装の選択を直接縛る。
//
// 同パターン: `habit_increment_inflight_test.dart` (BUG-71) /
// `habit_player_injection_contract_test.dart` (FEAT-524)。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late final String bootGate;
  late final String overlay;

  setUpAll(() {
    final b = File('lib/core/widgets/boot_gate.dart');
    final o = File('lib/core/widgets/connection_error_overlay.dart');
    expect(b.existsSync(), isTrue, reason: 'boot_gate.dart が見つからない');
    expect(o.existsSync(), isTrue, reason: 'connection_error_overlay.dart が見つからない');
    bootGate = b.readAsStringSync();
    overlay = o.readAsStringSync();
  });

  group('BUG-147 Phase C: probe は認証インターセプタ非経由', () {
    test('A: BootGate の health probe が probeDio を使う', () {
      expect(
        RegExp(r'probeDio\.get\(\s*\n?\s*.\/health\/.').hasMatch(bootGate),
        isTrue,
        reason: 'client.dio だと onRequest が認証ヘッダを付け、端末に古い '
            'トークンが残っていると /health/ が 401 になる',
      );
    });

    test('B: 再試行ボタンが probeDio を使う', () {
      expect(
        RegExp(r'probeDio\.get\(\s*\n?\s*.\/health\/.').hasMatch(overlay),
        isTrue,
        reason: '脱出のためのボタンが、脱出できない原因そのものを再現していた',
      );
    });

    test('C: どちらも `.dio.get(\'/health/\')` を残していない', () {
      // 【負の検証で守るもの】`probeDio` を足したうえで旧経路も残っていると、
      // 片方だけ直った状態に気付けない。
      final bad = <String>[];
      for (final entry in {'boot_gate': bootGate, 'overlay': overlay}.entries) {
        if (RegExp(r'(?<!probe)Dio\.get\(|\.dio\.get\(').hasMatch(entry.value)) {
          bad.add(entry.key);
        }
      }
      expect(bad, isEmpty,
          reason: '認証付き Dio で /health/ を叩いている箇所が残っている: $bad');
    });

    test('D: probeDio の定義に interceptor を足していない', () {
      final api = File('lib/core/api/api_client.dart').readAsStringSync();
      final m = RegExp(r'Dio get probeDio \{[\s\S]*?\n  \}').firstMatch(api);
      expect(m, isNotNull, reason: 'probeDio getter が見つからない');
      expect(
        m!.group(0)!.contains('interceptors'), isFalse,
        reason: 'probeDio に interceptor を足すと Phase C の意味が消える',
      );
    });
  });
}
