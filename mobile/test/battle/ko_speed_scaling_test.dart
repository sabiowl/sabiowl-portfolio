// 【FEAT-526 (2026-08-21)】KO 演出の倍速追従テスト (指示書 §4.6 / Pre-mortem #5)。
//
// 決定事項 1:「演出も倍速に合わせて短縮。ただし潰れすぎないよう下限を設ける」。
//
// 🔴 下限が要る理由: 3 倍速だとヒットストップが 80/3 = 27ms になり、
// 描画 2 フレーム分で **「止まった」と認識できない**。逆に下限を大きく取りすぎると
// 倍速の意味が薄れるので 40ms に留める。
//
// この 2 つは相反するので **両方向から縛る** —— 「下回らない」だけだと下限を
// 1000ms にしても通ってしまい、倍速が効かなくなったことに気付けない。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/battle/constants/battle_constants.dart';

void main() {
  group('FEAT-526 koScaled — 倍速追従と下限', () {
    test('等速では base をそのまま返す', () {
      for (final d in [
        BattleConstants.koTotalDuration,
        BattleConstants.koHitStopDuration,
        BattleConstants.koZoomInDuration,
        BattleConstants.koLabelDuration,
        BattleConstants.koZoomOutDuration,
      ]) {
        expect(BattleConstants.koScaled(d, 1.0), d);
      }
    });

    test('3 倍速で各区間が 1/3 になる (下限に掛からないもの)', () {
      // 具体値ではなく **関係** を書く。定数を調整するたびに
      // テストの数字を直す羽目になると、テストが仕様の写経になる。
      for (final d in [
        BattleConstants.koTotalDuration,
        BattleConstants.koLabelDuration,
      ]) {
        expect(BattleConstants.koScaled(d, 3.0).inMilliseconds,
            (d.inMilliseconds / 3).round(),
            reason: '下限に掛からない長さは素直に 1/3 になる');
      }
      expect(BattleConstants.koScaled(BattleConstants.koZoomInDuration, 3.0),
          const Duration(milliseconds: 40)); // 120 / 3 = ちょうど下限
    });

    test('1.5x / 2x でも素直に割られる', () {
      for (final speed in [1.5, 2.0]) {
        expect(
            BattleConstants.koScaled(BattleConstants.koTotalDuration, speed)
                .inMilliseconds,
            (BattleConstants.koTotalDuration.inMilliseconds / speed).round());
      }
    });

    test('🔴 3 倍速のヒットストップは下限 40ms に張り付く (27ms にしない)', () {
      final scaled =
          BattleConstants.koScaled(BattleConstants.koHitStopDuration, 3.0);
      expect(scaled, BattleConstants.koMinDuration);
      expect(scaled.inMilliseconds, 40);
      expect(
        BattleConstants.koHitStopDuration.inMilliseconds / 3,
        lessThan(40),
        reason: '素直に割ると下限を割る = 下限が実際に効いている状況',
      );
    });

    test('🔴 どの倍速でも下限を下回らない', () {
      for (final speed in [1.0, 1.5, 2.0, 3.0, 50.0]) {
        for (final d in [
          BattleConstants.koTotalDuration,
          BattleConstants.koHitStopDuration,
          BattleConstants.koZoomInDuration,
          BattleConstants.koLabelDuration,
          BattleConstants.koZoomOutDuration,
          BattleConstants.koShakeDuration,
        ]) {
          expect(
            BattleConstants.koScaled(d, speed).inMilliseconds,
            greaterThanOrEqualTo(BattleConstants.koMinDuration.inMilliseconds),
            reason: 'speed=$speed / base=${d.inMilliseconds}ms',
          );
        }
      }
    });

    test('🔴 下限が大きすぎない — 倍速が効かなくなっていないこと', () {
      // 下限だけを縛ると「下限 = 1000ms」でも通る。**倍速で実際に短くなる**
      // ことを同時に縛って、下限の引き上げによる degrade を検出する。
      expect(
        BattleConstants.koScaled(BattleConstants.koTotalDuration, 3.0),
        lessThan(BattleConstants.koTotalDuration),
      );
      expect(
        BattleConstants.koScaled(BattleConstants.koTotalDuration, 3.0)
            .inMilliseconds,
        lessThanOrEqualTo(BattleConstants.koTotalDuration.inMilliseconds ~/ 2),
        reason: '3 倍速なら少なくとも半分以下にはなる',
      );
      expect(BattleConstants.koMinDuration.inMilliseconds, lessThanOrEqualTo(60),
          reason: '下限が 60ms を超えると 3 倍速の体感が等速に近づく');
    });

    test('speedMultiplier が 0 / 負でも固まらない (等速扱い)', () {
      expect(BattleConstants.koScaled(BattleConstants.koTotalDuration, 0.0),
          BattleConstants.koTotalDuration);
      expect(BattleConstants.koScaled(BattleConstants.koTotalDuration, -1.0),
          BattleConstants.koTotalDuration);
    });
  });

  group('FEAT-526 §4.7 パラメータが定数に出ている', () {
    test('区間の合計が演出全体の長さと一致する', () {
      final sum = BattleConstants.koHitStopDuration +
          BattleConstants.koZoomInDuration +
          BattleConstants.koLabelDuration +
          BattleConstants.koZoomOutDuration;
      expect(sum, BattleConstants.koTotalDuration,
          reason: '内訳がずれると演出の途中で止まる / 余る');
    });

    test('値が意図どおり (変えるときはここも一緒に直す)', () {
      // 【2026-08-22 ユーザー判断 (2 回目)】「K.O.」が一瞬すぎるとの実機判断で
      // 320 → 1000 → 1500ms。出典 (`KO.md`) の 250〜400ms から意図的に外れている。
      expect(BattleConstants.koTotalDuration.inMilliseconds, 1830);
      expect(BattleConstants.koHitStopDuration.inMilliseconds, 80);
      expect(BattleConstants.koLabelDuration.inMilliseconds, 1500);
      expect(BattleConstants.koMaxZoom, 1.20); // 1.15〜1.30 の中央
      expect(BattleConstants.koMinDuration.inMilliseconds, 40);
    });

    test('🔴 「K.O.」は等速で 1.5 秒読める', () {
      // ユーザー要望の本体。ここが縮むと「一瞬すぎる」に戻る。
      expect(BattleConstants.koLabelDuration.inMilliseconds,
          greaterThanOrEqualTo(1400));
    });

    test('🔴 インパクトリングの実時間が伸びていない (比で持っているので要注意)', () {
      // `koImpactFraction` は**比**なので、全体を伸ばすとリングも伸びる。
      // 衝撃が余韻に化けるので、実時間 300ms 前後に収まっていること。
      final ringMs = BattleConstants.koTotalDuration.inMilliseconds *
          BattleConstants.koImpactFraction;
      expect(ringMs, lessThan(350));
      expect(ringMs, greaterThan(200));
    });

    test('🔴 アンビエントの次戦待ちが KO 演出より短くならない', () {
      // 以前は「2 秒固定に収まること」を縛っていたが、演出を伸ばすたびに
      // 余裕が削れていく (1.33 秒で残り 670ms → 1.83 秒で残り 170ms)。
      // **定数を縛るのをやめ、orchestrator 側を「長いほうを待つ」に変えた。**
      // ここではその実装が残っていることを見る。
      final f = File(
          'lib/features/battle/services/ambient_auto_battle_orchestrator.dart');
      expect(f.existsSync(), isTrue, reason: 'cwd 不一致?');
      final src = f.readAsStringSync();
      expect(src, contains('BattleConstants.koScaledTotal('),
          reason: '2 秒固定に戻すと、演出を伸ばした瞬間に額縁が途中で切り替わる');
      expect(src, contains('koTotal > roundTrip ? koTotal : roundTrip'),
          reason: 'round-trip と演出の長いほうを待つこと');
    });

    test('シェイクは演出全体より短い (短時間・1 回)', () {
      expect(BattleConstants.koShakeDuration,
          lessThan(BattleConstants.koTotalDuration));
      expect(BattleConstants.koShakeAmplitude, greaterThan(0));
    });
  });

  // ── 【2026-08-22 実機報告】下限が全体側で打ち消されていた ──────────────
  //
  // 🔴 演出全体の長さに `koScaled(koTotalDuration, speed)` を使っていたのが誤り。
  // 下限 [BattleConstants.koMinDuration] は **区間ごと**に掛かるので、全体を
  // 単純に割ると **区間の合計より短くなり、せっかくの下限が無効化される**。
  //
  //   ⏭ Skip (50x): 区間の合計 160ms に対し koScaled(650, 50) = 40ms
  //   → 演出全体が 60fps で 2.4 フレーム、「K.O.」は 10ms = 実質見えない
  group('FEAT-526 koScaledTotal — 全体の長さは区間の積み上げ', () {
    Duration sumOfPhases(double speed) =>
        BattleConstants.koScaled(BattleConstants.koHitStopDuration, speed) +
        BattleConstants.koScaled(BattleConstants.koZoomInDuration, speed) +
        BattleConstants.koScaledLabel(speed) +
        BattleConstants.koScaled(BattleConstants.koZoomOutDuration, speed);

    test('等速では koTotalDuration と一致する (既存の見た目を変えない)', () {
      expect(BattleConstants.koScaledTotal(1.0), BattleConstants.koTotalDuration);
    });

    test('🔴 どの倍速でも「区間の合計」と一致する', () {
      for (final speed in [1.0, 1.5, 2.0, 3.0, 10.0, 50.0]) {
        expect(BattleConstants.koScaledTotal(speed), sumOfPhases(speed),
            reason: '$speed 倍速で全体と内訳がずれると、下限が効かなくなる');
      }
    });

    test('🔴 高倍速で koScaled(全体) より長い = 下限が生きている', () {
      // ここが等しくなったら退行 (下限が打ち消されている)。
      for (final speed in [3.0, 50.0]) {
        expect(
          BattleConstants.koScaledTotal(speed).inMilliseconds,
          greaterThan(
            BattleConstants.koScaled(BattleConstants.koTotalDuration, speed)
                .inMilliseconds,
          ),
          reason: '$speed 倍速では区間の下限が効くので、全体は単純割りより長くなる',
        );
      }
    });

    test('⏭ Skip (50x) でも 3 区間ぶんの下限 + ラベル全長は確保される', () {
      expect(
        BattleConstants.koScaledTotal(50.0).inMilliseconds,
        BattleConstants.koMinDuration.inMilliseconds * 3 +
            BattleConstants.koLabelDuration.inMilliseconds,
      );
    });

    test('倍速が効かなくなっていない (等速より必ず短い)', () {
      for (final speed in [1.5, 2.0, 3.0, 50.0]) {
        expect(BattleConstants.koScaledTotal(speed),
            lessThan(BattleConstants.koScaledTotal(1.0)));
      }
    });
  });


  group('FEAT-526 演出 overlay が koScaledTotal を使っている', () {
    test('🔴 koScaled(koTotalDuration) を直接使っていない', () {
      // 使うと区間ごとの下限が打ち消され、⏭ Skip で演出が 40ms に潰れる。
      final f = File('lib/features/battle/widgets/ko_effect_overlay.dart');
      expect(f.existsSync(), isTrue, reason: 'cwd 不一致?');
      final src = f.readAsStringSync();
      expect(src, contains('BattleConstants.koScaledTotal(_speed)'),
          reason: '演出全体の長さは区間の積み上げで決めること');
      expect(src.contains('koScaled(BattleConstants.koTotalDuration'), isFalse,
          reason: '全体を単純割りすると下限が無効になる');
    });
  });

  // ── 【2026-08-22 実機報告 (2)】⏭ Skip で「K.O.」が読めない ──────────────
  //
  // 🔴 全区間を一律に倍速で割っていたのが誤り。区間には性質が 2 種類ある:
  //
  //   感じる区間 (ヒットストップ / ズーム / シェイク) … 割ってよい
  //   読む区間   (「K.O.」ラベル)                    … 割ってはいけない
  //
  // 倍速は「**戦闘の進行**を速く見たい」であって「**結果を読む時間**を削りたい」
  // ではない。ラベルを割ると、速くするほど何が起きたか分からなくなる。
  //
  // 経緯: 全区間を割る → Skip で読めないのでラベル専用の下限 400ms → 実機判断で
  // **倍速でも 1.5 秒**に確定 (下限で近似するより素直)。
  group('FEAT-526 koScaledLabel — ラベルは倍速の対象外', () {
    test('🔴 どの倍速でも 1.5 秒のまま', () {
      for (final speed in [1.0, 1.5, 2.0, 3.0, 50.0]) {
        expect(BattleConstants.koScaledLabel(speed),
            BattleConstants.koLabelDuration,
            reason: '$speed 倍速でラベルが縮んでいる (速いほど読めなくなる)');
      }
    });

    test('🔴 ⏭ Skip (50x) でも「K.O.」が 1.5 秒出る', () {
      // これがユーザー報告の本体。かつては 40ms = 60fps で 2.4 フレームだった。
      expect(BattleConstants.koScaledLabel(50.0).inMilliseconds, 1500);
    });

    test('異常値 (0 / 負) でも 1.5 秒 (割り算に触れないので固まりようがない)', () {
      expect(BattleConstants.koScaledLabel(0.0),
          BattleConstants.koLabelDuration);
      expect(BattleConstants.koScaledLabel(-1.0),
          BattleConstants.koLabelDuration);
    });

    test('⚠️ ⏭ Skip の演出全体は 1620ms —— 承知の上の代償', () {
      // Skip は「バトルを 1-2 秒で終える」機能なので、**戦闘が一瞬で終わった
      // 後に 1.6 秒の演出が乗る**。「読めないより待つほうがまし」という判断。
      // ここが変わったら、それは意図の変更なので指示書 §7.8 も直すこと。
      expect(BattleConstants.koScaledTotal(50.0).inMilliseconds, 1620);
    });

    test('🔴 overlay がラベルに koScaledLabel を使っている', () {
      // ここで `koScaled(koLabelDuration)` に戻すと Skip で 40ms に潰れる。
      // しかも `koScaledTotal` 側は 1500ms で計算しているので**区間がずれる**。
      final f = File('lib/features/battle/widgets/ko_effect_overlay.dart');
      expect(f.existsSync(), isTrue, reason: 'cwd 不一致?');
      final src = f.readAsStringSync();
      expect(src, contains('BattleConstants.koScaledLabel(_speed)'));
      expect(src.contains('ms(BattleConstants.koLabelDuration)'), isFalse,
          reason: 'ラベルを倍速で割ると Skip で読めなくなる');
    });
  });
}
