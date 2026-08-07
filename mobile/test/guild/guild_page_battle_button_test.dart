// 【FEAT-306 Phase 2】「参加する」ボタン enable/disable 制御の契約テスト 3 件。
// 【FEAT-406 (2026-06-01)】chargesPerBattle 1 → 3 に戻したため、シナリオ A/B の数値を
// 新仕様に合わせて更新 (3 達成 = 1 戦参加可能、旧 FEAT-295 思想復活)。
//
// 検証対象（指示書 §3 Phase 2 / §2.3）:
//   - A: battleCharges=3 + Lv 解禁済 → enabled (chargesPerBattle=3 で境界値)
//   - B: battleCharges=0 + Lv 解禁済 → disabled、サブテキスト「あと 3 回の達成で出陣可能」
//   - C: Lv 未達 → disabled、サブテキスト「Lv.XX で解禁」(charges に関係なく Lv 優先)
//
// `_BossQuestCard` widget 自体は私的 (`_` prefix)、Provider 経由の Riverpod 連動を
// 全モックすると setup コストが過剰なため、本テストは「enabled / 表示文字列の
// 算出ロジック」を boolean 表で縛る。実機ボタンの押下挙動は TestFlight 検証 D/E
// シナリオで担保。

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/battle/constants/battle_constants.dart';

void main() {
  // 実装と同じ enable 算出ロジック（_BossQuestCard.build の冒頭と同等）。
  bool isEnabled({
    required int playerLevel,
    required int enemyUnlockLevel,
    required int battleCharges,
  }) {
    final isLocked = enemyUnlockLevel > 0 && playerLevel < enemyUnlockLevel;
    final canBattle = battleCharges >= BattleConstants.chargesPerBattle;
    return !isLocked && canBattle;
  }

  /// 実装と同じ「disabled 理由」分岐（_BattleChargeSubtext.build と同等）。
  String disabledReason({
    required int playerLevel,
    required int enemyUnlockLevel,
    required int battleCharges,
  }) {
    final isLocked = enemyUnlockLevel > 0 && playerLevel < enemyUnlockLevel;
    if (isLocked) return 'Lv.$enemyUnlockLevel で解禁';
    final remaining = (BattleConstants.chargesPerBattle - battleCharges)
        .clamp(0, BattleConstants.chargesPerBattle);
    return 'あと $remaining 回の達成で出陣可能 🪶';
  }

  group('FEAT-306 「参加する」ボタン enable 制御契約', () {
    // ── シナリオ A ───────────────────────────────────────────────
    test('シナリオ A: battleCharges=3 + Lv 解禁済 → enabled '
        '(FEAT-406: chargesPerBattle=3)', () {
      final enabled = isEnabled(
        playerLevel: 20,
        enemyUnlockLevel: 15,
        battleCharges: BattleConstants.chargesPerBattle, // = 3 (FEAT-406)
      );
      expect(enabled, isTrue,
          reason: 'チャージ満たす (3) + Lv 解禁済 → 押下可能');
    });

    // ── シナリオ B ───────────────────────────────────────────────
    test('シナリオ B: battleCharges=0 + Lv 解禁済 → disabled + '
        '「あと 3 回の達成で出陣可能 🪶」 (FEAT-406: chargesPerBattle=3)', () {
      final enabled = isEnabled(
        playerLevel: 20,
        enemyUnlockLevel: 15,
        battleCharges: 0,
      );
      expect(enabled, isFalse,
          reason: 'チャージ未満 (0 < 3) → disabled');

      final reason = disabledReason(
        playerLevel: 20,
        enemyUnlockLevel: 15,
        battleCharges: 0,
      );
      expect(reason, contains('あと 3 回'));
      expect(reason, contains('🪶'),
          reason: 'サビ口調マーカー必須');
    });

    // ── シナリオ C ───────────────────────────────────────────────
    test('シナリオ C: Lv 未達 → disabled + 「Lv.XX で解禁」 '
        '(Lv 未達は battleCharges より優先)', () {
      // charges 満たしても Lv 未達なら disabled
      final enabled = isEnabled(
        playerLevel: 10, // 未達
        enemyUnlockLevel: 15,
        battleCharges: BattleConstants.chargesPerBattle, // = 3 (FEAT-406)
      );
      expect(enabled, isFalse,
          reason: 'Lv 未達は charges 満たすより優先 → disabled');

      final reason = disabledReason(
        playerLevel: 10,
        enemyUnlockLevel: 15,
        battleCharges: BattleConstants.chargesPerBattle,
      );
      expect(reason, 'Lv.15 で解禁',
          reason: 'Lv 未達理由が優先表示（charges 理由ではない）');
    });

    // ── 補助: enemyUnlockLevel=0 (常時解禁) ─────────────────────
    test('補助: enemyUnlockLevel=0 (常時解禁) は Lv 1 でも isLocked にならない '
        '(chargesPerBattle=3 満たすこと)', () {
      final enabled = isEnabled(
        playerLevel: 1,
        enemyUnlockLevel: 0,
        battleCharges: BattleConstants.chargesPerBattle, // = 3 (FEAT-406)
      );
      expect(enabled, isTrue,
          reason: 'unlockLevel=0 は既存 5 体 (FEAT-302 退行ゼロ) の挙動');
    });

    // ── 補助: battleCharges=1 (途中) は charges 不足で disabled ─────
    test('補助: battleCharges=1 + Lv 解禁済 → disabled (3 達成未満)', () {
      final enabled = isEnabled(
        playerLevel: 20,
        enemyUnlockLevel: 15,
        battleCharges: 1, // < chargesPerBattle=3
      );
      expect(enabled, isFalse, reason: '1 < 3 → disabled');

      final reason = disabledReason(
        playerLevel: 20,
        enemyUnlockLevel: 15,
        battleCharges: 1,
      );
      expect(reason, contains('あと 2 回'), reason: 'remaining = 3 - 1 = 2');
    });
  });
}
