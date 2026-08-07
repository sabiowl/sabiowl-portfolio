import 'dart:async';

import 'package:flutter/material.dart';

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
/// 【設計判断】
/// gameplay_review §2-1 で提案された 2 案のうち、PM 推奨案 B (共通 helper)。
/// 既存 listener の挙動と API はそのまま維持し、`showDialog` を本ヘルパー経由に
/// 置換するだけで対応できる軽量実装 (~2-4h)。
///
/// 【動作】
/// - 前の dialog が表示中なら、その完了 (dispose) を待ってから次を表示
/// - 前の dialog が例外 throw しても finally で _pending を解放、後続に影響しない
/// - 表示順は enqueue 呼び出し順 (FIFO)
/// - 同時に複数 enqueue が呼ばれても順次処理される (Dart の async event loop で保証)
///
/// 【使い方】
/// ```dart
/// // 旧:
/// // await showDialog<T>(context: context, builder: builder);
/// // 新:
/// await PopupSerializer.enqueueShowDialog<T>(context: context, builder: builder);
/// ```
///
/// 【Pre-mortem】
/// - context unmounted で enqueue → 自分の dialog は null returned、queue は次へ進む
/// - dialog 内で例外 throw → finally で _pending 解放、後続は予定通り表示
/// - 1 つの dialog をユーザーが放置 → 後続は待たされる (仕様通り、放置自体は稀)
/// - 同一 listener が一瞬で複数 enqueue → FIFO で順次表示 (重複発火検知は listener 側)
/// - 4 つの popup 同時発火 → 4 つすべてが順次表示される (1 つも漏れない設計)
class PopupSerializer {
  /// 現在表示中 / 直前に表示完了した dialog の Future。
  /// null なら直列化チェーンが空 = 次の dialog は即座に表示できる。
  static Future<void>? _pending;

  /// `showDialog` を直列化して呼び出す。
  ///
  /// 前の dialog が表示中なら、その完了を await してから次を showDialog する。
  /// 戻り値は `showDialog<T>` の戻り値そのまま (`Navigator.pop(value)` の値)。
  ///
  /// context が unmounted 状態で呼ばれた場合は null を返し、queue は次へ進む。
  /// dialog 内で例外が throw された場合は finally で _pending を解放し、
  /// 後続の enqueue が永久に block されないようにする。
  static Future<T?> enqueueShowDialog<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
    bool useRootNavigator = true,
  }) async {
    // 前の dialog 完了を待つ (null なら即座に通過)
    final previous = _pending;
    if (previous != null) {
      try {
        await previous;
      } catch (_) {
        // 前の dialog で例外があっても自分の表示には影響しない
      }
    }

    // context が unmounted なら諦める (queue は次へ進めるため _pending はセットしない)
    if (!context.mounted) return null;

    // 自分の completion completer を _pending にセット
    final completer = Completer<void>();
    _pending = completer.future;

    try {
      return await showDialog<T>(
        context: context,
        barrierDismissible: barrierDismissible,
        useRootNavigator: useRootNavigator,
        builder: builder,
      );
    } finally {
      // 自分の完了を notify (後続が pending を await している)
      completer.complete();
      // 後続から別の completer がセットされていなければ null クリア
      // (identical 比較で「自分が最後の pending」のときだけリセット)
      if (identical(_pending, completer.future)) {
        _pending = null;
      }
    }
  }

  /// 【FEAT-479 (2026-07-06)】汎用 enqueue。任意の Future factory を直列化する。
  ///
  /// `showGeneralDialog` / `showModalBottomSheet` 等、`showDialog` 以外の
  /// popup 系 API を直列化したい場合に使う。呼出側で任意の Future を
  /// 組み立てられる (context.mounted チェックも呼出側 responsibility)。
  ///
  /// 使用例 (Puzzle piece overlay で showGeneralDialog を直列化):
  /// ```dart
  /// await PopupSerializer.enqueue(() async {
  ///   if (!mounted) return;
  ///   await showGeneralDialog<void>(
  ///     context: context,
  ///     pageBuilder: (_, __, ___) => const MyOverlay(),
  ///   );
  ///   // 追加の副作用があればここに書ける (BUG-65 300ms wait など)
  /// });
  /// ```
  static Future<void> enqueue(Future<void> Function() task) async {
    final previous = _pending;
    if (previous != null) {
      try {
        await previous;
      } catch (_) {
        // 前の task で例外があっても自分の実行には影響しない
      }
    }

    final completer = Completer<void>();
    _pending = completer.future;

    try {
      await task();
    } finally {
      completer.complete();
      if (identical(_pending, completer.future)) {
        _pending = null;
      }
    }
  }

  /// テスト用に内部状態をリセット。プロダクションコードでは使わない。
  @visibleForTesting
  static void resetForTest() {
    _pending = null;
  }
}
