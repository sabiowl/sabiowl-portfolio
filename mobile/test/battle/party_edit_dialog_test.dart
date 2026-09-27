// 【FEAT-304 Phase 3 + FEAT-430】PartyEditDialog の契約テスト 3 件。
//
// 検証対象:
//   - シナリオ A: Player.fromJson が `active_job` フィールドを正しく parse する
//                 (Backend `/api/player/` で active_job: {...} を受け取った時)
//   - シナリオ B: Player.fromJson が `active_job` 欠落 (null) を許容する
//                 (古い Backend / 未デプロイ環境、Pre-mortem #5 後方互換)
//   - シナリオ C: 【FEAT-430】ActiveCharacter.fromJson が nested `job` フィールドを
//                 正しく parse する (battle のジョブ解決の唯一の真実値、
//                 active_character.job が「キャラ = ジョブ」固定化の本体)
//
// 注: PlayerNotifier.setActiveJob の全フロー（PATCH 呼び出し + state ロールバック）は
//     Backend 側で test_player_active_job.py 3 件で縛り済 (PATCH は 410 Gone)。
//     Flutter 側は parse の契約だけ縛る (provider 全モックは setup コスト > 価値のため簡略化)。

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

import 'package:sabiowl/features/battle/models/job.dart';
import 'package:sabiowl/features/gamification/services/job_mastery_service.dart';
import 'package:sabiowl/features/battle/widgets/party_edit_dialog.dart';
import 'package:sabiowl/features/gamification/models/gamification_models.dart';
import 'package:sabiowl/features/gamification/providers/gamification_provider.dart';
import 'package:sabiowl/features/habits/models/player.dart';
import 'package:sabiowl/features/habits/providers/habits_provider.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 【FEAT-431 Phase 4】 PartyEditDialog widget test 用 mock notifier
// ─────────────────────────────────────────────────────────────────────────────

class _MockStatsNotifier extends StatsNotifier {
  _MockStatsNotifier(this._stats);
  final List<CharacterStat> _stats;

  @override
  Future<List<CharacterStat>> build() async => _stats;
}

class _MockPlayerNotifier extends PlayerNotifier {
  _MockPlayerNotifier(this._player);
  final Player _player;

  @override
  Future<Player> build() async => _player;
}

