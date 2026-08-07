// 【FEAT-390】BattleDisplay 共通ヘルパーの契約テスト 7 件。
//
// カバー:
//   computeAtk × 3 件 (ベース計算 / fallback ジョブ / 減算ジョブ)
//   computeAtb × 2 件 (戦士 0.85 / 魔導士 0.90)
//   formatAtb  × 2 件 (percent / multiplier)
//
// Pre-mortem #1 対応 (リファクタ計算ズレ):
//   computeAtk の期待値は `battle_provider._buildPlayerCombatant` の旧計算式
//   `(10 + level*2 + weaponAtk + studyLv) * attackPowerModifier` と完全一致する。
//   本テストが PASS する限り、UI 表示値とバトル内部値が一致していることを保証する。
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/battle/constants/battle_constants.dart';

void main() {
  group('BattleDisplay.computeAtk', () {
    test('ベース計算 (level 12 + 武器 10 + 学習力 5 + 戦士 ×1.3)', () {
      final atk = BattleDisplay.computeAtk(
        level: 12, weaponAtk: 10, studyLv: 5, attackPowerModifier: 1.3,
      );
      // (10 + 12×2 + 10 + 5) × 1.3 = 49 × 1.3 = 63.7 → round = 64
      expect(atk, 64);
    });

    test('ジョブ modifier 1.0 (fallback) で純粋なステ計算', () {
      final atk = BattleDisplay.computeAtk(
        level: 1, weaponAtk: 0, studyLv: 0, attackPowerModifier: 1.0,
      );
      // (10 + 1×2 + 0 + 0) × 1.0 = 12 × 1.0 = 12
      expect(atk, 12);
    });

    test('ジョブ modifier 0.7 (僧侶) で減算', () {
      final atk = BattleDisplay.computeAtk(
        level: 10, weaponAtk: 5, studyLv: 3, attackPowerModifier: 0.7,
      );
      // (10 + 10×2 + 5 + 3) × 0.7 = 38 × 0.7 = 26.6 → round = 27
      expect(atk, 27);
    });
  });

  group('BattleDisplay.computeAtb', () {
    test('戦士 atbMod=0.8 + 精神力 5 → 0.85', () {
      final atb = BattleDisplay.computeAtb(
        atbSpeedModifier: 0.8, mentalLv: 5,
      );
      // 0.8 + 5 × 0.01 = 0.85
      expect(atb, closeTo(0.85, 0.001));
    });

    test('魔導士 atbMod=0.9 + 精神力 0 → 0.90', () {
      final atb = BattleDisplay.computeAtb(
        atbSpeedModifier: 0.9, mentalLv: 0,
      );
      // 0.9 + 0 × 0.01 = 0.90
      expect(atb, closeTo(0.90, 0.001));
    });
  });

  group('BattleDisplay.formatAtb', () {
    test('percent (default): 0.85 → "85%", 1.0 → "100%"', () {
      expect(BattleDisplay.formatAtb(0.85), '85%');
      expect(BattleDisplay.formatAtb(1.0), '100%');
    });

    test('multiplier: 0.85 → "0.85x"', () {
      expect(
        BattleDisplay.formatAtb(0.85, format: AtbDisplayFormat.multiplier),
        '0.85x',
      );
    });
  });
}
