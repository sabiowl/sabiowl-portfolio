// 【FEAT-521 Phase 1 (2026-08-07)】`BattleDisplay.computeAtk` の式を構造的に縛る。
//
// ## なぜ Dart 側からこれを縛るのか
//
// `backend/api/admin.py` の `EnemyAdmin` は「想定撃数」列を出すために
// **基準プレイヤーの攻撃力モデル**を持っている:
//
//     基準 ATK(Lv) = 20 + Lv × 2
//
// これは Dart の `computeAtk(level, weaponAtk, studyLv, attackPowerModifier)` に
//   weaponAtk = 10 (starter_sword) / studyLv = 0 / attackPowerModifier = 1.0
// を入れて 1 つの仮定に畳んだ結果である (Dart の式全体を移植したものではない)。
//
// つまり **Backend の admin は Dart の式に依存しているが、Dart からは見えない**。
// 係数 (`10` / `level * 2`) や starter_sword の `atkBonus` が変わっても、
// admin は何事もなく古いモデルで計算し続け、**数字が黙って嘘になる**
// (FEAT-521 Pre-mortem #2)。
//
// Backend から Dart を読むテストは書けない (CI の実行単位が別)。
// **Dart 側から「Python も直せ」と叫ばせる向きだけが機能する。**
//
// 同パターン: `test/habits/habit_card_period_count_test.dart` /
// `test/category_strings_truth_test.dart`。
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/battle/battle_display_formula_contract_test.dart
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/features/battle/constants/battle_constants.dart';

/// 失敗時に必ず出す文言。Backend 側のファイルを**名指し**する。
const _fixBackendToo = '\n'
    '───────────────────────────────────────────────────────────\n'
    '式を変えたなら、backend/api/admin.py の EnemyAdmin にある\n'
    '想定撃数モデル (_BASELINE_ATK_INTERCEPT / _BASELINE_ATK_PER_LEVEL) も\n'
    '同じコミットで直してください。\n'
    '直さないと admin の「想定撃数」列が黙って嘘の数字を出し続け、\n'
    'その数字を見てバランス調整が行われます。\n'
    '───────────────────────────────────────────────────────────';

void main() {
  late final String source;

  setUpAll(() {
    final f = File('lib/features/battle/constants/battle_constants.dart');
    expect(f.existsSync(), isTrue,
        reason: 'battle_constants.dart が cwd 配下に見つからない (cwd 不一致)');
    source = f.readAsStringSync();
  });

  group('BattleDisplay.computeAtk の式ガード (FEAT-521 Phase 1)', () {
    test('A: 本体が `10 + level * 2 + weaponAtk + studyLv` の形である', () {
      // `computeAtk` のシグネチャから対応する `}` までを抽出して中を見る。
      //
      // 終端は「行全体が `  }` の行」に限定する。名前付き引数リストの終わりが
      // `  }) {` なので、単に `^  \}` で止めると **引数リストだけ**を掴んで
      // 本体を素通りしてしまう (最初に書いてこれを踏んだ)。
      final match = RegExp(
        r'static\s+int\s+computeAtk\(\{([\s\S]*?)^  \}\r?$',
        multiLine: true,
      ).firstMatch(source);
      expect(match, isNotNull,
          reason: 'computeAtk が見つからない、シグネチャが変わった?$_fixBackendToo');

      final body = match!.group(1) ?? '';
      // 空白の入れ方には寛容にしつつ、係数と項の組み合わせは厳密に見る。
      final formula = RegExp(
        r'10\s*\+\s*level\s*\*\s*2\s*\+\s*weaponAtk\s*\+\s*studyLv',
      );
      expect(
        formula.hasMatch(body),
        isTrue,
        reason: 'computeAtk の本体が `10 + level * 2 + weaponAtk + studyLv` '
            'ではなくなっています。$_fixBackendToo\n\n本体:\n$body',
      );
    });

    test('B: 数値としても 20 + Lv × 2 が成立する (基準プレイヤー)', () {
      // 構造検査だけだと、`base` を後段で加工されたときに素通りする。
      // admin が実際に使う 3 つの引数を入れて値でも確かめる。
      for (final level in [1, 5, 18, 25, 48]) {
        final atk = BattleDisplay.computeAtk(
          level: level,
          weaponAtk: 10,        // starter_sword
          studyLv: 0,           // 学習力 未成長
          attackPowerModifier: 1.0,  // ジョブ修飾なし
        );
        expect(
          atk, 20 + level * 2,
          reason: 'Lv$level: 基準プレイヤーの ATK が 20 + Lv × 2 から外れました。'
              'backend/api/admin.py の想定撃数はこの値を分母にしています。'
              '$_fixBackendToo',
        );
      }
    });

    test('C: starter_sword の atkBonus 10 という前提を明示しておく', () {
      // starter_sword の値は Backend の migration 0082 が真実値で、Dart 側には
      // 定数として存在しない。ここでは「admin のモデルが 10 を仮定している」
      // という事実だけを記録し、B の引数と一致させておく。
      const starterSwordAtkBonus = 10;
      expect(
        BattleDisplay.computeAtk(
          level: 0,
          weaponAtk: starterSwordAtkBonus,
          studyLv: 0,
          attackPowerModifier: 1.0,
        ),
        20,
        reason: '切片 (基礎 10 + starter_sword 10 = 20) が変わっています。'
            'backend/api/admin.py の _BASELINE_ATK_INTERCEPT と揃えてください。'
            '$_fixBackendToo',
      );
    });

    test('D: ジョブ修飾は最後に 1 回だけ掛かる', () {
      // admin のモデルは modifier = 1.0 を仮定している。掛かる位置が変わると
      // (例: base の内側に入る) 1.0 以外での値がずれ、将来 modifier 込みの
      // 列を足したくなったときに前提が崩れる。
      expect(
        BattleDisplay.computeAtk(
          level: 10, weaponAtk: 10, studyLv: 0, attackPowerModifier: 1.3,
        ),
        ((20 + 10 * 2) * 1.3).round(),
        reason: 'attackPowerModifier が「最後に 1 回」ではなくなっています。'
            '$_fixBackendToo',
      );
    });
  });
}
