// 【FEAT-534 Phase 3 (2026-08-29)】popup の「合計を数える担当」。
//
// ## なぜこのテストが本 FEAT の成果物の本体なのか
//
// ゲームプレイレビュー 20260824 §2-2 の中心的な指摘は
// 「**誰も間違っていない。合計を数える担当が誰にも割り当てられていない**」
// だった。BUG-122 が 1 枚足し、FEAT-479 が 1 枚足し、FEAT-438 が SnackBar を
// ダイアログに昇格させた。**それぞれの判断は正しい。**
//
// したがって直すべきは個々の popup ではなく、
// **「6 枚目を足すときに合計が見える」構造**である。
//
// ## 縛り方
//
// `lib/` を走査して popup を出す API の呼び出しを**全部**見つけ、
// 1 件残らず下の census に登録されていることを確認する。登録が無ければ落ちる。
//
// 🔴 **`PopupSerializer` を通っていない `showDialog` 直呼びも走査対象に含める。**
// 「直列化を通っていない popup」こそ数え漏れの本体だからである。実際、本テストを
// 書いたことで **7 件の「自動発火なのに直列化されていない popup」** が見つかった
// (`_Kind.unserializedAuto`)。指示書 §1.1 が数えた 5 件には入っていなかった。
//
// ## 空振り検出 (§7.3)
//
// 🔴 走査が壊れて 0 件になったら、このテストは**緑のまま**になりうる。
// それを防ぐため、走査結果と census を**両方向**で突き合わせる:
//
//   1. 走査で見つかったのに census に無い  → fail (新しい popup が足された)
//   2. census にあるのに走査で見つからない → fail (走査が壊れた or 消された)
//
// 2 の判定は 1 と**同じ [_scanPopupSites] の戻り値**を使う。別ロジックで
// 「空振りしていないこと」を確かめると、走査を潰したときに両方緑になる
// (FEAT-536 で実際に起きた)。
//
// ## 走査対象に入れない API
//
// `SnackBar` / `LiliaFloatingPanel` / `OverlayEntry` (RewardToast) は
// **モーダルではない** ので数えない。タップを 1 つも要求せず、放置すれば消える。
// レビューが数えていた「タップ数」に乗らないため、順序制御の対象外である。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sabiowl/core/services/popup_serializer.dart';

/// popup がどういう性格のものか。**登録するときはここを選ぶことになる。**
enum _Kind {
  /// §3.1 の表示順に載る自動発火 popup。`PopupSerializer` 経由で
  /// [PopupPriority] を宣言する。**ここに増やすときは PM 判断が要る。**
  ordered,

  /// [ordered] な popup の実体。既に enqueue された task の中から呼ばれるので、
  /// それ自体は直列化を通っている。
  insideSerializer,

  /// 🔴 **自動発火 (ユーザーが求めていない) なのに `PopupSerializer` を
  /// 通っていない。** 既知の負債で、FEAT-534 では器 (順序・枚数) を決めるのが
  /// 目的なので**触っていない**。順序表に載せるかどうかは PM 判断。
  unserializedAuto,

  /// ユーザーのタップから始まる。表示順の対象外。
  userAction,
}

class _Entry {
  const _Entry(this.sites, this.kinds, this.note);

  /// 走査で見つかるはずの呼び出し箇所の数。
  ///
  /// 🔴 **数を持たせているのは「既存ファイルに 6 枚目を足す」を見逃さないため。**
  /// ファイル名だけの census だと、`home_listeners.dart` に popup をもう 1 つ
  /// 足しても気づけない。
  final int sites;
  final Set<_Kind> kinds;
  final String note;
}

