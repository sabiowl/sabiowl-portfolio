import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// FEAT-247: アプリ全体で共有する SnackBar dispatcher。
///
/// `MaterialApp.router` の `scaffoldMessengerKey` に [messengerKey] を固定し、
/// どの画面からでもサビ口調トーストを出せるようにする。
///
/// 主用途: `TimelineService` の fire-and-forget Google push 失敗通知を
/// ホーム / add_event_page / quick_add_task_sheet からも届けるための集約点。
/// 旧 `onGooglePushFailed` callback 方式（calendar_page 1 箇所だけ購読）は廃止。
class ToastCenter {
  ToastCenter._();

  /// `MaterialApp.router` に固定する scaffoldMessengerKey。
  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// サビ口調トーストを表示する。
  ///
  /// 背景色は [AppTheme.primary] で統一し、`Colors.redAccent` 等の機械色は
  /// 使わない（CLAUDE.md「サビの口調ルール」遵守）。文末 🪶 マーカーは
  /// 呼び出し側で付与する。
  static void showSabi(
    String message, {
    Duration duration = const Duration(seconds: 3),
  }) {
    final state = messengerKey.currentState;
    if (state == null) return;  // app 未起動 / scaffold 未マウント時の安全 fallback
    state.hideCurrentSnackBar();
    state.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppTheme.primary,
        duration: duration,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 成功系トースト。背景色は [AppTheme.primary] 維持（温度を変えない）。
  static void showSuccess(String message) {
    showSabi(message);
  }

  /// 警告系トースト。`Colors.redAccent` 等ではなく [AppTheme.primary] を維持し、
  /// 「サビが寄り添う温度」を保つ。表示時間のみ少し長く設定。
  static void showWarning(String message) {
    showSabi(message, duration: const Duration(seconds: 4));
  }
}
