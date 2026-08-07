// 【FEAT-240】LevelUpDialog integration test（BUG-61〜66 系譜の CI 保護）
//
// BUG-61 / BUG-64 / BUG-65 / BUG-66 と 5 度直した LevelUpDialog の
// 「dialog 表示 → 戻り値で caller が遷移判断」フローを CI で締める。
//
// シナリオ:
//   A: 「ステータスについて」タップ → bool true 返却 → caller が /stats へ push
//   B: 「続ける」タップ          → bool false 返却 → caller は push しない
//   C: barrier タップ           → null 返却     → caller は push しない
//   R-1: 連続レベルアップ        → 1 回目閉じる → 2 回目正常表示
//
// すべて mock provider override で実 dialog を起動し、本体コードを 1 行も
// 変えずに validate する設計。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:sabiowl/features/gamification/models/gamification_models.dart';
import 'package:sabiowl/features/gamification/providers/gamification_provider.dart';
import 'package:sabiowl/features/habits/models/player.dart';
import 'package:sabiowl/features/habits/providers/habits_provider.dart';
import 'package:sabiowl/l10n/app_localizations.dart';
import 'package:sabiowl/shared/widgets/level_up_dialog.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Mock data — dialog の表示に必要な最小限のステータスと Player
// ─────────────────────────────────────────────────────────────────────────────

List<CharacterStat> _mockStats() => const [
      CharacterStat(id: 1, name: '運動力', level: 1, currentExp: 0, maxExp: 100),
      CharacterStat(id: 2, name: '学習力', level: 1, currentExp: 0, maxExp: 100),
      CharacterStat(id: 3, name: '健康力', level: 1, currentExp: 0, maxExp: 100),
      CharacterStat(id: 4, name: '精神力', level: 1, currentExp: 0, maxExp: 100),
      CharacterStat(id: 5, name: '創造力', level: 1, currentExp: 0, maxExp: 100),
      CharacterStat(id: 6, name: '貢献力', level: 1, currentExp: 0, maxExp: 100),
    ];

Player _mockPlayer({int allocatablePoints = 0}) => Player(
      id: 1,
      name: 'テストプレイヤー',
      gender: 'f',
      level: 2,
      currentExp: 0,
      maxExp: 200,
      allocatablePoints: allocatablePoints,
      diamonds: 0,
      diamondsTotal: 0,
      friendId: 'TEST0001',
      dailyTickets: 0,
      weeklyTickets: 0,
      monthlyTickets: 0,
      reminderEnabled: false,
      mode: 'training',
    );

// ─────────────────────────────────────────────────────────────────────────────
// Mock notifiers
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

// ─────────────────────────────────────────────────────────────────────────────
// Test harness
// ─────────────────────────────────────────────────────────────────────────────

/// caller 側の遷移判断ロジックを再現するボタン。
/// `await LevelUpDialog.show(...)` の結果を `result` に保存し、
/// true なら 300ms 待機後に `/stats` へ push する（BUG-65 標準パターン）。
class _LauncherButton extends StatefulWidget {
  const _LauncherButton({this.onResult});
  final void Function(bool?)? onResult;

  @override
  State<_LauncherButton> createState() => _LauncherButtonState();
}

class _LauncherButtonState extends State<_LauncherButton> {
  bool? _lastResult;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ElevatedButton(
          onPressed: () async {
            final result = await LevelUpDialog.show(context, 2);
            _lastResult = result;
            widget.onResult?.call(result);
            if (result == true && context.mounted) {
              // BUG-65 標準パターン: dialog の transitionDuration (150ms) +
              // マージンで完全 dispose を待ってから push。
              await Future.delayed(const Duration(milliseconds: 300));
              if (context.mounted) context.push('/stats');
            }
          },
          child: const Text('レベルアップ起動'),
        ),
        Text('lastResult=${_lastResult ?? "none"}'),
      ],
    );
  }
}

/// 共通テストアプリ。GoRouter + ProviderScope.overrides で
/// statsNotifier / playerNotifier を mock 差し替え。
Widget _buildApp({
  required List<CharacterStat> stats,
  required Player player,
  void Function(bool?)? onResult,
}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => Scaffold(
          body: Center(child: _LauncherButton(onResult: onResult)),
        ),
      ),
      GoRoute(
        path: '/stats',
        builder: (_, __) => const Scaffold(
          body: Center(child: Text('Stats Page')),
        ),
      ),
    ],
  );

  return ProviderScope(
    overrides: [
      statsNotifierProvider.overrideWith(() => _MockStatsNotifier(stats)),
      playerNotifierProvider.overrideWith(() => _MockPlayerNotifier(player)),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('ja'),
    ),
  );
}

