// 【FEAT-528 (2026-08-22)】バトル設定モーダル + 速度バッジの契約テスト。
//
// ## 何を守るテストか
//
// 実機報告:「一度 Skip にすると次も Skip となり、次戦でバトルスピードを変更する前に
// 終了し、変更できません」。`⏭` は headless ではなく `speedMultiplier = 50.0` で、
// 書き込み UI はバトル画面の AppBar だけだった —— Skip では戦闘が 1-2 秒で終わるので
// **チップをタップする窓が無い**。本 FEAT はその出口（モーダル）と、
// **開かなくても気付ける場所**（バーのバッジ）を作る。
//
// 壊れると痛い順に:
//
//   D-1: 🔴 速度の書き手が 2 つに割れていない —— BUG-79 が全く同じ形で起きている
//        （「_SpeedChip は 1x をハイライトしているのに実速度は 3x」）
//   A-2: 🔴 歯車タップでオートバトルが誤 toggle されない —— バーは全体が InkWell。
//        素の Icon を置くと、設定を開くたびにホームの自動出陣が入り切りされる
//   B-2: 🔴 モーダルで変えた値が、走っているバトルの速度チップに届く
//
// 実行方法:
// ```powershell
// cd mobile
// flutter test test/battle/battle_settings_dialog_test.dart
// ```

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabiowl/core/constants/preferences_keys.dart';
import 'package:sabiowl/core/theme/app_theme.dart';
import 'package:sabiowl/features/battle/models/battle_state.dart';
import 'package:sabiowl/features/battle/models/combatant.dart';
import 'package:sabiowl/features/battle/models/tactic.dart';
import 'package:sabiowl/features/battle/pages/battle_page.dart';
import 'package:sabiowl/features/battle/providers/battle_provider.dart';
import 'package:sabiowl/features/battle/widgets/battle_settings_dialog.dart';
import 'package:sabiowl/features/battle/widgets/battle_toggle_switch.dart';
import 'package:sabiowl/features/guild/pages/guild_page.dart'
    show GuildBattleSettingsAction;
import 'package:sabiowl/l10n/app_localizations.dart';

const _speedKey = 'battle_speed_multiplier';
const _autoKey = 'ambient_auto_battle_enabled';

AppLocalizations get _l10n => lookupAppLocalizations(const Locale('ja'));

// ─────────────────────────────────────────────────────────────────────────────
// pump helper — バー単体
// ─────────────────────────────────────────────────────────────────────────────

/// GuildPage の AppBar だけを組み立てて pump する。
///
/// GuildPage を丸ごと pump すると敵一覧 / 受付 NPC / player の HTTP まで
/// 巻き込むので、**AppBar の actions と同じものを同じ順で**組んだ Scaffold を使う。
///
/// ⚠️ ここは実装のコピーなので、guild_page 側の actions を変えたら追随すること。
/// **並びと的の寸法は D-3 のソース走査でも縛っている**（コピーが古くなっても、
/// 実装側の並びが変わったことには気付ける）。
Future<ProviderContainer> _pumpGuildHeader(
  WidgetTester tester, {
  double speed = 1.0,
  bool autoBattle = false,
}) async {
  SharedPreferences.setMockInitialValues({
    _speedKey: speed,
    _autoKey: autoBattle,
  });
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(ambientAutoBattleEnabledProvider.notifier).state = autoBattle;

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale('ja'),
      home: _GuildHeaderHarness(),
    ),
  ));
  // battleSpeedPreferenceProvider は自分で prefs を読むので、完了まで進める。
  await tester.pump();
  await tester.pump();
  return container;
}

/// guild_page の AppBar を、**実装の widget をそのまま使って**組む。
///
/// actions を直書きするとテスト側に実装のコピーができ、必ず古くなる。
/// `GuildBattleSettingsAction` は実装が使っているものと同一。
/// 並び（歯車がハンバーガーの左）は D-3 のソース走査で縛る。
class _GuildHeaderHarness extends StatelessWidget {
  const _GuildHeaderHarness();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.guildPageTitle),
        centerTitle: true,
        actions: [
          const GuildBattleSettingsAction(),
          Builder(
            builder: (ctx) => IconButton(
              icon: const Icon(Icons.menu),
              tooltip: l10n.guildPageMenuTooltip,
              onPressed: () => Scaffold.of(ctx).openEndDrawer(),
            ),
          ),
        ],
      ),
      endDrawer: const Drawer(child: SizedBox.shrink()),
      body: const SizedBox.shrink(),
    );
  }
}

