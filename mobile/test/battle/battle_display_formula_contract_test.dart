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
// ## 【FEAT-535 (2026-08-29)】ATK 以外にも広げた
//
// admin にプレイヤーの**個票**（ATK / maxHP / ATB / 3 ステ効果）を出すにあたり、
// Python 側のミラーが `backend/api/services/battle_stats_preview.py` に 1 本増えた。
//
// 🔴 **HP 側にはそれまで Python ミラーも契約テストも無かった。**
// `playerBaseHp` は 2026-06-13 に **10 → 20 の 2 倍化**を経験した**動く定数**で、
// そこへ admin から新しい cross-language 依存を生やすことになる。
// **契約テストを広げることが、HP を admin に出すための前提条件**とした
// （FEAT-535 §5 / §7-3）。
//
// 縛る範囲: `computeAtk`（既存）+ `playerBaseHp` / `playerHpPerLevel` /
// 運動力 `5` / `computeAtb` / 健康力 `2` / 創造力 `0.005` / 貢献力 `0.005`。
// 係数はすべて Python 側にも同名の定数があり、**同じ worked example** を
// `backend/api/tests/test_battle_stats_preview.py` が持っている。
// 片方だけ直せば、必ずどちらかが落ちる。
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
    '式を変えたなら、backend/api/admin.py の EnemyAdmin が使っている\n'
    '想定撃数モデルも同じコミットで直してください。\n'
    '式の実体は backend/api/services/battle_stats_preview.py の\n'
    'baseline_atk_for_enemy_table() です (FEAT-535 で移設)。\n'
    '直さないと admin の「想定撃数」列が黙って嘘の数字を出し続け、\n'
    'その数字を見てバランス調整が行われます。\n'
    '───────────────────────────────────────────────────────────';

/// 【FEAT-535】HP / ATB / 3 ステ係数側の失敗文言。**別ファイル**を名指しする。
///
/// EnemyAdmin の簡約式 (`_fixBackendToo`) とは**別の依存**なので、文言を分けている。
/// 混ぜると「どっちを直せばいいのか」が読めなくなる。
const _fixPreviewToo = '\n'
    '───────────────────────────────────────────────────────────\n'
    '式を変えたなら、backend/api/services/battle_stats_preview.py の\n'
    'ミラー定数も同じコミットで直してください。\n'
    'あわせて backend/api/tests/test_battle_stats_preview.py の\n'
    'worked example (同じ入力 → 同じ期待値) も更新が要ります。\n'
    '直さないと admin の「バトルステータス」が黙って古い数字を出し続け、\n'
    'その数字を見てバランス調整が行われます。\n'
    '───────────────────────────────────────────────────────────';

/// コメント行を落とした行 map (**元ファイルの行番号を保つ**)。
///
/// doc コメントは式をそのまま日本語で書いているので (「運動力 → maxHp += level × 5」)、
/// 落とさないと**自分のコメントにヒットして緑になる**。
Map<int, String> _codeLines(String path) {
  final all = File(path).readAsLinesSync();
  return {
    for (var i = 0; i < all.length; i++)
      if (!all[i].trimLeft().startsWith('//')) i + 1: all[i],
  };
}

/// `<変数> * <係数>` の**係数を拾い集める**。
///
/// 🔴 「`athleticLv * 5` という行があるか」で書いてはいけない。
/// 運動力は `maxHp:` と `currentHp:` の **2 行**にあり、片方だけ 6 に変えても
/// もう片方が残っていて緑のまま通る (実際に一度そうなった)。
/// **見つけた係数の集合**を返し、呼び出し側が「全部これか」を assert する。
Set<String> _coefficientsOf(Map<int, String> code, String variable) {
  final re = RegExp('$variable' r'\s*\*\s*([0-9]+(?:\.[0-9]+)?)');
  return code.values
      .expand((l) => re.allMatches(l))
      .map((m) => m.group(1)!)
      .toSet();
}

/// [variable] が現れる**コード行の数**。0 になったら式ごと消えている。
int _occurrences(Map<int, String> code, String variable) {
  final re = RegExp('$variable' r'\s*\*\s*[0-9]');
  return code.values.where(re.hasMatch).length;
}

