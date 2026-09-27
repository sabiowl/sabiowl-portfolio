// 【BUG-150 (2026-08-29)】「達成レスポンス → provider」の配線を 1 箇所に閉じる。
//
// ## 何が起きていたか
//
// タスク達成のレスポンスには popup を出すためのフィールドが 4 つ乗っている
// (`todayLoginBonus` / `puzzlePieceAwarded` / `monthlyTicketAwarded` /
// `friendGiftCandidate`)。ところが**それを provider に流す配線が 5 箇所に
// 複製されており、どれも中身が違った**。
//
// | 経路 | 落ちていたもの |
// |---|---|
// | `habits_provider._incrementCount` | （完全） |
// | `habits_provider.toggleChecklistItem` | かけら / フレンドギフト / 復帰 / シールド / streak 系 |
// | `daily_task_section`（カレンダーの ToDo） | **上記 + ログインボーナス + 月次チケット + 結晶** |
// | `timeline_event_card`（ホームのタイムライン） | （完全） |
// | `daily_task_section`（カレンダーのタイムライン） | **ログインボーナス + かけら** |
//
// 🔴 **ログインボーナス / かけら / 月次チケットは Backend 側で配布済み**なので、
// 落ちた経路で初回達成すると **その日は二度と出ない**。報酬は入っているのに、
// もらったことに気づく手段が残らない。
//
// ## なぜ複製されたか
//
// `daily_task_section` が `habitsServiceProvider` を直呼びしているのは
// **BUG-56 の回避策**（`habitsNotifierProvider` は autoDispose で、カレンダー
// タブ滞在中に dispose されている）で、判断としては正しい。ただし結果として
// 配線が複製され、**後から足された BUG-122 / FEAT-433 / FEAT-452 / FEAT-479 が
// 片方にしか入らなかった**。
//
// FEAT-534 の `popup_census_test.dart` が見つけた「**誰も間違っていない。
// 合計を数える担当が誰にも割り当てられていない**」と同じ型の別インスタンスである。
//
// ## 縛り方
//
// 「popup 系 provider に**値を書いてよいファイル**」を走査で固定する。
// クリア（`null` / `false` / `const {}` を代入して popup を閉じたことにする）は
// listener 側の仕事なので別枠にする。
//
// 🔴 **6 箇所目を足したらここが落ちる。** 落ちたら
// `apply_completion_result.dart` に足すこと。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/features/habits/models/habit.dart';
import 'package:sabiowl/features/habits/providers/apply_completion_result.dart';
import 'package:sabiowl/features/habits/providers/habits_provider.dart';
import 'package:sabiowl/features/puzzle_world/providers/puzzle_world_provider.dart';
import 'package:sabiowl/features/social/providers/social_provider.dart';
import 'package:sabiowl/features/timeline/services/timeline_service.dart'
    show TimelineReward;

/// popup / トーストの発火に使われる provider。
const _kPopupProviders = <String>[
  'rewardToastProvider',
  'levelUpNotifierProvider',
  'levelUpAutoAllocationsProvider',
  'levelUpCrystalsProvider',
  'comebackNotifierProvider',
  'autoShieldNotifierProvider',
  'monthlyTicketAwardedNotifierProvider',
  'pendingLoginBonusProvider',
  'friendGiftCandidateProvider',
  'puzzlePieceAwardedProvider',
  'puzzlePieceColoredProvider',
];

/// 🔴 **値を書いてよいファイル。** ここに無いファイルが値を書いたら落ちる。
const _kAllowedValueWriters = <String, String>{
  'lib/features/habits/providers/apply_completion_result.dart':
      '🔴 単一真実値。達成レスポンス → provider の配線はここだけ',
  'lib/features/battle/providers/battle_provider.dart':
      'バトル経路の彩りかけら (puzzlePieceColored)。BattleFinishResult は別モデルなので '
      'BUG-150 のスコープ外 —— 触るなら別 FEAT で apply_completion_result に寄せること',
};

/// popup を閉じたあとに state を戻すファイル。**発火ではないので別枠。**
const _kAllowedClearers = <String, String>{
  'lib/features/habits/pages/home_listeners.dart': 'トースト / 復帰 SnackBar の後始末',
  'lib/core/widgets/app_popup_listeners.dart': 'ログインボーナス / レベルアップの後始末',
  'lib/features/calendar/pages/calendar_page.dart': '離脱時のトースト消し',
  'lib/features/puzzle_world/widgets/puzzle_piece_listener.dart': 'かけら overlay の後始末',
  'lib/features/social/widgets/friend_gift_popup_listener.dart': 'ギフト popup の後始末',
  'lib/main.dart': '月次チケット popup の後始末',
};

/// `ref.read(xxxProvider.notifier).state = ...;` を拾う。
final _assignment = RegExp(
  r'read\(\s*(' + _kPopupProviders.join('|') + r')\.notifier\s*\)\s*[.\s]*state\s*=\s*([^;]*);',
  dotAll: true,
);

