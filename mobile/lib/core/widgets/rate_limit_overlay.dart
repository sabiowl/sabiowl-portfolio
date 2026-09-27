import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../providers/maintenance_provider.dart';
import '../providers/rate_limit_provider.dart';
import '../theme/app_theme.dart';
import '../../l10n/app_localizations.dart';

/// 【BUG-158 (2026-09-12)】レート制限 (HTTP 429) 専用の全画面 overlay。
///
/// ## なぜ ConnectionErrorOverlay を使い回さないのか
///
/// 🔴 **文言が事実と逆になるから。** 429 はサーバが応答している証拠であり、
/// 「通信できませんでした」は嘘である。本 BUG の起点になった Sentry の
/// breadcrumb は `network_type: wifi` / `signal_strength: -51` で、
/// **通信は良好だった**。
///
/// ⚠️ さらに ConnectionErrorOverlay の「再試行」は `/health/` を叩く ——
/// **枠を使い切って出た画面が、押すたびに枠をもう 1 本消費していた**。
/// BUG-147 Phase C が 401 で解いたのとまったく同じ形である。
///
/// ## 表示の優先順位
///
///   停止 (FEAT-541) > メンテ (FEAT-463) > **レート制限** > 通信エラー > 通常 UI
///
/// 🔵 通信エラーより上に置く理由は、**429 のほうが情報量が多い**から。
/// 通信エラーは mobile 側の推測だが、429 は「あと N 秒」という
/// サーバからの確定した回答である。
///
/// ## この画面は放っておいても消える
///
/// `ApiClient` の interceptor が業務 API の 2xx で [RateLimitNotifier.clear]
/// を呼ぶ。🔵 anon バケットが枯れていても**認証済みユーザーのバケットは別**
/// なので、アプリ自体は動いていることがある。その場合この overlay は
/// 最初の成功応答で自然に消える。
class RateLimitOverlay extends ConsumerWidget {
  const RateLimitOverlay({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rateLimit = ref.watch(rateLimitProvider);
    final maintenance = ref.watch(maintenanceStatusProvider);

    // maintenance ON のときは MaintenanceOverlay が上位で覆うので出さない
    // (ConnectionErrorOverlay と同じ二重表示防止)。
    final shouldShow = rateLimit.isLimited && !maintenance.isEnabled;

    return Stack(
      children: [
        child,
        if (shouldShow) const Positioned.fill(child: _RateLimitScreen()),
      ],
    );
  }
}

class _RateLimitScreen extends ConsumerStatefulWidget {
  const _RateLimitScreen();

  @override
  ConsumerState<_RateLimitScreen> createState() => _RateLimitScreenState();
}

class _RateLimitScreenState extends ConsumerState<_RateLimitScreen> {
  Timer? _ticker;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    // 1 秒ごとに再描画してカウントダウンを進めるだけ。state は provider 側。
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    // 【BUG-66 v3】dispose では Timer の cancel のみ。setState は呼ばない。
    _ticker?.cancel();
    _ticker = null;
    super.dispose();
  }

  /// 「再試行」。**待ち時間が残っているあいだは押せない** (§4-4)。
  ///
  /// 🔴 押せるのに何も起きないボタンを残さないこと。旧 ConnectionErrorOverlay
  /// の「再試行」は、押すたびに枠を 1 本消費して状況を悪化させていた。
  Future<void> _onRetry() async {
    if (_retrying) return;
    setState(() => _retrying = true);

    final apiClient = ref.read(apiClientProvider);
    try {
      final response = await apiClient.probeDio.get(
        '/health/',
        options: Options(
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
          validateStatus: (_) => true,
        ),
      );
      final code = response.statusCode ?? 0;
      if (code == 429) {
        // まだ枯れている。サーバが言う新しい待ち時間で引き直す。
        ref.read(rateLimitProvider.notifier).mark(
              parseRetryAfter(response.headers.value('retry-after')),
            );
      } else if (code == 200) {
        ref.read(rateLimitProvider.notifier).clear();
      }
      // それ以外 (5xx 等) は state 維持。ここで connection error に
      // 化けさせると、429 で出た画面が別の嘘に変わるだけになる。
    } catch (_) {
      // 通信失敗 → state 保持
    }

    if (!mounted) return;
    setState(() => _retrying = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final status = ref.watch(rateLimitProvider);
    final remaining = status.remaining(DateTime.now());
    final waiting = remaining > Duration.zero;

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
                const Icon(
                  Icons.hourglass_bottom,
                  size: 64,
                  color: Colors.white54,
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.coreRateLimitTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.coreRateLimitBodySabi_message,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    height: 1.6,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                // ── 待ち時間。⚠️ これが「最も有用な情報」である ────────
                if (waiting)
                  Text(
                    l10n.coreRateLimitCountdown(remaining.inSeconds),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                const SizedBox(height: 24),
                ElevatedButton(
                  // 🔴 待っているあいだは押させない。押せても枠を消費して
                  //    同じ 429 が返るだけで、状況が悪化する。
                  onPressed: (waiting || _retrying) ? null : _onRetry,
                  child: _retrying
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.coreRetryButton),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
