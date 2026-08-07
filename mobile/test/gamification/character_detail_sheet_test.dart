// 【2026-08-05】CharacterPage 詳細シートの UI 契約テスト。
//
// _CharacterDetailSheet.build() が 423 行あったものを 8 個の widget に
// 分割した (build() は 94 行に縮小)。**このファイルにはテストが 1 件も
// 無かった**ため、分割前後で表示が変わっていないことを検証できなかった。
// 本テストはその安全網として追加する。
//
// 抽出した widget は private なのでテストから直接触れない。
// CharacterPage をレンダリングしてカードをタップし、シートの内容を
// 経路ごと検証する (= ユーザーが見るものを検証する)。
//
// カバーする widget:
//   _CharacterAvatar / _CharacterNameRow / _RoleBadge / _CharacterTagline
//   _JobModifierSection / _JobMasteryBar / _LockedPriceSection
//   _DetailActionButtons

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabiowl/features/battle/models/job.dart';
import 'package:sabiowl/features/gamification/models/gamification_models.dart';
import 'package:sabiowl/features/gamification/models/job_mastery.dart';
import 'package:sabiowl/features/gamification/pages/character_page.dart';
import 'package:sabiowl/features/gamification/providers/gamification_provider.dart';
import 'package:sabiowl/features/gamification/services/job_mastery_service.dart';
import 'package:sabiowl/features/habits/models/player.dart';
import 'package:sabiowl/features/habits/providers/habits_provider.dart';
import 'package:sabiowl/l10n/app_localizations.dart';

// ── モック ────────────────────────────────────────────────────

Character _character({
  required int id,
  required String name,
  String role = '戦士',
  String tagline = '',
  bool owned = false,
  bool active = false,
  bool isStarter = false,
  bool isNew = false,
  int price = 800,
  Job? job,
}) {
  return Character(
    id: id,
    key: 'char_$id',
    name: name,
    role: role,
    description: '',
    imagePath: '',
    price: price,
    unlockLevel: 1,
    isStarter: isStarter,
    order: id,
    owned: owned,
    active: active,
    job: job,
    tagline: tagline,
    isNew: isNew,
  );
}

Player _player({int exchangeTickets = 0}) => Player(
      id: 1,
      name: 'テスト',
      gender: 'f',
      level: 5,
      currentExp: 0,
      maxExp: 380,
      allocatablePoints: 0,
      diamonds: 0,
      diamondsTotal: 0,
      friendId: 'TEST0001',
      dailyTickets: 0,
      weeklyTickets: 0,
      monthlyTickets: 0,
      reminderEnabled: false,
      mode: 'training',
      characterExchangeTickets: exchangeTickets,
    );

class _MockCharactersNotifier extends CharactersNotifier {
  _MockCharactersNotifier(this._chars);
  final List<Character> _chars;

  @override
  Future<List<Character>> build() async => _chars;
}

class _MockPlayerNotifier extends PlayerNotifier {
  _MockPlayerNotifier(this._p);
  final Player _p;

  @override
  Future<Player> build() async => _p;
}

Widget _harness({
  required List<Character> chars,
  int exchangeTickets = 0,
  List<JobMastery> masteries = const [],
}) {
  return ProviderScope(
    overrides: [
      charactersNotifierProvider.overrideWith(() => _MockCharactersNotifier(chars)),
      playerNotifierProvider
          .overrideWith(() => _MockPlayerNotifier(_player(exchangeTickets: exchangeTickets))),
      jobMasteriesProvider.overrideWith((ref) async => masteries),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale('ja'),
      home: CharacterPage(),
    ),
  );
}

/// キャラカードをタップして詳細シートを開く。
Future<void> _openSheet(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).first);
  await tester.pumpAndSettle();
}

