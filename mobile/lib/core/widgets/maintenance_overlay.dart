import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/app_urls.dart';
import '../providers/maintenance_provider.dart';
import '../services/maintenance_service.dart';
import '../theme/app_theme.dart';
import '../../l10n/app_localizations.dart';

/// 【FEAT-463 (2026-06-22)】緊急メンテナンス全画面 overlay。
///
/// `MaterialApp.builder` で全アプリ (go_router ShellRoute より上位) を
/// 包み込み、maintenance 有効時は通常 UI の上に全画面表示する。
class MaintenanceOverlay extends ConsumerWidget {
  const MaintenanceOverlay({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(maintenanceStatusProvider);
    return Stack(
      children: [
        child,
        // 【Pre-mortem S3 (FEAT-462 由来パターン踏襲)】非表示時も Positioned で
        // ラップし、Stack の sizing を child (Positioned.fill 相当) に委ねる。
        if (status.isEnabled)
          Positioned.fill(
            child: _MaintenanceScreen(status: status),
          ),
      ],
    );
  }
}

class _MaintenanceScreen extends ConsumerStatefulWidget {
  const _MaintenanceScreen({required this.status});
  final MaintenanceStatus status;

  @override
  ConsumerState<_MaintenanceScreen> createState() => _MaintenanceScreenState();
}

class _MaintenanceScreenState extends ConsumerState<_MaintenanceScreen> {
  bool _retrying = false;

  /// 【2026-07-04 hotfix】expires_at 経過時の自動 refresh Timer。
  /// expires_at + 5 秒後に fire、`refresh()` を呼んで Backend に最新状態を問い合わせる。
  /// Backend は `now >= expires_at` なら `is_enabled_now() == False` を返すため、
  /// overlay が自動的に消える (`MaintenanceOverlay.build` 内の `if (status.isEnabled)`
  /// で描画されなくなる)。ユーザーは「再試行」を押さずとも通常利用に復帰できる。
  Timer? _autoRefreshTimer;

  @override
  void initState() {
    super.initState();
    _scheduleAutoRefresh();
  }

  @override
  void didUpdateWidget(covariant _MaintenanceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // expires_at が変更された (admin が別時刻に変更 / 別 Config を受信) 場合、
    // 古い Timer を破棄して新しい時刻で再スケジュール。
    if (oldWidget.status.expiresAt != widget.status.expiresAt) {
      _scheduleAutoRefresh();
    }
  }

  @override
  void dispose() {
    // 【CLAUDE.md「dispose() 内で setState() を呼ばない」BUG-66】
    // Timer の cancel は setState を伴わない安全な dispose 処理のため OK。
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
    super.dispose();
  }

