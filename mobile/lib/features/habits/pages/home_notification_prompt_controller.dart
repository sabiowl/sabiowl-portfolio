import 'package:flutter/material.dart';

import '../../../core/services/notification_prompt_service.dart';
import '../../../core/services/notification_service.dart';
import '../../settings/widgets/notification_soft_prompt_sheet.dart';

/// 【FEAT-473 Phase 3 (2026-07-04)】通知ソフトプロンプト判定 + 表示ロジックを
/// 集約した静的コントローラー。home_listeners.dart から切出し、単一責務化。
class HomeNotificationPromptController {
  const HomeNotificationPromptController._();

  static Future<void> maybeShow(BuildContext context) async {
    final status = await NotificationService.checkPermissionStatus();
    if (status == NotifPermissionStatus.granted) return;
    final isPermanentlyDenied = status == NotifPermissionStatus.permanentlyDenied;
    if (isPermanentlyDenied) {
      final shouldReprompt = await NotificationPromptService.shouldShowReprompt();
      if (!shouldReprompt) return;
    } else {
      final shouldShow = await NotificationPromptService.shouldShowPrompt();
      if (!shouldShow) return;
    }
    await Future.delayed(const Duration(milliseconds: 200));
    if (!context.mounted) return;
    if (isPermanentlyDenied) {
      await NotificationPromptService.markRepromptShown();
    } else {
      await NotificationPromptService.markPromptShown();
    }
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context:            context,
      backgroundColor:    Colors.transparent,
      isScrollControlled: true,
      builder: (_) => NotificationSoftPromptSheet(status: status),
    );
  }
}