/// 🔴 ここに載っていない popup が現れたらテストが落ちる。
///
/// 落ちたら「**順序 (§3.1) のどこに入るか**」と「**同時に何枚まで出るか**」を
/// 決めてから登録すること。**数えるのはこのテストの仕事である。**
const Map<String, _Entry> _census = <String, _Entry>{
  // ── ① §3.1 の表示順に載る 5 件 ────────────────────────────────────────
  'lib/shared/widgets/level_up_dialog.dart':
      _Entry(1, {_Kind.ordered}, '1: タップの直接の結果'),
  // 【BUG-150 (2026-08-29)】旧 home_listeners.dart から移設。
  // HomePage の中にしか居ないと、素の ShellRoute がタブ切替で unmount するため
  // カレンダータブから達成しても発火しなかった。
  'lib/core/widgets/app_popup_listeners.dart':
      _Entry(2, {_Kind.ordered, _Kind.unserializedAuto},
          '2: LoginBonusCalendarDialog / + BackupPromptSheet は未直列化'),
  'lib/main.dart':
      _Entry(1, {_Kind.ordered}, '3: 今月の節目 (21 日達成)'),
  'lib/features/puzzle_world/widgets/puzzle_piece_listener.dart':
      _Entry(3, {_Kind.ordered}, '4: 世界の変化 (task / quest / 完成の 3 経路)'),
  'lib/features/social/widgets/friend_gift_popup_listener.dart':
      _Entry(1, {_Kind.ordered}, '5: 他者が絡む'),

  // ── ② ordered の実体 (enqueue 済み task の中から呼ばれる) ──────────────
  'lib/features/puzzle_world/widgets/puzzle_piece_overlay_modal.dart':
      _Entry(2, {_Kind.insideSerializer}, 'かけら overlay 本体 (task / quest)'),
  'lib/features/puzzle_world/widgets/puzzle_completion_modal.dart':
      _Entry(1, {_Kind.insideSerializer}, 'シーン完成モーダル本体'),

  // ── ③ 🔴 自動発火なのに直列化を通っていない (既知の負債) ────────────────
  //
  // 🔴 **これが本テストを書いて見つかったもの。** 指示書 §1.1 の 5 件には
  // 1 つも入っていなかった。順序表に載せるかは PM 判断なので FEAT-534 では
  // **触っていない** (器を決めるのが本 FEAT の役目)。
  'lib/features/habits/pages/home_notification_prompt_controller.dart':
      _Entry(1, {_Kind.unserializedAuto},
          '🔴 通知ソフトプロンプト。**Day 1 の初回タップ経路**で 200ms 後に出る'),
  'lib/features/announcement/widgets/announcement_popup_listener.dart':
      _Entry(1, {_Kind.unserializedAuto}, 'お知らせ popup (未読があればホームで自動)'),
  'lib/features/habits/widgets/world_frame/world_frame_listeners.dart':
      _Entry(1, {_Kind.unserializedAuto}, '出陣上限ダイアログ (battleSession の listen)'),
  'lib/features/habits/widgets/world_frame/world_battle_end_modal.dart':
      _Entry(1, {_Kind.unserializedAuto}, '戦闘終了モーダル (ホーム経路)'),
  'lib/features/battle/pages/battle_page.dart':
      _Entry(1, {_Kind.unserializedAuto}, '戦闘終了モーダル (BattlePage 経路)'),
  'lib/features/battle/dialogs/post_battle_rewards.dart':
      _Entry(1, {_Kind.unserializedAuto}, '戦闘後報酬。上記 2 経路の共通実体'),

  // ── ④ ユーザーのタップから始まる (表示順の対象外) ──────────────────────
  'lib/features/calendar/pages/calendar_page.dart': _Entry(4, {_Kind.userAction}, ''),
  'lib/features/calendar/widgets/calendar_tab.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/features/calendar/widgets/gcal_intro_sheet.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/features/challenge/widgets/challenge_card.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/features/free_memo/pages/memo_page.dart': _Entry(5, {_Kind.userAction}, ''),
  'lib/features/free_memo/widgets/memo_trash_sheet.dart': _Entry(2, {_Kind.userAction}, ''),
  'lib/features/gamification/pages/achievement_page.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/features/gamification/pages/character_page.dart': _Entry(2, {_Kind.userAction}, ''),
  'lib/features/gamification/pages/gacha_page.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/features/gamification/pages/gacha_summon_page.dart': _Entry(2, {_Kind.userAction}, ''),
  'lib/features/gamification/pages/shop_page.dart': _Entry(3, {_Kind.userAction}, ''),
  'lib/features/gamification/pages/stats_page.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/features/gamification/widgets/job_mastery_info_dialog.dart':
      _Entry(1, {_Kind.userAction}, ''),
  'lib/features/guild/pages/guild_page.dart': _Entry(3, {_Kind.userAction}, ''),
  'lib/features/habits/pages/archived_habits_page.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/features/habits/pages/edit_todo_page.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/features/habits/pages/habit_detail_page.dart': _Entry(2, {_Kind.userAction}, ''),
  'lib/features/habits/pages/home_page.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/features/habits/widgets/habit_card.dart': _Entry(2, {_Kind.userAction}, ''),
  'lib/features/habits/widgets/habit_filter_bar.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/features/puzzle_world/pages/scene_selection_page.dart':
      _Entry(1, {_Kind.userAction}, ''),
  'lib/features/settings/pages/settings_page.dart': _Entry(9, {_Kind.userAction}, ''),
  'lib/features/shop/pages/diamond_pack_page.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/features/social/pages/contact_page.dart': _Entry(2, {_Kind.userAction}, ''),
  'lib/features/social/pages/friend_list_page.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/features/social/pages/friend_profile_page.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/features/social/pages/notifications_page.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/features/task_suggestion/widgets/task_title_search_sheet.dart':
      _Entry(1, {_Kind.userAction}, ''),
  'lib/features/timeline/pages/edit_event_page.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/features/timeline/pages/edit_template_page.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/features/timeline/pages/timeline_defaults_page.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/features/timeline/pages/timeline_page.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/shared/widgets/add_task_modal.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/shared/widgets/category_request_dialog.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/shared/widgets/drum_roll_time_picker.dart': _Entry(1, {_Kind.userAction}, ''),
  'lib/shared/widgets/guest_promote_conflict_dialog.dart': _Entry(1, {_Kind.userAction}, ''),
};

