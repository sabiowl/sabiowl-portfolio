import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/sabi_icon.dart';  // 【FEAT-415 (2026-06-01)】sabi_unified.png 統一

/// 通知権限ソフトプロンプト BottomSheet。
///
/// [status] が [NotifPermissionStatus.notDetermined] の場合は
/// システムダイアログへ誘導し、許可後にサーバーへトークンを登録する。
/// [status] が [NotifPermissionStatus.permanentlyDenied] の場合は
/// 設定アプリへ誘導するボタンを表示する。
class NotificationSoftPromptSheet extends ConsumerStatefulWidget {
  final NotifPermissionStatus status;

  const NotificationSoftPromptSheet({
    super.key,
    required this.status,
  });

  @override
  ConsumerState<NotificationSoftPromptSheet> createState() =>
      _NotificationSoftPromptSheetState();
}

class _NotificationSoftPromptSheetState
    extends ConsumerState<NotificationSoftPromptSheet> {
  bool _loading = false;

  Future<void> _handleApprove() async {
    setState(() => _loading = true);

    final result = await NotificationService.requestPermission();

    if (!mounted) return;

    if (result == NotifPermissionStatus.granted) {
      // 許可されたらサーバーにトークンを登録
      final apiClient = ref.read(apiClientProvider);
      await NotificationService.registerTokenWithServer(apiClient);
    }

    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _handleOpenSettings() async {
    await NotificationService.openAppSettings();
    if (mounted) Navigator.of(context).pop();
  }

  void _handleSkip() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final isDenied = widget.status == NotifPermissionStatus.permanentlyDenied;
    final l10n = AppLocalizations.of(context)!;

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
        24,
        16,
        24,
        24 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── ドラッグハンドル ────────────────────────────────────────
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),

          // ── サビの吹き出し ──────────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 【FEAT-415 (2026-06-01)】絵文字 🪶 → sabi_unified.png に統一。
              // SabiEmotion.pity (寄り添い) = 「通知を受け取りませんか」の優しい誘い。
              const SabiIcon(emotion: SabiEmotion.pity, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.08),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(4),
                      topRight: Radius.circular(16),
                      bottomLeft: Radius.circular(16),
                      bottomRight: Radius.circular(16),
                    ),
                    border: Border.all(
                      color: AppTheme.primary.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'SABI',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: Color(0xCB7F77DD),
                          letterSpacing: 3,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        isDenied
                            ? l10n.settingsNotifPromptDeniedSabi_message
                            : l10n.settingsNotifPromptNotDeterminedSabi_message,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withValues(alpha: 0.85),
                          height: 1.65,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // ── メリットリスト ──────────────────────────────────────────
          _BenefitRow(
            icon: '🔔',
            text: l10n.settingsNotifPromptBenefitReminder,
          ),
          const SizedBox(height: 10),
          _BenefitRow(
            icon: '⬆️',
            text: l10n.settingsNotifPromptBenefitLevelUp,
          ),
          const SizedBox(height: 10),
          _BenefitRow(
            icon: '👥',
            text: l10n.settingsNotifPromptBenefitFriends,
          ),
          const SizedBox(height: 28),

          // ── ボタン ──────────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _loading
                  ? null
                  : (isDenied ? _handleOpenSettings : _handleApprove),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(isDenied ? l10n.settingsNotifPromptOpenSettingsButton : l10n.settingsNotifPromptAllowButton),
            ),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: _loading ? null : _handleSkip,
            child: Text(
              isDenied ? l10n.settingsNotifPromptDismissDenied : l10n.settingsNotifPromptDismissNotDetermined,
              style: const TextStyle(color: Colors.white38),
            ),
          ),
        ],
      ),
    );
  }
}

class _BenefitRow extends StatelessWidget {
  final String icon;
  final String text;

  const _BenefitRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(icon, style: const TextStyle(fontSize: 18)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }
}
