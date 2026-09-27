// 【FEAT-526 (2026-08-22)】KO ハプティクスの契約テスト。
//
// 勝利の手応えとして `playUltimateHit` の流用をやめ、専用の `playKoFinish` を
// 新設した。両者の違いは **終わり方** である。
//
//   ultimateHit : タメ → 最強パルス → **減衰**して消える （= 強く当たった）
//   koFinish    : 一撃 → **間** → **上昇**する 3 連で終わる（= 勝った）
//
// 触覚はテストで「感じ」を検証できないので、縛るのは 3 点:
//   A. Dart / Android / iOS の 3 面に `koFinish` が揃っていること
//   B. 波形の骨格（一撃 → 無音 → 上昇）が保たれていること
//   C. 必殺技がとどめだったときに `ultimateHit` と二重に打たないこと

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) {
  final f = File(path);
  expect(f.existsSync(), isTrue, reason: '$path が見つからない (cwd 不一致?)');
  return f.readAsStringSync();
}

void main() {
  group('FEAT-526 A: 3 面に koFinish が揃っている', () {
    test('Dart 側に playKoFinish がある', () {
      final src =
          _read('lib/features/battle/services/battle_haptics_service.dart');
      expect(src, contains('Future<void> playKoFinish()'));
      expect(src, contains("_invokeNative('koFinish')"));
    });

    test('Android 側に koFinish ハンドラと波形がある', () {
      final src = _read(
          '../mobile/android/app/src/main/kotlin/com/sabiowl/app/MainActivity.kt');
      expect(src, contains('"koFinish"'), reason: 'MethodChannel の分岐');
      expect(src, contains('private fun playKoFinish'));
    });

    test('iOS 側に koFinish ハンドラと波形がある', () {
      // ⚠️ Swift は Windows ではコンパイルできないので、ここで綴りだけでも縛る。
      // 3 面のうち 1 面だけ足し忘れると、その OS だけ静かにフォールバックする。
      final src = _read('../mobile/ios/Runner/AppDelegate.swift');
      expect(src, contains('case "koFinish"'));
      expect(src, contains('private func playKoFinish'));
    });
  });

  group('FEAT-526 B: 波形の骨格 (一撃 → 間 → 上昇)', () {
    test('Android: 無音を挟み、振幅が上昇して終わる', () {
      final src = _read(
          '../mobile/android/app/src/main/kotlin/com/sabiowl/app/MainActivity.kt');
      final body = src.substring(src.indexOf('private fun playKoFinish'));
      final amps = RegExp(r'intArrayOf\(([^)]*)\)').firstMatch(body);
      expect(amps, isNotNull, reason: '振幅配列が見つからない');
      final values = amps!
          .group(1)!
          .split(',')
          .map((e) => int.parse(e.trim()))
          .toList();

      expect(values.first, 255, reason: 'とどめの一撃は最強で始まる');
      expect(values.contains(0), isTrue,
          reason: '🔴 真ん中の無音 (ヒットストップの「間」) が骨格');
      // 無音の後ろ = 祝祭パート。単調増加であること。
      final tail = values.sublist(values.lastIndexOf(0) + 1);
      expect(tail, isNotEmpty);
      final celebration =
          values.where((v) => v > 0).skip(1).toList(); // 先頭の一撃を除く
      expect(celebration, celebration.toList()..sort(),
          reason: '祝祭は上昇して終わる (減衰させると ultimateHit と同じ意味になる)');
      expect(celebration.last, 255, reason: '最後がいちばん強い');
    });

    test('iOS: 一撃の後に間があり、intensity が上昇して終わる', () {
      final src = _read('../mobile/ios/Runner/AppDelegate.swift');
      final body = src.substring(src.indexOf('private func playKoFinish'));
      final times = RegExp(r'relativeTime:\s*([0-9.]+)')
          .allMatches(body)
          .map((m) => double.parse(m.group(1)!))
          .toList();
      expect(times.first, 0.0, reason: 'とどめは t=0');
      expect(times.length, greaterThanOrEqualTo(4), reason: '一撃 + 祝祭 3 連');
      expect(times[1] - times[0], greaterThanOrEqualTo(0.12),
          reason: '🔴 一撃と祝祭の間に「間」があること (120ms 以上)');

      final intensities = RegExp(r'\.hapticIntensity, value:\s*([0-9.]+)')
          .allMatches(body)
          .map((m) => double.parse(m.group(1)!))
          .toList();
      final celebration = intensities.skip(1).toList();
      expect(celebration, celebration.toList()..sort(),
          reason: '祝祭は上昇して終わる');
      expect(celebration.last, 1.0, reason: '最後がいちばん強い');
    });

    test('Dart フォールバックも 間 → 上昇 の形をしている', () {
      final src =
          _read('lib/features/battle/services/battle_haptics_service.dart');
      final body = src.substring(src.indexOf('Future<void> playKoFinish()'));
      final delays = RegExp(r'milliseconds:\s*(\d+)')
          .allMatches(body)
          .map((m) => int.parse(m.group(1)!))
          .toList();
      expect(delays.first, greaterThanOrEqualTo(150),
          reason: '一撃の直後に「間」を置く');
      // heavy → light → medium → heavy の順 (上昇)
      final order = RegExp(r'HapticFeedback\.(\w+)Impact')
          .allMatches(body)
          .map((m) => m.group(1)!)
          .toList();
      expect(order, ['heavy', 'light', 'medium', 'heavy']);
    });
  });

  group('FEAT-526 C: 🔴 必殺技がとどめでも二重に重ねない', () {
    // `koFinish` の先頭には強い一撃が入っているので、`ultimateHit` を重ねても
    // とどめの重さは増えず、2 つの波形が濁るだけ。
    //
    // 【2026-08-22 追記】**視覚も同じ**だった。撃墜エフェクトの白フラッシュ
    // (alpha 0.6 / 350ms) が KO 演出の前半を覆い隠し、3 倍速では丸ごと
    // 飲み込む。当初はハプティクスにだけガードを掛けていたので、
    // **視覚と振動を 1 つのガードでまとめて縛る**。
    //
    // ガードの書き方は問わない (`!=` の条件でも `==` の early return でも
    // 意図は同じ)。**呼び出しの手前に won の判定があること**だけを見る。
    bool guarded(String src, String call) {
      final at = src.indexOf(call);
      expect(at, greaterThan(-1), reason: '$call が見つからない');
      final before = src.substring(at < 500 ? 0 : at - 500, at);
      return before.contains('status != BattleStatus.won') ||
          before.contains('status == BattleStatus.won) return');
    }

    test('battle_page: 必殺ハプティクスに won ガードがある', () {
      final src = _read('lib/features/battle/pages/battle_page.dart');
      // コメント中の言及ではなく **実際の呼び出し** を探す
      expect(guarded(src, 'instance.playUltimateHit'), isTrue);
    });

    test('🔴 battle_page: 必殺の視覚エフェクトにも同じガードがある', () {
      // ここが抜けていたのが「全画面だけ KO 演出が見えない」の原因
      // (指示書 §7.5)。白フラッシュは全画面に掛かるので、KO 演出の
      // ヒットストップとズームインが丸ごと白飛びする。
      final src = _read('lib/features/battle/pages/battle_page.dart');
      expect(guarded(src, '_ultimateHitEffect.fire()'), isTrue,
          reason: 'ハプティクスだけ直して視覚を忘れた、が実際に起きた');
    });

    test('mini_battle_arena: 必殺ハプティクスに won ガードがある', () {
      final src = _read('lib/features/battle/widgets/mini_battle_arena.dart');
      expect(guarded(src, 'instance.playUltimateHit'), isTrue);
    });

    test('額縁には撃墜エフェクトが無い (差分はここだけ)', () {
      // 「額縁では KO が見えるのに全画面では見えない」の切り分けはここが根拠。
      // 額縁に足すなら、同じ won ガードを掛けること。
      final src = _read('lib/features/battle/widgets/mini_battle_arena.dart');
      expect(src.contains('UltimateHitEffect'), isFalse);
    });

    test('KO 側は playKoFinish を使い、playUltimateHit を流用していない', () {
      for (final path in [
        'lib/features/battle/pages/battle_page.dart',
        'lib/features/battle/widgets/mini_battle_arena.dart',
      ]) {
        final src = _read(path);
        final at = src.indexOf('_maybeFireKo');
        final body = src.substring(at, src.indexOf('}', src.indexOf('{', at)) + 400);
        expect(body, contains('playKoFinish'), reason: path);
      }
    });
  });
}
