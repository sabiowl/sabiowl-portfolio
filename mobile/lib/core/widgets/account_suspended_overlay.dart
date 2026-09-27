import 'package:dio/dio.dart';  // 【BUG-164】再試行の 403 判定
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../features/auth/providers/auth_provider.dart';
import '../../l10n/app_localizations.dart';
import '../api/api_client.dart';  // 【BUG-164】再試行で 1 本叩く
import '../api/dio_error_helper.dart';  // 【BUG-164】ApiError.fromResponse
import '../constants/app_urls.dart';
import '../providers/account_suspension_provider.dart';
import '../theme/app_theme.dart';

/// 【FEAT-541 (2026-09-06)】アカウント停止の全画面 overlay。
///
/// ## なぜ route ではなく overlay なのか
///
/// 停止は**どの画面からでも入りうる**（起動直後 / 利用中に停止された瞬間）。
/// route にすると「戻る」や deep link で抜けられる経路を個別に塞ぐ必要が出る。
/// `MaterialApp.builder` で全体を包めば、そこは考えなくてよい。
///
/// ## 優先順位: 停止 > メンテ > 通信エラー > 通常 UI
///
/// `MaintenanceOverlay` の**1 段外側**に置く。
/// 🔵 メンテは一時的な全体事象、停止はこのアカウントに対する**確定した判定**である。
/// 停止されている人に「メンテナンス中です」と見せると、
/// **待てば直る**と誤解させる。
///
/// ## 表示条件
///
/// 🔴 `403` **かつ** code が `auth_account_suspended` のときだけ
/// （`api_client.dart` の interceptor が判定する）。
/// 通信エラー / タイムアウト / 500 では**絶対に出さない**。
class AccountSuspendedOverlay extends ConsumerWidget {
  const AccountSuspendedOverlay({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suspended = ref.watch(accountSuspendedProvider);
    return Stack(
      children: [
        child,
        if (suspended) const Positioned.fill(child: _SuspendedScreen()),
      ],
    );
  }
}

class _SuspendedScreen extends ConsumerStatefulWidget {
  const _SuspendedScreen();

  @override
  ConsumerState<_SuspendedScreen> createState() => _SuspendedScreenState();
}

class _SuspendedScreenState extends ConsumerState<_SuspendedScreen> {
  /// 確認中はボタンを止める（二重タップで 2 本飛ぶのを防ぐ）。
  bool _checking = false;

  /// 🔴 【BUG-165 (2026-09-12)】告知は**この画面の中**に出す。
  ///
  /// ⚠️ **SnackBar は使えない。** この overlay の根は**不透明な
  /// `Material`** で、`ScaffoldMessenger` の SnackBar は
  /// **route 側の `Scaffold` の中**に描かれる ——
  /// つまり**この画面の下に隠れて見えない**。
  ///
  /// 実機確認 2026-09-12 で「再試行は効いたがメッセージが出ない」と
  /// 報告されたのがこれである。
  String? _notice;

