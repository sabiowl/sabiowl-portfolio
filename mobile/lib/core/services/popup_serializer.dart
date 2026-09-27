import 'dart:async';

import 'package:flutter/material.dart';

/// 【FEAT-534 (2026-08-29)】祝祭系 popup の表示順。**小さいほど先に出る。**
///
/// 🔴 **この順序は PM 判断である。Develop が黙って変えないこと。**
/// 変えるなら PM 判断を取ること (FEAT-534 §3.1)。
///
/// 方針は「**① そのタップの直接の結果 → ② その日の節目 → ③ 世界の変化**」:
///
/// | 順 | popup | 理由 |
/// |:-:|---|---|
/// | 1 | `LevelUpDialog` | タップした行為の直接の結果。EXP バーが満ちた理由をその場で示す |
/// | 2 | `LoginBonusCalendarDialog` | 「今日の初回」という節目の報酬 |
/// | 3 | `MonthlyTicketAwardedDialog` | 「今月の節目」。2 より粒度が粗い |
/// | 4 | `PuzzlePieceOverlayModal` | 世界側の変化。**自分の行為から最も遠い** |
/// | 5 | `FriendGiftPopup` | 他者が絡む。かつ**確認を求める**ので祝祭の直後に置きたくない |
///
/// 【FEAT-534 以前】順序は「誰が先に `enqueue` を呼んだか」だけで決まっていた。
/// かけらは `build` の同期パスで、他は `addPostFrameCallback` の中で enqueue して
/// いたため、**かけらが構造的に必ず先頭**になっていた。これは設計判断の結果では
/// なく、**片方が同期・片方が postFrame という実装差の副産物**だった。
/// 結果として「ユーザーがタップした行為に対する報酬 (ログインボーナス)」より
/// 「世界の副作用 (かけら)」が先に出ていた。
abstract final class PopupPriority {
  /// 1: タップした行為の直接の結果。
  static const int levelUp = 1;

  /// 2: その日の節目 (初回タスク達成)。
  static const int loginBonus = 2;

  /// 3: 今月の節目 (21 日達成)。
  static const int monthlyTicket = 3;

  /// 4: 世界側の変化。自分の行為から最も遠い。
  static const int puzzlePiece = 4;

  /// 5: 他者が絡む。確認を求めるので最後。
  static const int friendGift = 5;

  /// 優先度を宣言していない popup の既定値。
  ///
  /// 🔴 **意図的に最後尾**にしてある。宣言し忘れた popup が黙って先頭に
  /// 割り込むより、最後に回って「順序表に載せ忘れている」と気づけるほうがよい。
  static const int unranked = 100;
}

/// 【2026-06-27 / gameplay_review 20260627 P2-1 対応】
/// 複数の「祝祭系」ポップアップが同一アクションから同時発火しても、
/// **構造的に順次表示** されるように直列化するヘルパー。
///
/// 【背景】
/// `LoginBonusCalendarDialog` / `LevelUpDialog` / `FriendGiftPopupListener` /
/// `MonthlyTicketAwardedDialog` は、それぞれ独立した `ref.listen` + 独立した
/// `addPostFrameCallback` で `showDialog` を呼ぶ設計になっており、ある日の
/// 3 回目の習慣達成がたまたまレベルアップも引き起こす等の狭いエッジケースで、
/// 「お祝いダイアログを連続で 2 回閉じる」体験が発生しうる。これは Sabi の
/// 「静かな聖環」哲学とやや相反するため、ダイアログをシリアル化する。
///
/// 【動作 (FEAT-534 で FIFO → 優先度付きキューに変更)】
/// - **待機中**の popup は優先度順 (小さいほど先)、同一優先度は enqueue 順 (FIFO)
/// - 🔴 **表示中の popup は追い越されない。** 優先度を見るのは「次に何を出すか」を
///   決める瞬間だけで、走り出した task は最後まで走る
/// - 前の task が例外を投げても後続には影響しない (例外は enqueue した本人に返る)
/// - 優先度を渡さない呼び出しは [PopupPriority.unranked] = 最後尾
///
/// 【使い方】
/// ```dart
/// // 旧:
/// // await showDialog<T>(context: context, builder: builder);
/// // 新:
/// await PopupSerializer.enqueueShowDialog<T>(
///   context: context,
///   builder: builder,
///   priority: PopupPriority.loginBonus,
/// );
/// ```
///
/// 【Pre-mortem】
/// - context unmounted で enqueue → 自分の dialog は null returned、queue は次へ進む
/// - dialog 内で例外 throw → 後続は予定通り表示、例外は呼出元に伝わる
/// - 1 つの dialog をユーザーが放置 → 後続は待たされる (仕様通り、放置自体は稀)
/// - 同一 listener が一瞬で複数 enqueue → 同一優先度なので FIFO で順次表示
/// - 4 つの popup 同時発火 → 4 つすべてが順次表示される (1 つも漏れない設計)
/// - 🔴 **task の中から `enqueue` を await しないこと** —— pump が自分の完了を
///   待っている状態で自分を待つことになり、deadlock する (旧 FIFO 実装も同じ)
class PopupSerializer {
  PopupSerializer._();