void main() {
  late final String source;
  late final Map<int, String> providerCode;

  setUpAll(() {
    final f = File('lib/features/battle/constants/battle_constants.dart');
    expect(f.existsSync(), isTrue,
        reason: 'battle_constants.dart が cwd 配下に見つからない (cwd 不一致)');
    source = f.readAsStringSync();

    // 運動力 / 健康力 / 創造力 / 貢献力 の係数は `battle_constants.dart` ではなく
    // `_buildPlayerCombatant` の inline にある。定数化されていないので走査で縛る。
    const providerPath = 'lib/features/battle/providers/battle_provider.dart';
    expect(File(providerPath).existsSync(), isTrue,
        reason: 'battle_provider.dart が cwd 配下に見つからない (cwd 不一致)');
    providerCode = _codeLines(providerPath);
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

  // ───────────────────────────────────────────────────────────────────────────
  // 【FEAT-535 Phase 7-3】HP / ATB / 3 ステ係数
  //
  // ここから下が本 FEAT で足した分。admin の「バトルステータス」個票が
  // 依存している式をすべて縛る。
  // ───────────────────────────────────────────────────────────────────────────

  group('maxHP の式ガード (FEAT-535 Phase 7-3)', () {
    test('E-1: playerBaseHp = 200 / playerHpPerLevel = 20', () {
      // 🔴 playerBaseHp は 2026-06-13 に 10 → 20 の 2 倍化を経験している。
      // 「動かない定数」ではないので、値そのものを縛る。
      expect(BattleConstants.playerBaseHp, 200,
          reason: 'playerBaseHp が変わりました。'
              'battle_stats_preview.PLAYER_BASE_HP と揃えてください。$_fixPreviewToo');
      expect(BattleConstants.playerHpPerLevel, 20,
          reason: 'playerHpPerLevel が変わりました。'
              'battle_stats_preview.PLAYER_HP_PER_LEVEL と揃えてください。'
              '$_fixPreviewToo');
    });

    test('E-2: maxHp が `base + level * perLevel + 運動力Lv * 5` の形である', () {
      expect(
        providerCode.values
            .where((l) => l.contains('BattleConstants.playerBaseHp'))
            .length,
        greaterThan(0),
        reason: 'maxHp が playerBaseHp を使わなくなっています。$_fixPreviewToo',
      );
      expect(
        providerCode.values.any((l) =>
            l.contains('player.level * BattleConstants.playerHpPerLevel')),
        isTrue,
        reason: 'maxHp の Lv 項が `player.level * playerHpPerLevel` '
            'ではなくなっています。$_fixPreviewToo',
      );

      // 運動力の係数は定数化されていない inline なので走査で縛る。
      // 🔴 `maxHp:` と `currentHp:` の **2 行**にあるので、
      //    「5 という行があるか」ではなく「見つかった係数が 5 だけか」を見る。
      expect(
        _coefficientsOf(providerCode, 'athleticLv'),
        {'5'},
        reason: '運動力 → maxHp の係数が 5 だけではなくなっています '
            '(battle_stats_preview.ATHLETIC_HP_PER_LEVEL)。'
            'maxHp と currentHp の片方だけ変えた場合もここで落ちます。'
            '$_fixPreviewToo',
      );
      expect(_occurrences(providerCode, 'athleticLv'), 2,
          reason: '運動力の連動箇所が maxHp / currentHp の 2 行ではなくなっています。'
              '$_fixPreviewToo');
    });

    test('E-3: worked example —— Python 側と同じ数字を持つ', () {
      // backend/api/tests/test_battle_stats_preview.py に**同じ 3 件**がある。
      // 片方だけ直せば必ずどちらかが落ちる。
      int maxHp(int level, int athleticLv) =>
          BattleConstants.playerBaseHp +
          level * BattleConstants.playerHpPerLevel +
          athleticLv * 5;

      expect(maxHp(1, 0), 220, reason: 'Lv1 / 運動力 0$_fixPreviewToo');
      expect(maxHp(10, 5), 425, reason: 'Lv10 / 運動力 5$_fixPreviewToo');
      expect(maxHp(25, 12), 760, reason: 'Lv25 / 運動力 12$_fixPreviewToo');
    });
  });

  group('ATB / 3 ステ係数のガード (FEAT-535 Phase 7-3)', () {
    test('F-1: computeAtb が `atbSpeedModifier + mentalLv * 0.01` である', () {
      final match = RegExp(
        r'static\s+double\s+computeAtb\(\{([\s\S]*?)^  \}\r?$',
        multiLine: true,
      ).firstMatch(source);
      expect(match, isNotNull,
          reason: 'computeAtb が見つからない、シグネチャが変わった?$_fixPreviewToo');

      expect(
        RegExp(r'atbSpeedModifier\s*\+\s*mentalLv\s*\*\s*0\.01')
            .hasMatch(match!.group(1) ?? ''),
        isTrue,
        reason: 'computeAtb の本体が `atbSpeedModifier + mentalLv * 0.01` '
            'ではなくなっています (battle_stats_preview.MENTAL_ATB_PER_LEVEL)。'
            '$_fixPreviewToo\n\n本体:\n${match.group(1)}',
      );

      // 値でも確かめる (構造だけだと後段で加工されたときに素通りする)。
      expect(BattleDisplay.computeAtb(atbSpeedModifier: 0.9, mentalLv: 5),
          closeTo(0.95, 1e-9), reason: '戦士 (0.9) + 精神力 Lv5$_fixPreviewToo');
      expect(BattleDisplay.computeAtb(atbSpeedModifier: 1.4, mentalLv: 0),
          closeTo(1.4, 1e-9), reason: 'アサシン (1.4) + 精神力 未成長$_fixPreviewToo');
    });

    test('F-2: 健康力 → 毎ターン回復の係数は 2', () {
      expect(
        _coefficientsOf(providerCode, 'healthLv'),
        {'2'},
        reason: '健康力 → 毎ターン回復の係数が 2 ではなくなっています '
            '(battle_stats_preview.HEALTH_REGEN_PER_LEVEL)。$_fixPreviewToo',
      );
    });

    test('F-3: 創造力 → クリ率の係数は 0.005', () {
      expect(
        _coefficientsOf(providerCode, 'creativityLv'),
        {'0.005'},
        reason: '創造力 → クリ率の係数が 0.005 ではなくなっています '
            '(battle_stats_preview.CREATIVITY_CRIT_PER_LEVEL)。$_fixPreviewToo',
      );
    });

    test('F-4: 貢献力 → 被ダメ軽減の係数は 0.005', () {
      expect(
        _coefficientsOf(providerCode, 'contributionLv'),
        {'0.005'},
        reason: '貢献力 → 被ダメ軽減の係数が 0.005 ではなくなっています '
            '(battle_stats_preview.CONTRIBUTION_REDUCTION_PER_LEVEL)。'
            '$_fixPreviewToo',
      );
    });

    test('F-5: SPD は 10 固定のまま (MVP)', () {
      final spd = providerCode.values
          .expand((l) => RegExp(r'spd:\s*([0-9]+)').allMatches(l))
          .map((m) => m.group(1)!)
          .toSet();
      expect(spd.contains('10'), isTrue,
          reason: 'プレイヤー SPD が 10 固定ではなくなっています '
              '(battle_stats_preview.PLAYER_SPD)。見つかった値: $spd'
              '$_fixPreviewToo');
    });
  });

  group('丸めの契約 (FEAT-535 Phase 7-1)', () {
    test('G-1: 🔴 `.5` は切り上げ —— Python の組み込み round() とは違う', () {
      // Dart の `.round()` は half away from zero。
      // Python の組み込み round() は banker's rounding で `round(34.5) == 34`。
      // battle_stats_preview.dart_round() は Decimal(ROUND_HALF_UP) で合わせている。
      //
      // 🔵 これは理論上の話ではない: `attack_power_modifier = 1.5` は
      //    dark_mage (闇魔導士) の実在の値である (backend migration 0112)。
      //
      //    base = 10 + 1*2 + 10 + 1 = 23 → 23 × 1.5 = 34.5 → **35**
      expect(
        BattleDisplay.computeAtk(
          level: 1, weaponAtk: 10, studyLv: 1, attackPowerModifier: 1.5,
        ),
        35,
        reason: '.5 が切り上げではなくなっています。Python 側で banker\'s rounding '
            'に戻すと 34 になり、admin だけ 1 ずれます。$_fixPreviewToo',
      );

      // 同じ形でもう 1 件 (base = 25 → 37.5 → 38)。
      expect(
        BattleDisplay.computeAtk(
          level: 2, weaponAtk: 10, studyLv: 1, attackPowerModifier: 1.5,
        ),
        38,
        reason: '.5 の 2 件目$_fixPreviewToo',
      );
    });
  });
}