  /// 「再試行」= **実際に 1 本叩いて、解除されていたときだけ**フラグを下ろす。
  ///
  /// 🔴 **これが無いと、解除してもユーザーが戻ってこない。**
  /// 解除されたことをユーザーは知らないので、「もう一度ログインしてみよう」と
  /// 思う動機が無い —— **誤 ban を解除しても、その人は戻ってこない。**
  ///
  /// ## 🔴 【BUG-164 (2026-09-12)】先にフラグを下ろしてはいけない
  ///
  /// 旧実装は**フラグを下ろして次の API 呼び出しの結果に判定を委ねていた**。
  /// 実機ではこうなった:
  ///
  /// ```
  /// 停止画面 → 再試行 → ⚠️ ホーム画面（プロフィールが出ず、習慣も読めない）
  ///          → 手で再読み込み → 停止画面
  /// ```
  ///
  /// ⚠️ **「壊れたホーム画面」を見せてから停止画面に戻る**ので、
  /// ユーザーには**アプリが壊れたように見える**。
  /// 🔵 停止中であることは**サーバに聞けば分かる**のだから、
  /// **聞いてから下ろす**のが正しい。
  ///
  /// ⚠️ **通信できなかったときは下ろさない。** 「解除されたか分からない」
  /// のに通常 UI に戻すと、**同じ壊れたホーム画面**になる。
  Future<void> _onRetry() async {
    if (_checking) return;
    setState(() => _checking = true);
    final l10n = AppLocalizations.of(context)!;
    // 押すたびに前回の告知を消す（古い結果が残らないように）。
    setState(() => _notice = null);
    try {
      // 🔴 **認証を通る endpoint でなければ停止は判定できない。**
      //    `/health/` や `/maintenance/` は認証を通らないので使えない。
      await ref.read(apiClientProvider).dio.get('/player/');
      // ここに来たら解除されている。
      if (!mounted) return;
      ref.read(accountSuspendedProvider.notifier).clear();
    } on DioException catch (e) {
      if (!mounted) return;
      // 🔵 まだ停止中なら interceptor がフラグを維持しているので、
      //    画面はそのままでよい。**下ろさない**ことが仕事である。
      final code = ApiError.fromResponse(e.response?.data).code;
      _notice =
          e.response?.statusCode == 403 && code == kAccountSuspendedErrorCode
              ? l10n.coreAccountSuspendedStillSabi_message
              : l10n.coreAccountSuspendedCheckFailedSabi_message;
    } catch (_) {
      if (!mounted) return;
      _notice = l10n.coreAccountSuspendedCheckFailedSabi_message;
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// 「ログアウト」= トークンを消してログイン画面へ。
  ///
  /// 🔴 **停止フラグを必ず一緒に下ろす。** 消し忘れると
  /// **ログイン画面の上に overlay が乗ったまま**になり、
  /// ログインボタンが押せなくなる。
  Future<void> _onLogout() async {
    try {
      await ref.read(authProvider.notifier).logout();
    } finally {
      // ⚠️ `logout()` の中でも下ろしている (出口を 1 つにするため)。
      //    ここで **finally** にしているのは、`_service.logout()` が
      //    通信エラー等で投げたときに**下ろす処理ごと飛ばされない**ようにするため。
      //    同じ `clear()` を呼ぶだけなので、値が食い違う余地は無い。
      ref.read(accountSuspendedProvider.notifier).clear();
    }
  }

  Future<void> _openHomePage() async {
    final l10n = AppLocalizations.of(context)!;
    await _safeLaunch(
      Uri.parse(kSabiowlHomePageTopUrl),
      mode: LaunchMode.externalApplication,
      failureMessage: l10n.coreOpenHomePageFailedSabi_message,
    );
  }

  /// 🔵 **`mailto:` であることがこの機能では効く。**
  /// アプリ内の `/contact` 画面経由だと「停止中に問い合わせ画面を開けるか」を
  /// 別途保証しないといけないが、`mailto:` は OS のメーラーを開くだけなので
  /// **認証状態と無関係に動く**。
  Future<void> _onContactSupport() async {
    final l10n = AppLocalizations.of(context)!;
    await _safeLaunch(
      buildSabiowlMaintenanceContactMailto(),
      failureMessage: l10n.coreOpenMailerFailedSabi_message(kSabiowlSupportEmail),
    );
  }

  /// `canLaunchUrl` の pre-check は使わない
  /// (iOS / Android の queries scheme 未登録で false を返す環境が実在するため、
  /// 2026-07-03 hotfix と同じ判断)。
  Future<void> _safeLaunch(
    Uri uri, {
    LaunchMode mode = LaunchMode.platformDefault,
    required String failureMessage,
  }) async {
    bool opened = false;
    try {
      opened = await launchUrl(uri, mode: mode);
    } catch (_) {
      opened = false;
    }
    if (!opened && mounted) {
      // ⚠️ 【BUG-165】ここも SnackBar では見えない（上の [_notice] 参照）。
      setState(() => _notice = failureMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Material(
      color: AppTheme.background,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 64, color: Colors.white54),
                const SizedBox(height: 24),
                Text(
                  l10n.coreAccountSuspendedTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                // ⚠️ 停止理由は出さない。出すと回避方法を教えることになり、
                //    文言の運用コストも常時かかる。理由は
                //    `AccountSuspensionLog` に残し、導線だけを示す。
                Text(
                  l10n.coreAccountSuspendedSabi_message,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    height: 1.6,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),
                // ── 主動作: 再試行 (解除されていれば通常 UI に戻る) ─────────
                ElevatedButton(
                  key: const Key('account_suspended_retry'),
                  // ⚠️ 確認中は止める。二重タップで 2 本飛ぶのを防ぐ。
                  onPressed: _checking ? null : _onRetry,
                  child: _checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(l10n.coreRetryButton),
                ),
                // 🔴 【BUG-165】告知はここに出す（SnackBar は下に隠れる）。
                if (_notice != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      _notice!,
                      key: const Key('account_suspended_notice'),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: _openHomePage,
                  icon: const Text('🌐', style: TextStyle(fontSize: 16)),
                  label: Text(l10n.coreLatestInfoButton,
                      style: const TextStyle(color: Colors.white70)),
                ),
                TextButton.icon(
                  onPressed: _onContactSupport,
                  icon: const Text('✉️', style: TextStyle(fontSize: 16)),
                  label: Text(l10n.coreSupportButton,
                      style: const TextStyle(color: Colors.white54)),
                ),
                // ── 退出は最後 (主動作である復帰を先に置く) ─────────────────
                TextButton(
                  key: const Key('account_suspended_logout'),
                  onPressed: _onLogout,
                  child: Text(l10n.coreAccountSuspendedLogoutButton,
                      style: const TextStyle(color: Colors.white38)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
