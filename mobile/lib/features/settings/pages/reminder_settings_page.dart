import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/services/notification_service.dart';  // 【FEAT-273】再スケジュール
import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../habits/providers/habits_provider.dart';
import '../../../shared/widgets/drum_roll_time_picker.dart'; // FEAT-120
import '../../timeline/providers/timeline_provider.dart';  // 【FEAT-273】todayTimeline 再スケジュール

class ReminderSettingsPage extends ConsumerStatefulWidget {
  const ReminderSettingsPage({super.key});

  @override
  ConsumerState<ReminderSettingsPage> createState() =>
      _ReminderSettingsPageState();
}

class _ReminderSettingsPageState extends ConsumerState<ReminderSettingsPage> {
  bool _enabled = false;
  TimeOfDay? _time;
  bool _initialized = false;

  /// 【FEAT-273】タイムライン予定の +15 分未完了リマインダー設定
  bool _timelineUncompletedEnabled = false;

  void _initFromPlayer() {
    final player = ref.read(playerNotifierProvider).valueOrNull;
    if (player == null || _initialized) return;
    final rawTime = player.reminderTime;
    setState(() {
      _enabled = player.reminderEnabled;
      // 【FEAT-273】タイムライン未完了リマインダー設定も読み込み
      _timelineUncompletedEnabled = player.timelineUncompletedReminderEnabled;
      if (rawTime != null) {
        final parts = rawTime.split(':');
        if (parts.length >= 2) {
          _time = TimeOfDay(
            hour:   int.tryParse(parts[0]) ?? 8,
            minute: int.tryParse(parts[1]) ?? 0,
          );
        }
      }
      _time ??= const TimeOfDay(hour: 8, minute: 0);
      _initialized = true;
    });
  }

  /// 【FEAT-279】保存共通処理。リマインダー通知 ON/OFF と通知時刻の両方を
  /// 一括 PATCH する。トグル即時保存・ピッカー即時保存の共通エントリ。
  ///
  /// 失敗時は SnackBar 表示 + state ロールバックを呼び出し側で実装。
  Future<void> _saveReminderSettings({
    required bool enabled,
    required TimeOfDay? time,
  }) async {
    final timeStr = enabled && time != null
        ? '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}'
        : null;
    await ref.read(playerNotifierProvider.notifier).updateReminderSettings(
      enabled:      enabled,
      reminderTime: timeStr,
    );
  }

