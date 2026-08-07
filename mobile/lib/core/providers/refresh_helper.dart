import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/habits/providers/habits_provider.dart';

// ── 集約 invalidate ヘルパー ──────────────────────────────────────────────────
//
// ref.invalidate を複数箇所で個別に呼ぶと、抜け漏れによる表示ズレが発生しやすい
// （BUG-19: タイムライン完了時の EXP バー更新漏れ 等）。
// ドメインイベント単位でこのヘルパーを呼ぶことで、無効化セットを一元管理する。
//
// 使い方:
//   RefreshHelper.afterHabitCount(ref);
//   RefreshHelper.afterPlayerAction(ref);

abstract final class RefreshHelper {
  // 習慣カウント完了後（EXP 付与・レベルアップ・達成解除が連鎖）
  static void afterHabitCount(Ref ref) {
    ref.invalidate(habitsNotifierProvider);
    ref.invalidate(playerNotifierProvider);
    // NOTE: achievement / quest は autoDispose かつ画面個別ロードのため
    //       必要な画面が ref.invalidate を追加で呼ぶこと。
  }

  // プロフィール編集・設定変更後（プレイヤー情報のみ更新）
  static void afterPlayerAction(Ref ref) {
    ref.invalidate(playerNotifierProvider);
  }

  // ガチャ・アイテム購入後（プレイヤー情報 + 習慣リスト）
  static void afterGachaOrShop(Ref ref) {
    ref.invalidate(playerNotifierProvider);
    ref.invalidate(habitsNotifierProvider);
  }
}