  /// 待機中の popup。**表示中のものはここには居ない** (pump が取り出している)。
  static final List<_QueuedPopup> _waiting = <_QueuedPopup>[];

  /// pump が走っているか。表示中の task があるあいだ true。
  static bool _pumping = false;

  /// 同一優先度の FIFO を保つための連番。
  static int _sequence = 0;

  /// 待機中の popup 数。テストと診断用。
  @visibleForTesting
  static int get waitingCount => _waiting.length;

  /// 表示中の popup があるか。テストと診断用。
  @visibleForTesting
  static bool get isBusy => _pumping;

  /// `showDialog` を直列化して呼び出す。
  ///
  /// 戻り値は `showDialog<T>` の戻り値そのまま (`Navigator.pop(value)` の値)。
  /// context が unmounted 状態で呼ばれた場合は null を返し、queue は次へ進む。
  ///
  /// [priority] は [PopupPriority] の定数を渡すこと。省略すると最後尾。
  static Future<T?> enqueueShowDialog<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
    bool useRootNavigator = true,
    int priority = PopupPriority.unranked,
  }) async {
    T? result;
    await enqueue(
      () async {
        // context が unmounted なら諦める (queue は次へ進む)
        if (!context.mounted) return;
        result = await showDialog<T>(
          context: context,
          barrierDismissible: barrierDismissible,
          useRootNavigator: useRootNavigator,
          builder: builder,
        );
      },
      priority: priority,
    );
    return result;
  }

  /// 【FEAT-479 (2026-07-06)】汎用 enqueue。任意の Future factory を直列化する。
  ///
  /// `showGeneralDialog` / `showModalBottomSheet` 等、`showDialog` 以外の
  /// popup 系 API を直列化したい場合に使う。呼出側で任意の Future を
  /// 組み立てられる (context.mounted チェックも呼出側 responsibility)。
  ///
  /// ⚠️ 【FEAT-534】**task の中で `Future.delayed` して「間」を作らないこと。**
  /// task はキューを握っているので、待っているあいだ**他の popup 全員が
  /// 道連れで止まる**。間を置きたいなら enqueue する**前**に待つこと。
  /// 前例: `puzzle_piece_listener` は 2 秒の演出待ちを task の中でやっており、
  /// 無関係な `LoginBonusCalendarDialog` / `LevelUpDialog` まで待たせていた。
  static Future<void> enqueue(
    Future<void> Function() task, {
    int priority = PopupPriority.unranked,
  }) {
    final entry = _QueuedPopup(
      task: task,
      priority: priority,
      sequence: _sequence++,
    );
    _waiting.add(entry);
    // pump は fire-and-forget。呼出元は自分の完了だけを待つ。
    unawaited(_pump());
    return entry.done.future;
  }

  /// 待機列から 1 件ずつ取り出して実行する。多重起動しない。
  static Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_waiting.isNotEmpty) {
        // 🔴 取り出す瞬間に選び直す。ここが「優先度」の全部である。
        // 走り出した task は途中で差し替えないので、**表示中の popup が
        // 追い越されることはない**。追い越しが起きるのは「まだ出ていない
        // popup どうし」だけ。
        _waiting.sort(_byPriorityThenArrival);
        final entry = _waiting.removeAt(0);
        try {
          await entry.task();
          entry.done.complete();
        } catch (error, stackTrace) {
          // 例外は enqueue した本人に返す。キューは止めない
          // (1 つの popup の失敗で後続が永久に出なくなるのを防ぐ)。
          entry.done.completeError(error, stackTrace);
        }
      }
    } finally {
      _pumping = false;
    }
  }

  static int _byPriorityThenArrival(_QueuedPopup a, _QueuedPopup b) {
    final byPriority = a.priority.compareTo(b.priority);
    if (byPriority != 0) return byPriority;
    // 同一優先度は enqueue 順 (FIFO)。既存の挙動を壊さない。
    return a.sequence.compareTo(b.sequence);
  }

  /// テスト用に内部状態をリセット。プロダクションコードでは使わない。
  @visibleForTesting
  static void resetForTest() {
    _waiting.clear();
    _pumping = false;
    _sequence = 0;
  }
}

class _QueuedPopup {
  _QueuedPopup({
    required this.task,
    required this.priority,
    required this.sequence,
  });

  final Future<void> Function() task;
  final int priority;

  /// 同一優先度の FIFO を保つための到着順。
  final int sequence;

  final Completer<void> done = Completer<void>();
}