/// 走査から外すファイル。**実装そのもの**なので数えない。
const _kExcluded = <String>{
  'lib/core/services/popup_serializer.dart',
};

/// popup を出す API。
///
/// `showModalBottomSheet` も含める —— 通知ソフトプロンプトは bottom sheet で、
/// **Day 1 の初回タップ経路に実在する**。「ダイアログだけ数える」にすると
/// それを取りこぼす。
final _popupApi = RegExp(
  r'\b(showDialog|showGeneralDialog|showModalBottomSheet'
  r'|PopupSerializer\.enqueueShowDialog|PopupSerializer\.enqueue)\s*[<(]',
);

/// 🔴 **走査本体。空振り検出もこの関数の戻り値を使う** (§7.3)。
///
/// 別々のロジックで「見つけた」と「見落としていない」を確かめると、走査を
/// 潰したときに両方緑になる。同じ関数を共有していれば、走査が 0 件を返した
/// 瞬間に「census にあるのに見つからない」側が落ちる。
Map<String, int> _scanPopupSites() {
  final result = <String, int>{};
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    // Windows は path separator が円記号なので、census のキー ('/') に寄せる。
    final path = entity.path.split(Platform.pathSeparator).join('/');
    if (_kExcluded.contains(path)) continue;
    // 行コメントは落とす。「昔こう書いていた」という説明文を数えないため。
    final code = entity
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    final count = _popupApi.allMatches(code).length;
    if (count > 0) result[path] = count;
  }
  return result;
}