  /// 【FEAT-279】リマインダー通知 ON/OFF を即時保存。
  /// タイムライン未完了リマインダーと同じ UX パターン (トグル即反映)。
  Future<void> _toggleEnabled(bool newValue) async {
    final l10n = AppLocalizations.of(context)!;
    final previous = _enabled;
    setState(() => _enabled = newValue);
    try {
      await _saveReminderSettings(enabled: newValue, time: _time);
    } catch (e) {
      // 失敗時は state を元に戻して SnackBar 表示
      if (!mounted) return;
      setState(() => _enabled = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.settingsReminderPageSaveErrorSnackbarSabi_message),
        ),
      );
    }
  }

  /// 【FEAT-273】タイムライン未完了リマインダーの ON/OFF を切替。
  /// PATCH 直後に今日の予定の通知を即時再スケジュール（既存通知をキャンセル +
  /// 新設定で再構築）することで、設定変更が反映されたユーザー体験を提供する。
  Future<void> _toggleTimelineUncompletedReminder(bool newValue) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _timelineUncompletedEnabled = newValue);
    try {
      await ref
          .read(playerNotifierProvider.notifier)
          .setTimelineUncompletedReminderEnabled(newValue);

      // 即時反映: 今日の予定の通知を再スケジュール
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final events = await ref.read(timelineEventsProvider(today).future);
      await NotificationService.scheduleTodayTimelineNotifications(
        events,
        includeUncompletedReminder: newValue,
      );
    } catch (e) {
      // 失敗時は state を元に戻す
      if (mounted) {
        setState(() => _timelineUncompletedEnabled = !newValue);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.settingsReminderPageSaveErrorSnackbarSabi_message),
          ),
        );
      }
    }
  }

  /// 【FEAT-279】通知時刻ピッカーを開き、選択結果を即時保存。
  /// 旧実装は保存ボタン押下まで反映されなかったが、トグルと同じく即時反映に統一。
  Future<void> _pickTime() async {
    // FEAT-120: showTimePicker → showDrumRollTimePicker に変更
    final l10n = AppLocalizations.of(context)!;
    final picked = await showDrumRollTimePicker(
      context:     context,
      initialTime: _time ?? const TimeOfDay(hour: 8, minute: 0),
    );
    if (picked == null) return;

    final previous = _time;
    setState(() => _time = picked);
    try {
      await _saveReminderSettings(enabled: _enabled, time: picked);
    } catch (e) {
      // 失敗時は state を元に戻して SnackBar 表示
      if (!mounted) return;
      setState(() => _time = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.settingsReminderPageSaveErrorSnackbarSabi_message),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(playerNotifierProvider, (_, next) {
      next.whenData((_) => _initFromPlayer());
    });
    _initFromPlayer();

    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsReminderPageTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── 説明 ─────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(14),
            margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: AppTheme.primary, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.settingsReminderPageInfoBox,
                    style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
                  ),
                ),
              ],
            ),
          ),

          // ── リマインダー ON/OFF ───────────────────────────────
          // 【FEAT-279】トグル操作で即時保存（保存ボタン廃止）
          // 【2026-07-09】説明文追加: 何を通知する機能なのか user に伝える。
          //   旧: subtitle が「有効 / 無効」のみで、通知内容が不明 (user 報告)。
          //   新: description サブ text + subtitle 状態表示の 2 段構成。
          _buildCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    l10n.settingsReminderPageToggleTitle,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  ),
                  subtitle: Text(
                    _enabled ? l10n.settingsReminderPageToggleEnabled : l10n.settingsReminderPageToggleDisabled,
                    style: TextStyle(
                      color: _enabled ? AppTheme.primary : Colors.white38,
                      fontSize: 12,
                    ),
                  ),
                  value: _enabled,
                  activeColor: AppTheme.primary,
                  onChanged: _toggleEnabled,
                ),
                // 【2026-07-09】通知内容の説明文 (user 報告「何を通知するのか分からない」対応)。
                const SizedBox(height: 6),
                Text(
                  l10n.settingsReminderPageDescriptionSabi_message,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ── 通知時刻 ──────────────────────────────────────────
          // 【FEAT-279】ピッカー選択で即時保存（保存ボタン廃止）
          AnimatedOpacity(
            opacity: _enabled ? 1.0 : 0.4,
            duration: const Duration(milliseconds: 200),
            child: _buildCard(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                enabled: _enabled,
                title: Text(
                  l10n.settingsReminderPageTimeLabel,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
                subtitle: Text(
                  _time != null
                      ? '${_time!.hour.toString().padLeft(2, '0')}:${_time!.minute.toString().padLeft(2, '0')}'
                      : l10n.settingsReminderPageTimeNotSet,
                  style: TextStyle(
                    color: _enabled ? AppTheme.secondary : Colors.white38,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                trailing: _enabled
                    ? const Icon(Icons.access_time, color: Colors.white38)
                    : null,
                onTap: _enabled ? _pickTime : null,
              ),
            ),
          ),
          const SizedBox(height: 24),

          // ── 【FEAT-273】タイムライン予定の +15 分未完了リマインダー ─────
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.settingsReminderPageTimelineSection,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.settingsReminderPageTimelineDescriptionSabi_message,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    l10n.settingsReminderPageTimelineToggleTitle,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  subtitle: Text(
                    _timelineUncompletedEnabled ? l10n.settingsReminderPageToggleEnabled : l10n.settingsReminderPageToggleDisabled,
                    style: TextStyle(
                      color: _timelineUncompletedEnabled
                          ? AppTheme.primary
                          : Colors.white38,
                      fontSize: 12,
                    ),
                  ),
                  value: _timelineUncompletedEnabled,
                  activeColor: AppTheme.primary,
                  onChanged: _toggleTimelineUncompletedReminder,
                ),
              ],
            ),
          ),

          // 【FEAT-279】保存ボタンは廃止。すべての設定はトグル/ピッカーで即時保存。
          // エラー時は各操作内で SnackBar 表示 + state ロールバックで対応。
        ],
      ),
    );
  }

  Widget _buildCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        // 【FEAT-293】AppTheme.surface → AppTheme.card で視認性確保
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: child,
    );
  }
}
