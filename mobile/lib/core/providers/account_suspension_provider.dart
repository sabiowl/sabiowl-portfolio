import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 【FEAT-541 (2026-09-06)】Backend が返した「このアカウントは停止中」の code。
///
/// 🔴 **status だけをトリガにしないこと。** 403 は権限まわりの他のエラーでも
/// 返りうる。停止と判定してよいのは、サーバーが**この code を明示的に返した
/// ときだけ**である。
const kAccountSuspendedErrorCode = 'auth_account_suspended';

/// アカウント停止状態。
///
/// ## 🔴 端末に永続化しない
///
/// `SharedPreferences` にも `SecureStorage` にも書かない。**メモリだけ**に持つ。
/// 永続化すると、**運営が停止を解除してもアプリを消すまで画面が残る**。
/// アプリを再起動すれば消え、次の API 呼び出しでサーバーに聞き直す。
///
/// 🔵 これは FEAT-483 / BootGate v1 が踏んだ罠と同じ形である
/// (5xx / timeout をメンテ扱いにして「メンテしていないのにメンテ画面が出る」)。
/// **サーバーが明示的にそう言ったときだけ**信じる。
///
/// ⚠️ `autoDispose` にしない。アプリ全体で保持し続けるグローバル状態である。
final accountSuspendedProvider =
    StateNotifierProvider<AccountSuspendedNotifier, bool>((ref) {
  return AccountSuspendedNotifier();
});

class AccountSuspendedNotifier extends StateNotifier<bool> {
  AccountSuspendedNotifier() : super(false);

  /// Dio の interceptor が `403` + [kAccountSuspendedErrorCode] を見たときだけ呼ぶ。
  void markSuspended() {
    if (!state) state = true;
  }

  /// 停止フラグを下ろす。
  ///
  /// 🔴 **ログアウト時に必ず呼ぶこと。** 消し忘れると
  /// **ログイン画面の上に停止 overlay が乗ったまま**になり、
  /// ログインボタンが押せなくなる ——
  /// **この機能で一番起きやすい詰み方**である
  /// (`test/core/account_suspension_test.dart` が縛っている)。
  ///
  /// 「再試行」からも呼ぶ。下ろしたうえで通常 UI に戻し、
  /// 次の API 呼び出しの結果に判定を委ねる ——
  /// まだ停止中なら 403 が返ってすぐ立ち直る。
  void clear() {
    if (state) state = false;
  }
}