/// 「消す」代入かどうか。popup を閉じたあとの後始末はこちら。
bool _isClear(String rhs) {
  final normalized = rhs.replaceAll(RegExp(r'\s+'), ' ').trim();
  return normalized == 'null' || normalized == 'false' || normalized == 'const {}';
}

class _Write {
  const _Write(this.file, this.provider, this.rhs);
  final String file;
  final String provider;
  final String rhs;

  @override
  String toString() => '$file  $provider = $rhs';
}

/// 🔴 **走査本体。空振り検出もこの戻り値を使う。**
///
/// 別ロジックで「見落としていない」を確かめると、走査を潰したときに両方緑になる
/// (FEAT-536 で実際に起きた)。
(List<_Write> values, List<_Write> clears) _scanPopupProviderWrites() {
  final values = <_Write>[];
  final clears = <_Write>[];
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = entity.path.split(Platform.pathSeparator).join('/');
    final source = entity.readAsStringSync();
    for (final match in _assignment.allMatches(source)) {
      final rhs = match.group(2)!.replaceAll(RegExp(r'\s+'), ' ').trim();
      final write = _Write(path, match.group(1)!, rhs.length > 48 ? '${rhs.substring(0, 48)}…' : rhs);
      (_isClear(rhs) ? clears : values).add(write);
    }
  }
  return (values, clears);
}

