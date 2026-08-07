// 【gameplay_review 20260803 §2-1 / §2-2 d / §2-3】Ambient Auto Battle の **UI 側**
// 契約テスト。
//
// ## なぜ必要か
//
// 既存の `ambient_auto_battle_orchestrator_test.dart` 7 本はすべて orchestrator
// 単体で、**UI の gate を 1 本も通っていなかった**。その隙間で起きたのが §2-1:
//
//   - 発火の真実値: `AmbientAutoBattlePreferences.isEnabled(prefs)` (orchestrator)
//   - 描画の真実値: `ambientAutoBattleEnabledProvider` (StateProvider、初期値 false)
//
// 後者に prefs を流し込むのは `GuildPage.initState` の 1 箇所だけで、ShellRoute 配下の
// GuildPage は **ギルドタブを開くまで build されない**。結果「起動 → ホーム着地 →
// ギルド未訪問」という最も普通の導線で、countdown は回るのに中止ボタンが画面に無い
// = 意図しない自動出陣を止める手段が存在しない状態だった。
//
// 本テストは **ギルド画面を一度も build せずに** countdown state を立て、
// WorldFrame の overlay に中止ボタンが出ることを固定する。
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/battle/ambient_auto_battle_ui_test.dart
// ```

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/features/battle/providers/battle_provider.dart';
import 'package:sabiowl/features/battle/services/ambient_auto_battle_orchestrator.dart';
import 'package:sabiowl/features/habits/widgets/world_frame/ambient_battle_overlays.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  // A: countdown overlay — ギルドを開いていなくても「中止」が出る
  // ───────────────────────────────────────────────────────────────────────────
  group('A: countdown overlay の表示条件 (§2-1)', () {
    testWidgets(
        'ギルド画面を一度も build せずに countdown が立つと、中止 / 今すぐ開始 が出る',
        (tester) async {
      final container = _container();
      addTearDown(container.dispose);

      // ギルド未訪問を再現: enabled provider は初期値 false のまま触らない。
      expect(
        container.read(ambientAutoBattleEnabledProvider),
        isFalse,
        reason: 'GuildPage.initState を通っていないので provider は false のまま。'
            'この状態でも countdown UI は出なければならない',
      );

      final notifier =
          container.read(ambientAutoBattleProvider.notifier) as _TestNotifier;
      notifier.emit(const AmbientBattleState(countdownSecondsLeft: 7));

      await tester.pumpWidget(_app(container));
      await tester.pump();

      final l10n = lookupAppLocalizations(const Locale('ja'));
      expect(find.text('7'), findsOneWidget, reason: '残り秒数が出る');
      expect(
        find.text(l10n.habitWorldAmbientCountdownCancelButton),
        findsOneWidget,
        reason: '【§2-1 本体】中止ボタンが無いと、意図しない自動出陣を止める手段が'
            '画面上に存在しない状態になる',
      );
      expect(
        find.text(l10n.habitWorldAmbientCountdownStartButton),
        findsOneWidget,
      );
    });

    testWidgets('countdown が null なら overlay は描かれない', (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container));
      await tester.pump();

      final l10n = lookupAppLocalizations(const Locale('ja'));
      expect(find.text(l10n.habitWorldAmbientCountdownCancelButton), findsNothing);
    });

    testWidgets('中止 / 今すぐ開始 のタップが notifier に届く', (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      final notifier =
          container.read(ambientAutoBattleProvider.notifier) as _TestNotifier;
      notifier.emit(const AmbientBattleState(countdownSecondsLeft: 5));

      await tester.pumpWidget(_app(container));
      await tester.pump();

      final l10n = lookupAppLocalizations(const Locale('ja'));
      await tester.tap(find.text(l10n.habitWorldAmbientCountdownCancelButton));
      expect(notifier.cancelCalls, 1);

      await tester.tap(find.text(l10n.habitWorldAmbientCountdownStartButton));
      expect(notifier.skipCalls, 1);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // B: 額縁下部インジケーター
  // ───────────────────────────────────────────────────────────────────────────
  group('B: AmbientBattleStatusIndicator の出し分け', () {
    testWidgets('【§2-3】オートバトル OFF でも charges 進捗が出る (文面は出陣表現)',
        (tester) async {
      final container = _container(
        availability: _avail(charges: 1),
        // 既定 = OFF。ここが旧実装では `SizedBox.shrink()` の分岐だった。
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container));
      await tester.pump();

      final l10n = lookupAppLocalizations(const Locale('ja'));
      expect(
        find.text(l10n.habitWorldAmbientIndicatorChargingManual(2)),
        findsOneWidget,
        reason: 'オート OFF (= 既定) のユーザーにもホームで「あと N 回」が見える。'
            '7/29 に入れた timeline の ⚔️ N/3 は重複解消で撤去され、'
            'BottomNav バッジは charges >= 3 でしか出ないため、'
            'ここが消えると既定ユーザーは進捗をどこでも見られない',
      );
      expect(
        find.text(l10n.habitWorldAmbientIndicatorCharging(2)),
        findsNothing,
        reason: 'OFF のユーザーに「オートバトルが始まります」と言ってはいけない',
      );
    });

    testWidgets('オートバトル ON ならオート文面に切り替わる', (tester) async {
      final container = _container(
        availability: _avail(charges: 1),
        autoEnabled: true,
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container));
      await tester.pump();

      final l10n = lookupAppLocalizations(const Locale('ja'));
      expect(find.text(l10n.habitWorldAmbientIndicatorCharging(2)), findsOneWidget);
    });

    testWidgets('日次上限到達なら休息を肯定する文面になる (auto OFF でも)',
        (tester) async {
      final container = _container(
        availability: _avail(charges: 9, dailyLimitReached: true),
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container));
      await tester.pump();

      final l10n = lookupAppLocalizations(const Locale('ja'));
      expect(
        find.text(l10n.habitWorldAmbientDailyLimitSabi_message),
        findsOneWidget,
      );
    });

    testWidgets('【§2-2 d】queue 実行中は「残り N 戦」の subtle 表示になる',
        (tester) async {
      final container = _container(availability: _avail(charges: 9));
      addTearDown(container.dispose);
      final notifier =
          container.read(ambientAutoBattleProvider.notifier) as _TestNotifier;
      notifier.emit(const AmbientBattleState(isRunning: true, remainingBattles: 3));

      await tester.pumpWidget(_app(container));
      await tester.pump();

      final l10n = lookupAppLocalizations(const Locale('ja'));
      expect(find.text(l10n.habitWorldAmbientQueueProgress(3)), findsOneWidget);
    });

    testWidgets('出陣可能 (charges 満タン) なら何も出さない', (tester) async {
      final container = _container(
        availability: _avail(charges: 3, canBattle: true),
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container));
      await tester.pump();

      expect(find.byType(Text), findsNothing);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // C: source レベルの不変条件
  // ───────────────────────────────────────────────────────────────────────────
  group('C: source ガード', () {
    test('【§2-1】main() が起動時に auto battle の ON/OFF を override している', () {
      final src = _readSource('lib/main.dart');
      expect(
        src.contains('AmbientAutoBattlePreferences.isEnabled(prefs)'),
        isTrue,
        reason: 'locale と同じく runApp 前に prefs から解決すること。'
            'GuildPage.initState だけが真実値を流し込む構造に戻すと、'
            'ギルド未訪問の session で countdown UI が消える (§2-1)',
      );
      expect(
        src.contains('ambientAutoBattleEnabledProvider'),
        isTrue,
        reason: 'ProviderScope の override に載せること',
      );
    });

    test('【§2-1】countdown overlay は enabled provider に依存しない', () {
      final src = _readSource(
          'lib/features/habits/widgets/world_frame/ambient_battle_overlays.dart');
      final start = src.indexOf('class AmbientBattleCountdownOverlay');
      final end = src.indexOf('class AmbientBattleStatusIndicator');
      expect(start, greaterThan(-1));
      expect(end, greaterThan(start));

      expect(
        src.substring(start, end).contains('ambientAutoBattleEnabledProvider'),
        isFalse,
        reason: 'countdown が回っている時点で orchestrator が isEnabled(prefs) を'
            '確認済なので二重チェックは冗長。ここに gate を戻すと、provider が'
            '未同期の起動直後に「countdown は進むが中止できない」が再発する',
      );
    });

    test('【§2-2 d】queue 実行中は per-battle モーダルを抑止している', () {
      final src = _readSource(
          'lib/features/habits/widgets/world_frame/world_frame_listeners.dart');
      final suppressAt = src.indexOf('ambientAutoBattleProvider).isRunning) return');
      final lockAt = src.indexOf('markModalShown()');

      expect(
        suppressAt,
        greaterThan(-1),
        reason: 'FEAT-513 S7 は「連続勝利中は表示しない」と決めている。'
            '1 戦ごとに barrierDismissible: false のダイアログを出すと、'
            'ユーザーが閉じる前に (status 変化の 2 秒後に) 次戦が始まる',
      );
      expect(
        suppressAt,
        lessThan(lockAt),
        reason: '抑止は markModalShown() の **前** に行うこと。先に排他ロックを'
            '取ってしまうと、ユーザーが自分で BattlePage を開いているケースで'
            'BattlePage 側のモーダルまで消える',
      );
    });

    test('【§2-2 b】熟練度 Lv アップが PostHog だけで終わっていない', () {
      final src = _readSource('lib/features/battle/providers/battle_provider.dart');
      final at = src.indexOf('mastery.leveledUpNow');
      expect(at, greaterThan(-1));
      expect(
        src.substring(at, at + 1200).contains(
            'battleJobMasteryLevelUpToastSabi_message'),
        isTrue,
        reason: 'FEAT-511 §2.2 が指定していたサビ口調通知。Lv 1 → Max は 786 EXP '
            '(雑魚 ≒ 157 勝) で、その道中の 9 回のマイルストーンが全部無音だと'
            '「積み上げの可視化」というプロダクトの中核価値が届かない',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // D: AmbientBattleState / Summary の契約
  // ───────────────────────────────────────────────────────────────────────────
  group('D: state の契約', () {
    test('既定値は「何も起きていない」', () {
      const s = AmbientBattleState();
      expect(s.isRunning, isFalse);
      expect(s.countdownSecondsLeft, isNull);
      expect(s.remainingBattles, 0);
      expect(s.summary, isNull);
    });

    test('summary は run 全体の戦果を運ぶ', () {
      const s = AmbientBattleSummary(
        wins: 3,
        coins: 120,
        exp: 45,
        queueExhausted: true,
      );
      expect(s.wins, 3);
      expect(s.coins, 120);
      expect(s.exp, 45);
      expect(
        s.queueExhausted,
        isTrue,
        reason: 'true のときだけ「次の相手を選んでくださいね」を添える。'
            'charges 切れ / 日次上限で止まった場合に同じ案内を出すと誤誘導になる',
      );
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// helpers
// ─────────────────────────────────────────────────────────────────────────────

/// 本番の [AmbientAutoBattleNotifier] を継承し、テストから state を注入できるようにする。
///
/// fake に差し替えず本物を継承するのは、`skipCountdown` / `cancelCountdown` の
/// 実体まで含めて widget → notifier の結線を検査するため。
class _TestNotifier extends AmbientAutoBattleNotifier {
  _TestNotifier(super.ref);

  int cancelCalls = 0;
  int skipCalls = 0;

  void emit(AmbientBattleState next) => state = next;

  @override
  void cancelCountdown() {
    cancelCalls++;
    super.cancelCountdown();
  }

  @override
  void skipCountdown() {
    skipCalls++;
    super.skipCountdown();
  }
}

BattleAvailability _avail({
  required int charges,
  bool canBattle = false,
  bool dailyLimitReached = false,
}) =>
    BattleAvailability(
      charges: charges,
      canBattle: canBattle,
      label: '',
      description: '',
      dailyBattleLimitReached: dailyLimitReached,
    );

ProviderContainer _container({
  BattleAvailability? availability,
  bool autoEnabled = false,
}) =>
    ProviderContainer(
      overrides: [
        ambientAutoBattleProvider.overrideWith(_TestNotifier.new),
        battleAvailabilityProvider
            .overrideWithValue(availability ?? _avail(charges: 0)),
        if (autoEnabled)
          ambientAutoBattleEnabledProvider.overrideWith((ref) => true),
      ],
    );

/// countdown overlay と下部インジケーターだけを載せた最小画面。
///
/// ホーム画面そのものは puzzle / player / 背景アセットまで必要とするため、
/// **UI gate の検査に必要な 2 widget だけ**を本番のまま置く。
Widget _app(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('ja'),
        home: const Scaffold(
          body: Column(
            children: [
              SizedBox(
                height: 240,
                child: AmbientBattleCountdownOverlay(),
              ),
              AmbientBattleStatusIndicator(),
            ],
          ),
        ),
      ),
    );

String _readSource(String path) {
  final f = File(path);
  expect(f.existsSync(), isTrue,
      reason: '$path が見つかりません。プロジェクトルート (mobile/) から実行してください');
  return f
      .readAsStringSync()
      .split('\n')
      // コメント行は検査対象外 (説明文のヒットで誤 pass しないように)
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');
}