void main() {
  group('popup census (FEAT-534 §7)', () {
    late final Map<String, int> found;

    setUpAll(() {
      found = _scanPopupSites();
    });

    test('走査が実際に popup を見つけている (空振りしていない)', () {
      // 🔴 これが無いと、走査が壊れて 0 件になったときに以降の突き合わせが
      // 「差分なし」で緑になる余地が残る。
      expect(found, isNotEmpty,
          reason: '走査が 1 件も popup を見つけていない。_popupApi か lib/ の '
              '読み取りが壊れている。');
    });

    test('🔴 走査で見つかった popup はすべて census に登録されている', () {
      final unregistered = found.keys.where((p) => !_census.containsKey(p)).toList()
        ..sort();
      expect(
        unregistered,
        isEmpty,
        reason: '''
census に無い popup が見つかった:
${unregistered.map((p) => '  - $p (${found[p]} 箇所)').join('\n')}

FEAT-534 §7: 落ちたら「順序 (§3.1) のどこに入るか」と「同時に何枚まで出るか」を
決めてから popup_census_test.dart の _census に登録すること。
数えるのはこのテストの仕事である。''',
      );
    });

    test('🔴 census にあるのに走査で見つからない項目が無い (空振り検出)', () {
      // §7.3: 走査本体 (_scanPopupSites) と**同じ戻り値**で判定する。
      final stale = _census.keys.where((p) => !found.containsKey(p)).toList()..sort();
      expect(
        stale,
        isEmpty,
        reason: '''
census にあるのに走査で見つからなかった:
${stale.map((p) => '  - $p').join('\n')}

popup を消したなら census からも消すこと。消していないなら**走査が壊れている**。''',
      );
    });

    test('🔴 各ファイルの呼び出し箇所数が census と一致する', () {
      final mismatched = <String>[];
      for (final path in _census.keys) {
        final actual = found[path];
        if (actual == null) continue;   // 上のテストが担当
        if (actual != _census[path]!.sites) {
          mismatched.add('  - $path: census ${_census[path]!.sites} 箇所 → 実際 $actual 箇所');
        }
      }
      mismatched.sort();
      expect(
        mismatched,
        isEmpty,
        reason: '''
呼び出し箇所数が census とずれている:
${mismatched.join('\n')}

🔴 **数を持たせているのは「既存ファイルに 6 枚目を足す」を見逃さないため。**
ファイル名だけの census だと、home_listeners.dart に popup をもう 1 つ足しても
気づけない。増やしたなら §3.1 のどこに入るかを決めてから数を更新すること。''',
      );
    });

    test('§3.1 の表示順に載る popup は 5 件で、優先度を宣言している', () {
      final ordered = _census.entries
          .where((e) => e.value.kinds.contains(_Kind.ordered))
          .map((e) => e.key)
          .toList()
        ..sort();
      expect(ordered.length, 5,
          reason: '順序表に載る popup が 5 件から変わった: $ordered\n'
              '🔴 §3.1 の順序は PM 判断。増減させるなら PM 判断を取ること。');

      // 実際に PopupPriority を渡しているか (優先度が「宣言されている」こと)。
      for (final path in ordered) {
        final source = File(path).readAsStringSync();
        expect(source.contains('PopupPriority.'), isTrue,
            reason: '$path が PopupPriority を宣言していない。'
                '宣言しないと PopupPriority.unranked = 最後尾に落ちる。');
      }
    });

    test('§3.1 の順位が 1..5 で重複していない', () {
      const order = <String, int>{
        'levelUp': PopupPriority.levelUp,
        'loginBonus': PopupPriority.loginBonus,
        'monthlyTicket': PopupPriority.monthlyTicket,
        'puzzlePiece': PopupPriority.puzzlePiece,
        'friendGift': PopupPriority.friendGift,
      };
      expect(order.values.toList(), [1, 2, 3, 4, 5],
          reason: '🔴 §3.1「① そのタップの直接の結果 → ② その日の節目 → ③ 世界の変化」。'
              'この順序は PM 判断なので Develop が黙って変えないこと。');
      expect(order.values.toSet().length, 5, reason: '優先度が重複している。');
      expect(PopupPriority.unranked, greaterThan(5),
          reason: '宣言し忘れた popup は最後尾に落ちること。');
    });

    test('🔴 直列化されていない自動発火 popup は既知の 7 件だけ', () {
      final unserialized = _census.entries
          .where((e) => e.value.kinds.contains(_Kind.unserializedAuto))
          .map((e) => e.key)
          .toList()
        ..sort();
      expect(
        unserialized.length,
        7,
        reason: '''
「自動発火なのに PopupSerializer を通っていない popup」の数が変わった:
${unserialized.map((p) => '  - $p').join('\n')}

🔴 **増えたなら止めること。** 直列化を通らない自動 popup は、順序制御の外側で
他の popup と重なりうる。PopupSerializer 経由に直すか、なぜ通さないのかを
census の note に書くこと。''',
      );
    });

    test('自動発火 popup の総数が把握できている', () {
      var autoSites = 0;
      for (final entry in _census.entries) {
        final kinds = entry.value.kinds;
        if (kinds.contains(_Kind.ordered) ||
            kinds.contains(_Kind.unserializedAuto)) {
          autoSites += entry.value.sites;
        }
      }
      // ordered 8 箇所 (level_up 1 + home_listeners 1 + main 1 + puzzle 3
      // + friend_gift 1 ... のうち home_listeners は 2 箇所で 1 つが未直列化)
      // + unserializedAuto (home_listeners を除く 6 ファイル) 6 箇所 = 14。
      expect(autoSites, 14,
          reason: '🔴 ユーザーが求めていないのに出る popup の総数が変わった。'
              'この数字が「合計を数える担当」の答えである。');
    });
  });
}