void main() {
  group('達成レスポンスの配線 (BUG-150)', () {
    late final List<_Write> values;
    late final List<_Write> clears;

    setUpAll(() {
      final scanned = _scanPopupProviderWrites();
      values = scanned.$1;
      clears = scanned.$2;
    });

    test('走査が実際に代入を見つけている (空振りしていない)', () {
      // 🔴 これが無いと、走査が壊れて 0 件になったときに以降の突き合わせが
      // 「差分なし」で緑になる。
      expect(values, isNotEmpty,
          reason: '走査が 1 件も代入を見つけていない。_assignment か lib/ の読み取りが壊れている。');
      expect(clears, isNotEmpty, reason: '同上（クリア側）。');
    });

    test('🔴 popup 系 provider に値を書いているのは許可されたファイルだけ', () {
      final offenders = values
          .where((w) => !_kAllowedValueWriters.containsKey(w.file))
          .toList();
      expect(
        offenders,
        isEmpty,
        reason: '''
達成レスポンスの配線が ${offenders.map((w) => w.file).toSet().length} ファイルに複製されている:

${offenders.map((w) => '  - $w').join('\n')}

🔴 **これが BUG-150 の本体である。** 配線を複製すると、次に popup が増えたときに
「片方にだけ足す」が起きる —— 実際に BUG-122 / FEAT-433 / FEAT-452 / FEAT-479 が
そうなった。

`apply_completion_result.dart` の `applyHabitLogResult` / `applyTimelineReward` を
呼ぶこと。新しいフィールドを足すならそこ 1 箇所に足す。''',
      );
    });

    test('後始末 (null / false / const {}) は listener 側に閉じている', () {
      final offenders =
          clears.where((w) => !_kAllowedClearers.containsKey(w.file)).toList();
      expect(
        offenders,
        isEmpty,
        reason: '''
popup を閉じる後始末が想定外のファイルにある:

${offenders.map((w) => '  - $w').join('\n')}

後始末は「その popup を表示した listener」の責任である。''',
      );
    });

    test('許可リストに死んだ項目が残っていない (空振り検出)', () {
      // 走査本体と**同じ戻り値**で判定する。走査が壊れれば必ずここが落ちる。
      final seenValues = values.map((w) => w.file).toSet();
      final seenClears = clears.map((w) => w.file).toSet();

      final staleValues =
          _kAllowedValueWriters.keys.where((f) => !seenValues.contains(f)).toList();
      final staleClears =
          _kAllowedClearers.keys.where((f) => !seenClears.contains(f)).toList();

      expect(staleValues, isEmpty,
          reason: '値を書く許可があるのに 1 度も書いていない: $staleValues\n'
              '消したなら許可リストからも消すこと。消していないなら走査が壊れている。');
      expect(staleClears, isEmpty,
          reason: '後始末の許可があるのに 1 度も後始末していない: $staleClears\n同上。');
    });

    // ── 実際に流れることを見る ────────────────────────────────────────
    //
    // 走査だけだと「共有関数を呼んでいる」ことしか分からない。**その関数が
    // 4 つとも provider に入れているか**は別に見る必要がある —— 落ちていたのは
    // まさにそこだからである。

    test('🔴 applyHabitLogResult は popup 4 種をすべて provider に入れる', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await applyHabitLogResult(
        container.read,
        HabitLogResult(
          habit: _dummyHabit,
          diamondEarned: true,
          expGain: 45,
          bonusExp: 5,
          newLevel: 3,
          prevLevel: 2,
          autoAllocations: const {'運動力': 10},
          crystalsAwarded: const {'exercise': 1},
          isComeback: true,
          autoShieldType: 'auto',
          monthlyTicketAwarded: true,
          todayLoginBonus: const {'amount': 500, 'days_count': 1},
          friendGiftCandidate: const {
            'id': 1, 'name': 'ふれんど', 'level': 5, 'friend_id': '000000000001',
          },
          puzzlePieceAwarded: const {
            'piece_index': 3, 'new_state': 1, 'scene_key': 'forest',
          },
        ),
      );

      // 🔴 落ちていた 4 つ
      expect(container.read(pendingLoginBonusProvider), isNotNull,
          reason: 'ログインボーナスが provider に入っていない。'
              'Backend は配布済みなので、ここで落とすとその日は二度と出ない。');
      expect(container.read(puzzlePieceAwardedProvider), isNotNull,
          reason: 'かけらが provider に入っていない。');
      expect(container.read(monthlyTicketAwardedNotifierProvider), isTrue,
          reason: '月次チケットが provider に入っていない。');
      expect(container.read(friendGiftCandidateProvider), isNotNull,
          reason: 'フレンドギフト候補が provider に入っていない。');

      // 併せて落ちていたもの
      expect(container.read(rewardToastProvider)?.expGain, 45);
      expect(container.read(levelUpNotifierProvider), 3);
      expect(container.read(levelUpAutoAllocationsProvider), {'運動力': 10});
      expect(container.read(levelUpCrystalsProvider), {'exercise': 1});
      expect(container.read(comebackNotifierProvider), isTrue);
      expect(container.read(autoShieldNotifierProvider), 'auto');
    });

    test('applyHabitLogResult は空のレスポンスで何も立てない', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await applyHabitLogResult(
        container.read,
        HabitLogResult(
          habit: _dummyHabit,
          diamondEarned: false,
          expGain: 0,
          newLevel: 1,
          prevLevel: 1,
        ),
      );

      expect(container.read(rewardToastProvider), isNull);
      expect(container.read(levelUpNotifierProvider), isNull);
      expect(container.read(pendingLoginBonusProvider), isNull);
      expect(container.read(puzzlePieceAwardedProvider), isNull);
      expect(container.read(monthlyTicketAwardedNotifierProvider), isFalse);
      expect(container.read(friendGiftCandidateProvider), isNull);
    });

    test('🔴 applyTimelineReward は popup 3 種をすべて provider に入れる', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      applyTimelineReward(
        container.read,
        const TimelineReward(
          expGain: 20,
          diamondEarned: true,
          todayLoginBonus: {'amount': 20, 'days_count': 3},
          friendGiftCandidate: {
            'id': 2, 'name': 'ともだち', 'level': 8, 'friend_id': '000000000002',
          },
          puzzlePieceAwarded: {
            'piece_index': 7, 'new_state': 1, 'scene_key': 'forest',
          },
        ),
      );

      expect(container.read(rewardToastProvider)?.expGain, 20);
      expect(container.read(pendingLoginBonusProvider), isNotNull,
          reason: 'カレンダーのタイムライン経路で落ちていたもの。');
      expect(container.read(puzzlePieceAwardedProvider), isNotNull,
          reason: '同上。');
      expect(container.read(friendGiftCandidateProvider), isNotNull);
    });

    test('🔴 4 つの popup フィールドは 1 ファイルからしか発火しない', () {
      // 「許可ファイルが 2 つある」ことで穴が開かないよう、popup 4 種だけは
      // **apply_completion_result.dart 単独**であることを別途縛る。
      const popupOnly = <String>[
        'pendingLoginBonusProvider',
        'puzzlePieceAwardedProvider',
        'monthlyTicketAwardedNotifierProvider',
        'friendGiftCandidateProvider',
      ];
      final files = values
          .where((w) => popupOnly.contains(w.provider))
          .map((w) => w.file)
          .toSet();
      expect(
        files,
        {'lib/features/habits/providers/apply_completion_result.dart'},
        reason: '''
popup 4 種の発火元が 1 ファイルに閉じていない: $files

🔴 これらは **Backend 側で配布済み** のフラグなので、落とした経路で初回達成すると
その日 (月) は二度と出ない。**報酬は入っているのに気づく手段が残らない。**''',
      );
    });
  });
}

/// テスト用の最小 Habit。`HabitLogResult` が required で要求するだけで、
/// 本テストの assert 対象ではない。
final _dummyHabit = Habit(
  id: 1,
  name: 'テスト習慣',
  category: '運動',
  frequency: 'daily',
  resetCycle: 'daily',
  habitType: 'count',
  difficulty: 'normal',
  priority: 'medium',
  order: 0,
  streak: 1,
  bestStreak: 1,
  totalCount: 1,
  isActive: true,
  memo: '',
  isPublic: false,
  shieldActive: false,
  checklistItems: const [],
);
