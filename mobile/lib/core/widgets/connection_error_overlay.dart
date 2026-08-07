import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../constants/app_urls.dart';
import '../providers/connection_error_provider.dart';
import '../providers/maintenance_provider.dart';
import '../theme/app_theme.dart';
import '../../l10n/app_localizations.dart';

/// 【2026-07-09】通信接続エラー / サーバエラー全画面 overlay。
///
/// `MaterialApp.builder` で MaintenanceOverlay の 1 段内側に配置され、
/// `connectionErrorProvider.hasError == true` かつ maintenance が OFF のときのみ
/// 全画面表示する。maintenance ON のときは MaintenanceOverlay が外側で覆うため
/// 本 overlay は自動的に隠れる (Stack の layer 順で担保)。
///
/// UX: MaintenanceOverlay とほぼ同じレイアウト (アイコン + タイトル + 本文 + 3 ボタン)。
/// 差分はアイコン (`Icons.cloud_off_outlined`) と文言 (「通信接続エラー、または
/// サーバに一時的な問題」) のみ。
///
/// 復旧経路:
/// 1. 「再試行」ボタン: `/api/health/` を叩き 200 なら `connectionErrorProvider.clear()`
///    + 同時に `/api/maintenance/` も確認して maintenance が ON なら
///    MaintenanceOverlay に遷移する
/// 2. 業務 API から 2xx 受信: `ApiClient` interceptor の `_reset5xxCounter` 経路で
///    `connectionErrorProvider.clear()` が自動的に呼ばれる (本 widget の外側で処理)
class ConnectionErrorOverlay extends ConsumerWidget {
  const ConnectionErrorOverlay({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connError = ref.watch(connectionErrorProvider);
    final maintenance = ref.watch(maintenanceStatusProvider);

    // maintenance ON のときは MaintenanceOverlay が上位で表示するため
    // 本 overlay は絶対に出さない (二重表示防止)
    final shouldShow = connError.hasError && !maintenance.isEnabled;

    return Stack(
      children: [
        child,
        if (shouldShow)
          const Positioned.fill(
            child: _ConnectionErrorScreen(),
          ),
      ],
    );
  }
}

class _ConnectionErrorScreen extends ConsumerStatefulWidget {
  const _ConnectionErrorScreen();

  @override
  ConsumerState<_ConnectionErrorScreen> createState() =>
      _ConnectionErrorScreenState();
}

class _ConnectionErrorScreenState extends ConsumerState<_ConnectionErrorScreen> {
  bool _retrying = false;

  /// 「再試行」ボタン: `/api/health/` を叩き Backend 到達性を確認する。
  /// 200 なら connection error を clear、それ以外は state 維持。
  /// 同時に `/api/maintenance/` も確認し、maintenance が ON に変わっていたら
  /// MaintenanceOverlay に遷移させる。
  Future<void> _onRetry() async {
    if (_retrying) return;
    setState(() => _retrying = true);

    final apiClient = ref.read(apiClientProvider);
    try {
      final response = await apiClient.dio.get(
        '/health/',
        options: Options(
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
          validateStatus: (_) => true,
        ),
      );
      if (response.statusCode == 200) {
        // Backend 到達可能。maintenance 状態も更新して maintenance が ON なら
        // MaintenanceOverlay に遷移させる。
        final status = await ref.read(maintenanceServiceProvider).fetchStatus();
        if (!mounted) return;
        if (status.isEnabled) {
          ref
              .read(maintenanceStatusProvider.notifier)
              .setStatusForBoot(status);
        }
        // connection error は clear (maintenance が ON でも OFF でも
        // 「Backend に届いた」時点で本 overlay は役割終了)
        ref.read(connectionErrorProvider.notifier).clear();
      }
      // 200 以外は state を保持 (user が再度「再試行」を押す or 業務 API で clear)
    } catch (_) {
      // 通信失敗 → state 保持
    }

    if (!mounted) return;
    setState(() => _retrying = false);
  }

  Future<void> _openHomePage() async {
    final l10n = AppLocalizations.of(context)!;
    await _safeLaunch(
      Uri.parse(kSabiowlHomePageTopUrl),
      mode: LaunchMode.externalApplication,
      failureMessage: l10n.coreOpenHomePageFailedSabi_message,
    );
  }

  Future<void> _onContactSupport() async {
    // 【FEAT-479 hotfix (2026-07-06)】件名 + 本文テンプレを事前入力
    // MaintenanceOverlay と同じ template を再利用 (問い合わせ導線の一貫性)。
    final l10n = AppLocalizations.of(context)!;
    await _safeLaunch(
      buildSabiowlMaintenanceContactMailto(),
      failureMessage: l10n.coreOpenMailerFailedSabi_message(kSabiowlSupportEmail),
    );
  }

  /// `canLaunchUrl` の pre-check は iOS / Android の queries scheme 未登録で
  /// false を返す環境が実在するため使わず、直接 `launchUrl` を叩き、
  /// 失敗時のみ SnackBar でユーザーに通知する (MaintenanceOverlay と同 pattern)。
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
                const Icon(
                  Icons.cloud_off_outlined,
                  size: 64,
                  color: Colors.white54,
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.coreErrorOverlayTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.coreErrorOverlayBodySabi_message,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    height: 1.6,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),
                // ── 主動作: 再試行 (ElevatedButton primary、Column 内のため
                // full-width が既定挙動 = 問題なし) ─────────────────────
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