void main() {
  group('LevelUpDialog integration test（BUG-61〜66 系譜の CI 保護）', () {
    // ── シナリオ A（必須）─────────────────────────────────────────
    testWidgets(
      'A: 「ステータスについて」タップ → bool true → caller が /stats へ push',
      (tester) async {
        bool? captured;
        await tester.pumpWidget(_buildApp(
          stats: _mockStats(),
          player: _mockPlayer(allocatablePoints: 10),
          onResult: (r) => captured = r,
        ));
        await tester.pumpAndSettle();

        // 1. dialog 起動
        await tester.tap(find.text('レベルアップ起動'));
        await tester.pumpAndSettle();
        expect(find.text('LEVEL UP!'), findsOneWidget,
            reason: 'dialog が表示されている');
        expect(find.text('スキップして続ける'), findsOneWidget,
            reason: 'allocatable > 0 のときは「スキップして続ける」表示');

        // 2. 「ステータスについて」リンクタップ
        await tester.tap(find.text('ステータスについて'));
        // dialog dispose (150ms) + caller の Future.delayed (300ms) + push 演出
        await tester.pumpAndSettle(const Duration(milliseconds: 600));

        // 3. caller の戻り値・遷移結果を検証
        expect(captured, isTrue, reason: 'showDialog は true を返した');
        expect(find.text('Stats Page'), findsOneWidget,
            reason: '/stats に遷移している');
        expect(find.text('LEVEL UP!'), findsNothing,
            reason: 'dialog は完全 dispose 済み');
      },
    );

    // ── シナリオ B（必須）─────────────────────────────────────────
    testWidgets(
      'B: 「続ける」タップ → bool false → caller は push しない',
      (tester) async {
        bool? captured;
        await tester.pumpWidget(_buildApp(
          stats: _mockStats(),
          player: _mockPlayer(),  // allocatable = 0
          onResult: (r) => captured = r,
        ));
        await tester.pumpAndSettle();

        await tester.tap(find.text('レベルアップ起動'));
        await tester.pumpAndSettle();
        expect(find.text('続ける'), findsOneWidget,
            reason: 'allocatable = 0 のときは「続ける」表示');

        await tester.tap(find.text('続ける'));
        // dialog dispose のみ（push が走らないので 300ms 待機も不要だが念のため）
        await tester.pumpAndSettle(const Duration(milliseconds: 600));

        expect(captured, isFalse, reason: 'showDialog は false を返した');
        expect(find.text('Stats Page'), findsNothing,
            reason: '/stats への遷移は発生しない');
        expect(find.text('LEVEL UP!'), findsNothing,
            reason: 'dialog は閉じた');
      },
    );

    // ── シナリオ C（推奨）─────────────────────────────────────────
    testWidgets(
      'C: barrier タップ → null 返却 → caller は push しない',
      (tester) async {
        bool? captured;
        bool resultCalled = false;
        await tester.pumpWidget(_buildApp(
          stats: _mockStats(),
          player: _mockPlayer(),
          onResult: (r) {
            captured = r;
            resultCalled = true;
          },
        ));
        await tester.pumpAndSettle();

        await tester.tap(find.text('レベルアップ起動'));
        await tester.pumpAndSettle();
        expect(find.text('LEVEL UP!'), findsOneWidget);

        // barrier タップ: showDialog は `useRootNavigator: true` で
        // RootNavigator 上に dialog を push し、barrierDismissible: true なので
        // ModalBarrier 外側タップで dismiss する。dialog は中央寄せされており
        // 画面の左上 (10, 10) は dialog の外 = barrier 領域。
        // `find.byType(ModalBarrier).last` だと dialog 内側の barrier widget が
        // 当たることがあるので、座標タップで barrier 領域を直撃させる。
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle(const Duration(milliseconds: 600));

        expect(resultCalled, isTrue, reason: 'showDialog の Future が resolve した');
        expect(captured, isNull, reason: 'barrier 経由は null を返す');
        expect(find.text('Stats Page'), findsNothing,
            reason: '/stats への遷移は発生しない');
        expect(find.text('LEVEL UP!'), findsNothing,
            reason: 'dialog は閉じた');
      },
    );

    // ── シナリオ R-1（推奨）───────────────────────────────────────
    testWidgets(
      'R-1: 連続レベルアップ — 1 回目閉じる → 2 回目正常表示',
      (tester) async {
        final results = <bool?>[];
        await tester.pumpWidget(_buildApp(
          stats: _mockStats(),
          player: _mockPlayer(),
          onResult: (r) => results.add(r),
        ));
        await tester.pumpAndSettle();

        // 1 回目
        await tester.tap(find.text('レベルアップ起動'));
        await tester.pumpAndSettle();
        expect(find.text('LEVEL UP!'), findsOneWidget);
        await tester.tap(find.text('続ける'));
        await tester.pumpAndSettle(const Duration(milliseconds: 600));
        expect(find.text('LEVEL UP!'), findsNothing,
            reason: '1 回目の dialog は完全 dispose');

        // 2 回目
        await tester.tap(find.text('レベルアップ起動'));
        await tester.pumpAndSettle();
        expect(find.text('LEVEL UP!'), findsOneWidget,
            reason: '2 回目の dialog が独立して再表示される');
        await tester.tap(find.text('続ける'));
        await tester.pumpAndSettle(const Duration(milliseconds: 600));

        expect(results, [isFalse, isFalse],
            reason: '2 回とも「続ける」経由で false 返却');
      },
    );
  });
}