  /// expires_at 経過時に自動 refresh する Timer をスケジュール。
  ///
  /// - `expiresAt == null` (無期限メンテ) → 何もしない
  /// - `expiresAt` が未来 → その時刻 +5 秒後に refresh (Backend 判定に猶予)
  /// - `expiresAt` が既に過去 → 次フレームで即 refresh (build 中の setState 回避)
  void _scheduleAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
    final expiresAt = widget.status.expiresAt;
    if (expiresAt == null) return;
    final delta = expiresAt.difference(DateTime.now());
    if (!delta.isNegative) {
      // 未来: expires_at + 5 秒後に refresh (Backend の time skew + is_enabled_now
      // 判定に若干の余裕を持たせる)
      _autoRefreshTimer = Timer(delta + const Duration(seconds: 5), () {
        if (!mounted) return;
        // ignore: discarded_futures — fire-and-forget、失敗しても user 再試行で復帰可能
        ref.read(maintenanceStatusProvider.notifier).refresh();
      });
    } else {
      // 既に過ぎている: build 中の setState を避けるため次フレームで refresh 実行。
      // widget が build されているタイミングで開き直しても、この経路で復帰する。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // ignore: discarded_futures
        ref.read(maintenanceStatusProvider.notifier).refresh();
      });
    }
  }

  Future<void> _onRetry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    await ref.read(maintenanceStatusProvider.notifier).refresh();
    if (!mounted) return;
    setState(() => _retrying = false);
  }

  Future<void> _openHomePage() async {
    // 【2026-07-03 hotfix】canLaunchUrl は iOS Info.plist の
    // LSApplicationQueriesSchemes / Android 11+ の <queries> 制約で false を
    // 返すことがあり、その場合ボタンが silent に無反応になっていた。
    // 直接 launchUrl を呼び、失敗時のみ SnackBar でユーザーに通知する。
    final l10n = AppLocalizations.of(context)!;
    await _safeLaunch(
      Uri.parse(kSabiowlHomePageTopUrl),
      mode: LaunchMode.externalApplication,
      failureMessage: l10n.coreOpenHomePageFailedSabi_message,
    );
  }

  Future<void> _onContactSupport() async {
    // 【2026-07-03 hotfix】同上、canLaunchUrl の bypass。
    // mailto: はメーラー未インストール時に開けないことがあるため、その場合の
    // fallback として support メールアドレスを SnackBar に表示する。
    // 【FEAT-479 hotfix (2026-07-06)】件名 + 本文テンプレを事前入力
    // (buildSabiowlMaintenanceContactMailto) してユーザー入力負荷を軽減。
    final l10n = AppLocalizations.of(context)!;
    await _safeLaunch(
      buildSabiowlMaintenanceContactMailto(),
      failureMessage: l10n.coreOpenMailerFailedSabi_message(kSabiowlSupportEmail),
    );
  }

  /// 【2026-07-03】url_launcher の launchUrl を直接呼び、成功/失敗を SnackBar
  /// でユーザーに通知する共通ヘルパー。canLaunchUrl の pre-check は使わない
  /// (iOS/Android の queries scheme 未登録で false を返す環境が実在するため)。
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(failureMessage),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
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
                const Icon(Icons.construction_outlined,
                    size: 64, color: Colors.white54),
                const SizedBox(height: 24),
                Text(
                  widget.status.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  widget.status.body,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    height: 1.6,
                  ),
                  textAlign: TextAlign.center,
                ),
                // 【2026-07-04 hotfix】終了予定時刻を本文の下に表示。
                // expires_at が未来なら「終了予定: YYYY年M月D日 HH:MM」、
                // 既に過ぎていれば「終了予定時刻を過ぎました。『再試行』で
                // 最新状態を確認してください 🪶」を表示。null (無期限) は非表示。
                if (widget.status.expiresAt != null) ...[
                  const SizedBox(height: 20),
                  _ExpiresAtDisplay(expiresAt: widget.status.expiresAt!),
                ],
                const SizedBox(height: 40),
                // ── 主動作: 再試行 (ElevatedButton primary、Column 内のため
                // full-width が既定挙動 = 問題なし、CLAUDE.md「Row 内に裸の
                // ElevatedButton」注意点は Row 限定で本件は対象外) ──────────
                ElevatedButton(
                  onPressed: _retrying ? null : _onRetry,
                  child: _retrying
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.coreRetryButton),
                ),
                const SizedBox(height: 12),
                // ── 副動作 1: 最新情報 (sabiowl-home-pages リンク) ────────
                TextButton.icon(
                  onPressed: _openHomePage,
                  icon: const Text('🌐', style: TextStyle(fontSize: 16)),
                  label: Text(l10n.coreLatestInfoButton,
                      style: const TextStyle(color: Colors.white70)),
                ),
                // ── 副動作 2: お問い合わせ (mailto:) ──────────────────────
                TextButton.icon(
                  onPressed: _onContactSupport,
                  icon: const Text('✉️', style: TextStyle(fontSize: 16)),
                  label: Text(l10n.coreSupportButton,
                      style: const TextStyle(color: Colors.white54)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 【2026-07-04 hotfix】終了予定時刻の表示 widget。
///
/// 状態 3 パターン:
/// - `expiresAt == null`: 呼び出し側で本 widget を組み込まないため、本 widget が
///   build されるのは常に non-null。
/// - `expiresAt` が未来: 「終了予定: YYYY年M月D日 HH:MM」を穏やかな灰色で表示
///   (地域は toLocal() 済の DateTime、日本ユーザーは JST 表示)。
/// - `expiresAt` が既に過去: 「終了予定時刻を過ぎました。『再試行』で最新状態を
///   確認してください 🪶」をサビ口調 (🪶 マーカー付き) で表示。auto-refresh Timer と
///   並列で表示し、ユーザーが手動で再試行することも許容。
class _ExpiresAtDisplay extends StatelessWidget {
  const _ExpiresAtDisplay({required this.expiresAt});

  final DateTime expiresAt;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final localExpiresAt = expiresAt.toLocal();
    final isPassed = localExpiresAt.isBefore(DateTime.now());

    if (isPassed) {
      return Text(
        l10n.coreMaintenanceExpiresAtPassedSabi_message,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 13,
          height: 1.5,
        ),
        textAlign: TextAlign.center,
      );
    }

    final hour = localExpiresAt.hour.toString().padLeft(2, '0');
    final minute = localExpiresAt.minute.toString().padLeft(2, '0');
    final dateTime = l10n.coreMaintenanceExpiresAtDateTime(
      localExpiresAt.year,
      localExpiresAt.month,
      localExpiresAt.day,
      '$hour:$minute',
    );
    return Text(
      l10n.coreMaintenanceExpiresAtLabel(dateTime),
      style: const TextStyle(
        color: Colors.white54,
        fontSize: 13,
        height: 1.5,
      ),
      textAlign: TextAlign.center,
    );
  }
}