Future<void> _tapGear(WidgetTester tester) async {
  await tester.tap(find.widgetWithIcon(IconButton, Icons.settings));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

// ─────────────────────────────────────────────────────────────────────────────
// pump helper — BattlePage (B-2 用)
// ─────────────────────────────────────────────────────────────────────────────

/// `startBattle` を潰し、`setSpeedMultiplier` は orchestrator の代わりに
/// state を書き換える fake。
///
/// 本物の `setSpeedMultiplier` は `_orchestrator == null` で早期 return するので、
/// Backend を通さない test では何も起きない。ここで見たいのは
/// **「モーダル → notifier → 速度チップ」の配線**であって orchestrator ではないので、
/// orchestrator の役割だけを肩代わりさせる。
class _FakeSessionNotifier extends BattleSessionNotifier {
  _FakeSessionNotifier(super.ref);

  @override
  Future<void> startBattle({String? enemyKey, bool ambient = false}) async {}

  @override
  void setSpeedMultiplier(double value) {
    final s = state.state;
    if (s == null) return;
    state = state.copyWith(state: s.copyWith(speedMultiplier: value));
  }

  void push(BattleSession session) => state = session;
}

BattleSession _runningSession({double speed = 1.0}) => const BattleSession().copyWith(
      token: 'test',
      state: BattleState(
        player: Combatant(
          id: 'player', name: '勇者', spriteKey: 'sabi',
          maxHp: 100, currentHp: 100, atk: 10, spd: 10,
        ),
        enemy: Combatant(
          id: 'enemy_goblin', name: 'ゴブリン', spriteKey: 'enemy_goblin',
          maxHp: 60, currentHp: 60, atk: 5, spd: 10,
        ),
        tactic: Tactic.offense,
        status: BattleStatus.running,
        logLines: ['戦闘開始'],
        speedMultiplier: speed,
      ),
    );

/// AppBar の速度チップ (モーダル側の同ラベルと区別する)。
Container _appBarChip(WidgetTester tester, String label) {
  final text = find.descendant(
    of: find.byType(AppBar),
    matching: find.text(label),
  );
  return tester.widget<Container>(
    find
        .ancestor(of: text, matching: find.byType(Container))
        .first,
  );
}

bool _isChipSelected(WidgetTester tester, String label) {
  final decoration = _appBarChip(tester, label).decoration as BoxDecoration?;
  return decoration?.color == AppTheme.primary;
}

// ─────────────────────────────────────────────────────────────────────────────
// テスト本体
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  group('【FEAT-528】A: AppBar の歯車と速度バッジ', () {
    testWidgets('A-1: 歯車タップでモーダルが開く', (tester) async {
      await _pumpGuildHeader(tester);
      expect(find.byType(BattleSettingsDialog), findsNothing);

      await _tapGear(tester);

      expect(find.byType(BattleSettingsDialog), findsOneWidget);
      expect(find.text(_l10n.battleSettingsTitle), findsOneWidget);
      expect(
        find.text(_l10n.battleSettingsSkipDescription),
        findsOneWidget,
        reason: '⏭ は他の 4 つと違い「倍速」ではなく体験の種類が変わる。'
            '説明が無いと「一番速いやつ」と誤解され、知らずに触った戦闘が飛ぶ '
            '(Pre-mortem #5)',
      );
    });

    testWidgets('🔴 A-2: 歯車は自分の的を持ち、隣のハンバーガーとは別物',
        (tester) async {
      await _pumpGuildHeader(tester);

      final gear = tester.getRect(find.widgetWithIcon(IconButton, Icons.settings));
      final menu = tester.getRect(find.widgetWithIcon(IconButton, Icons.menu));

      expect(gear.width, greaterThanOrEqualTo(44.0),
          reason: 'iOS HIG の最小タップ領域');
      expect(gear.height, greaterThanOrEqualTo(44.0));
      expect(gear.overlaps(menu), isFalse,
          reason: '的が重なると、狙ったほうと違う操作が発火する');
      expect(gear.right, lessThanOrEqualTo(menu.left),
          reason: '🔵 歯車はハンバーガーの左。設定は「画面の操作」なので '
              'actions が規約で、leading (iOS では戻るの場所) には置かない');
    });

    testWidgets('🔴 A-3: 等速のときバッジは描かれない', (tester) async {
      await _pumpGuildHeader(tester, speed: 1.0);

      expect(find.text('1x'), findsNothing,
          reason: '既定値の「1x」は情報量がゼロ。常時出していると見慣れてしまい、'
              '本当に気付いて欲しい ⏭ / 3x のときに埋もれる');
      expect(find.byIcon(Icons.settings), findsOneWidget,
          reason: '既定状態の AppBar は歯車とハンバーガーだけになること');
    });

    testWidgets('🔴 A-3b: Skip のときはバッジが現れて強調される', (tester) async {
      await _pumpGuildHeader(tester, speed: 50.0);

      expect(find.text('⏭'), findsOneWidget,
          reason: 'モーダルは出口を作るが、そもそも Skip のままだと気付けていない'
              'のが問題の本体。開かなくても見える場所に現在値を出すのが'
              '一方通行問題の実質的な解決 (決定事項 2)');
      final badge = tester.widget<Text>(find.text('⏭'));
      expect(badge.style?.color, AppTheme.primary);
    });

    testWidgets('A-3c: 3x でもバッジが出る (⏭ 専用ではない)', (tester) async {
      await _pumpGuildHeader(tester, speed: 3.0);
      expect(find.text('3x'), findsOneWidget);
    });

    testWidgets('🔴 A-4: バッジをまたいでもハンバーガーは押せる', (tester) async {
      // バッジは幅が状態で変わる。出た分だけ他の action がずれるので、
      // 押せなくなっていないことを両方の状態で見る。
      for (final speed in [1.0, 50.0]) {
        await _pumpGuildHeader(tester, speed: speed);
        final menu = find.widgetWithIcon(IconButton, Icons.menu);
        expect(menu, findsOneWidget, reason: '速度 $speed で消えている');
        expect(tester.getRect(menu).width, greaterThanOrEqualTo(44.0),
            reason: '速度 $speed でハンバーガーの的が潰れている');
      }
    });
  });

  group('【FEAT-528】B: モーダルの読み書き', () {
    testWidgets('B-1: 速度を選ぶと provider と SharedPreferences の両方が変わる',
        (tester) async {
      final container = await _pumpGuildHeader(tester, speed: 1.0);
      await _tapGear(tester);

      await tester.tap(find.descendant(
        of: find.byType(BattleSettingsDialog),
        matching: find.text('3x'),
      ));
      await tester.pump();
      await tester.pump();

      expect(container.read(battleSpeedPreferenceProvider), 3.0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(_speedKey), 3.0,
          reason: '永続化しないと、次のバトルで元に戻る = 出口として機能しない');
    });

    testWidgets('B-1b: ⏭ を選ぶと 50.0 になり、AppBar のバッジが即座に現れる',
        (tester) async {
      final container = await _pumpGuildHeader(tester, speed: 1.0);
      await _tapGear(tester);

      await tester.tap(find.descendant(
        of: find.byType(BattleSettingsDialog),
        matching: find.text('⏭'),
      ));
      await tester.pump();
      await tester.pump();

      expect(container.read(battleSpeedPreferenceProvider), 50.0);
      expect(find.descendant(
        of: find.byType(GuildBattleSettingsAction),
        matching: find.text('⏭'),
      ), findsOneWidget,
          reason: '等速では出ていなかったバッジが、変更した瞬間に現れること');
    });

    testWidgets(
      '🔴 B-2: モーダルで変えた値が、走っているバトルの速度チップに届く',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          _speedKey: 1.0,
          kPrefsBattleBackHintShown: true,
        });
        late _FakeSessionNotifier notifier;
        final container = ProviderContainer(overrides: [
          battleSessionProvider.overrideWith((ref) {
            notifier = _FakeSessionNotifier(ref);
            return notifier;
          }),
        ]);
        addTearDown(container.dispose);

        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        container.read(battleSessionProvider.notifier);
        notifier.push(_runningSession(speed: 1.0));

        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('ja'),
            home: BattlePage(),
          ),
        ));
        await tester.pump();

        expect(_isChipSelected(tester, '1x'), isTrue, reason: '前提: 1x が選択状態');

        // BattlePage の上にモーダルを重ねる (ギルドと同じ開き方)。
        final ctx = tester.element(find.byType(BattlePage));
        showGeneralDialog<void>(
          context: ctx,
          barrierDismissible: true,
          barrierLabel: 'close',
          transitionDuration: const Duration(milliseconds: 200),
          pageBuilder: (dialogContext, __, ___) =>
              BattleSettingsDialog(onClose: () => Navigator.of(dialogContext).pop()),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        await tester.tap(find.descendant(
          of: find.byType(BattleSettingsDialog),
          matching: find.text('3x'),
        ));
        await tester.pump();
        // チップは AnimatedContainer(150ms) なので、色が着き切るまで進める。
        await tester.pump(const Duration(milliseconds: 250));

        expect(
          container.read(battleSessionProvider).state!.speedMultiplier,
          3.0,
          reason: 'AtbController.speedMultiplier は setSpeedMultiplier 経由でしか'
              '変わらない。これが無いと、モーダルを他画面に置いた瞬間に'
              '「変えたのに速さが変わらない」が発現する (Pre-mortem #2)',
        );
        expect(_isChipSelected(tester, '3x'), isTrue,
            reason: 'チップのハイライトが取り残されるのが BUG-79 の形');
        expect(_isChipSelected(tester, '1x'), isFalse);
        expect(container.read(battleSpeedPreferenceProvider), 3.0,
            reason: '永続設定と走行中の値の 2 つが食い違わないこと');

        await tester.pump(const Duration(seconds: 2)); // 戻るヒントの Timer
      },
    );

    testWidgets('B-3: モーダルでオートバトルを切り替えるとバーのトグルも変わる',
        (tester) async {
      final container = await _pumpGuildHeader(tester, autoBattle: false);

      await _tapGear(tester);
      final toggleInDialog = find.descendant(
        of: find.byType(BattleSettingsDialog),
        matching: find.byType(BattleToggleSwitch),
      );
      expect(tester.widget<BattleToggleSwitch>(toggleInDialog).value, isFalse);

      await tester.tap(find.descendant(
        of: find.byType(BattleSettingsDialog),
        matching: find.text(_l10n.guildAutoBattleLabel),
      ));
      await tester.pump();
      await tester.pump();

      expect(container.read(ambientAutoBattleEnabledProvider), isTrue);
      expect(tester.widget<BattleToggleSwitch>(toggleInDialog).value, isTrue,
          reason: 'モーダル内の表示が provider に追従すること');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(_autoKey), isTrue,
          reason: '永続化まで通ること (orchestrator の発火はこちらを見る)');
    });
  });

  group('【FEAT-528】C: 閉じ方', () {
    testWidgets('C-1: X ボタンで閉じる。勝手には閉じない', (tester) async {
      await _pumpGuildHeader(tester);
      await _tapGear(tester);
      expect(find.byType(BattleSettingsDialog), findsOneWidget);

      // モーダル手動 close 原則: 時間が経っても消えない。
      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(BattleSettingsDialog), findsOneWidget,
          reason: 'auto-dismiss は祝祭系 popup でも禁止されている (CLAUDE.md)');

      await tester.tap(find.descendant(
        of: find.byType(BattleSettingsDialog),
        matching: find.byIcon(Icons.close),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(BattleSettingsDialog), findsNothing);
      expect(find.byType(GuildBattleSettingsAction), findsOneWidget,
          reason: 'ShellRoute 配下で外側 context を pop すると、モーダルではなく'
              '画面ごと消える (FEAT-215)');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // E: 【2026-08-23 実機 QA】オートバトルバーの撤去
  // ───────────────────────────────────────────────────────────────────────────
  // ───────────────────────────────────────────────────────────────────────────
  // E: 【2026-08-23 実機 QA】オートバトルバーの撤去
  // ───────────────────────────────────────────────────────────────────────────
  group('【FEAT-528】E: バーの撤去とオートバトルの行き先', () {
    testWidgets('🔴 E-1: オートバトルのトグルはモーダルの中にある', (tester) async {
      await _pumpGuildHeader(tester);

      expect(find.byType(BattleToggleSwitch), findsNothing,
          reason: 'ギルド画面本体にトグルは無い (バーごと撤去した)');

      await _tapGear(tester);

      expect(
        find.descendant(
          of: find.byType(BattleSettingsDialog),
          matching: find.byType(BattleToggleSwitch),
        ),
        findsOneWidget,
        reason: '🔴 撤去したのであって、機能を失ったのではないこと。'
            'ここが落ちるとオートバトルを切る手段が画面上のどこにも無くなる',
      );
      expect(
        find.descendant(
          of: find.byType(BattleSettingsDialog),
          matching: find.text(_l10n.guildAutoBattleSubtitle),
        ),
        findsOneWidget,
        reason: '「何をする機能か」の説明もモーダル側にあること',
      );
    });

    test('🔴 E-2: バーの実装はソースから消えている', () {
      final src =
          File('lib/features/guild/pages/guild_page.dart').readAsStringSync();
      expect(src.contains('class AutoBattleBar'), isFalse,
          reason: '未参照のまま残すと、次に触る人が「どちらが本物か」で迷う');
      expect(src.contains('guildAutoBattleSubtitle'), isFalse,
          reason: '副題はモーダル専用になった');
    });

    test('🔵 E-3: ON/OFF の判断材料は参加回数スピナーが担う', () {
      // バーを消せるのは、`_PresetCountRow` が **オートバトル ON のときだけ**
      // 描かれるから。ここが無条件描画に変わると、ギルド画面から
      // 「今 ON かどうか」を知る手段が完全に消える。
      // 🔴 コメントを落としてから走査する。**すぐ上の doc コメントに
      // 「`if (!isLocked && autoEnabled)` で囲まれている」と書いてある**ので、
      // 素朴に indexOf するとガードを外しても説明文に当たって緑のまま通る
      // (負の検証で実際に取り逃がした)。D-1 と同じ罠。
      final src = const LineSplitter()
          .convert(File('lib/features/guild/pages/guild_page.dart')
              .readAsStringSync())
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('|');
      final spinner = src.indexOf('_PresetCountRow(');
      expect(spinner, greaterThan(0), reason: 'スピナー自体が消えている');

      // ⚠️ `lastIndexOf('autoEnabled', spinner)` ではダメ。変数宣言
      // (`final autoEnabled = ...`) が遥か上にあるので、ガードを外しても
      // そちらに当たって緑のまま通る (実際に負の検証で取り逃がした)。
      // **ガードの式そのもの**を探し、スピナーが直後にあることまで見る。
      final guard = src.indexOf('if (!isLocked && autoEnabled)');
      expect(
        guard,
        greaterThan(0),
        reason: '🔴 スピナーの autoEnabled ガードが消えている。'
            'ガードが無いとオートバトル OFF でもスピナーが出るので、'
            '**バーを撤去した前提（ON のときだけ出るから状態が分かる）が崩れる**',
      );
      expect(guard, lessThan(spinner), reason: 'ガードはスピナーより前にあること');
      expect(spinner - guard, lessThan(200),
          reason: 'ガードとスピナーが離れている = 間に別の分岐が挟まった');
    });
  });

  group('【FEAT-528】D: ソース走査 (BUG-79 の再発防止)', () {
    // 行コメントを落としてから走査する。
    // doc コメントには「こう書いてはいけない」の例として同じ文字列が載っており、
    // 素直に走査すると**説明文が違反として検出される**。
    String stripComments(String src) => src
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    List<({String path, String src})> libSources() {
      final out = <({String path, String src})>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final rel = e.path.split(Platform.pathSeparator).join('/');
        // gen-l10n の生成物は対象外 (gitignore 済、内容は ARB 由来)。
        if (rel.startsWith('lib/l10n/app_localizations')) continue;
        out.add((path: rel, src: stripComments(e.readAsStringSync())));
      }
      return out;
    }

    test('🔴 D-1: バトル速度を書き込むファイルは battle_provider だけ', () {
      final writers = <String>[];
      for (final f in libSources()) {
        if (!f.src.contains('setDouble')) continue;
        // 直書きリテラルでも、notifier の定数経由でも捕まえる。
        if (!f.src.contains('battle_speed_multiplier') &&
            !f.src.contains('prefsKey')) {
          continue;
        }
        writers.add(f.path);
      }
      writers.sort();

      expect(
        writers,
        ['lib/features/battle/providers/battle_provider.dart'],
        reason: '🔴 書き手が 2 つあると BUG-79 が再発する —— FEAT-416 の hotfix で '
            '「_SpeedChip は 1x をハイライトしているのに実速度は 3x」という'
            'ユーザー報告が実際に出ている。書き手が分かれた瞬間、どちらかが'
            '片方の更新を忘れる',
      );
    });

    test('D-1b: battle_provider 内でも setDouble は 1 箇所だけ', () {
      final src = libSources()
          .firstWhere((f) =>
              f.path == 'lib/features/battle/providers/battle_provider.dart')
          .src;
      expect(
        'setDouble'.allMatches(src).length,
        1,
        reason: 'clamp 結果の書き戻し (FEAT-529 Pre-mortem #1) 等が紛れ込んでいない',
      );
    });

    test('D-1c: battle_page は速度 pref を直接触らない', () {
      final src = libSources()
          .firstWhere((f) => f.path == 'lib/features/battle/pages/battle_page.dart')
          .src;
      expect(src.contains('SharedPreferences'), isFalse,
          reason: '_SpeedChip の永続化は battleSpeedPreferenceProvider に移した');
    });

    test('🔴 D-3: 歯車は AppBar actions のハンバーガーの左にある', () {
      // widget テストはハーネス側で actions を組むので、**実装の並び**は
      // ここで見る。ハーネスと実装がズレたときに気付ける唯一の場所。
      final src = libSources()
          .firstWhere((f) => f.path == 'lib/features/guild/pages/guild_page.dart')
          .src;

      final action = src.indexOf('const GuildBattleSettingsAction()');
      final menu = src.indexOf('Icons.menu');
      expect(action, greaterThan(0), reason: '歯車が AppBar から消えている');
      expect(menu, greaterThan(0));
      expect(
        action,
        lessThan(menu),
        reason: '🔵 歯車はハンバーガーの左 (2026-08-23 ユーザー判断)。'
            '設定は「画面の操作」なので actions が規約',
      );

      // leading に置かないこと: iOS の左上は「戻る」の場所で、
      // 他画面から戻ったつもりで設定を開いてしまう。
      expect(src.contains('leading:'), isFalse,
          reason: 'AppBar の leading は空のままにする');
    });

    test('🔴 D-2: オートバトルの toggle 処理も 1 箇所だけ', () {
      // バーとモーダルの 2 箇所から呼ぶので、コピーすると
      // **片方を直したときにもう片方が古くなる**。特に PostHog の計測が
      // 「バーからの toggle だけ」になっても、数字が減ったことに誰も気付けない。
      final owners = <String>[];
      for (final f in libSources()) {
        if (f.src.contains("'ambient_battle_toggled'")) owners.add(f.path);
      }
      owners.sort();
      expect(
        owners,
        ['lib/features/battle/providers/battle_provider.dart'],
        reason: 'FEAT-528 Pre-mortem #6',
      );
    });

    test('D-2b: トグルの見た目も共有されている (バーとモーダルで 2 本持たない)', () {
      final definitions = <String>[];
      for (final f in libSources()) {
        if (f.src.contains('class BattleToggleSwitch')) definitions.add(f.path);
        if (f.src.contains('class _ToggleSwitch')) definitions.add(f.path);
      }
      expect(
        definitions,
        ['lib/features/battle/widgets/battle_toggle_switch.dart'],
        reason: '同じ画面から 1 タップで行き来できる 2 箇所なので、'
            '寸法や色がズレると即座に目に付く',
      );
    });
  });
}