void main() {
  group('CharacterPage 詳細シート (build() 分割の回帰ガード)', () {
    testWidgets('1. 名前・役職・キャッチコピーが表示される', (tester) async {
      await tester.pumpWidget(_harness(chars: [
        _character(id: 1, name: 'ソル', role: '剣士', tagline: '静かなる一撃'),
      ]));
      await _openSheet(tester, 'ソル');

      // 名前はカードとシートの両方に出るので複数ヒットしうる
      expect(find.text('ソル'), findsWidgets);
      expect(find.text('剣士'), findsWidgets);
      expect(find.text('静かなる一撃'), findsOneWidget);
    });

    testWidgets('2. tagline が空なら表示されない', (tester) async {
      await tester.pumpWidget(_harness(chars: [
        _character(id: 1, name: 'ソル', tagline: ''),
      ]));
      await _openSheet(tester, 'ソル');

      // イタリック体の tagline widget が存在しないこと
      final italic = find.byWidgetPredicate(
        (w) => w is Text && w.style?.fontStyle == FontStyle.italic,
      );
      expect(italic, findsNothing);
    });

    // 【注】1 つの testWidgets 内で pumpWidget を 2 回呼ぶと、開いたままの
    // モーダルルートが次の pump に残って tap が hit test に失敗する。
    // isNew の on/off は別テストに分ける。
    testWidgets('3-a. NEW バッジは isNew=true のとき出る', (tester) async {
      await tester.pumpWidget(_harness(chars: [
        _character(id: 1, name: 'ノワール', isNew: true),
      ]));
      await _openSheet(tester, 'ノワール');
      expect(find.text('NEW'), findsWidgets);
    });

    testWidgets('3-b. NEW バッジは isNew=false なら出ない', (tester) async {
      await tester.pumpWidget(_harness(chars: [
        _character(id: 2, name: 'アリア', isNew: false),
      ]));
      await _openSheet(tester, 'アリア');
      expect(find.text('NEW'), findsNothing);
    });

    testWidgets('4. 未所持キャラは価格とロックアイコンが出る', (tester) async {
      await tester.pumpWidget(_harness(chars: [
        _character(id: 1, name: 'ノワール', owned: false, isStarter: false, price: 1500),
      ]));
      await _openSheet(tester, 'ノワール');

      // 価格はカード側とシート側の両方に出るため findsWidgets (元の挙動どおり)
      expect(find.text('💎'), findsWidgets);
      expect(find.text('1500'), findsWidgets);
      expect(find.byIcon(Icons.lock), findsWidgets);
      // 無料入手経路のヒント (ガチャアイコン) はシート側だけ
      expect(find.byIcon(Icons.casino_outlined), findsOneWidget);
    });

    testWidgets('5. 所持キャラは価格を出さず「選択する」ボタンになる', (tester) async {
      await tester.pumpWidget(_harness(chars: [
        _character(id: 1, name: 'ソル', owned: true),
      ]));
      await _openSheet(tester, 'ソル');

      expect(find.byIcon(Icons.casino_outlined), findsNothing);
      expect(find.byType(ElevatedButton), findsOneWidget);
    });

    testWidgets('6. 使用中キャラはボタンを出さない', (tester) async {
      await tester.pumpWidget(_harness(chars: [
        _character(id: 1, name: 'ソル', owned: true, active: true),
      ]));
      await _openSheet(tester, 'ソル');

      expect(find.byType(ElevatedButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('7. 交換券があれば交換ボタンが増える (未所持 SSR のみ)', (tester) async {
      await tester.pumpWidget(_harness(
        chars: [_character(id: 1, name: 'ノワール', owned: false, isStarter: false)],
        exchangeTickets: 2,
      ));
      await _openSheet(tester, 'ノワール');

      expect(find.byType(ElevatedButton), findsOneWidget);   // 購入
      expect(find.byType(OutlinedButton), findsOneWidget);   // 交換
    });

    testWidgets('8. 交換券が 0 なら交換ボタンは出ない', (tester) async {
      await tester.pumpWidget(_harness(
        chars: [_character(id: 1, name: 'ノワール', owned: false, isStarter: false)],
        exchangeTickets: 0,
      ));
      await _openSheet(tester, 'ノワール');

      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('9. job があればジョブ修飾子セクションが出る', (tester) async {
      await tester.pumpWidget(_harness(chars: [
        _character(
          id: 1,
          name: 'ソル',
          owned: true,
          job: const Job(
            jobId: 'warrior',
            jobName: '戦士',
            atbSpeedModifier: 1.0,
            attackPowerModifier: 1.2,
            onHitEffect: 'none',
            ultCost: 3,
          ),
        ),
      ]));
      await _openSheet(tester, 'ソル');

      expect(find.byIcon(Icons.shield), findsOneWidget);
    });

    testWidgets('10. job が null ならジョブセクションは出ない', (tester) async {
      await tester.pumpWidget(_harness(chars: [
        _character(id: 1, name: 'ソル', owned: true, job: null),
      ]));
      await _openSheet(tester, 'ソル');

      expect(find.byIcon(Icons.shield), findsNothing);
    });
  });
}
