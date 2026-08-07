import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../l10n/app_localizations.dart';

/// 【BUG-122 (2026-06-14)】その日初回タスク達成ボーナスの演出ダイアログ。
///
/// 7 日カレンダー (今週、Duolingo 風) + スタンプアニメ + 報酬表示。
/// 今回は「軽」実装 (scale + fade-in)、将来「厚」(Lottie / 凝った演出) で実装拡張予定。
///
/// 報酬テーブル (Backend `award_daily_first_task_bonus` 仕様):
///   - Day 1 (登録日 初回タスク達成): 500 ダイヤ + 3 デイリー + 3 ウィークリーチケット
///   - Day 2-7: +100 ダイヤ
///   - Day 8 以降: +20 ダイヤ
class LoginBonusCalendarDialog extends StatefulWidget {
  /// Backend `today_login_bonus` レスポンス:
  ///   {amount, days_count, granted_daily_tickets, granted_weekly_tickets}
  final Map<String, dynamic> bonus;

  const LoginBonusCalendarDialog({super.key, required this.bonus});

  @override
  State<LoginBonusCalendarDialog> createState() =>
      _LoginBonusCalendarDialogState();
}

class _LoginBonusCalendarDialogState extends State<LoginBonusCalendarDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _stampScale;
  late final Animation<double> _stampOpacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    // スタンプ scale: 1.6 → 1.0 で押し下ろす感
    _stampScale = Tween<double>(begin: 1.6, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _stampOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0, 0.6)),
    );
    // 100ms 後に開始 (ダイアログが出てから一拍置いてスタンプ演出)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _amount => widget.bonus['amount'] as int? ?? 0;
  int get _daysCount => widget.bonus['days_count'] as int? ?? 1;
  int get _grantedDaily =>
      widget.bonus['granted_daily_tickets'] as int? ?? 0;
  int get _grantedWeekly =>
      widget.bonus['granted_weekly_tickets'] as int? ?? 0;

  String _sabiMessage(AppLocalizations l10n) {
    if (_daysCount == 1) return l10n.habitLoginBonusSabiDay1Sabi_message;
    if (_daysCount <= 7) return l10n.habitLoginBonusSabiDay2to7Sabi_message;
    return l10n.habitLoginBonusSabiDay8PlusSabi_message;
  }

  /// 7 日分のカレンダーセル (月〜日)。
  /// 【BUG-126 (2026-06-14)】Row の各セルを `Expanded` で包んで均等配分し、
  /// 親 Dialog 幅に応じて自動収縮 (旧 spaceEvenly + 固定 36px で 12px overflow)。
  ///
  /// 【BUG-130 (2026-06-17)】過去日チェック判定を「曜日位置のみ」から
  /// 「登録日以降の過去日のみ」に厳格化。旧実装は曜日位置のみで past 判定したため、
  /// 水曜に新規登録したユーザーで月・火が「達成済」表示になっていた。
  /// 登録日は `days_count` (Day 1 ベース) から `today - (daysCount - 1)` で算出。
  Widget _buildCalendar(AppLocalizations l10n) {
    final days = [
      l10n.habitLoginBonusDayMon,
      l10n.habitLoginBonusDayTue,
      l10n.habitLoginBonusDayWed,
      l10n.habitLoginBonusDayThu,
      l10n.habitLoginBonusDayFri,
      l10n.habitLoginBonusDaySat,
      l10n.habitLoginBonusDaySun,
    ];
    final now = DateTime.now();
    final todayOnly = DateTime(now.year, now.month, now.day);
    final monday = todayOnly.subtract(Duration(days: todayOnly.weekday - 1));
    // _daysCount=1 → registrationDate = today (登録日 = 今日、過去日チェックなし)
    // _daysCount=5 → registrationDate = today - 4 日 (それ以前の同週日はチェックなし)
    final registrationDate =
        todayOnly.subtract(Duration(days: _daysCount - 1));

    return Row(
      children: List.generate(7, (i) {
        final cellDate = monday.add(Duration(days: i));
        final isToday = cellDate.isAtSameMomentAs(todayOnly);
        // 過去日かつ登録日以降のセルだけ「達成済」扱い (登録前の日は空セル)
        final isPast = cellDate.isBefore(todayOnly) &&
            !cellDate.isBefore(registrationDate);
        return Expanded(
          child: Center(
            child: _CalendarCell(
              dayLabel: days[i],
              isToday: isToday,
              isPast: isPast,
              stampScale: isToday ? _stampScale : null,
              stampOpacity: isToday ? _stampOpacity : null,
            ),
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Dialog(
      backgroundColor: AppTheme.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── タイトル ────────────────────────────────────
            Text(
              l10n.habitLoginBonusTitle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),

            // ── 7 日カレンダー ─────────────────────────────
            _buildCalendar(l10n),
            const SizedBox(height: 24),

            // ── 報酬表示 (ダイヤ) ──────────────────────────
            FadeTransition(
              opacity: _stampOpacity,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppTheme.primary.withValues(alpha: 0.40),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('💎', style: TextStyle(fontSize: 22)),
                    const SizedBox(width: 8),
                    Text(
                      '+$_amount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Day 1 のみ: チケット bonus 表示 ──────────────
            if (_grantedDaily > 0 || _grantedWeekly > 0) ...[
              const SizedBox(height: 10),
              FadeTransition(
                opacity: _stampOpacity,
                child: Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (_grantedDaily > 0)
                      _ticketChip(
                          icon: '🎟️',
                          label: l10n.habitLoginBonusTicketDaily(_grantedDaily)),
                    if (_grantedWeekly > 0)
                      _ticketChip(
                          icon: '🎫',
                          label: l10n.habitLoginBonusTicketWeekly(_grantedWeekly)),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 18),

            // ── サビ口調メッセージ ────────────────────────
            Text(
              _sabiMessage(l10n),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),

            // ── 閉じるボタン ──────────────────────────────
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  l10n.habitLoginBonusCloseButton,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ticketChip({required String icon, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(icon, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// 7 日カレンダーの 1 セル。
class _CalendarCell extends StatelessWidget {
  final String dayLabel;
  final bool isToday;
  final bool isPast;
  final Animation<double>? stampScale;
  final Animation<double>? stampOpacity;

  const _CalendarCell({
    required this.dayLabel,
    required this.isToday,
    required this.isPast,
    this.stampScale,
    this.stampOpacity,
  });

  @override
  Widget build(BuildContext context) {
    // 【BUG-126 (2026-06-14)】36 → 32 に縮小 (狭画面端末でのフィット余裕確保、
    // 親 Row が Expanded 配置になったため Center で揃う)。
    final cellSize = 32.0;
    final Color borderColor;
    final Color bgColor;
    if (isToday) {
      borderColor = AppTheme.primary;
      bgColor = AppTheme.primary.withValues(alpha: 0.12);
    } else if (isPast) {
      borderColor = Colors.white.withValues(alpha: 0.18);
      bgColor = Colors.white.withValues(alpha: 0.04);
    } else {
      borderColor = Colors.white.withValues(alpha: 0.08);
      bgColor = Colors.transparent;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          dayLabel,
          style: TextStyle(
            color: isToday ? AppTheme.primary : Colors.white54,
            fontSize: 11,
            fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: cellSize,
          height: cellSize,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bgColor,
            shape: BoxShape.circle,
            border: Border.all(color: borderColor, width: isToday ? 2 : 1),
          ),
          child: isToday && stampScale != null
              ? FadeTransition(
                  opacity: stampOpacity!,
                  child: ScaleTransition(
                    scale: stampScale!,
                    child: const Text(
                      '🪶',
                      style: TextStyle(fontSize: 18),
                    ),
                  ),
                )
              : isPast
                  ? const Icon(Icons.check,
                      size: 16, color: Colors.white38)
                  : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