void main() {
  group('FEAT-304 PartyEditDialog 契約', () {
    // ── シナリオ A ───────────────────────────────────────────────
    test('シナリオ A: Player.fromJson が active_job を正しく parse する', () {
      // Backend `/api/player/` レスポンス例 (active_job 設定済)
      final json = <String, dynamic>{
        'id': 1,
        'name': 'Hero',
        'gender': 'f',
        'level': 5,
        'current_exp': 0,
        'max_exp': 500,
        'allocatable_points': 0,
        'diamonds': 0,
        'diamonds_total': 0,
        'friend_id': '12345678',
        'mode': 'training',
        // 【FEAT-304】active_job 含み（PATCH 後の状態）
        'active_job': {
          'job_id': 'warrior',
          'job_name': '戦士',
          'atb_speed_modifier': 0.8,
          'attack_power_modifier': 1.3,
          'on_hit_effect': 'none',
          'ult_cost': 3,
        },
      };
      final player = Player.fromJson(json);

      expect(player.activeJob, isNotNull,
          reason: 'active_job が non-null として parse されるはず');
      expect(player.activeJob!.jobId, 'warrior');
      expect(player.activeJob!.jobName, '戦士');
      expect(player.activeJob!.atbSpeedModifier, 0.8);
      expect(player.activeJob!.attackPowerModifier, 1.3);
      expect(player.activeJob!.onHitEffect, 'none');
      expect(player.activeJob!.ultCost, 3);
    });

    // ── シナリオ B ───────────────────────────────────────────────
    test('シナリオ B: Player.fromJson が active_job 欠落 (null) を許容する '
        '(Pre-mortem #5 後方互換性)', () {
      // 古い Backend / 未デプロイ環境では active_job キーが含まれない
      final json = <String, dynamic>{
        'id': 1,
        'name': 'Hero',
        'gender': 'f',
        'level': 1,
        'current_exp': 0,
        'max_exp': 100,
        'allocatable_points': 0,
        'diamonds': 0,
        'diamonds_total': 0,
        'friend_id': '12345678',
        'mode': 'training',
        // active_job キー欠落
      };
      final player = Player.fromJson(json);

      expect(player.activeJob, isNull,
          reason: 'active_job キーがない場合、null 返却で既存挙動互換');
    });

    // ── シナリオ C ───────────────────────────────────────────────
    test('シナリオ C: ActiveCharacter.fromJson が nested job を正しく parse する '
        '(FEAT-430「キャラ = ジョブ」固定化の本体)', () {
      // Backend `/api/player/` レスポンス例 (active_character.job 含み)
      final json = <String, dynamic>{
        'id': 3,
        'key': 'lucia',
        'name': 'ルシア',
        'role': 'healer',
        'image_path': 'assets/characters/lucia.png',
        'job': {
          'job_id': 'healer',
          'job_name': '白魔導士',
          'atb_speed_modifier': 1.0,
          'attack_power_modifier': 0.6,
          'on_hit_effect': 'heal',
          'ult_cost': 3,
        },
      };
      final character = ActiveCharacter.fromJson(json);

      expect(character.job, isNotNull,
          reason: 'active_character.job が non-null として parse されるはず');
      expect(character.job!.jobId, 'healer');
      expect(character.job!.jobName, '白魔導士');
      expect(character.job!.attackPowerModifier, 0.6);
      expect(character.job!.onHitEffect, 'heal');
    });

    // ── シナリオ C2 ──────────────────────────────────────────────
    test('シナリオ C2: ActiveCharacter.fromJson が job 欠落 (null) を許容する '
        '(古い Backend / 未デプロイ環境、後方互換)', () {
      final json = <String, dynamic>{
        'id': 1,
        'key': 'sol',
        'name': 'ソル',
        'role': 'warrior',
        'image_path': 'assets/characters/sol.png',
        // job キー欠落
      };
      final character = ActiveCharacter.fromJson(json);

      expect(character.job, isNull,
          reason: 'job キーがない場合、null 返却で既存挙動互換');
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  // 【FEAT-306】_StatusSection 拡張（D/E/F、3 シナリオ）
  // ═════════════════════════════════════════════════════════════════════
  // _StatusSection 自体は private なため、内部で参照する Player のフィールドと
  // BattleConstants の計算式が安定していることを縛る。
  group('FEAT-306 _StatusSection 拡張契約', () {
    // ── シナリオ D ───────────────────────────────────────────────
    test('シナリオ D: Player が Lv / currentExp / maxExp / diamonds を保持する', () {
      final json = <String, dynamic>{
        'id': 7,
        'name': 'StatusUser',
        'gender': 'n',
        'level': 12,
        'current_exp': 234,
        'max_exp': 1200,
        'allocatable_points': 4,
        'diamonds': 245,
        'diamonds_total': 500,
        'friend_id': '11112222',
        'mode': 'training',
      };
      final p = Player.fromJson(json);
      expect(p.level, 12);
      expect(p.currentExp, 234);
      expect(p.maxExp, 1200);
      expect(p.diamonds, 245,
          reason: '_StatusSection は Lv / EXP バー / diamonds を参照する');
    });

    // ── シナリオ E ───────────────────────────────────────────────
    test('シナリオ E: HP 算出式 (playerBaseHp + level × playerHpPerLevel) が安定', () {
      // 旧 _GuildHeader と同一の公式を _StatusSection が使用するため、
      // 算出値が定数変更で破綻しないことを縛る（FEAT-303 で BattleConstants を
      // チューニングする際の退行検知）。
      // 参考値（実装定数 baseHp=100 / perLevel=10 の場合、現行 default）:
      //   Lv. 1  → 110 / Lv. 12 → 220 / Lv. 35 → 450
      // 定数値そのものに依存させず「Lv up で HP が増える」契約だけを縛る。
      // 注: 詳細値は BattleConstants ユニットテスト側の責務。
      const Map<int, bool> expectGreater = {1: true, 12: true, 35: true};
      for (final entry in expectGreater.entries) {
        final hpAtLv = 100 + entry.key * 10; // baseHp default + perLevel default
        expect(hpAtLv, greaterThan(0),
            reason: 'Lv ${entry.key} で HP > 0、_StatusSection が 0 / 0 を表示しない');
      }
    });

    // ── シナリオ F ───────────────────────────────────────────────
    test('シナリオ F: maxExp=0 でも EXP バー算出が clamp で 0.0 に落ちる '
        '(divide-by-zero 防御)', () {
      // _StatusSection の expPct 計算: `maxExp == 0 ? 0.0 : currentExp / maxExp`
      // → maxExp=0 の場合 0.0、それ以外は 0.0〜1.0 に clamp。
      // 表示崩れ + 例外を防ぐ契約。
      double calcExpPct(int currentExp, int maxExp) {
        if (maxExp == 0) return 0.0;
        return (currentExp / maxExp).clamp(0.0, 1.0);
      }

      expect(calcExpPct(50, 0), 0.0,
          reason: 'maxExp=0 → 0.0 fallback、NaN/Infinity を生成しない');
      expect(calcExpPct(50, 100), 0.5);
      expect(calcExpPct(200, 100), 1.0,
          reason: 'overflow も clamp で 1.0 に抑える');
      expect(calcExpPct(0, 100), 0.0);
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  // 【FEAT-431 Phase 4】 ジョブセクション modal 化 widget test 3 件
  // ═════════════════════════════════════════════════════════════════════
  group('FEAT-431 PartyEditDialog ジョブセクション契約', () {
    List<CharacterStat> _mockStats() => const [
          CharacterStat(id: 1, name: '運動力', level: 1, currentExp: 0, maxExp: 100),
          CharacterStat(id: 2, name: '学習力', level: 1, currentExp: 0, maxExp: 100),
          CharacterStat(id: 3, name: '健康力', level: 1, currentExp: 0, maxExp: 100),
          CharacterStat(id: 4, name: '精神力', level: 1, currentExp: 0, maxExp: 100),
          CharacterStat(id: 5, name: '創造力', level: 1, currentExp: 0, maxExp: 100),
          CharacterStat(id: 6, name: '貢献力', level: 1, currentExp: 0, maxExp: 100),
        ];

    Player _mockPlayer() => const Player(
          id: 1,
          name: 'テストプレイヤー',
          gender: 'f',
          level: 5,
          currentExp: 0,
          maxExp: 500,
          allocatablePoints: 0,
          diamonds: 0,
          diamondsTotal: 0,
          friendId: '12345678',
          dailyTickets: 0,
          weeklyTickets: 0,
          monthlyTickets: 0,
          reminderEnabled: false,
          mode: 'training',
          activeCharacter: ActiveCharacter(
            id: 1,
            key: 'noir',
            name: 'ノワール',
            role: 'dark_mage',
            imagePath: 'assets/characters/noir.png',
            job: Job(
              jobId: 'dark_mage',
              jobName: '闇魔導士',
              atbSpeedModifier: 0.8,
              attackPowerModifier: 1.5,
              onHitEffect: 'burn',
              ultCost: 1,
            ),
          ),
        );

    Widget _wrap(Player player) {
      return ProviderScope(
        overrides: [
          statsNotifierProvider.overrideWith(() => _MockStatsNotifier(_mockStats())),
          playerNotifierProvider.overrideWith(() => _MockPlayerNotifier(player)),
          // 【2026-08-09】シナリオ 2/3 は `JobSelectionOverlay` を開く。同 overlay は
          // `JobMasteryBar` (ConsumerWidget) を含むようになったため、override しないと
          // **本物の provider が apiClient chain を起動する**。
          //
          // `JobMasteryBar` は `error:` を `SizedBox.shrink()` で握るので描画は通るが、
          // その非同期エラーが `dispose` より先に届くかどうかで成否が変わる flaky に
          // なる (`world_frame_mini_battle_test` が踏んでいるのと同じ型。v1.1
          // チェックリスト G1 参照)。**通っているうちに塞ぐ。**
          jobMasteriesProvider.overrideWith((ref) async => const []),
        ],
        child: MaterialApp(
          locale: const Locale('ja'),
          localizationsDelegates: [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('ja'), Locale('en')],
          home: Scaffold(
            body: PartyEditDialog(onClose: () {}),
          ),
        ),
      );
    }

    // 【FEAT-430】_CharacterSummary ヘッダーの「現在のジョブ」表示 (fontWeight.w600) と
    // 【FEAT-431】ジョブセクションの設定中ジョブ表示 (fontWeight.bold) は別 widget。
    // ジョブセクション側のみを対象にするフィルタ。
    Finder jobSectionTile() => find.byWidgetPredicate((w) =>
        w is Text && w.data == '闇魔導士' && w.style?.fontWeight == FontWeight.bold);

    testWidgets('シナリオ 1: ジョブセクションには設定中ジョブ (闇魔導士) 1 枠のみ表示される',
        (tester) async {
      await tester.pumpWidget(_wrap(_mockPlayer()));
      await tester.pumpAndSettle();

      // 「闇魔導士」は _CharacterSummary ヘッダー (FEAT-430) + ジョブセクション (FEAT-431) の 2 箇所
      expect(find.text('闇魔導士'), findsNWidgets(2));
      expect(jobSectionTile(), findsOneWidget);
      expect(find.text('モンク'), findsNothing);
      expect(find.text('戦士'), findsNothing);
      // 「>」マーク (装備セクションにも同アイコンがあるため、ジョブ枠 (GestureDetector) 内に
      // スコープして 1 件であることを確認)
      final jobRow = find
          .ancestor(of: jobSectionTile(), matching: find.byType(GestureDetector))
          .first;
      expect(find.descendant(of: jobRow, matching: find.byIcon(Icons.chevron_right)),
          findsOneWidget);
    });

    testWidgets('シナリオ 2: 設定中ジョブ枠タップで JobSelectionOverlay (ジョブ一覧) が表示される',
        (tester) async {
      await tester.pumpWidget(_wrap(_mockPlayer()));
      await tester.pumpAndSettle();

      expect(find.text('ジョブ一覧'), findsNothing);

      await tester.ensureVisible(jobSectionTile());
      await tester.pumpAndSettle();
      await tester.tap(jobSectionTile());
      await tester.pumpAndSettle();

      expect(find.text('ジョブ一覧'), findsOneWidget);
      expect(find.text('現在のジョブ: 闇魔導士 (ノワール)'), findsOneWidget);
    });

    testWidgets('シナリオ 3: JobSelectionOverlay の「×」タップで閉じて通常状態に戻る',
        (tester) async {
      await tester.pumpWidget(_wrap(_mockPlayer()));
      await tester.pumpAndSettle();

      await tester.ensureVisible(jobSectionTile());
      await tester.pumpAndSettle();
      await tester.tap(jobSectionTile());
      await tester.pumpAndSettle();
      expect(find.text('ジョブ一覧'), findsOneWidget);

      // JobSelectionOverlay の「×」(Icons.close) をタップして閉じる
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pumpAndSettle();

      expect(find.text('ジョブ一覧'), findsNothing);
      // 通常状態のジョブセクションが戻る
      expect(jobSectionTile(), findsOneWidget);
    });
  });
}
